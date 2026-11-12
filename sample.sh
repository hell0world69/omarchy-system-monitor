#!/usr/bin/env bash
# Emits one space-separated line per tick:
#   cpu% ram% swap% tempC load1 uptimeSec memUsedKB memTotalKB swapUsedKB
# Reads /proc and sysfs with bash builtins only, so a tick costs one `sleep`.
# $1 = interval in seconds (default 2). tempC is -1 when no sensor is found.

interval="${1:-2}"
[[ "$interval" =~ ^[0-9]+([.][0-9]+)?$ ]] || interval=2

# Package temperature: coretemp temp1, then k10temp/zenpower, then x86_pkg_temp.
temp_file=""
for h in /sys/class/hwmon/hwmon*; do
  read -r n < "$h/name" 2>/dev/null || continue
  case "$n" in coretemp|k10temp|zenpower)
    [ -r "$h/temp1_input" ] && { temp_file="$h/temp1_input"; break; } ;;
  esac
done
if [ -z "$temp_file" ]; then
  for z in /sys/class/thermal/thermal_zone*; do
    read -r t < "$z/type" 2>/dev/null || continue
    [ "$t" = x86_pkg_temp ] && { temp_file="$z/temp"; break; }
  done
fi

prev_total=0 prev_idle=0
while :; do
  read -r _ u n s i w q sq st _ < /proc/stat
  total=$((u + n + s + i + w + q + sq + st)); idle=$((i + w))
  cpu=0
  if [ "$prev_total" -gt 0 ] && [ $((total - prev_total)) -gt 0 ]; then
    cpu=$(( (100 * ((total - prev_total) - (idle - prev_idle))) / (total - prev_total) ))
  fi
  prev_total=$total prev_idle=$idle

  mt=0 ma=0 sw=0 sf=0
  while read -r k v _; do
    case "$k" in
      MemTotal:) mt=$v ;; MemAvailable:) ma=$v ;;
      SwapTotal:) sw=$v ;; SwapFree:) sf=$v ;;
    esac
  done < /proc/meminfo
  used=$((mt - ma)); ram=0; [ "$mt" -gt 0 ] && ram=$((100 * used / mt))
  swused=$((sw - sf)); swap=0; [ "$sw" -gt 0 ] && swap=$((100 * swused / sw))

  temp=-1
  if [ -n "$temp_file" ] && read -r t < "$temp_file" 2>/dev/null; then temp=$((t / 1000)); fi

  read -r load1 _ < /proc/loadavg
  read -r up _ < /proc/uptime

  printf '%s %s %s %s %s %s %s %s %s\n' "$cpu" "$ram" "$swap" "$temp" "$load1" "${up%.*}" "$used" "$mt" "$swused"
  sleep "$interval"
done
