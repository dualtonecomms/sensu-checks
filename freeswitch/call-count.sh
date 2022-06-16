if { /usr/local/dualtone/sensu-checks/freeswitch/fscli-check.pl -q show-calls-count 2>&1 >&3 3>&- | grep '^' >&2; } 3>&1; then
  exit 1;
fi
