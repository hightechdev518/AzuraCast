#!/usr/bin/env bash
#
# Apply pending Doctrine migrations by inspecting LIVE schema state first.
#
# For each pending version (in order):
#   1. Parse addSql(...) strings from the migration's up() method
#   2. For each DDL target (table / column / index / constraint), query
#      information_schema (via SHOW TABLES / SHOW COLUMNS / SHOW INDEX /
#      TABLE_CONSTRAINTS) to see whether the desired end-state already holds
#   3. If EVERY checkable target is already satisfied →
#        migrations:version FQCN --add -n   (SKIPPED-already-present)
#      NEVER runs the migration SQL in this case
#   4. If anything is still missing / unknown / non-DDL →
#        migrations:execute FQCN --up -n    (EXECUTED)
#
# No error-message parsing. Decisions are based only on schema probes.
#
# Run INSIDE the AzuraCast web container, e.g.:
#   docker compose exec --user=azuracast web bash util/apply_pending_migrations_by_schema.sh
#
# Exit codes:
#   0  — all pending migrations executed or skip-marked; New count is 0
#   1  — unexpected failure
#   3  — failed to parse pending list / New count / version identity
#
set -uo pipefail

OUTCOME_LOG="${OUTCOME_LOG:-/var/azuracast/storage/migration_schema_outcomes.log}"
DECISION_LOG="${DECISION_LOG:-/var/azuracast/storage/migration_schema_decisions.log}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTRACT_HELPER="${SCRIPT_DIR}/migration_schema_extract.php"
SPLIT_HELPER="${SCRIPT_DIR}/migration_schema_split_alter.php"
if [[ ! -f "$EXTRACT_HELPER" && -f /var/azuracast/www/util/migration_schema_extract.php ]]; then
  EXTRACT_HELPER="/var/azuracast/www/util/migration_schema_extract.php"
  SPLIT_HELPER="/var/azuracast/www/util/migration_schema_split_alter.php"
fi

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

# Resolve migration source directory (Docker symlink layout vs repo checkout).
MIGRATION_DIR=""
for candidate in \
  /var/azuracast/www/backend/src/Entity/Migration \
  /var/azuracast/www/src/Entity/Migration \
  "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/backend/src/Entity/Migration"
do
  if [[ -d "$candidate" ]]; then
    MIGRATION_DIR="$candidate"
    break
  fi
done

if [[ -z "$MIGRATION_DIR" ]]; then
  echo "ERROR: could not locate Entity/Migration directory." >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTCOME_LOG")" "$(dirname "$DECISION_LOG")"
touch "$OUTCOME_LOG" "$DECISION_LOG"

echo "==> Outcome log:  $OUTCOME_LOG"
echo "==> Decision log: $DECISION_LOG"
echo "==> Migrations:   $MIGRATION_DIR"
echo "==> CLI:          ${CLI[*]}"
echo

# ---------------------------------------------------------------------------
# MariaDB / MySQL client (schema probes)
# ---------------------------------------------------------------------------

DB_HOST="${MYSQL_HOST:-localhost}"
DB_PORT="${MYSQL_PORT:-3306}"
DB_NAME="${MYSQL_DATABASE:-azuracast}"
DB_USER="${MYSQL_USER:-azuracast}"
DB_PASS="${MYSQL_PASSWORD:-}"

if command -v mariadb >/dev/null 2>&1; then
  DB_BIN=mariadb
elif command -v mysql >/dev/null 2>&1; then
  DB_BIN=mysql
else
  echo "ERROR: neither mariadb nor mysql client found for schema probes." >&2
  exit 1
fi

db_query() {
  # Run a SQL query; print result rows (tab-separated). Exit non-zero on client error.
  local sql="$1"
  if [[ -n "$DB_PASS" ]]; then
    "$DB_BIN" \
      --host="$DB_HOST" \
      --port="$DB_PORT" \
      --user="$DB_USER" \
      --password="$DB_PASS" \
      --database="$DB_NAME" \
      --batch --skip-column-names --raw \
      -e "$sql" 2>/dev/null
  else
    "$DB_BIN" \
      --host="$DB_HOST" \
      --port="$DB_PORT" \
      --user="$DB_USER" \
      --database="$DB_NAME" \
      --batch --skip-column-names --raw \
      -e "$sql" 2>/dev/null
  fi
}

