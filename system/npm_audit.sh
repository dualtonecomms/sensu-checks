#!/bin/sh

CONFIG_FILE="${1:-/usr/local/dualtone/projects.txt}"
# advisories accepted per project; a missing file means nothing is allowed
ALLOW_FILE="${2:-/usr/local/dualtone/npm-audit-allow.txt}"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "NODE_SECURITY UNKNOWN - No config file at $CONFIG_FILE"
  exit 3
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
  echo "NODE_SECURITY UNKNOWN - No project paths found in $CONFIG_FILE"
  exit 3
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
    found=$(find /root/.nvm /home/*/.nvm /opt/nvm /usr/local /usr/lib \
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
  echo "NODE_SECURITY UNKNOWN - npm not found, cannot run audit | node ${node_ver:-not found}"
  exit 3
fi

# npm writes its cache and logs under $HOME/.npm, but the sensu user's HOME
# may not exist, so give it a throwaway cache for this run
npm_cache=$(mktemp -d "${TMPDIR:-/tmp}/.node_security_npm.XXXXXX") || {
  echo "NODE_SECURITY UNKNOWN - cannot create npm cache dir | node ${node_ver:-not found} | npm $npm_ver"
  exit 3
}
trap 'rm -rf "$npm_cache"' EXIT
export npm_config_cache="$npm_cache"
export npm_config_update_notifier=false

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
rm -f /tmp/.node_security_state.$$ /tmp/.node_security_output.$$ /tmp/.node_security_err.$$

# --- check each project ---

echo "$projects" | while IFS= read -r project; do
  [ -z "$project" ] && continue

  if [ ! -d "$project" ]; then
    echo "  UNKNOWN $(basename "$project") (directory not found)"
    echo "3" >> /tmp/.node_security_state.$$
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
    echo "  UNKNOWN no lockfile, cannot audit"
    echo "3" >> /tmp/.node_security_state.$$
    echo ""
    continue
  fi

  audit_err=/tmp/.node_security_err.$$
  audit_json=$(cd "$project" && "$NPM_BIN" audit --json 2>"$audit_err") || true
  npm_err=$(grep -m1 -E '^npm (ERR!|error) ' "$audit_err" 2>/dev/null | cut -c1-200)

  if [ -z "$audit_json" ]; then
    echo "  UNKNOWN audit returned no data${npm_err:+: $npm_err}"
    echo "3" >> /tmp/.node_security_state.$$
    echo ""
    continue
  fi

  # Prints "critical high moderate low" on the first line, then tagged lines:
  # ROW (alerting advisory), ALLOWED, EXPIRED and UNUSED (allowlist notes).
  # Counts are npm's per-package counts, except that an allowed advisory no
  # longer raises the package it is in or any package that depends on it.
  report=$(printf '%s' "$audit_json" | \
    NODE_SECURITY_ALLOW_FILE="$ALLOW_FILE" \
    NODE_SECURITY_PROJECT="$project" \
    NODE_SECURITY_NAME="$project_name" \
    "$NODE_BIN" -e '
    var fs = require("fs");
    var keys = ["critical", "high", "moderate", "low"];
    var rankOf = { low: 1, moderate: 2, high: 3, critical: 4 };

    function fail(message) {
      console.log(String(message).split("\n")[0].slice(0, 200));
      process.exitCode = 3;
    }

    function readAllowlist() {
      var file = process.env.NODE_SECURITY_ALLOW_FILE;
      var project = process.env.NODE_SECURITY_PROJECT;
      var name = process.env.NODE_SECURITY_NAME;
      var today = new Date().toISOString().slice(0, 10);
      var result = { allowed: {}, expired: [], specific: {} };
      var text;
      if (!file) return result;
      try {
        text = fs.readFileSync(file, "utf8");
      } catch (e) {
        if (e.code === "ENOENT") return result;
        throw new Error("cannot read allowlist " + file + ": " + e.code);
      }
      text.split("\n").forEach(function (raw, i) {
        var line = raw.replace(/#.*/, "").trim();
        if (!line) return;
        var parts = line.split(/\s+/);
        var where = "invalid allowlist entry at " + file + ":" + (i + 1);
        if (parts.length < 2 || parts.length > 3) {
          throw new Error(where + " (expected: project GHSA-id [YYYY-MM-DD])");
        }
        var id = parts[1].toUpperCase();
        var until = parts[2];
        if (!/^GHSA(-[0-9A-Z]{4}){3}$/.test(id)) throw new Error(where + " (bad advisory id " + parts[1] + ")");
        if (until && !/^\d{4}-\d{2}-\d{2}$/.test(until)) throw new Error(where + " (bad date " + until + ")");
        if (parts[0] !== "*" && parts[0] !== name && parts[0] !== project) return;
        if (until && until < today) {
          result.expired.push(id + " (expired " + until + ")");
          return;
        }
        result.allowed[id] = until || "";
        if (parts[0] !== "*") result.specific[id] = true;
      });
      return result;
    }

    var input = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", function (chunk) { input += chunk; });
    process.stdin.on("end", function () {
      var report;
      try {
        report = JSON.parse(input);
        var meta = report && report.metadata && report.metadata.vulnerabilities;
        if (!meta || report.error || keys.some(function (key) {
          return !Number.isSafeInteger(meta[key]) || meta[key] < 0;
        })) throw new Error("invalid audit report");
      } catch (_) {
        var reason = "";
        try {
          var err = report && (report.error || report);
          reason = (err && (err.summary || err.message || err.code)) || "";
        } catch (_) {}
        if (!report) reason = "output was not JSON";
        return fail("audit returned invalid or incomplete data" + (reason ? ": " + reason : ""));
      }

      var allow;
      try {
        allow = readAllowlist();
      } catch (e) {
        return fail(e.message);
      }

      var vulns = report.vulnerabilities || {};
      var seenAllowed = {};

      function advisoryId(via) {
        var match = String(via.url || "").match(/GHSA(-[0-9a-z]{4}){3}/i);
        return match ? match[0].toUpperCase() : "";
      }

      // highest severity reachable from pkg through advisories that are not allowed
      function effective(pkg, path) {
        if (path[pkg] || !vulns[pkg]) return 0;
        path[pkg] = true;
        var best = 0;
        (vulns[pkg].via || []).forEach(function (via) {
          var rank = 0;
          if (typeof via === "string") {
            rank = effective(via, path);
          } else if (via && typeof via === "object") {
            var id = advisoryId(via);
            if (id && id in allow.allowed) seenAllowed[id] = via.name || pkg;
            else rank = rankOf[via.severity] || 0;
          }
          if (rank > best) best = rank;
        });
        delete path[pkg];
        return best;
      }

      // npm rates each package by the advisories that really reach its version,
      // which the via chain cannot show, so npm stays the ceiling. A package only
      // drops below it when everything left it could reach is allowed or lower.
      var counts = { critical: 0, high: 0, moderate: 0, low: 0 };
      Object.keys(vulns).forEach(function (pkg) {
        var rank = Math.min(rankOf[vulns[pkg].severity] || 0, effective(pkg, {}));
        keys.forEach(function (key) { if (rankOf[key] === rank) counts[key]++; });
      });
      console.log(keys.map(function (key) { return counts[key]; }).join(" "));

      var seen = {};
      var rows = [];
      var allowedRows = [];
      Object.keys(vulns).forEach(function (pkg) {
        (vulns[pkg].via || []).forEach(function (via) {
          if (!via || typeof via !== "object" || !(via.severity in rankOf)) return;
          var row = { name: via.name || pkg, severity: via.severity, url: via.url || "", id: advisoryId(via) };
          var key = row.name + " " + row.url;
          if (seen[key]) return;
          seen[key] = true;
          if (row.id && row.id in allow.allowed) allowedRows.push(row);
          else if (rankOf[row.severity] >= rankOf.high) rows.push(row);
        });
      });
      function bySeverity(a, b) {
        return rankOf[b.severity] - rankOf[a.severity] || a.name.localeCompare(b.name);
      }
      rows.sort(bySeverity).forEach(function (row) {
        console.log("ROW " + row.name + " (" + row.severity + ") " + row.url);
      });
      allowedRows.sort(bySeverity).forEach(function (row) {
        var until = allow.allowed[row.id];
        console.log("ALLOWED " + row.name + " (" + row.severity + ") " + row.url + (until ? " until " + until : ""));
      });
      allow.expired.forEach(function (entry) { console.log("EXPIRED " + entry); });
      Object.keys(allow.specific).forEach(function (id) {
        if (!seenAllowed[id]) console.log("UNUSED " + id);
      });
    });
  ') || {
    reason=${report:-"audit returned invalid or incomplete data${npm_err:+: $npm_err}"}
    echo "  UNKNOWN $reason"
    echo "3" >> /tmp/.node_security_state.$$
    echo ""
    continue
  }

  # The first line is exactly four space-separated integers.
  # shellcheck disable=SC2046
  set -- $(printf '%s\n' "$report" | head -n 1)
  critical=$1
  high=$2
  moderate=$3
  low=$4
  allowed_count=$(printf '%s\n' "$report" | grep -c '^ALLOWED ')
  allowed_note=""
  [ "$allowed_count" -gt 0 ] && allowed_note=", $allowed_count allowed"

  # only high and critical advisories alert; moderate and low are reported as OK
  if [ "$critical" -gt 0 ] || [ "$high" -gt 0 ]; then
    echo "  CRITICAL audit: $critical critical, $high high, $moderate moderate, $low low$allowed_note"
    echo "2" >> /tmp/.node_security_state.$$
  elif [ $((moderate + low)) -gt 0 ]; then
    echo "  OK       audit: $moderate moderate, $low low (below alert threshold)$allowed_note"
  elif [ "$allowed_count" -gt 0 ]; then
    echo "  OK       audit: clean apart from $allowed_count allowed"
  else
    echo "  OK       audit: clean"
  fi

  # list each critical/high advisory, then what the allowlist is doing
  printf '%s\n' "$report" | sed -n \
    -e 's/^ROW /           -> /p' \
    -e 's/^ALLOWED /  INFO     allowed: /p' \
    -e 's/^EXPIRED /  INFO     allowlist entry no longer applies: /p' \
    -e 's/^UNUSED /  INFO     allowlist entry not needed any more: /p'

  echo ""
done > /tmp/.node_security_output.$$

# --- determine exit code ---

worst_exit=0
if [ -f /tmp/.node_security_state.$$ ]; then
  if grep -q "2" /tmp/.node_security_state.$$; then
    worst_exit=2
  elif grep -q "3" /tmp/.node_security_state.$$; then
    worst_exit=3
  elif grep -q "1" /tmp/.node_security_state.$$; then
    worst_exit=1
  fi
  rm -f /tmp/.node_security_state.$$
fi

case $worst_exit in
  0) label="OK" ;;
  1) label="WARNING" ;;
  2) label="CRITICAL" ;;
  3) label="UNKNOWN" ;;
esac

echo "NODE_SECURITY $label - $project_count project(s) | node ${node_ver:-not found} | npm $npm_ver"
cat /tmp/.node_security_output.$$
rm -f /tmp/.node_security_output.$$ /tmp/.node_security_err.$$

exit $worst_exit
