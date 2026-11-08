#!/bin/bash
# step28_watch.sh -- Step 28 watcher for the 220M->250M grind.
# Polls every 600s. Relaunches the runner (setsid nohup) if it is
# dead and the run is unfinished. Exits with a summary when the
# 250M checkpoint lands, or on kernel panic / HALTED: 1 / prompt.
# Survives nothing by itself: a VM restart kills this watcher too;
# the hourly watcher cron (watermark kernel/cont220_250_watermark.txt)
# is the backstop for that case. Never pushes anything.
set -u
cd "$(dirname "$0")/.."
LOG=kernel/boot_attempt17_cont220_250.log
PROG=kernel/cont220_250_progress.log
WLOG=kernel/cont220_250_watcher.log

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

log "WATCHER start; latest done: $(latest_done)"
while true; do
    sleep 600
    if [ -f ckpt_cont170_run/ckpt_250000000.done ]; then
        log "WATCHER: 250M done present -- finished"
        break
    fi
    if grep -a -q "Kernel panic" "$LOG" 2>/dev/null; then
        log "WATCHER: kernel panic in log -- finished"
        break
    fi
    if grep -a -q "HALTED: 1" "$LOG" 2>/dev/null; then
        log "WATCHER: HALTED: 1 in log -- finished"
        break
    fi
    if grep -a -q "big32# " "$LOG" 2>/dev/null; then
        log "WATCHER: prompt in log -- finished"
        break
    fi
    if ! pgrep -f "run_cont220_250" >/dev/null && ! pgrep -f "tb_kboot_ckpt" >/dev/null; then
        log "WATCHER: runner dead and unfinished -- relaunching"
        setsid nohup ./tools/run_cont220_250.sh >> /tmp/cont220_250_runner.out 2>&1 < /dev/null &
        sleep 10
        if pgrep -f "run_cont220_250" >/dev/null; then
            log "WATCHER: relaunch OK"
        else
            log "WATCHER: relaunch FAILED -- will retry next poll"
        fi
    else
        log "WATCHER: alive, latest done: $(latest_done)"
    fi
done

echo "=== STEP28 WATCHER FINAL ==="
date -u +%FT%TZ
echo "--- checkpoints ---"
ls -l ckpt_cont170_run/ckpt_*.done
echo "--- greps (panic / HALTED:1 / prompt) ---"
grep -a -c "Kernel panic" "$LOG" 2>/dev/null
grep -a -c "HALTED: 1" "$LOG" 2>/dev/null
grep -a -c "big32# " "$LOG" 2>/dev/null
echo "--- CYCLES footers ---"
grep -a "CYCLES:" "$LOG" 2>/dev/null | tail -5
echo "--- kernel-timestamp lines ---"
grep -a -c "^\[" "$LOG" 2>/dev/null
echo "--- progress tail ---"
tail -n 25 "$PROG"
echo "--- watcher log ---"
cat "$WLOG"
