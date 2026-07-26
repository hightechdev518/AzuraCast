#!/usr/bin/env bash
#
# Automate marking idempotent/schema-drift migrations as "already applied"
# when azuracast:setup:migrate fails with the usual "already exists" /
# "doesn't exist" class of errors.
#
# IMPORTANT: Final SUCCESS is declared ONLY when `migrations:status` reports
# New Migrations == 0 — never based on migrate's exit code alone.
#
# Every command and its raw output is streamed live to the terminal.
#
# Run INSIDE the AzuraCast web container, e.g.:
#   docker compose exec --user=azuracast web bash util/skip_failed_migrations.sh
#
# Exit codes:
#   0  — New Migrations is 0 (done)
#   1  — unexpected migration error (refused to skip)
#   2  — hit the safety-cap without finishing
#   3  — failed to parse a Version* / New count from output
#
set -uo pipefail

MAX_ATTEMPTS="${MAX_ATTEMPTS:-60}"
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

mkdir -p "$(dirname "$SKIP_LOG")"
touch "$SKIP_LOG"

echo "==> Skip log: $SKIP_LOG"
echo "==> Safety cap: $MAX_ATTEMPTS attempts"
echo "==> CLI: ${CLI[*]}"
echo

# Run a command with its argv printed, stream stdout+stderr live, and capture
# the combined output into the nameref variable. Returns the command's exit code.
run_visible() {
  local -n _capture="$1"
  shift

  echo
  echo "------------------------------------------------------------------------"
  echo "+ $*"
  echo "------------------------------------------------------------------------"

  set +e
  # Stream live to the controlling TTY when available; otherwise stderr.
  local tee_target=/dev/stderr
  if [[ -w /dev/tty ]]; then
    tee_target=/dev/tty
  fi
  _capture="$("$@" 2>&1 | tee "$tee_target")"
  local rc=${PIPESTATUS[0]}
  set -e

  echo "------------------------------------------------------------------------"
  echo "+ exit code: ${rc}"
  echo "------------------------------------------------------------------------"
  echo

  return "$rc"
}

is_skippable_error() {
  local out="$1"
  echo "$out" | grep -Eiq "already exists|doesn't exist|does not exist"
}

parse_failed_version() {
  local out="$1"
  # Example:
  #   Migration App\Entity\Migration\Version20260717120000 failed during Execution.
  echo "$out" | grep -Eo 'Migration App\\Entity\\Migration\\Version[0-9]{14} failed' \
    | head -n1 \
    | grep -Eo 'Version[0-9]{14}' \
    || true
}

# Strip ANSI color codes from command output before parsing.
strip_ansi() {
  # shellcheck disable=SC2001
  echo "$1" | sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g'
}

# Parse the New count from Doctrine Migrations 3.x `migrations:status` table.
#
# Real format (rowspan group "Migrations") looks like:
#   | Migrations | Executed             | 250 |
#   |            | Executed Unavailable | 0   |
#   |            | Available            | 280 |
#   |            | New                  |  5  |
#
# When New > 0 the value cell is padded with spaces (e.g. " 5 "). The label
# is the single word "New" — NOT "New Migrations".
parse_new_count() {
  local out cleaned line count

  cleaned="$(strip_ansi "$1")"

  # Prefer an exact table-cell match for the label "New".
  # Matches both ASCII pipes and common box-drawing verticals.
  line="$(
    echo "$cleaned" \
      | grep -E '(^|[|+│])[[:space:]]*New[[:space:]]*([|+│]|$)' \
      | grep -viE 'New[[:space:]]+Migrations|Namespace' \
      | head -n1 \
      || true
  )"

  # Fallback: older Doctrine text style "New Migrations: 5"
  if [[ -z "$line" ]]; then
    line="$(echo "$cleaned" | grep -iE 'New[[:space:]]+Migrations' | head -n1 || true)"
  fi

  if [[ -z "$line" ]]; then
    echo ""
    return 1
  fi

  # Value is the last integer on that row (handles "  12  " padding).
  count="$(echo "$line" | grep -Eo '[0-9]+' | tail -n1 || true)"
  if [[ -z "$count" ]]; then
    echo ""
    return 1
  fi

  echo "$count"
  return 0
}

