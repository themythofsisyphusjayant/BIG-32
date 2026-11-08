#!/bin/bash
# run_skipjent_cont150.sh -- attempt 18 CONTINUATION: skip-jent boot
# resumed from the banked 100M checkpoint, explicit 150M cap.
# Same skip-jent configuration as attempt 18 (blacklist DTB, 10 MHz,
# attempt-12 firmware, virtio-blk rootfs) -- this is NOT the full-config
# boot; the full-config grind from the banked 170M checkpoint in
# ckpt_cont160/ remains open and is untouched by this script.
#
# Why a custom runner + checkpoint-dir copy: the testbench restores
# rx2idx/rx2next from the checkpoint header on resume, and the 100M
# header has rx2idx=50 (attempt 18's feed fully consumed), so plain
# plusargs cannot re-feed. ckpt_skipjent_cont150/ is a COPY of the
# 100M checkpoint set with ONLY header lines 2-3 changed
# (rx2idx 50->0, rx2next 50100000->140000000); the original in
# ckpt_skipjent/ is untouched (verified: diff shows exactly those
# two lines). RX feed therefore lands at 140M, 1 byte/2000 cycles,
# all 50 bytes by 140.1M -- after a plausible prompt time. If the
# prompt appears before 140M, the shell simply waits and the feed
# still lands; if the prompt appears after the feed, the header-copy
# re-arm from a post-prompt checkpoint is the follow-up.
# Caveat carried from the 160M continuation: the first 16 bytes of
# the attempt-18 feed may still sit in the restored 16550 RX FIFO
# (it drops past 16, it does not clear), so a future shell could
# read those stale bytes first.
#
# Each segment is one explicit-cap run, never uncapped loop mode
# (loop's maxiter resets on relaunch and would overshoot). Survives
# VM restarts only by being re-run: it always resumes from the
# newest complete checkpoint in ckpt_skipjent_cont150/.
# Log: kernel/boot_attempt18_skipjent_cont150.log (NEW file -- the
# attempt-18 record in boot_attempt18_skipjent.log is untouched).
set -u
cd "$(dirname "$0")/.."

LOG=kernel/boot_attempt18_skipjent_cont150.log
DIR=ckpt_skipjent_cont150
PROG=kernel/skipjent_cont150_progress.log
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
echo "$(date -u +%FT%TZ) skipjent cont150 start; latest checkpoint: $(latest)" >> "$PROG"

run_one() {
    # $1 = target cycle
    local target="$1" before after
    before="$(latest)"
    ensure_vvp || { echo "$(date -u +%FT%TZ) ERROR: vvp reinstall failed" >> "$PROG"; exit 1; }
    echo "$(date -u +%FT%TZ) segment: resume $before -> $target" >> "$PROG"
    stdbuf -oL -eL vvp "$VVP" \
        +HEX=soc2_hex/kboot_fw.hex +DISKHEX=soc2_hex/rootfs_disk.hex \
        +DTBFILE="$DTB" +DTBOFF=131072 \
        +KIMGBIN=kernel/linux-6.6.52/arch/riscv/boot/Image +KIMGOFF=4194304 +NOCLEAR \
        +CKPTDIR="$DIR" +RESUME="$before" +MAXCYCLES="$target" +CKPTAT="$target" \
        +RX2FILE=rootfs/rx_cmds.txt +RX2START=140000000 +RX2PERIOD=2000 \
        >> "$LOG" 2>&1
    after="$(latest)"
    echo "$(date -u +%FT%TZ) segment done: $before -> $after" >> "$PROG"
    echo "$(date -u +%FT%TZ) latest UART lines:" >> "$PROG"
    grep -a "^\[" "$LOG" | tail -3 >> "$PROG" 2>&1
}

for target in 110000000 120000000 130000000 140000000 150000000; do
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

echo "$(date -u +%FT%TZ) skipjent cont150 complete: 150M cap reached" >> "$PROG"
exit 0
