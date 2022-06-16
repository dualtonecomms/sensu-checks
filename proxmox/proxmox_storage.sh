PERCENT=$(lvs | grep twi-aotz | awk '{print $5}')

if (( $(echo "$PERCENT < 70" | bc -l) )); then
	echo -e "$PERCENT - Storage Space OK"
	exit 0
elif (( $(echo "$PERCENT < 80" | bc -l) )); then
	echo -e "$PERCENT - Storage Space WARNING"
       	exit 1
else
	echo -e "$PERCENT - Storage Space CRITICAL"
	exit 2
fi
