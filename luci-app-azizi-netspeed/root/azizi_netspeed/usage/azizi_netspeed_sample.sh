#!/bin/sh

# Runs every minute from cron. Records how many bytes each device used since
# the previous run, so the UI can show top users over the last 5 minutes,
# hour and day. Everything lives in /tmp (RAM) to avoid flash wear.

DIR="/tmp/azizi_netspeed"
LAST="$DIR/last"       # previous counter readings: ip up down
MINUTES="$DIR/minutes" # per-minute usage for the last hour: epoch ip up down
HOURS="$DIR/hours"     # per-hour usage for the last day: hour_epoch ip up down
OUT="$DIR/top.json"

mkdir -p "$DIR"

# The midnight save script also calls us, so don't run twice at once
exec 9>"$DIR/lock"
flock 9

NOW=$(date +%s)
HOUR_START=$((NOW - NOW % 3600))

read_set() {
    nft list set inet fw4 "$1" 2>/dev/null |
        grep -oE '[0-9.]+ counter packets [0-9]+ bytes [0-9]+' |
        awk -v t="$2" '{ print t, $1, $6 }'
}

# Current counters: ip up down
{ read_set up_per_ip u; read_set down_per_ip d; } | awk '
    { ips[$2] = 1; if ($1 == "u") u[$2] = $3; else d[$2] = $3 }
    END { for (ip in ips) printf "%s %.0f %.0f\n", ip, u[ip], d[ip] }' > "$DIR/cur"

# First run (e.g. after reboot): just take a baseline
if [ ! -f "$LAST" ]; then
    mv "$DIR/cur" "$LAST"
    exit 0
fi

touch "$MINUTES" "$HOURS"

# Usage since last run. A counter that went down was reset (midnight flush,
# firewall restart, element expiry), so everything it holds now is new.
awk -v now="$NOW" '
    FILENAME == ARGV[1] { pu[$1] = $2; pd[$1] = $3; next }
    {
        du = ($1 in pu && $2 >= pu[$1]) ? $2 - pu[$1] : $2
        dd = ($1 in pd && $3 >= pd[$1]) ? $3 - pd[$1] : $3
        if (du > 0 || dd > 0) printf "%s %s %.0f %.0f\n", now, $1, du, dd
    }' "$LAST" "$DIR/cur" > "$DIR/delta"

awk -v cut=$((NOW - 3600)) '$1 > cut' "$MINUTES" "$DIR/delta" > "$MINUTES.tmp"
mv "$MINUTES.tmp" "$MINUTES"

awk -v hs="$HOUR_START" -v cut=$((NOW - 86400)) '
    FILENAME == ARGV[1] { if ($1 > cut) { k = $1 " " $2; u[k] += $3; d[k] += $4 } next }
    { k = hs " " $2; u[k] += $3; d[k] += $4 }
    END { for (k in u) printf "%s %.0f %.0f\n", k, u[k], d[k] }' "$HOURS" "$DIR/delta" > "$HOURS.tmp"
mv "$HOURS.tmp" "$HOURS"

# {"time":N,"5m":{"ip":[up,down]},"1h":{...},"1d":{...}}
awk -v now="$NOW" '
    function emit(name, U, D,   ip, n) {
        printf ",\"%s\":{", name
        for (ip in U) printf "%s\"%s\":[%.0f,%.0f]", (n++ ? "," : ""), ip, U[ip], D[ip]
        printf "}"
    }
    FILENAME == ARGV[1] {
        if ($1 > now - 300) { u5[$2] += $3; d5[$2] += $4 }
        u60[$2] += $3; d60[$2] += $4
        next
    }
    { u1d[$2] += $3; d1d[$2] += $4 }
    END {
        printf "{\"time\":%s", now
        emit("5m", u5, d5); emit("1h", u60, d60); emit("1d", u1d, d1d)
        printf "}\n"
    }' "$MINUTES" "$HOURS" > "$OUT.tmp"
mv "$OUT.tmp" "$OUT"

mv "$DIR/cur" "$LAST"