db_scalar() {
  local sql="$1"
  local out
  out="$(db_query "$sql" || true)"
  # Trim whitespace / newlines
  echo -n "$out" | tr -d '\r' | head -n1 | sed -E 's/^[[:space:]]+|[[:space:]]+$//g'
}

# ---------------------------------------------------------------------------
# Schema existence helpers (information_schema via SHOW / SELECT)
# ---------------------------------------------------------------------------

table_exists() {
  local table="$1"
  local n
  n="$(db_scalar "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = '${table}'")"
  [[ "$n" == "1" ]]
}

column_exists() {
  local table="$1"
  local column="$2"
  local n
  n="$(db_scalar "SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = '${table}' AND COLUMN_NAME = '${column}'")"
  [[ "$n" == "1" ]]
}

index_exists() {
  local table="$1"
  local index_name="$2"
  local n
  n="$(db_scalar "SELECT COUNT(*) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = '${table}' AND INDEX_NAME = '${index_name}'")"
  [[ "$n" =~ ^[1-9][0-9]*$ ]]
}

constraint_exists() {
  local table="$1"
  local constraint_name="$2"
  local n
  n="$(db_scalar "SELECT COUNT(*) FROM information_schema.TABLE_CONSTRAINTS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = '${table}' AND CONSTRAINT_NAME = '${constraint_name}'")"
  [[ "$n" =~ ^[1-9][0-9]*$ ]]
}

# ---------------------------------------------------------------------------
# Console helpers (same live-capture pattern as skip_failed_migrations.sh)
# ---------------------------------------------------------------------------

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

log_outcome() {
  local result="$1"
  local fqcn="$2"
  local reason="${3:-}"
  local line
  line="$(date -u +'%Y-%m-%dT%H:%M:%SZ')  ${result}  ${fqcn}"
  if [[ -n "$reason" ]]; then
    line="${line}  — ${reason}"
  fi
  echo "$line" | tee -a "$OUTCOME_LOG"
}

log_decision() {
  local fqcn="$1"
  local decision="$2"
  local detail="$3"
  local line
  line="$(date -u +'%Y-%m-%dT%H:%M:%SZ')  ${decision}  ${fqcn}  ${detail}"
  echo "$line" | tee -a "$DECISION_LOG"
}

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

