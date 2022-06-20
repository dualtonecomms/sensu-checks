#!/bin/sh

WARN=85
CRIT=95
df -H | grep -vE '^Filesystem|tmpfs|cdrom' | awk '{ print $5 " " $1 }' | while read output;
do
  used=$(echo $output | awk '{ print $1}' | cut -d'%' -f1  )
  partition=$(echo $output | awk '{ print $2 }' )
  if [ $used -lt $WARN ]; then
    echo "Disk Usage is OK \"$partition ($used%)\" on $(hostname) as on $(date)"
    exit 0;
  elif [ $used -lt $CRIT ]; then
    echo "Disk Usage is WARNING \"$partition ($used%)\" on $(hostname) as on $(date)"
    exit 1; 
  else
    echo "Disk Usage is CRITICAL \"$partition ($used%)\" on $(hostname) as on $(date)"
    exit 2;
  fi
done