#!/bin/bash

NAME=$(whoami)
PERCENT=$(lvdisplay | grep "Allocated pool data" | awk '{print $4}' 2> /dev/null)
PLAIN=${PERCENT::-1}

echo "$PLAIN"

#if (( $(echo "$PLAIN < 1" | bc -l) )); then
#	echo -e "$PERCENT - Storage Space OK"
#	exit 0
#elif (( $(echo "$PLAIN < 2" | bc -l) )); then
#	echo -e "$PERCENT - Storage Space WARNING"
#       	exit 1
#else
#	echo -e "$PERCENT - Storage Space CRITICAL"
#	exit 2
#fi