parse_pending_fqcns() {
  local cleaned="$1"
  local line version fqcn

  while IFS= read -r line; do
    echo "$line" | grep -Eiq 'not migrated' || continue
    echo "$line" | grep -Eiq 'migrated, not available' && continue

    version="$(echo "$line" | grep -Eo 'Version[0-9]{14}' | head -n1 || true)"
    if [[ -z "$version" ]]; then
      continue
    fi

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

fqcn_to_file() {
  local fqcn="$1"
  local version
  version="$(echo "$fqcn" | grep -Eo 'Version[0-9]{14}' | head -n1 || true)"
  if [[ -z "$version" ]]; then
    echo ""
    return 1
  fi
  echo "${MIGRATION_DIR}/${version}.php"
}

# Strip outer backticks / quotes from an identifier.
unquote_ident() {
  local s="$1"
  s="${s#\`}"
  s="${s%\`}"
  s="${s#\"}"
  s="${s%\"}"
  s="${s#\'}"
  s="${s%\'}"
  echo -n "$s"
}

# ---------------------------------------------------------------------------
# Extract addSql('...') string literals from up()
# ---------------------------------------------------------------------------

extract_up_sql() {
  local file="$1"
  if [[ ! -f "$EXTRACT_HELPER" ]]; then
    return 0
  fi
  php "$EXTRACT_HELPER" "$file" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Classify one SQL statement → emit check lines:
#   NEED|<kind>|<table>|<name>|<human>
#   OK_IF_PRESENT|<kind>|<table>|<name>|<human>   (ADD/CREATE: skip if present)
#   OK_IF_ABSENT|<kind>|<table>|<name>|<human>    (DROP: skip if absent)
#   UNKNOWN|<reason>
# ---------------------------------------------------------------------------

classify_sql() {
  local sql="$1"
  local upper table name rest

  # Normalize
  sql="$(echo "$sql" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
  upper="$(echo "$sql" | tr '[:lower:]' '[:upper:]')"

  # ---- CREATE TABLE ----
  if [[ "$upper" =~ ^CREATE[[:space:]]+TABLE ]]; then
    # CREATE TABLE [IF NOT EXISTS] name
    table="$(echo "$sql" | sed -E 's/^CREATE[[:space:]]+[Tt][Aa][Bb][Ll][Ee][[:space:]]+([Ii][Ff][[:space:]]+[Nn][Oo][Tt][[:space:]]+[Ee][Xx][Ii][Ss][Tt][Ss][[:space:]]+)?[`"]?([A-Za-z0-9_]+)[`"]?.*/\2/')"
    if [[ -n "$table" && "$table" != "$sql" ]]; then
      echo "OK_IF_PRESENT|table|${table}||CREATE TABLE ${table}"
      return 0
    fi
    echo "UNKNOWN|unparseable CREATE TABLE"
    return 0
  fi

  # ---- DROP TABLE ----
  if [[ "$upper" =~ ^DROP[[:space:]]+TABLE ]]; then
    table="$(echo "$sql" | sed -E 's/^DROP[[:space:]]+[Tt][Aa][Bb][Ll][Ee][[:space:]]+([Ii][Ff][[:space:]]+[Ee][Xx][Ii][Ss][Tt][Ss][[:space:]]+)?[`"]?([A-Za-z0-9_]+)[`"]?.*/\2/')"
    if [[ -n "$table" && "$table" != "$sql" ]]; then
      echo "OK_IF_ABSENT|table|${table}||DROP TABLE ${table}"
      return 0
    fi
    echo "UNKNOWN|unparseable DROP TABLE"
    return 0
  fi

  # ---- CREATE [UNIQUE|FULLTEXT|SPATIAL] INDEX name ON table ----
  if [[ "$upper" =~ ^CREATE[[:space:]]+(UNIQUE[[:space:]]+|FULLTEXT[[:space:]]+|SPATIAL[[:space:]]+)?INDEX ]]; then
    name="$(echo "$sql" | sed -E 's/^CREATE[[:space:]]+([Uu][Nn][Ii][Qq][Uu][Ee][[:space:]]+|[Ff][Uu][Ll][Ll][Tt][Ee][Xx][Tt][[:space:]]+|[Ss][Pp][Aa][Tt][Ii][Aa][Ll][[:space:]]+)?[Ii][Nn][Dd][Ee][Xx][[:space:]]+[`"]?([A-Za-z0-9_]+)[`"]?[[:space:]]+[Oo][Nn][[:space:]]+[`"]?([A-Za-z0-9_]+)[`"]?.*/\2/')"
    table="$(echo "$sql" | sed -E 's/^CREATE[[:space:]]+([Uu][Nn][Ii][Qq][Uu][Ee][[:space:]]+|[Ff][Uu][Ll][Ll][Tt][Ee][Xx][Tt][[:space:]]+|[Ss][Pp][Aa][Tt][Ii][Aa][Ll][[:space:]]+)?[Ii][Nn][Dd][Ee][Xx][[:space:]]+[`"]?([A-Za-z0-9_]+)[`"]?[[:space:]]+[Oo][Nn][[:space:]]+[`"]?([A-Za-z0-9_]+)[`"]?.*/\3/')"
    name="$(unquote_ident "$name")"
    table="$(unquote_ident "$table")"
    if [[ -n "$name" && -n "$table" && "$table" != "$sql" ]]; then
      echo "OK_IF_PRESENT|index|${table}|${name}|CREATE INDEX ${name} ON ${table}"
      return 0
    fi
    echo "UNKNOWN|unparseable CREATE INDEX"
    return 0
  fi

  # ---- DROP INDEX name ON table ----
  if [[ "$upper" =~ ^DROP[[:space:]]+INDEX ]]; then
    name="$(echo "$sql" | sed -E 's/^DROP[[:space:]]+[Ii][Nn][Dd][Ee][Xx][[:space:]]+[`"]?([A-Za-z0-9_]+)[`"]?[[:space:]]+[Oo][Nn][[:space:]]+[`"]?([A-Za-z0-9_]+)[`"]?.*/\1/')"
    table="$(echo "$sql" | sed -E 's/^DROP[[:space:]]+[Ii][Nn][Dd][Ee][Xx][[:space:]]+[`"]?([A-Za-z0-9_]+)[`"]?[[:space:]]+[Oo][Nn][[:space:]]+[`"]?([A-Za-z0-9_]+)[`"]?.*/\2/')"
    name="$(unquote_ident "$name")"
    table="$(unquote_ident "$table")"
    if [[ -n "$name" && -n "$table" && "$table" != "$sql" ]]; then
      echo "OK_IF_ABSENT|index|${table}|${name}|DROP INDEX ${name} ON ${table}"
      return 0
    fi
    echo "UNKNOWN|unparseable DROP INDEX"
    return 0
  fi

  # ---- ALTER TABLE … ----
  if [[ "$upper" =~ ^ALTER[[:space:]]+TABLE ]]; then
    table="$(echo "$sql" | sed -E 's/^ALTER[[:space:]]+[Tt][Aa][Bb][Ll][Ee][[:space:]]+[`"]?([A-Za-z0-9_]+)[`"]?[[:space:]]+(.*)$/\1/')"
    rest="$(echo "$sql" | sed -E 's/^ALTER[[:space:]]+[Tt][Aa][Bb][Ll][Ee][[:space:]]+[`"]?([A-Za-z0-9_]+)[`"]?[[:space:]]+(.*)$/\2/')"
    table="$(unquote_ident "$table")"

    if [[ -z "$table" || "$table" == "$sql" ]]; then
      echo "UNKNOWN|unparseable ALTER TABLE"
      return 0
    fi

    # Anything we cannot safely preflight → force EXECUTE.
    if echo "$rest" | grep -Eiq \
      '\b(CHANGE|MODIFY|RENAME|CONVERT|ORDER BY|DISABLE|ENABLE|ALGORITHM|LOCK)\b'; then
      echo "UNKNOWN|ALTER TABLE contains CHANGE/MODIFY/RENAME/etc. (${table})"
      return 0
    fi

    local emitted=0
    local piece col idx

    # Split on commas that introduce a new ADD/DROP clause. Keep it simple:
    # walk ADD / DROP tokens with a regex scan over the rest string.
    # Process ADD COLUMN / ADD <col> / ADD INDEX|KEY|UNIQUE|FULLTEXT|CONSTRAINT
    # and DROP COLUMN / DROP INDEX|KEY|FOREIGN KEY / DROP <col>

    # Use PHP for robust clause splitting on ALTER TABLE bodies.
    while IFS= read -r piece; do
      [[ -z "$piece" ]] && continue
      local pu
      pu="$(echo "$piece" | tr '[:lower:]' '[:upper:]')"

      if [[ "$pu" =~ ^ADD[[:space:]]+(COLUMN[[:space:]]+)? ]]; then
        # ADD INDEX / KEY / UNIQUE / FULLTEXT / SPATIAL / CONSTRAINT → not a column
        if [[ "$pu" =~ ^ADD[[:space:]]+(CONSTRAINT|INDEX|KEY|UNIQUE|FULLTEXT|SPATIAL|PRIMARY) ]]; then
          if [[ "$pu" =~ ^ADD[[:space:]]+CONSTRAINT ]]; then
            idx="$(echo "$piece" | sed -E 's/^ADD[[:space:]]+[Cc][Oo][Nn][Ss][Tt][Rr][Aa][Ii][Nn][Tt][[:space:]]+[`"]?([A-Za-z0-9_]+)[`"]?.*/\1/')"
            idx="$(unquote_ident "$idx")"
            if [[ -n "$idx" && "$idx" != "$piece" ]]; then
              echo "OK_IF_PRESENT|constraint|${table}|${idx}|ADD CONSTRAINT ${idx} ON ${table}"
              emitted=1
            else
              echo "UNKNOWN|unparseable ADD CONSTRAINT on ${table}"
              emitted=1
            fi
          else
            # ADD [UNIQUE|FULLTEXT|SPATIAL] INDEX|KEY name
            idx="$(echo "$piece" | sed -E 's/^ADD[[:space:]]+(([Uu][Nn][Ii][Qq][Uu][Ee]|[Ff][Uu][Ll][Ll][Tt][Ee][Xx][Tt]|[Ss][Pp][Aa][Tt][Ii][Aa][Ll])[[:space:]]+)?([Ii][Nn][Dd][Ee][Xx]|[Kk][Ee][Yy]|[Pp][Rr][Ii][Mm][Aa][Rr][Yy][[:space:]]+[Kk][Ee][Yy])[[:space:]]+[`"]?([A-Za-z0-9_]+)[`"]?.*/\4/')"
            idx="$(unquote_ident "$idx")"
            if [[ -n "$idx" && "$idx" != "$piece" ]]; then
              echo "OK_IF_PRESENT|index|${table}|${idx}|ADD INDEX ${idx} ON ${table}"
              emitted=1
            else
              # PRIMARY KEY without name
              if [[ "$pu" =~ PRIMARY[[:space:]]+KEY ]]; then
                echo "OK_IF_PRESENT|index|${table}|PRIMARY|ADD PRIMARY KEY ON ${table}"
                emitted=1
              else
                echo "UNKNOWN|unparseable ADD INDEX on ${table}"
                emitted=1
              fi
            fi
          fi
        else
          # ADD [COLUMN] col_name …
          col="$(echo "$piece" | sed -E 's/^ADD[[:space:]]+([Cc][Oo][Ll][Uu][Mm][Nn][[:space:]]+)?[`"]?([A-Za-z0-9_]+)[`"]?.*/\2/')"
          col="$(unquote_ident "$col")"
          if [[ -n "$col" && "$col" != "$piece" ]]; then
            echo "OK_IF_PRESENT|column|${table}|${col}|ADD COLUMN ${table}.${col}"
            emitted=1
          else
            echo "UNKNOWN|unparseable ADD COLUMN on ${table}"
            emitted=1
          fi
        fi
        continue
      fi

      if [[ "$pu" =~ ^DROP[[:space:]]+ ]]; then
        if [[ "$pu" =~ ^DROP[[:space:]]+(FOREIGN[[:space:]]+KEY|CONSTRAINT) ]]; then
          idx="$(echo "$piece" | sed -E 's/^DROP[[:space:]]+([Ff][Oo][Rr][Ee][Ii][Gg][Nn][[:space:]]+[Kk][Ee][Yy]|[Cc][Oo][Nn][Ss][Tt][Rr][Aa][Ii][Nn][Tt])[[:space:]]+[`"]?([A-Za-z0-9_]+)[`"]?.*/\2/')"
          idx="$(unquote_ident "$idx")"
          if [[ -n "$idx" && "$idx" != "$piece" ]]; then
            echo "OK_IF_ABSENT|constraint|${table}|${idx}|DROP CONSTRAINT ${idx} ON ${table}"
            emitted=1
          else
            echo "UNKNOWN|unparseable DROP CONSTRAINT on ${table}"
            emitted=1
          fi
        elif [[ "$pu" =~ ^DROP[[:space:]]+(INDEX|KEY) ]]; then
          idx="$(echo "$piece" | sed -E 's/^DROP[[:space:]]+([Ii][Nn][Dd][Ee][Xx]|[Kk][Ee][Yy])[[:space:]]+[`"]?([A-Za-z0-9_]+)[`"]?.*/\2/')"
          idx="$(unquote_ident "$idx")"
          if [[ -n "$idx" && "$idx" != "$piece" ]]; then
            echo "OK_IF_ABSENT|index|${table}|${idx}|DROP INDEX ${idx} ON ${table}"
            emitted=1
          else
            echo "UNKNOWN|unparseable DROP INDEX on ${table}"
            emitted=1
          fi
        elif [[ "$pu" =~ ^DROP[[:space:]]+PRIMARY[[:space:]]+KEY ]]; then
          echo "OK_IF_ABSENT|index|${table}|PRIMARY|DROP PRIMARY KEY ON ${table}"
          emitted=1
        else
          # DROP [COLUMN] col
          col="$(echo "$piece" | sed -E 's/^DROP[[:space:]]+([Cc][Oo][Ll][Uu][Mm][Nn][[:space:]]+)?[`"]?([A-Za-z0-9_]+)[`"]?.*/\2/')"
          col="$(unquote_ident "$col")"
          if [[ -n "$col" && "$col" != "$piece" ]]; then
            echo "OK_IF_ABSENT|column|${table}|${col}|DROP COLUMN ${table}.${col}"
            emitted=1
          else
            echo "UNKNOWN|unparseable DROP COLUMN on ${table}"
            emitted=1
          fi
        fi
        continue
      fi

      echo "UNKNOWN|unhandled ALTER clause on ${table}: ${piece}"
      emitted=1
    done < <(
      if [[ -f "$SPLIT_HELPER" ]]; then
        php "$SPLIT_HELPER" <<<"$rest" 2>/dev/null || true
      fi
    )

    if (( emitted == 0 )); then
      echo "UNKNOWN|ALTER TABLE ${table} produced no clauses"
    fi
    return 0
  fi

  # ---- DML / other ----
  if [[ "$upper" =~ ^(INSERT|UPDATE|DELETE|REPLACE|TRUNCATE|SET|CALL|CREATE[[:space:]]+(VIEW|TRIGGER|PROCEDURE|FUNCTION|EVENT)|DROP[[:space:]]+(VIEW|TRIGGER|PROCEDURE|FUNCTION|EVENT)|RENAME) ]]; then
    echo "UNKNOWN|non-schema / data statement: ${sql:0:80}"
    return 0
  fi

  echo "UNKNOWN|unrecognized SQL: ${sql:0:80}"
}

