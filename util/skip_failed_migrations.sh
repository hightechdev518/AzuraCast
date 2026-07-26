#!/usr/bin/env bash
#
# Apply pending Doctrine migrations ONE AT A TIME via migrations:execute,
# so a failure cannot roll back earlier successes in the same run.
#
# For each pending version:
#   1. azuracast_cli migrations:execute 'App\Entity\Migration\Version…' --up -n
#   2. On success → log EXECUTED
#   3. On 'already exists' / 'doesn't exist' / 'can't drop…check that it exists'
#      → migrations:version … --add -n, log SKIPPED
#   4. On any other failure → stop and print the full error
#
# Run INSIDE the AzuraCast web container, e.g.:
#   docker compose exec --user=azuracast web bash util/skip_failed_migrations.sh
#
# Exit codes:
#   0  — all pending migrations executed or skip-marked; New count is 0
#   1  — unexpected migration error (refused to skip)
#   3  — failed to parse pending list / New count / version identity
#
set -uo pipefail

OUTCOME_LOG="${OUTCOME_LOG:-/var/azuracast/storage/migration_execute_outcomes.log}"
SKIP_LOG="${SKIP_LOG:-/var/azuracast/storage/skipped_migrations.log}"

CLI=(azuracast_cli)
if ! command -v azuracast_cli >/dev/null 2>&1; then
  if [[ -x /var/azuracast/www/bin/console ]]; then
    CLI=(php /var/azuracast/www/bin/console)
  elif [[ -x /var/azuracast/www/backend/bin/console ]]; then
    CLI=(php /var/azuracast/www/backend/bin/console)
  else
    echo "ERROR: azuracast_cli / bin/console not found." >&2
    exit 1
  fi
fi

mkdir -p "$(dirname "$OUTCOME_LOG")" "$(dirname "$SKIP_LOG")"
touch "$OUTCOME_LOG" "$SKIP_LOG"

echo "==> Outcome log: $OUTCOME_LOG"
echo "==> Skip log:    $SKIP_LOG"
echo "==> CLI:         ${CLI[*]}"
echo

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Run a command with argv printed, stream stdout+stderr live, and capture the
# full combined output into the nameref variable. Returns the command's exit code.
#
# Uses a real temp file (not var="$(cmd | tee)"), so:
#   - live output still appears on the terminal
#   - is_skippable_error always sees the full error text
#   - PIPESTATUS[0] is read in the same shell as the pipeline
run_visible() {
  local -n _capture="$1"
  shift

  local tmp rc
  tmp="$(mktemp)"
  rc=0

  echo
  echo "------------------------------------------------------------------------"
  echo "+ $*"
  echo "------------------------------------------------------------------------"

  set +e
  # Same-shell pipeline: cmd → tee → stdout (live) + temp file (capture).
  # PIPESTATUS[0] is the CLI exit code in THIS shell (not inside $()).
  "$@" 2>&1 | tee "$tmp"
  rc=${PIPESTATUS[0]}
  set -e

  _capture="$(cat "$tmp" 2>/dev/null || true)"
  rm -f "$tmp"

  echo "------------------------------------------------------------------------"
  echo "+ exit code: ${rc}"
  echo "------------------------------------------------------------------------"
  echo

  return "$rc"
}

strip_ansi() {
  # shellcheck disable=SC2001
  echo "$1" | sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g'
}

is_skippable_error() {
  local out="$1"
  # Idempotent schema-drift failures: object already present, or drop/alter of
  # something that is already gone (incl. MySQL 1091 "Can't DROP … check that it exists").
  echo "$out" | grep -Eiq \
    "already exists|doesn't exist|does not exist|check that it exists|can'?t drop"
}

log_outcome() {
  local result="$1"
  local fqcn="$2"
  local note="${3:-}"
  local line
  line="$(date -u +'%Y-%m-%dT%H:%M:%SZ')  ${result}  ${fqcn}"
  if [[ -n "$note" ]]; then
    line="${line}  (${note})"
  fi
  echo "$line" | tee -a "$OUTCOME_LOG"
  if [[ "$result" == "SKIPPED" ]]; then
    echo "$line" >>"$SKIP_LOG"
  fi
}

# Doctrine 3.9 status table uses a "New" cell under the Migrations group.
parse_new_count() {
  local cleaned line count
  cleaned="$(strip_ansi "$1")"

  line="$(
    echo "$cleaned" \
      | grep -E '(^|[|+│])[[:space:]]*New[[:space:]]*([|+│]|$)' \
      | grep -viE 'New[[:space:]]+Migrations|Namespace' \
      | head -n1 \
      || true
  )"
  if [[ -z "$line" ]]; then
    line="$(echo "$cleaned" | grep -iE 'New[[:space:]]+Migrations' | head -n1 || true)"
  fi
  if [[ -z "$line" ]]; then
    echo ""
    return 1
  fi

  count="$(echo "$line" | grep -Eo '[0-9]+' | tail -n1 || true)"
  [[ -n "$count" ]] || return 1
  echo "$count"
}

