#!/usr/bin/env bash
# Prints the busiest processes over a short window, one per line:
#   pid <TAB> cpu% of the whole machine <TAB> rss KiB <TAB> command
# Run only while the panel is open. $1 = how many rows (default 6).
count="${1:-6}"
[[ "$count" =~ ^[0-9]+$ ]] || count=6
cores=$(nproc 2>/dev/null || echo 1)
LC_ALL=C top -b -n2 -d1 -w 512 -e k -o %CPU 2>/dev/null \
  | awk -v want="$count" -v cores="$cores" -v self="$$" '
      /^top -/ { frame++; header = 0; next }
      frame == 2 && /^ *PID / { header = 1; next }
      frame == 2 && header && NF >= 12 {
        if ($12 == "top" || $1 == self) next
        printf "%s\t%.1f\t%s\t%s\n", $1, $9 / cores, $6, $12
        if (++rows >= want) exit
      }'