# Probe one classified check line. Prints:
#   SATISFIED|<human>|<detail>
#   NEEDED|<human>|<detail>
#   UNKNOWN|<human>
probe_check() {
  local line="$1"
  IFS='|' read -r mode kind table name human <<<"$line"

  case "$mode" in
    UNKNOWN)
      echo "UNKNOWN|${kind}"
      return 0
      ;;
    OK_IF_PRESENT)
      case "$kind" in
        table)
          if table_exists "$table"; then
            echo "SATISFIED|${human}|table ${table} already exists"
          else
            echo "NEEDED|${human}|table ${table} does not exist"
          fi
          ;;
        column)
          if column_exists "$table" "$name"; then
            echo "SATISFIED|${human}|column ${table}.${name} already exists"
          else
            echo "NEEDED|${human}|column ${table}.${name} does not exist"
          fi
          ;;
        index)
          if index_exists "$table" "$name"; then
            echo "SATISFIED|${human}|index ${table}.${name} already exists"
          else
            echo "NEEDED|${human}|index ${table}.${name} does not exist"
          fi
          ;;
        constraint)
          if constraint_exists "$table" "$name"; then
            echo "SATISFIED|${human}|constraint ${table}.${name} already exists"
          else
            echo "NEEDED|${human}|constraint ${table}.${name} does not exist"
          fi
          ;;
        *)
          echo "UNKNOWN|${human}"
          ;;
      esac
      ;;
    OK_IF_ABSENT)
      case "$kind" in
        table)
          if table_exists "$table"; then
            echo "NEEDED|${human}|table ${table} still exists (drop pending)"
          else
            echo "SATISFIED|${human}|table ${table} already absent"
          fi
          ;;
        column)
          if column_exists "$table" "$name"; then
            echo "NEEDED|${human}|column ${table}.${name} still exists (drop pending)"
          else
            echo "SATISFIED|${human}|column ${table}.${name} already absent"
          fi
          ;;
        index)
          if index_exists "$table" "$name"; then
            echo "NEEDED|${human}|index ${table}.${name} still exists (drop pending)"
          else
            echo "SATISFIED|${human}|index ${table}.${name} already absent"
          fi
          ;;
        constraint)
          if constraint_exists "$table" "$name"; then
            echo "NEEDED|${human}|constraint ${table}.${name} still exists (drop pending)"
          else
            echo "SATISFIED|${human}|constraint ${table}.${name} already absent"
          fi
          ;;
        *)
          echo "UNKNOWN|${human}"
          ;;
      esac
      ;;
    *)
      echo "UNKNOWN|${line}"
      ;;
  esac
}

