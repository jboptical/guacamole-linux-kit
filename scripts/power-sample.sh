#!/bin/sh
# Run ON THE PHONE (any user): average battery power over a while.
#   sh power-sample.sh [SECONDS] [LABEL]
# Only meaningful while the phone runs on battery (charger input suspended by
# the battery-care window, or unplugged): bq27411 current_now is then the
# whole phone's draw. Also prints the screen state and the busiest IRQs.
SECS=${1:-60}
LABEL=${2:-sample}
B=/sys/class/power_supply/bq27411-0
DPMS=$(cat /sys/class/drm/card1-DSI-1/dpms 2>/dev/null)
STATUS=$(cat $B/status)
irq_snapshot() { awk 'NR>1 {s=0; for(i=2;i<=9;i++) s+=$i; $1=$1; printf "%s %d %s\n", $1, s, $NF}' /proc/interrupts; }
irq_snapshot > /tmp/irq.a
n=0; sum_uw=0; sum_ua=0; min_uw=999999999; max_uw=0
end=$(( $(date +%s) + SECS ))
while [ "$(date +%s)" -lt "$end" ]; do
  ua=$(cat $B/current_now); uv=$(cat $B/voltage_now)
  uw=$(( -ua / 1000 * uv / 1000 / 1000 ))   # mW (positive = drawing from battery)
  sum_uw=$((sum_uw + uw)); sum_ua=$((sum_ua - ua)); n=$((n + 1))
  [ "$uw" -lt "$min_uw" ] && min_uw=$uw; [ "$uw" -gt "$max_uw" ] && max_uw=$uw
  sleep 2
done
irq_snapshot > /tmp/irq.b
echo "$LABEL: $((sum_uw / n)) mW avg ($((sum_ua / n / 1000)) mA), min $min_uw, max $max_uw mW, $n samples over ${SECS}s, battery $STATUS, screen $DPMS"
echo "busiest IRQs (per second):"
join /tmp/irq.a /tmp/irq.b 2>/dev/null | awk -v s="$SECS" '{d=$4-$2; if (d>0) printf "  %7.1f/s  %s %s\n", d/s, $1, $5}' | sort -rn | head -8
rm -f /tmp/irq.a /tmp/irq.b
