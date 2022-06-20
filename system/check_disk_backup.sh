#!/bin/sh

THRESHOLD=90
df -H | grep -vE '^Filesystem|tmpfs|cdrom' | awk '{ print $5 " " $1 }' | while read output;
do
  used=$(echo $output | awk '{ print $1}' | cut -d'%' -f1  )
  partition=$(echo $output | awk '{ print $2 }' )
  if [ $used -ge $THRESHOLD ]; then
    echo "Running out of space \"$partition ($usep%)\" on $(hostname) as on $(date)"
    exit 1;
  elif
    exit 0;
  fi
done