#!/bin/bash

USER=$(whoami)
STORAGE=$(/usr/local/dualtone/sensu-checks/proxmox/pve-storage.sh 2> /dev/null)

#echo "$USER $STORAGE"

if (( $(echo "$STORAGE < 80" | bc -l) )); then
        echo -e "$STORAGE - Storage Space OK"
        exit 0
elif (( $(echo "$STORAGE < 85" | bc -l) )); then
        echo -e "$STORAGE - Storage Space WARNING"
        exit 1
else
        echo -e "$STORAGE - Storage Space CRITICAL"
        exit 2
fi
