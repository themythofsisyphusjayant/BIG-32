#!/bin/bash
# step29_watch.sh -- Step 29 watcher for the open-ended 250M+ grind.
# Polls every 600s. Relaunches the runner (setsid nohup) if it is
# dead and the run is unfinished. Exits with a summary when a finish
# criterion appears (kernel panic / HALTED: 1 / prompt / serial
# console enabled / Run /init / Freeing unused kernel image).
# There is NO cap and NO checkpoint-count finish: a new checkpoint
# alone never ends the watch. Survives nothing by itself: a VM
# restart kills this watcher too; the hourly watcher cron
# (watermark kernel/cont250_open_watermark.txt) is the backstop.
# Never pushes anything.
set -u
cd "$(dirname "$0")/.."
LOG=kernel/boot_attempt17_cont250_open.log
PROG=kernel/cont250_open_progress.log
WLOG=kernel/cont250_open_watcher.log

log() { echo "$(date -u +%FT%TZ) $*" >> "$WLOG"; }

latest_done() {
    local f best=""
    for f in ckpt_cont170_run/ckpt_*.done; do
        [ -f "$f" ] || continue
        local n="${f##*/ckpt_}"; n="${n%.done}"
        if [ -z "$best" ] || [ "$n" -gt "$best" ]; then best="$n"; fi
    done
    echo "$best"
}

finished() {
    grep -a -q "Kernel panic" "$LOG" 2>/dev/null && return 0
    grep -a -q "HALTED: 1" "$LOG" 2>/dev/null && return 0
    grep -a -q "big32# " "$LOG" 2>/dev/null && return 0
    grep -a -q "console \[ttyS0\] enabled" "$LOG" 2>/dev/null && return 0
    grep -a -q "Run /init" "$LOG" 2>/dev/null && return 0
    grep -a -q "Freeing unused kernel image" "$LOG" 2>/dev/null && return 0
    return 1
}

log "WATCHER start; latest done: $(latest_done)"
while true; do
    sleep 600
    if finished; then
        log "WATCHER: finish criterion in log -- finished"
        break
    fi
    if ! pgrep -f "run_cont250_open" >/dev/null && ! pgrep -f "tb_kboot_ckpt" >/dev/null; then
        log "WATCHER: runner dead and unfinished -- relaunching"
        setsid nohup ./tools/run_cont250_open.sh >> /tmp/cont250_open_runner.out 2>&1 < /dev/null &
        sleep 10
        if pgrep -f "run_cont250_open" >/dev/null; then
            log "WATCHER: relaunch OK"
        else
            log "WATCHER: relaunch FAILED -- will retry next poll"
        fi
    else
        log "WATCHER: alive, latest done: $(latest_done)"
    fi
done

echo "=== STEP29 WATCHER FINAL ==="
date -u +%FT%TZ
echo "--- checkpoints ---"
ls -l ckpt_cont170_run/ckpt_*.done
echo "--- greps (panic / HALTED:1 / prompt / console / Run-init) ---"
grep -a -c "Kernel panic" "$LOG" 2>/dev/null
grep -a -c "HALTED: 1" "$LOG" 2>/dev/null
grep -a -c "big32# " "$LOG" 2>/dev/null
grep -a -c "console \[ttyS0\] enabled" "$LOG" 2>/dev/null
grep -a -c "Run /init" "$LOG" 2>/dev/null
echo "--- CYCLES footers ---"
grep -a "CYCLES:" "$LOG" 2>/dev/null | tail -5
echo "--- kernel-timestamp lines ---"
grep -a -c "^\[" "$LOG" 2>/dev/null
grep -a "^\[" "$LOG" 2>/dev/null | tail -10
echo "--- progress tail ---"
tail -n 25 "$PROG"
echo "--- watcher log ---"
cat "$WLOG"