# Decide SKIP vs EXECUTE for one migration file.
# Sets globals: DECISION (SKIP|EXECUTE), DECISION_REASON
analyze_migration() {
  local file="$1"
  local sql checks_out probe_out
  local -a sqls=()
  local -a reasons_sat=()
  local -a reasons_need=()
  local -a reasons_unk=()

  DECISION="EXECUTE"
  DECISION_REASON=""

  if [[ ! -f "$file" ]]; then
    DECISION="EXECUTE"
    DECISION_REASON="migration file not found; cannot preflight → execute"
    return 0
  fi

  mapfile -t sqls < <(extract_up_sql "$file")

  if (( ${#sqls[@]} == 0 )); then
    DECISION="EXECUTE"
    DECISION_REASON="no parseable addSql() literals in up(); cannot preflight → execute"
    return 0
  fi

  echo "    Parsed ${#sqls[@]} addSql statement(s) from up():"
  for sql in "${sqls[@]}"; do
    echo "      • ${sql:0:120}"
  done

  while IFS= read -r checks_out; do
    [[ -z "$checks_out" ]] && continue
    while IFS= read -r probe_out; do
      [[ -z "$probe_out" ]] && continue
      IFS='|' read -r status human detail <<<"$probe_out"
      case "$status" in
        SATISFIED)
          reasons_sat+=("${detail:-$human}")
          echo "      [schema] SATISFIED — ${detail:-$human}"
          ;;
        NEEDED)
          reasons_need+=("${detail:-$human}")
          echo "      [schema] NEEDED    — ${detail:-$human}"
          ;;
        *)
          reasons_unk+=("${human}")
          echo "      [schema] UNKNOWN   — ${human}"
          ;;
      esac
    done < <(probe_check "$checks_out")
  done < <(
    for sql in "${sqls[@]}"; do
      classify_sql "$sql"
    done
  )

  if (( ${#reasons_need[@]} > 0 )); then
    DECISION="EXECUTE"
    DECISION_REASON="still needed: $(IFS='; '; echo "${reasons_need[*]}")"
    return 0
  fi

  if (( ${#reasons_unk[@]} > 0 )); then
    DECISION="EXECUTE"
    DECISION_REASON="uncheckable SQL present: $(IFS='; '; echo "${reasons_unk[*]}")"
    return 0
  fi

  if (( ${#reasons_sat[@]} == 0 )); then
    DECISION="EXECUTE"
    DECISION_REASON="no schema checks produced; execute for safety"
    return 0
  fi

  DECISION="SKIP"
  DECISION_REASON="all targets already at desired state: $(IFS='; '; echo "${reasons_sat[*]}")"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

echo "==> Probing DB connectivity (${DB_BIN} ${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME})…"
if ! db_query "SELECT 1" >/dev/null; then
  echo "ERROR: cannot query database with ${DB_BIN}." >&2
  echo "Ensure MYSQL_HOST / MYSQL_USER / MYSQL_PASSWORD / MYSQL_DATABASE are set." >&2
  exit 1
fi
echo "    OK"
echo

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
  file="$(fqcn_to_file "$fqcn" || true)"

  echo
  echo "########################################################################"
  echo "## [${index}/${total}] ${fqcn}"
  echo "## file: ${file:-<unknown>}"
  echo "########################################################################"

  analyze_migration "$file"

  echo
  echo "--> Decision: ${DECISION}"
  echo "--> Reason:   ${DECISION_REASON}"

  if [[ "$DECISION" == "SKIP" ]]; then
    log_decision "$fqcn" "SKIPPED-already-present" "$DECISION_REASON"

    mark_out=""
    mark_rc=0
    set +e
    run_visible mark_out "${CLI[@]}" migrations:version "$fqcn" --add -n
    mark_rc=$?
    set -e

    if (( mark_rc != 0 )); then
      echo "ERROR: failed to mark ${fqcn} applied (migrations:version --add)." >&2
      exit 1
    fi

    log_outcome "SKIPPED-already-present" "$fqcn" "$DECISION_REASON"
    skipped=$((skipped + 1))
    continue
  fi

  log_decision "$fqcn" "EXECUTED" "$DECISION_REASON"

  exec_out=""
  exec_rc=0
  set +e
  run_visible exec_out "${CLI[@]}" migrations:execute "$fqcn" --up -n
  exec_rc=$?
  set -e

  if (( exec_rc != 0 )); then
    echo
    echo "ERROR: migrations:execute failed for ${fqcn}."
    echo "Preflight decided EXECUTE because: ${DECISION_REASON}"
    echo "Full execute output was printed above. Not marking as applied."
    exit 1
  fi

  log_outcome "EXECUTED" "$fqcn" "$DECISION_REASON"
  executed=$((executed + 1))
done

echo
echo "==> Finished schema-aware pass (executed=${executed}, skipped=${skipped})."
echo "==> Re-checking migrations:status…"
check_new_count

if [[ "${NEW_COUNT}" != "0" ]]; then
  echo "ERROR: finished the pending list but New is still ${NEW_COUNT}." >&2
  echo "Re-run this script, or inspect manually." >&2
  echo "Outcomes:  $OUTCOME_LOG" >&2
  echo "Decisions: $DECISION_LOG" >&2
  exit 1
fi

echo
echo "SUCCESS: all pending migrations processed; New = 0."
echo "---- outcomes ----"
cat "$OUTCOME_LOG"
echo "------------------"
exit 0
