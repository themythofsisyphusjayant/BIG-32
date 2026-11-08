#!/bin/bash
# run_cont160.sh -- continuation 110M -> 160M under the checkpoint harness.
# Resumes from ckpt_cont160/ckpt_110000000 (a COPY of the banked 110M
# checkpoint whose header lines 2-3 were reset to rx2idx=0,
# rx2next=150000000, re-arming the RX command file; the original in
# ckpt_attempt17/ is untouched). Appends to kernel/boot_attempt17.log.
# Each segment is one explicit-cap resume (never loop mode: loop's
# maxiter resets on relaunch and would overshoot the 160M cap).
# Stops early on HALTED, on a kernel panic, or on prompt + command
# output. Survives VM restarts only by being re-run: it always resumes
# from the newest complete checkpoint in ckpt_cont160/.
set -u
cd "$(dirname "$0")/.."

LOG=kernel/boot_attempt17.log
DIR=ckpt_cont160
PROG=kernel/cont160_progress.log

ensure_vvp() {
    if command -v vvp >/dev/null 2>&1; then return 0; fi
    echo "$(date -u +%FT%TZ) vvp missing (VM restart); reinstalling from cached deb" >> "$PROG"
    for _ in $(seq 1 60); do
        if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then break; fi
        sleep 10
    done
    dpkg -i iverilog_12.0-2build2_amd64.deb >> "$PROG" 2>&1
    command -v vvp >/dev/null 2>&1
}

latest() {
    local f best=""
    for f in "$DIR"/ckpt_*.done; do
        [ -f "$f" ] || continue
        local n="${f##*/ckpt_}"; n="${n%.done}"
        if [ -z "$best" ] || [ "$n" -gt "$best" ]; then best="$n"; fi
    done
    [ -n "$best" ] && echo "$best"
}

echo "$(date -u +%FT%TZ) cont160 start; latest checkpoint: $(latest)" >> "$PROG"

for target in 120000000 130000000 140000000 150000000 160000000; do
    tries=0
    while [ "$tries" -lt 3 ]; do
        before="$(latest)"
        ensure_vvp || { echo "$(date -u +%FT%TZ) ERROR: vvp reinstall failed" >> "$PROG"; exit 1; }
        echo "$(date -u +%FT%TZ) segment: resume $before -> $target" >> "$PROG"
        ./tools/ckpt_run.sh resume "$LOG" "$DIR" \
            +MAXCYCLES="$target" +CKPTAT="$target" \
            +RX2FILE=rootfs/rx_cmds.txt +RX2START=150000000 +RX2PERIOD=2000 \
            >> "$PROG" 2>&1
        after="$(latest)"
        echo "$(date -u +%FT%TZ) segment done: $before -> $after" >> "$PROG"
        if [ "$after" != "$before" ]; then break; fi
        tries=$((tries + 1))
        echo "$(date -u +%FT%TZ) no progress, retry $tries/3 for $target" >> "$PROG"
    done
    if grep -a -q "Kernel panic" "$LOG"; then
        echo "$(date -u +%FT%TZ) STOP: kernel panic in log" >> "$PROG"; exit 0
    fi
    if grep -a -q "HALTED: 1" "$LOG"; then
        echo "$(date -u +%FT%TZ) STOP: HALTED" >> "$PROG"; exit 0
    fi
    if grep -a -q "big32# " "$LOG" && grep -a -q "^hello from big32$" "$LOG"; then
        echo "$(date -u +%FT%TZ) STOP: prompt + command output seen" >> "$PROG"; exit 0
    fi
    if grep -a -q "big32# " "$LOG"; then
        echo "$(date -u +%FT%TZ) NOTE: prompt seen, no command output yet; continuing" >> "$PROG"
    fi
    # New UART lines since the last segment boundary are the real signal.
    echo "$(date -u +%FT%TZ) latest UART lines:" >> "$PROG"
    grep -a "^\[" "$LOG" | tail -3 >> "$PROG" 2>&1
done

echo "$(date -u +%FT%TZ) cont160 complete: 160M cap reached" >> "$PROG"
exit 0
