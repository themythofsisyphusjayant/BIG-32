#!/bin/bash
# run_skipjent_fixedcore_cont170.sh -- attempt 18 STEP 10 continuation:
# skip-jent boot resumed from the banked 150M checkpoint under the
# FIXED virtio model (VIRTIO_F_VERSION_1 advertised, Step 9), explicit
# 170M cap, in two 10M segments (150M->160M, 160M->170M). Same
# skip-jent configuration as attempt 18 (blacklist DTB, 10 MHz,
# attempt-12 firmware, virtio-blk rootfs) -- this is NOT the
# full-config boot; the full-config grind from the banked 170M
# checkpoint in ckpt_cont160/ remains open and is untouched.
#
# Why a checkpoint-dir copy: on RESUME the testbench restores
# rx2idx/rx2next from the checkpoint header (the RX2START plusarg
# is only honoured on a fresh start, so it cannot re-feed a
# resumed run). ckpt_skipjent_fixedcore_cont170/ is a COPY of the
# 150M checkpoint set with ONLY header lines 2-3 changed
# (rx2idx 50->0, rx2next 140100000->167000000); the original in
# ckpt_skipjent_fixedcore/ is untouched (verified: diff shows
# exactly those two lines, RAM md5 identical). RX feed therefore
# lands at 167M, 1 byte/2000 cycles, all 50 bytes by 167.1M.
# Arming choice, documented: Step 8 reached kernel time 14.724 s
# by 160M, so the probe [357] re-runs early in this window and a
# prompt, if it appears, most plausibly appears before 167M;
# a 167M feed lands after most plausible prompt times while
# staying inside the cap. Trade-off: if the prompt appears
# AFTER 167M, the shell reads only the FIFO's first 16 bytes
# (truncated first command) and a header-copy re-arm from a
# post-prompt checkpoint is the follow-up; if the prompt
# appears before 167M, the feed lands cleanly after it.
# Caveat carried from earlier continuations: stale bytes from
# earlier feeds may still sit in the restored 16550 RX FIFO
# (it drops past 16, it does not clear), so a future shell
# could read stale bytes first.
#
# The testbench binary MUST be the one rebuilt from the fixed
# model (sim/tb_kboot_ckpt.vvp, built 30 Oct 10:01 UTC from the
# fixed soc2 sources; soc2.v timestamp 09:42 UTC -- binary is
# newer, so no rebuild needed). Do NOT reuse a pre-fix .vvp.
# Two explicit-cap segments, never uncapped loop mode (loop's
# maxiter resets on relaunch and would overshoot). Survives VM
# restarts only by being re-run: it always resumes from the
# newest complete checkpoint in ckpt_skipjent_fixedcore_cont170/.
# Log: kernel/boot_attempt18_skipjent_fixedcore_cont170.log
# (NEW file -- all earlier logs untouched).
set -u
cd "$(dirname "$0")/.."

LOG=kernel/boot_attempt18_skipjent_fixedcore_cont170.log
DIR=ckpt_skipjent_fixedcore_cont170
PROG=kernel/skipjent_fixedcore_cont170_progress.log
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
echo "$(date -u +%FT%TZ) skipjent fixedcore cont170 start; latest checkpoint: $(latest); vvp: $(ls -la --time-style=long-iso "$VVP" | awk '{print $6, $7}')" >> "$PROG"

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
        +RX2FILE=rootfs/rx_cmds.txt +RX2PERIOD=2000 \
        >> "$LOG" 2>&1
    after="$(latest)"
    echo "$(date -u +%FT%TZ) segment done: $before -> $after" >> "$PROG"
    echo "$(date -u +%FT%TZ) latest UART lines:" >> "$PROG"
    grep -a "^\[" "$LOG" | tail -5 >> "$PROG" 2>&1
}

for target in 160000000 170000000; do
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
        echo "$(date -u +%FT%TZ) NOTE: prompt seen, no command output yet" >> "$PROG"
    fi
done

echo "$(date -u +%FT%TZ) skipjent fixedcore cont170 complete: 170M cap reached" >> "$PROG"
exit 0
