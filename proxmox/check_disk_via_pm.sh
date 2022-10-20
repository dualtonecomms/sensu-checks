 #!/bin/bash
 
 if [ -z "$1" ]; then
     echo  "No given proxmox ID"; exit 2
 else
     echo -ne "Proxmox ID Parsed - "
 fi
 
 ID=$1
 LOGLINE=$(wc -l /var/log/proxmox.$1.log | awk '{print $1}')
 
 if [ $LOGLINE == "2" ]; then
     echo -ne "Log file has 2 lines - "
 else
     echo "Log file does not have a suitable value and is not multiple lines"
     echo "$(cat /var/log/proxmox.$1.log)"
     exit 1
 fi
 
 TOTAL=$(cat /var/log/proxmox.${1}.log | tail -1 | awk '{print $3}')
 AVAILABLE=$(cat /var/log/proxmox.${1}.log | tail -1 | awk '{print $5}')
 TOTAL_INT=${TOTAL::-1}
 AVAILABLE_INT=${AVAILABLE::-1}
 
 echo -ne "Converted to integers successfully - "
 
 PERCENT=$(echo "scale=4; $AVAILABLE_INT/$TOTAL_INT*100" | bc)
 
 echo -ne "Maths complete - "
 FINALPERCENT=${PERCENT::-2}
 
 echo -ne "Final percentage is $FINALPERCENT\n"
 
 #echo -ne "\n$(date +%m-%d-%Y)-$(date +%X)-$(whoami):[$1]\"Total = $TOTAL, Available = $AVAILABLE, Total_int = $TOTAL_INT, Available_int = $AVAILABLE_INT, Percentage = $PERCENT, Final = $FINALPERCENT\"" >> /var/log/proxmox-storage-check.log
 
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