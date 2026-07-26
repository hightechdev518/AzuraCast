#!/usr/bin/env bash
#
# Automate marking idempotent/schema-drift migrations as "already applied"
# when azuracast:setup:migrate fails with the usual "already exists" /
# "doesn't exist" class of errors.
#
# Run INSIDE the AzuraCast web container, e.g.:
#   docker compose exec --user=azuracast web bash util/skip_failed_migrations.sh
#   # or, if the script is copied into the container:
#   bash /path/to/skip_failed_migrations.sh
#
# Exit codes:
#   0  — migrate completed successfully (possibly after skips)
#   1  — unexpected migration error (full output printed)
#   2  — hit the safety-cap without finishing
#   3  — failed to parse a Version* from the error output
#
set -uo pipefail

MAX_ATTEMPTS="${MAX_ATTEMPTS:-60}"
SKIP_LOG="${SKIP_LOG:-/var/azuracast/storage/skipped_migrations.log}"
TMP_OUT="$(mktemp)"
trap 'rm -f "$TMP_OUT"' EXIT

CLI=(azuracast_cli)
if ! command -v azuracast_cli >/dev/null 2>&1; then
  # Fallback when running against a bind-mounted checkout without the wrapper.
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
echo

# True if output looks like the idempotent schema-drift failures we skip.
is_skippable_error() {
  local out="$1"
  # Case-insensitive match for the patterns we've been hitting manually.
  echo "$out" | grep -Eiq \
    "already exists|doesn't exist|does not exist"
}

# Extract VersionYYYYMMDDHHMMSS from Doctrine failure line.
parse_failed_version() {
  local out="$1"
  # Example:
  #   Migration App\Entity\Migration\Version20260717120000 failed during Execution.
  echo "$out" | grep -Eo 'Migration App\\Entity\\Migration\\Version[0-9]{14} failed' \
    | head -n1 \
    | grep -Eo 'Version[0-9]{14}' \
    || true
}

attempt=0
while (( attempt < MAX_ATTEMPTS )); do
  attempt=$((attempt + 1))
  echo "==> [${attempt}/${MAX_ATTEMPTS}] Running: ${CLI[*]} azuracast:setup:migrate"

  set +e
  "${CLI[@]}" azuracast:setup:migrate >"$TMP_OUT" 2>&1
  status=$?
  set -e

  if (( status == 0 )); then
    echo
    echo "SUCCESS: migrations completed cleanly on attempt ${attempt}."
    if [[ -s "$SKIP_LOG" ]]; then
      echo "Skipped versions were logged to: $SKIP_LOG"
      echo "---- skipped versions ----"
      cat "$SKIP_LOG"
      echo "--------------------------"
    fi
    exit 0
  fi

  output="$(cat "$TMP_OUT")"
  version="$(parse_failed_version "$output")"

  if [[ -z "$version" ]]; then
    echo
    echo "ERROR: migrate failed, but no 'Migration App\\Entity\\Migration\\Version… failed' line was found."
    echo "Full output follows for manual review:"
    echo "======================================"
    echo "$output"
    echo "======================================"
    exit 3
  fi

  if ! is_skippable_error "$output"; then
    echo
    echo "ERROR: migration ${version} failed with an unexpected error (not 'already exists' / 'doesn't exist')."
    echo "Refusing to skip blindly. Full output follows for manual review:"
    echo "======================================"
    echo "$output"
    echo "======================================"
    exit 1
  fi

  fqcn="App\\Entity\\Migration\\${version}"
  echo "--> Skippable failure on ${version}; marking as already applied…"
  echo "$(date -u +'%Y-%m-%dT%H:%M:%SZ')  SKIPPED  ${version}" >>"$SKIP_LOG"

  set +e
  "${CLI[@]}" migrations:version "$fqcn" --add -n >>"$TMP_OUT" 2>&1
  mark_status=$?
  set -e

  if (( mark_status != 0 )); then
    echo
    echo "ERROR: failed to mark ${fqcn} as applied (migrations:version --add)."
    echo "Full output follows for manual review:"
    echo "======================================"
    cat "$TMP_OUT"
    echo "======================================"
    exit 1
  fi

  echo "--> Marked ${fqcn} applied; retrying migrate…"
  echo
done

echo
echo "ERROR: hit safety cap of ${MAX_ATTEMPTS} attempts without a clean migrate."
echo "Skipped versions so far are in: $SKIP_LOG"
exit 2
