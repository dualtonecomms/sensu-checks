#!/bin/sh
# HTTP availability and response-time check. Retry transient failures once.

usage() {
    printf 'RESPONSE: UNKNOWN - %s\n' "$1"
    printf 'Usage: %s -w <warning ms> -c <critical ms> -u <url> [-nocert] [-e <exact response body>]\n' "$0"
    exit 3
}

WARN=
CRIT=
URL=
NOCERT=
EXPECTED_BODY=
while getopts ':w:c:u:n:e:' option; do
    case "$option" in
        w) WARN=$OPTARG ;;
        c) CRIT=$OPTARG ;;
        u) URL=$OPTARG ;;
        n) NOCERT=1 ;;
        e) [ -n "$OPTARG" ] || usage 'Expected response body cannot be empty'
           EXPECTED_BODY=$OPTARG ;;
        *) usage 'Missing or invalid option' ;;
    esac
done

case "$WARN" in ''|*[!0-9]*) usage 'Warning must be an integer in milliseconds' ;; esac
case "$CRIT" in ''|*[!0-9]*) usage 'Critical must be an integer in milliseconds' ;; esac
[ "$CRIT" -ge "$WARN" ] || usage 'Critical must be at least the warning threshold'
[ -n "$URL" ] || usage 'URL not set'
for dependency in curl awk mktemp cmp; do
    command -v "$dependency" >/dev/null 2>&1 || usage "$dependency is required"
done

HTTP_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/sensu-web.XXXXXX") || usage 'Cannot create temporary directory'
trap 'rm -f "$HTTP_TMPDIR/body" "$HTTP_TMPDIR/error" "$HTTP_TMPDIR/expected"; rmdir "$HTTP_TMPDIR"' 0
trap 'exit 3' HUP INT TERM
printf '%s' "$EXPECTED_BODY" > "$HTTP_TMPDIR/expected"

# Leave enough time to classify a slow response, with two attempts inside 15s at -c 5000.
MAX_TIME=$(LC_ALL=C awk -v critical="$CRIT" 'BEGIN { printf "%.3f", critical / 1000 + 1 }')
set -- --silent --show-error --location --max-redirs 5 --proto '=http,https' --proto-redir '=http,https' \
    --max-time "$MAX_TIME" --header 'Cache-Control: no-cache' \
    --output "$HTTP_TMPDIR/body" --write-out '%{http_code} %{time_total}' --url "$URL"
[ -z "$NOCERT" ] || set -- "$@" --insecure

ATTEMPT=1
FIRST_MESSAGE=
while :; do
    : > "$HTTP_TMPDIR/body"
    METRICS=$(curl --disable "$@" 2> "$HTTP_TMPDIR/error")
    CURL_STATUS=$?
    HTTP_STATUS=${METRICS%% *}
    TOTAL_SECONDS=${METRICS#* }
    TIMEDIFF=$(LC_ALL=C awk -v seconds="$TOTAL_SECONDS" 'BEGIN { printf "%.0f", int(seconds * 1000) }')
    STATUS=CRITICAL
    EXIT_STATUS=2
    RETRY=

    if [ "$CURL_STATUS" -ne 0 ]; then
        OUTMSG=$(awk 'NR == 1 { print; exit }' "$HTTP_TMPDIR/error")
        [ -n "$OUTMSG" ] || OUTMSG="curl failed with exit code $CURL_STATUS"
        case "$CURL_STATUS" in 5|6|7|18|28|35|52|55|56) RETRY=1 ;; esac
    elif [ "$HTTP_STATUS" -lt 200 ] || [ "$HTTP_STATUS" -ge 300 ]; then
        OUTMSG="HTTP $HTTP_STATUS"
    elif [ ! -s "$HTTP_TMPDIR/body" ]; then
        OUTMSG='Empty response body'
    elif [ -n "$EXPECTED_BODY" ] && ! cmp -s "$HTTP_TMPDIR/expected" "$HTTP_TMPDIR/body"; then
        OUTMSG='Unexpected response body'
    else
        OUTMSG="$TIMEDIFF ms"
        if [ "$TIMEDIFF" -lt "$WARN" ]; then
            STATUS=OK
            EXIT_STATUS=0
        elif [ "$TIMEDIFF" -lt "$CRIT" ]; then
            STATUS=WARNING
            EXIT_STATUS=1
            RETRY=1
        else
            RETRY=1
        fi
    fi

    if [ "$ATTEMPT" -eq 1 ] && [ -n "$RETRY" ]; then
        FIRST_MESSAGE="$STATUS - $OUTMSG"
        ATTEMPT=2
        sleep 0.2
        continue
    fi
    [ "$ATTEMPT" -eq 1 ] || OUTMSG="$OUTMSG (after retry; first attempt: $FIRST_MESSAGE)"
    printf 'RESPONSE: %s - %s|Response=%sms;%s;%s;0\n' "$STATUS" "$OUTMSG" "$TIMEDIFF" "$WARN" "$CRIT"
    exit "$EXIT_STATUS"
done
