#!/bin/bash

# Checks the Sensu backend on this host is working, not just running.
# Usage: check_sensu_backend.sh [health_url] [agent_warn] [agent_crit]
HEALTH_URL="${1:-http://127.0.0.1:8080/health}"
AGENT_WARN="${2:-55}"
AGENT_CRIT="${3:-30}"
PORTS="8080 8081 3000"

CRITS=""
WARNS=""

# Service
if ! systemctl is-active --quiet sensu-backend; then
  CRITS="$CRITS sensu-backend service not active;"
fi

# Backend health (etcd members and alarms)
health=$(curl -sk -m 5 "$HEALTH_URL")
if [ -z "$health" ]; then
  CRITS="$CRITS no response from $HEALTH_URL;"
elif echo "$health" | grep -q '"Healthy":false'; then
  CRITS="$CRITS etcd member unhealthy;"
elif ! echo "$health" | grep -q '"Alarms":null'; then
  CRITS="$CRITS etcd alarm raised;"
fi

# API, agent websocket and web UI ports
for port in $PORTS; do
  if [ "$(ss -Htln "( sport = :$port )" | wc -l)" -eq 0 ]; then
    CRITS="$CRITS port $port not listening;"
  fi
done

# Connected agents
agents=$(ss -Htn state established '( sport = :8081 )' | wc -l)
if [ "$agents" -lt "$AGENT_CRIT" ]; then
  CRITS="$CRITS only $agents agents connected;"
elif [ "$agents" -lt "$AGENT_WARN" ]; then
  WARNS="$WARNS only $agents agents connected;"
fi

# etcd timeouts in the last 10 minutes
timeouts=$(journalctl -u sensu-backend --since "-10 min" --no-pager -q 2>/dev/null | grep -c 'etcdserver: request timed out')
if [ "$timeouts" -gt 0 ]; then
  WARNS="$WARNS $timeouts etcd timeouts in last 10 min;"
fi

if [ -n "$CRITS" ]; then
  echo "Sensu Backend is CRITICAL:$CRITS$WARNS on $(hostname) as on $(date)"
  exit 2
elif [ -n "$WARNS" ]; then
  echo "Sensu Backend is WARNING:$WARNS on $(hostname) as on $(date)"
  exit 1
fi
echo "Sensu Backend is OK ($agents agents connected) on $(hostname) as on $(date)"
exit 0