# Extract ordered FQCNs of pending migrations from `migrations:list`.
# Pending rows contain the status text "not migrated" (and not "migrated, not available").
parse_pending_fqcns() {
  local cleaned="$1"
  local line version fqcn

  while IFS= read -r line; do
    # Skip headers / separators / already-migrated rows.
    echo "$line" | grep -Eiq 'not migrated' || continue
    echo "$line" | grep -Eiq 'migrated, not available' && continue

    version="$(echo "$line" | grep -Eo 'Version[0-9]{14}' | head -n1 || true)"
    if [[ -z "$version" ]]; then
      continue
    fi

    # Prefer a full FQCN if present on the line; otherwise synthesize it.
    fqcn="$(echo "$line" | grep -Eo 'App\\Entity\\Migration\\Version[0-9]{14}' | head -n1 || true)"
    if [[ -z "$fqcn" ]]; then
      fqcn="App\\Entity\\Migration\\${version}"
    fi

    echo "$fqcn"
  done < <(echo "$cleaned")
}

check_new_count() {
  local status_out=""
  set +e
  run_visible status_out "${CLI[@]}" migrations:status
  set -e

  NEW_COUNT="$(parse_new_count "$status_out" || true)"
  if [[ -z "${NEW_COUNT}" ]]; then
    echo "ERROR: could not parse 'New' count from migrations:status." >&2
    exit 3
  fi
  echo "==> Parsed New count: ${NEW_COUNT}"
  echo
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Keep metadata storage schema in sync (same prelude as azuracast:setup:migrate).
sync_out=""
set +e
run_visible sync_out "${CLI[@]}" migrations:sync-metadata-storage
set -e

check_new_count
if [[ "${NEW_COUNT}" == "0" ]]; then
  echo "SUCCESS: no pending migrations (New = 0)."
  exit 0
fi

echo "==> Fetching ordered pending migration list…"
list_out=""
set +e
run_visible list_out "${CLI[@]}" migrations:list
set -e

cleaned_list="$(strip_ansi "$list_out")"
mapfile -t PENDING < <(parse_pending_fqcns "$cleaned_list")

if (( ${#PENDING[@]} == 0 )); then
  echo "ERROR: New count is ${NEW_COUNT}, but could not parse any 'not migrated' rows from migrations:list." >&2
  exit 3
fi

echo "==> Pending migrations to process (${#PENDING[@]}):"
for fqcn in "${PENDING[@]}"; do
  echo "    - $fqcn"
done
echo

executed=0
skipped=0
index=0
total=${#PENDING[@]}

for fqcn in "${PENDING[@]}"; do
  index=$((index + 1))
  echo
  echo "########################################################################"
  echo "## [${index}/${total}] ${fqcn}"
  echo "########################################################################"

  exec_out=""
  exec_rc=0
  set +e
  # One migration, isolated from the rest of the batch.
  run_visible exec_out "${CLI[@]}" migrations:execute "$fqcn" --up -n
  exec_rc=$?
  set -e

  if (( exec_rc == 0 )); then
    log_outcome "EXECUTED" "$fqcn"
    executed=$((executed + 1))
    continue
  fi

  if is_skippable_error "$exec_out"; then
    echo "--> Skippable failure; marking ${fqcn} as already applied…"
    mark_out=""
    mark_rc=0
    set +e
    run_visible mark_out "${CLI[@]}" migrations:version "$fqcn" --add -n
    mark_rc=$?
    set -e

    if (( mark_rc != 0 )); then
      echo "ERROR: failed to mark ${fqcn} applied after skippable execute failure." >&2
      echo "See command output above." >&2
      exit 1
    fi

    log_outcome "SKIPPED" "$fqcn" "idempotent schema drift"
    skipped=$((skipped + 1))
    continue
  fi

  echo
  echo "ERROR: unexpected failure executing ${fqcn}."
  echo "Refusing to skip blindly. Full execute output was printed above."
  exit 1
done

echo
echo "==> Finished per-migration pass (executed=${executed}, skipped=${skipped})."
echo "==> Re-checking migrations:status…"
check_new_count

if [[ "${NEW_COUNT}" != "0" ]]; then
  echo "ERROR: finished the pending list but New is still ${NEW_COUNT}." >&2
  echo "Re-run this script (new pending versions may have appeared), or inspect manually." >&2
  echo "Outcomes: $OUTCOME_LOG" >&2
  exit 1
fi

echo
echo "SUCCESS: all pending migrations processed; New = 0."
echo "---- outcomes ----"
cat "$OUTCOME_LOG"
echo "------------------"
exit 0
