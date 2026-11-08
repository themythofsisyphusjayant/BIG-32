#!/bin/bash
# run_skipjent.sh -- attempt 18: FRESH boot from cycle zero with
# initcall_blacklist=jent_mod_init (skip-jent configuration).
# This tests a DIFFERENT configuration from the full-config boot:
# it proves the boot path after jent (serial, virtio-blk, root-mount,
# prompt), it does NOT prove the full-config boot. The full-config
# grind from the banked 170M checkpoint in ckpt_cont160/ remains open.
#
# Why a custom runner instead of tools/ckpt_run.sh: ckpt_run.sh's
# KBOOT_ARGS hardcodes +DTBFILE=soc2_hex/big32_kboot_10mhz_rootfs.dtb.txt,
# and Icarus $value$plusargs takes the FIRST match, so appending a
# second +DTBFILE would not override it. This script invokes vvp
# directly with the skip-jent DTB and is otherwise identical in
# launch args (firmware, disk, kernel, offsets, NOCLEAR).
#
# Each segment is one explicit-cap run (fresh start, then resume from
# the newest complete checkpoint in ckpt_skipjent/), never uncapped
# loop mode (loop's maxiter resets on relaunch and would overshoot).
# Survives VM restarts only by being re-run: it always resumes from
# the newest complete checkpoint. Log: kernel/boot_attempt18_skipjent.log
# (a NEW file -- the full-config story stays in boot_attempt17.log).
# RX: rootfs/rx_cmds.txt fed from cycle 50M, one byte per 2000 cycles
# (all 50 bytes by 50.1M). Rationale: if the prompt is already up by
# 50M, the waiting shell reads the full stream intact; if the prompt
# lands after the feed, the FIFO caveat applies and a header-copy
# re-arm from a post-prompt checkpoint is the follow-up.
set -u
cd "$(dirname "$0")/.."

LOG=kernel/boot_attempt18_skipjent.log
DIR=ckpt_skipjent
PROG=kernel/skipjent_progress.log
VVP=sim/tb_kboot_ckpt.vvp
DTB=soc2_hex/big32_kboot_10mhz_rootfs_skipjent.dtb.txt

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

mkdir -p "$DIR"
touch "$LOG" "$PROG"
echo "$(date -u +%FT%TZ) skipjent start; latest checkpoint: $(latest)" >> "$PROG"

run_one() {
    # $1 = target cycle
    local target="$1" before after
    before="$(latest)"
    ensure_vvp || { echo "$(date -u +%FT%TZ) ERROR: vvp reinstall failed" >> "$PROG"; exit 1; }
    if [ -n "$before" ]; then
        echo "$(date -u +%FT%TZ) segment: resume $before -> $target" >> "$PROG"
        stdbuf -oL -eL vvp "$VVP" \
            +HEX=soc2_hex/kboot_fw.hex +DISKHEX=soc2_hex/rootfs_disk.hex \
            +DTBFILE="$DTB" +DTBOFF=131072 \
            +KIMGBIN=kernel/linux-6.6.52/arch/riscv/boot/Image +KIMGOFF=4194304 +NOCLEAR \
            +CKPTDIR="$DIR" +RESUME="$before" +MAXCYCLES="$target" +CKPTAT="$target" \
            +RX2FILE=rootfs/rx_cmds.txt +RX2START=50000000 +RX2PERIOD=2000 \
            >> "$LOG" 2>&1
    else
        echo "$(date -u +%FT%TZ) segment: fresh start 0 -> $target" >> "$PROG"
        stdbuf -oL -eL vvp "$VVP" \
            +HEX=soc2_hex/kboot_fw.hex +DISKHEX=soc2_hex/rootfs_disk.hex \
            +DTBFILE="$DTB" +DTBOFF=131072 \
            +KIMGBIN=kernel/linux-6.6.52/arch/riscv/boot/Image +KIMGOFF=4194304 +NOCLEAR \
            +CKPTDIR="$DIR" +MAXCYCLES="$target" +CKPTAT="$target" \
            +RX2FILE=rootfs/rx_cmds.txt +RX2START=50000000 +RX2PERIOD=2000 \
            >> "$LOG" 2>&1
    fi
    after="$(latest)"
    echo "$(date -u +%FT%TZ) segment done: $before -> $after" >> "$PROG"
    echo "$(date -u +%FT%TZ) latest UART lines:" >> "$PROG"
    grep -a "^\[" "$LOG" | tail -3 >> "$PROG" 2>&1
}

for target in 10000000 20000000 30000000 40000000 50000000 60000000 70000000 80000000 90000000 100000000; do
    tries=0
    while [ "$tries" -lt 3 ]; do
        before="$(latest)"
        run_one "$target"
        after="$(latest)"
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
done

echo "$(date -u +%FT%TZ) skipjent complete: 100M cap reached" >> "$PROG"
exit 0
