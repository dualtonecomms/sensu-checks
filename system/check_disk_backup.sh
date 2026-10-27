#!/bin/sh

WARN=85
CRIT=95
LC_ALL=C
export LC_ALL

if ! disk_usage=$(df -HP 2>/dev/null); then
  echo 'DISK_USAGE UNKNOWN - could not read filesystem usage'
  exit 3
fi

printf '%s\n' "$disk_usage" | awk -v warn="$WARN" -v crit="$CRIT" '
  NR==1 { next }
  /tmpfs|cdrom/ { next }
  {
    if (NF < 6 || $5 !~ /^[0-9]+%$/) { invalid=1; next }
    percent=$5
    sub(/%$/, "", percent)
    percent+=0
    if (percent < 0 || percent > 100) { invalid=1; next }
    mount=$6
    for (i=7; i<=NF; i++) mount=mount " " $i
    level="OK"
    if (percent >= crit) { level="CRITICAL"; status=2 }
    else if (percent >= warn) {
      level="WARNING"
      if (status != 2) status=1
    }
    if (level != "OK" && affected_count < 3) {
      if (affected_count) affected=affected ", "
      affected=affected mount " (" percent "%)"
      affected_count++
    }
    lines[++count]=level " " $1 " on " mount ": " percent "%"
  }
  END {
    if (count == 0 || invalid) {
      if (status != 2) status=3
    }
    label=(status==2 ? "CRITICAL" : status==1 ? "WARNING" : status==3 ? "UNKNOWN" : "OK")
    printf "DISK_USAGE %s - %d filesystem(s) checked", label, count
    if (affected_count) printf "; %s", affected
    printf "\n"
    if (invalid) print "UNKNOWN: some filesystem output could not be read"
    for (i=1; i<=count; i++) print lines[i]
    exit status
  }'