# Run migrations:status, print New count, set NEW_COUNT. Exit 3 if unparsable.
check_new_count() {
  local status_out=""
  local rc=0

  set +e
  run_visible status_out "${CLI[@]}" migrations:status
  rc=$?
  set -e

  # Status can be non-zero in some edge cases; still try to parse New count.
  NEW_COUNT="$(parse_new_count "$status_out" || true)"
  if [[ -z "${NEW_COUNT}" ]]; then
    echo "ERROR: could not parse 'New' count from migrations:status table output." >&2
    echo "Expected a table row like: | New | 5 |" >&2
    echo "Raw status output was printed above for manual review." >&2
    exit 3
  fi

  echo "==> Parsed New count: ${NEW_COUNT}"
  echo

  return 0
}

attempt=0
while (( attempt < MAX_ATTEMPTS )); do
  attempt=$((attempt + 1))
  echo
  echo "########################################################################"
  echo "## Attempt ${attempt}/${MAX_ATTEMPTS}"
  echo "########################################################################"

  migrate_out=""
  migrate_rc=0
  set +e
  run_visible migrate_out "${CLI[@]}" azuracast:setup:migrate
  migrate_rc=$?
  set -e

  # Always verify with status — never trust migrate exit code alone.
  NEW_COUNT=""
  check_new_count

  if [[ "${NEW_COUNT}" == "0" ]]; then
    echo
    echo "SUCCESS: migrations:status reports New Migrations = 0 (attempt ${attempt})."
    if [[ -s "$SKIP_LOG" ]]; then
      echo "Skipped versions were logged to: $SKIP_LOG"
      echo "---- skipped versions ----"
      cat "$SKIP_LOG"
      echo "--------------------------"
    fi
    exit 0
  fi

  echo "==> Still ${NEW_COUNT} new migration(s) pending — migrate exit was ${migrate_rc}."

  # Pending work remains. If migrate exited 0, do NOT stop — loop and retry.
  # Only skip-mark when migrate actually failed with a known idempotent error.
  if (( migrate_rc == 0 )); then
    echo "WARNING: migrate exited 0 but New count is still ${NEW_COUNT}."
    echo "         Looping to retry migrate automatically (attempt will increment)."
    echo
    continue
  fi

  version="$(parse_failed_version "$migrate_out")"
  if [[ -z "$version" ]]; then
    echo
    echo "ERROR: migrate failed and New=${NEW_COUNT}, but no"
    echo "       'Migration App\\Entity\\Migration\\Version… failed' line was found."
    echo "Refusing to guess. See migrate output above for manual review."
    exit 3
  fi

  if ! is_skippable_error "$migrate_out"; then
    echo
    echo "ERROR: migration ${version} failed with an unexpected error"
    echo "       (not 'already exists' / 'doesn't exist')."
    echo "Refusing to skip blindly. See migrate output above for manual review."
    exit 1
  fi

  fqcn="App\\Entity\\Migration\\${version}"
  echo "--> Skippable failure on ${version}; marking as already applied…"
  echo "$(date -u +'%Y-%m-%dT%H:%M:%SZ')  SKIPPED  ${version}  (New was ${NEW_COUNT})" >>"$SKIP_LOG"

  mark_out=""
  mark_rc=0
  set +e
  run_visible mark_out "${CLI[@]}" migrations:version "$fqcn" --add -n
  mark_rc=$?
  set -e

  if (( mark_rc != 0 )); then
    echo
    echo "ERROR: failed to mark ${fqcn} as applied (migrations:version --add)."
    echo "See command output above for manual review."
    exit 1
  fi

  echo "--> Marked ${fqcn} applied; re-checking New count, then looping to retry migrate…"
  check_new_count
  if [[ "${NEW_COUNT}" == "0" ]]; then
    echo
    echo "SUCCESS: migrations:status reports New = 0 after marking ${version}."
    if [[ -s "$SKIP_LOG" ]]; then
      echo "Skipped versions were logged to: $SKIP_LOG"
      echo "---- skipped versions ----"
      cat "$SKIP_LOG"
      echo "--------------------------"
    fi
    exit 0
  fi

  echo "==> New is still ${NEW_COUNT} after skip-mark; continuing loop to run migrate again."
  echo
done

echo
echo "ERROR: hit safety cap of ${MAX_ATTEMPTS} attempts without New Migrations = 0."
echo "Skipped versions so far are in: $SKIP_LOG"
exit 2
