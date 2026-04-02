#!/bin/sh

CONFIG_FILE="${1:-/usr/local/dualtone/projects.txt}"
WARN_ON_MODERATE=true

if [ ! -f "$CONFIG_FILE" ]; then
  echo "NODE_SECURITY OK - No config file at $CONFIG_FILE, nothing to check"
  exit 0
fi

projects=""
while IFS= read -r line || [ -n "$line" ]; do
  clean="${line%%#*}"
  clean=$(echo "$clean" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -z "$clean" ] && continue
  projects="$projects
$clean"
done < "$CONFIG_FILE"
projects=$(echo "$projects" | sed '/^$/d')

if [ -z "$projects" ]; then
  echo "NODE_SECURITY OK - No project paths found in $CONFIG_FILE"
  exit 0
fi

project_count=$(echo "$projects" | wc -l | tr -d ' ')

# --- find node/npm ---
# 1. check PATH
# 2. scan common locations and nvm directories
# 3. last resort: find on the filesystem
if [ -z "$(command -v node 2>/dev/null)" ] || [ -z "$(command -v npm 2>/dev/null)" ]; then
  found=""
  for p in /usr/local/bin /usr/bin /opt/node/bin; do
    if [ -x "$p/node" ] && [ -x "$p/npm" ]; then
      found="$p"
      break
    fi
  done

  if [ -z "$found" ]; then
    found=$(find /root/.nvm /home/*/.nvm /opt/nvm /usr/local /usr/lib 2>/dev/null \
      -name node -type f -executable 2>/dev/null \
      | sort -V | tail -1 \
      | xargs dirname 2>/dev/null)
  fi

  if [ -z "$found" ]; then
    found=$(find / -name node -type f -executable \
      -not -path "*/node_modules/*" \
      -not -path "/proc/*" \
      -not -path "/sys/*" \
      2>/dev/null | sort -V | tail -1 | xargs dirname 2>/dev/null)
  fi

  if [ -n "$found" ]; then
    export PATH="$found:$PATH"
  fi
fi

NODE_BIN=$(command -v node 2>/dev/null)
NPM_BIN=$(command -v npm 2>/dev/null)

node_ver=""
npm_ver=""
[ -n "$NODE_BIN" ] && node_ver=$("$NODE_BIN" --version 2>/dev/null)
[ -n "$NPM_BIN" ] && npm_ver=$("$NPM_BIN" --version 2>/dev/null)

# if we still can't find npm, we can't audit anything
if [ -z "$NPM_BIN" ]; then
  echo "NODE_SECURITY WARNING - npm not found, cannot run audit | node ${node_ver:-not found}"
  exit 1
fi

# --- helpers ---

get_mtime() {
  if [ "$(uname)" = "Darwin" ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

fmt_ts() {
  ts="$1"
  if date --version >/dev/null 2>&1; then
    date -d "@$ts" "+%Y-%m-%d %H:%M:%S" 2>/dev/null
  else
    date -r "$ts" "+%Y-%m-%d %H:%M:%S" 2>/dev/null
  fi
}

# --- clean up any stale temp files ---
rm -f /tmp/.node_security_state.$$ /tmp/.node_security_output.$$

# --- check each project ---

echo "$projects" | while IFS= read -r project; do
  [ -z "$project" ] && continue

  if [ ! -d "$project" ]; then
    echo "  SKIP $(basename "$project") (directory not found)"
    echo ""
    continue
  fi

  project_name=$(basename "$project")
  echo "  [$project_name] $project"

  dep_count=0
  if [ -d "$project/node_modules" ]; then
    dep_count=$(find "$project/node_modules" -maxdepth 1 -mindepth 1 -type d ! -name ".*" 2>/dev/null | wc -l | tr -d ' ')
  fi

  last_install="unknown"
  if [ -f "$project/node_modules/.package-lock.json" ]; then
    install_ts=$(get_mtime "$project/node_modules/.package-lock.json")
    if [ -n "$install_ts" ]; then
      last_install=$(fmt_ts "$install_ts")
    fi
  fi

  echo "  deps: $dep_count | last install: $last_install"

  # --- phantom dependencies ---
  if [ -d "$project/node_modules" ] && [ -f "$project/package-lock.json" ]; then
    lock_pkgs=$(sed -n 's|.*"node_modules/\([^"/]*\)".*|\1|p' "$project/package-lock.json" 2>/dev/null | sort -u)

    for dir in "$project/node_modules"/*/; do
      [ ! -d "$dir" ] && continue
      pkg=$(basename "$dir")
      case "$pkg" in .*) continue ;; esac
      case "$pkg" in @*) continue ;; esac

      if ! echo "$lock_pkgs" | grep -qx "$pkg"; then
        if [ -f "$dir/package.json" ] && grep -q '"postinstall"' "$dir/package.json" 2>/dev/null; then
          echo "  CRITICAL phantom dep with postinstall: $pkg"
          echo "2" >> /tmp/.node_security_state.$$
        else
          echo "  WARNING  phantom dep (not in lockfile): $pkg"
          echo "1" >> /tmp/.node_security_state.$$
        fi
      fi
    done
  fi

  # --- suspicious postinstall hooks ---
  if [ -d "$project/node_modules" ]; then
    safe_names="node-gyp|husky|patch-package|esbuild|electron|sharp|better-sqlite3|bcrypt|canvas|grpc|puppeteer|prisma|sqlite3|turbo|swc|lmdb|msgpackr-extract|cpu-features|prebuild-install|parcel|ngcc|core-js"

    find "$project/node_modules" -maxdepth 3 -name "package.json" \
      -not -path "*/node_modules/*/node_modules/*" 2>/dev/null | while IFS= read -r pkg_json; do

      postinstall_cmd=$(sed -n 's/.*"postinstall"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$pkg_json" 2>/dev/null)
      [ -z "$postinstall_cmd" ] && continue

      pkg_dir=$(dirname "$pkg_json")
      pkg=$(basename "$pkg_dir")

      echo "$pkg" | grep -qEi "$safe_names" && continue
      echo "$postinstall_cmd" | grep -qEi "node-gyp|prebuild-install|husky|patch-package" && continue

      if echo "$postinstall_cmd" | grep -qEi "curl |wget |http://|https://|eval |exec(Sync)?|chmod |/tmp/|\.sh[[:space:]]|\.py[[:space:]]|nohup|osascript"; then
        echo "  CRITICAL suspicious postinstall in $pkg: $postinstall_cmd"
        echo "2" >> /tmp/.node_security_state.$$
      fi
    done
  fi

  # --- lockfile integrity ---
  if [ -f "$project/package-lock.json" ] && [ -f "$project/node_modules/.package-lock.json" ]; then
    lock_mod=$(get_mtime "$project/package-lock.json")
    hidden_mod=$(get_mtime "$project/node_modules/.package-lock.json")

    if [ -n "$lock_mod" ] && [ -n "$hidden_mod" ] && [ "$lock_mod" -gt "$hidden_mod" ]; then
      lock_date=$(fmt_ts "$lock_mod")
      install_date=$(fmt_ts "$hidden_mod")
      echo "  INFO     lockfile ($lock_date) newer than last install ($install_date) - npm install may be pending"
    fi
  fi

  # --- npm audit ---
  if [ ! -f "$project/package-lock.json" ] && [ ! -f "$project/npm-shrinkwrap.json" ]; then
    echo "  SKIP no lockfile, cannot audit"
    echo ""
    continue
  fi

  audit_json=$(cd "$project" && "$NPM_BIN" audit --json 2>/dev/null) || true

  if [ -z "$audit_json" ]; then
    echo "  SKIP audit returned no data"
    echo ""
    continue
  fi

  critical=$(echo "$audit_json" | sed -n 's/.*"critical":\([0-9]*\).*/\1/p' | head -1)
  high=$(echo "$audit_json" | sed -n 's/.*"high":\([0-9]*\).*/\1/p' | head -1)
  moderate=$(echo "$audit_json" | sed -n 's/.*"moderate":\([0-9]*\).*/\1/p' | head -1)
  low=$(echo "$audit_json" | sed -n 's/.*"low":\([0-9]*\).*/\1/p' | head -1)

  critical=${critical:-0}
  high=${high:-0}
  moderate=${moderate:-0}
  low=${low:-0}

  total=$((critical + high + moderate + low))

  if [ "$critical" -gt 0 ] || [ "$high" -gt 0 ]; then
    echo "  CRITICAL audit: $critical critical, $high high, $moderate moderate, $low low"
    echo "2" >> /tmp/.node_security_state.$$
  elif [ "$WARN_ON_MODERATE" = true ] && [ "$moderate" -gt 0 ]; then
    echo "  WARNING  audit: $critical critical, $high high, $moderate moderate, $low low"
    echo "1" >> /tmp/.node_security_state.$$
  elif [ "$total" -gt 0 ]; then
    echo "  OK       audit: $total low severity"
  else
    echo "  OK       audit: clean"
  fi

  if [ "$critical" -gt 0 ] || [ "$high" -gt 0 ]; then
    echo "$audit_json" | sed -n 's/.*"name":"\([^"]*\)".*"severity":"\(critical\|high\)".*"url":"\([^"]*\)".*/\1|\2|\3/p' | sort -u | while IFS='|' read -r vname vsev vurl; do
      echo "           -> $vname ($vsev) $vurl"
    done
  fi

  echo ""
done > /tmp/.node_security_output.$$

# --- determine exit code ---

worst_exit=0
if [ -f /tmp/.node_security_state.$$ ]; then
  if grep -q "2" /tmp/.node_security_state.$$; then
    worst_exit=2
  elif grep -q "1" /tmp/.node_security_state.$$; then
    worst_exit=1
  fi
  rm -f /tmp/.node_security_state.$$
fi

case $worst_exit in
  0) label="OK" ;;
  1) label="WARNING" ;;
  2) label="CRITICAL" ;;
esac

echo "NODE_SECURITY $label - $project_count project(s) | node ${node_ver:-not found} | npm $npm_ver"
cat /tmp/.node_security_output.$$
rm -f /tmp/.node_security_output.$$

exit $worst_exit