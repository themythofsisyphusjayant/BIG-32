#!/bin/bash
# step31_watch.sh -- Step 31 watcher for the 520M->530M prompt-commands run.
# Polls every 600s. Relaunches the runner (setsid nohup) if it is dead
# and the run is unfinished. Exits with a summary when the 530M
# checkpoint lands or a failure criterion appears (kernel panic /
# HALTED: 1). There is NO cap beyond 530M and NO checkpoint-count
# finish: the 530M checkpoint IS the finish. Survives nothing by
# itself: a VM restart kills this watcher too; the hourly watcher cron
# (watermark kernel/cont_prompt_cmds_watermark.txt) is the backstop.
# Never pushes anything.
set -u
cd "$(dirname "$0")/.."
LOG=kernel/boot_attempt17_prompt_cmds.log
PROG=kernel/cont_prompt_cmds_progress.log
WLOG=kernel/cont_prompt_cmds_watcher.log

log() { echo "$(date -u +%FT%TZ) $*" >> "$WLOG"; }

latest_done() {
    local f best=""
    for f in ckpt_prompt_run/ckpt_*.done; do
        [ -f "$f" ] || continue
        local n="${f##*/ckpt_}"; n="${n%.done}"
        if [ -z "$best" ] || [ "$n" -gt "$best" ]; then best="$n"; fi
    done
    echo "$best"
}

finished() {
    [ -f ckpt_prompt_run/ckpt_530000000.done ] && return 0
    grep -a -q "Kernel panic" "$LOG" 2>/dev/null && return 0
    grep -a -q "HALTED: 1" "$LOG" 2>/dev/null && return 0
    return 1
}

log "WATCHER start; latest done: $(latest_done)"
while true; do
    sleep 600
    if finished; then
        log "WATCHER: finish criterion met -- finished"
        break
    fi
    if ! pgrep -f "run_prompt_cmds" >/dev/null && ! pgrep -f "tb_kboot_ckpt" >/dev/null; then
        log "WATCHER: runner dead and unfinished -- relaunching"
        setsid nohup ./tools/run_prompt_cmds.sh >> /tmp/prompt_cmds_runner.out 2>&1 < /dev/null &
        sleep 10
        if pgrep -f "run_prompt_cmds" >/dev/null; then
            log "WATCHER: relaunch OK"
        else
            log "WATCHER: relaunch FAILED -- will retry next poll"
        fi
    else
        log "WATCHER: alive, latest done: $(latest_done)"
    fi
done

echo "=== STEP31 WATCHER FINAL ==="
date -u +%FT%TZ
echo "--- checkpoints ---"
ls -l ckpt_prompt_run/ckpt_*.done
echo "--- greps (panic / HALTED:1 / hello / ls-root / cat-hello / uname / pwd / done) ---"
grep -a -c "Kernel panic" "$LOG" 2>/dev/null
grep -a -c "HALTED: 1" "$LOG" 2>/dev/null
grep -a -c "hello" "$LOG" 2>/dev/null
grep -a -c "Hello from the big32 root filesystem" "$LOG" 2>/dev/null
grep -a -c "cannot open directory" "$LOG" 2>/dev/null
echo "--- CYCLES footers ---"
grep -a "CYCLES:" "$LOG" 2>/dev/null | tail -5
echo "--- UART (non-timestamp lines, the shell I/O) ---"
grep -a -v "^\[" "$LOG" 2>/dev/null | tail -40
echo "--- progress tail ---"
tail -n 25 "$PROG"
echo "--- watcher log ---"
cat "$WLOG"
