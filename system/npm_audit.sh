#!/bin/bash

set -u

CONFIG_FILE="${1:-/usr/local/dualtone/projects.txt}"
WARN_ON_MODERATE=true

OK=0
WARNING=1
CRITICAL=2

worst_exit=$OK
output=""

set_worst() {
  [ "$1" -gt "$worst_exit" ] && worst_exit="$1"
}

log() {
  output="${output}${1}\n"
}

fmt_timestamp() {
  local ts="$1"
  if date --version >/dev/null 2>&1; then
    date -d "@$ts" "+%Y-%m-%d %H:%M:%S" 2>/dev/null
  else
    date -r "$ts" "+%Y-%m-%d %H:%M:%S" 2>/dev/null
  fi
}

get_mtime() {
  local file="$1"
  if [ "$(uname)" = "Darwin" ]; then
    stat -f %m "$file" 2>/dev/null
  else
    stat -c %Y "$file" 2>/dev/null
  fi
}

if [ ! -f "$CONFIG_FILE" ]; then
  printf "NODE_SECURITY OK - No config file at %s, nothing to check\n" "$CONFIG_FILE"
  exit 0
fi

projects=()
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%%#*}"
  line=$(printf "%s" "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -z "$line" ] && continue
  projects+=("$line")
done < "$CONFIG_FILE"

if [ ${#projects[@]} -eq 0 ]; then
  printf "NODE_SECURITY OK - No project paths found in %s\n" "$CONFIG_FILE"
  exit 0
fi

node_ver=$(node --version 2>/dev/null || echo "not found")
npm_ver=$(npm --version 2>/dev/null || echo "not found")

for project in "${projects[@]}"; do
  if [ ! -d "$project" ]; then
    log "  SKIP $(basename "$project") (directory not found)"
    log ""
    continue
  fi

  project_name=$(basename "$project")
  log "  [$project_name] $project"

  # --- project info ---

  dep_count=0
  if [ -d "$project/node_modules" ]; then
    dep_count=$(find "$project/node_modules" -maxdepth 1 -mindepth 1 -type d ! -name ".*" 2>/dev/null | wc -l | tr -d ' ')
  fi

  last_install="unknown"
  if [ -f "$project/node_modules/.package-lock.json" ]; then
    install_ts=$(get_mtime "$project/node_modules/.package-lock.json")
    if [ -n "$install_ts" ]; then
      last_install=$(fmt_timestamp "$install_ts")
    fi
  fi

  log "  deps: $dep_count | last install: $last_install"

  # -------------------------------------------------------
  # CHECK 1: phantom dependencies
  # -------------------------------------------------------
  if [ -d "$project/node_modules" ] && [ -f "$project/package-lock.json" ]; then
    lock_pkgs=$(sed -n 's|.*"node_modules/\([^"/]*\)".*|\1|p' "$project/package-lock.json" 2>/dev/null | sort -u)

    for dir in "$project/node_modules"/*/; do
      [ ! -d "$dir" ] && continue
      pkg=$(basename "$dir")
      case "$pkg" in .*)  continue ;; esac
      case "$pkg" in @*)  continue ;; esac

      if ! printf "%s\n" "$lock_pkgs" | grep -qx "$pkg"; then
        if [ -f "$dir/package.json" ] && grep -q '"postinstall"' "$dir/package.json" 2>/dev/null; then
          log "  CRITICAL phantom dep with postinstall: $pkg"
          set_worst $CRITICAL
        else
          log "  WARNING  phantom dep (not in lockfile): $pkg"
          set_worst $WARNING
        fi
      fi
    done
  fi

  # -------------------------------------------------------
  # CHECK 2: suspicious postinstall hooks
  # -------------------------------------------------------
  if [ -d "$project/node_modules" ]; then
    safe_names="node-gyp|husky|patch-package|esbuild|electron|sharp|better-sqlite3|bcrypt|canvas|grpc|puppeteer|prisma|sqlite3|turbo|swc|lmdb|msgpackr-extract|cpu-features|prebuild-install|parcel|ngcc|core-js"

    find "$project/node_modules" -maxdepth 3 -name "package.json" \
      -not -path "*/node_modules/*/node_modules/*" 2>/dev/null | while IFS= read -r pkg_json; do

      postinstall_cmd=$(sed -n 's/.*"postinstall"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$pkg_json" 2>/dev/null)
      [ -z "$postinstall_cmd" ] && continue

      pkg_dir=$(dirname "$pkg_json")
      pkg=$(basename "$pkg_dir")

      if printf "%s" "$pkg" | grep -qEi "$safe_names"; then
        continue
      fi
      if printf "%s" "$postinstall_cmd" | grep -qEi "node-gyp|prebuild-install|husky|patch-package"; then
        continue
      fi

      if printf "%s" "$postinstall_cmd" | grep -qEi "curl |wget |http://|https://|eval |exec(Sync)?|chmod |/tmp/|\.sh[[:space:]]|\.py[[:space:]]|nohup|osascript"; then
        log "  CRITICAL suspicious postinstall in $pkg: $postinstall_cmd"
        set_worst $CRITICAL
      fi
    done
  fi

  # -------------------------------------------------------
  # CHECK 3: lockfile integrity
  # -------------------------------------------------------
  if [ -f "$project/package-lock.json" ] && [ -f "$project/node_modules/.package-lock.json" ]; then
    lock_mod=$(get_mtime "$project/package-lock.json")
    hidden_mod=$(get_mtime "$project/node_modules/.package-lock.json")

    if [ -n "$lock_mod" ] && [ -n "$hidden_mod" ] && [ "$lock_mod" -gt "$hidden_mod" ]; then
      lock_date=$(fmt_timestamp "$lock_mod")
      install_date=$(fmt_timestamp "$hidden_mod")
      log "  WARNING  lockfile ($lock_date) newer than last install ($install_date)"
      set_worst $WARNING
    fi
  fi

  # -------------------------------------------------------
  # CHECK 4: npm audit
  # -------------------------------------------------------
  if [ ! -f "$project/package-lock.json" ] && [ ! -f "$project/npm-shrinkwrap.json" ]; then
    log "  SKIP no lockfile, cannot audit"
    log ""
    continue
  fi

  audit_json=$(cd "$project" && npm audit --json 2>/dev/null) || true

  critical=$(printf "%s" "$audit_json" | sed -n 's/.*"critical":\([0-9]*\).*/\1/p' | head -1)
  high=$(printf "%s" "$audit_json" | sed -n 's/.*"high":\([0-9]*\).*/\1/p' | head -1)
  moderate=$(printf "%s" "$audit_json" | sed -n 's/.*"moderate":\([0-9]*\).*/\1/p' | head -1)
  low=$(printf "%s" "$audit_json" | sed -n 's/.*"low":\([0-9]*\).*/\1/p' | head -1)

  critical=${critical:-0}
  high=${high:-0}
  moderate=${moderate:-0}
  low=${low:-0}

  total=$((critical + high + moderate + low))

  if [ "$critical" -gt 0 ] || [ "$high" -gt 0 ]; then
    log "  CRITICAL audit: $critical critical, $high high, $moderate moderate, $low low"
    set_worst $CRITICAL
  elif [ "$WARN_ON_MODERATE" = true ] && [ "$moderate" -gt 0 ]; then
    log "  WARNING  audit: $critical critical, $high high, $moderate moderate, $low low"
    set_worst $WARNING
  elif [ "$total" -gt 0 ]; then
    log "  OK       audit: $total low severity"
  else
    log "  OK       audit: clean"
  fi

  # list individual vulnerabilities if any critical or high
  if [ "$critical" -gt 0 ] || [ "$high" -gt 0 ]; then
    printf "%s" "$audit_json" | sed -n 's/.*"name":"\([^"]*\)".*"severity":"\(critical\|high\)".*"url":"\([^"]*\)".*/\1|\2|\3/p' | sort -u | while IFS='|' read -r vname vsev vurl; do
      log "           -> $vname ($vsev) $vurl"
    done

    # fallback: some npm audit json formats differ, try alternate parse
    if ! printf "%s" "$audit_json" | grep -q '"name".*"severity".*"url"'; then
      printf "%s" "$audit_json" | sed -n '/"severity"[[:space:]]*:[[:space:]]*"\(critical\|high\)"/{ 
        N; N; N; N; N
        s/.*"module_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*"severity"[[:space:]]*:[[:space:]]*"\([^"]*\)".*"url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1|\2|\3/p
      }' 2>/dev/null | sort -u | while IFS='|' read -r vname vsev vurl; do
        [ -n "$vname" ] && log "           -> $vname ($vsev) $vurl"
      done
    fi
  fi

  log ""
done

case $worst_exit in
  $OK)       label="OK" ;;
  $WARNING)  label="WARNING" ;;
  $CRITICAL) label="CRITICAL" ;;
esac

printf "NODE_SECURITY %s - %d project(s) | node %s | npm %s\n" "$label" "${#projects[@]}" "$node_ver" "$npm_ver"
printf "%b" "$output"

exit $worst_exit