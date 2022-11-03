#!/bin/bash

CHECK=`/usr/local/freeswitch/bin/fs_cli -x "sofia status profile internal"`

if
	echo "$CHECK" | grep -q "Invalid Profile!"; then
	echo "$CHECK"
	exit 2
elif
	echo "$CHECK" | grep -q "REGISTRATIONS"; then
	echo "$CHECK"
	exit 0
else
	echo "$CHECK"
	exit 1
fi
