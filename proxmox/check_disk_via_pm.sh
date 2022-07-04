#!/bin/bash

ID=$1

TOTAL=$(pct df $ID | tail -1 | awk '{print $3}')
AVAILABLE=$(pct df $ID | tail -1 | awk '{print $5}')
TOTAL_INT=${TOTAL::-1}
AVAILABLE_INT=${AVAILABLE::-1}
PERCENT=`echo "scale=4; $AVAILABLE_INT/$TOTAL_INT*100" | bc`
FINALPERCENT=${PERCENT::-2}

if (( $(echo "$FINALPERCENT > 15" | bc -l) )); then
        echo -e "${FINALPERCENT}% disk space remaining - OK"
        exit 0
elif (( $(echo "$FINALPERCENT > 5" | bc -l) )); then
        echo -e "${FINALPERCENT}% disk space remaining - WARNING"
        exit 1
else
        echo -e "${FINALPERCENT}% disk space remaining - CRITICAL"
        exit 2
fi