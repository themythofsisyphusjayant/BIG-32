#!/bin/bash
# run_skipjent_fixedcore_cont210.sh -- attempt 18 STEP 13 continuation:
# skip-jent boot resumed from the banked 190M checkpoint under the
# FIXED core + FIXED virtio model, explicit 210M cap, in two 10M
# segments (190M->200M, 200M->210M). Same skip-jent configuration
# as attempt 18 (blacklist DTB, 10 MHz, attempt-12 firmware,
# virtio-blk rootfs) -- this is NOT the full-config boot; the
# full-config grind from the banked 170M checkpoint in
# ckpt_cont160/ remains open and is untouched.
#
# Why this continuation, and why now: Step 12's pc-trace
# (190M->200M, 100,000 samples) verdict was PROGRESSING -- the
# kernel marched initcall ~[520]->~[553] of 555 and the trace
# run itself printed again (debug_vm_pgtable 18.446 s, Btrfs
# loaded 18.648 s, Legacy PMU 18.705 s, clk disabling unused
# 18.724 s). Initcalls are essentially complete, so the prompt
# should fall inside this window; the milestones judged here,
# in order, are: "Freeing unused kernel memory", VFS/root-mount,
# "Run /init", init banner, big32# prompt, RX command outputs.
#
# CRITICAL: resume from the BANKED 190M checkpoint in
# ckpt_skipjent_fixedcore_cont190/ -- NOT from the Step 12 trace
# run, which wrote no checkpoint. The trace binary
# sim/tb_kboot_ckpt_trace_fixed_v1.vvp is a trace variant, not
# the boot binary; this runner uses the regular rebuilt
# sim/tb_kboot_ckpt.vvp (30 Oct 10:01 UTC, built after the fixed
# soc2 sources 09:42 UTC; fix line at src/big32_soc2.v:525).
# Do NOT resume from ckpt_skipjent_cont150/ or
# ckpt_skipjent_repro110/ (110M panic-loop checkpoints), and do
# NOT resume from ckpt_skipjent_fixedcore_cont160/ (160M
# post-failure checkpoint, device removed).
#
# Why a checkpoint-dir copy: on RESUME the testbench restores
# rx2idx/rx2next from the checkpoint header (the RX2START plusarg
# is only honoured on a fresh start, so it cannot re-feed a
# resumed run). ckpt_skipjent_fixedcore_cont210/ is a COPY of the
# 190M checkpoint set with ONLY header lines 2-3 changed
# (rx2idx 50->0, rx2next 189100000->209000000); the original in
# ckpt_skipjent_fixedcore_cont190/ is untouched (verified: diff
# shows exactly those two lines, RAM md5 identical). RX feed
# therefore lands at 209M, 1 byte/2000 cycles, all 50 bytes by
# 209.1M.
# Arming choice, documented: Step 12 shows initcalls essentially
# complete by 200M, so the prompt should fall inside this
# window; arming at 209M (last 1M of the window) means a prompt
# appearing any time before 209M is followed by a clean feed
# into a waiting shell, while feeding earlier risks bytes lost
# past the 16-byte FIFO before any shell exists. Trade-off: if
# the prompt appears AFTER 209M, the feed is moot and a
# header-copy re-arm from the 210M checkpoint is the follow-up.
# Caveat carried from earlier continuations: stale bytes from
# earlier feeds may still sit in the restored 16550 RX FIFO
# (it drops past 16, it does not clear), so a future shell
# could read stale bytes first.
#
# Two explicit-cap segments, never uncapped loop mode (loop's
# maxiter resets on relaunch and would overshoot). Survives VM
# restarts only by being re-run: it always resumes from the
# newest complete checkpoint in ckpt_skipjent_fixedcore_cont210/.
# Log: kernel/boot_attempt18_skipjent_fixedcore_cont210.log
# (NEW file -- all earlier logs untouched).
set -u
cd "$(dirname "$0")/.."

LOG=kernel/boot_attempt18_skipjent_fixedcore_cont210.log
DIR=ckpt_skipjent_fixedcore_cont210
PROG=kernel/skipjent_fixedcore_cont210_progress.log
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
echo "$(date -u +%FT%TZ) skipjent fixedcore cont210 start; latest checkpoint: $(latest); vvp: $(ls -la --time-style=long-iso "$VVP" | awk '{print $6, $7}')" >> "$PROG"

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

for target in 200000000 210000000; do
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

echo "$(date -u +%FT%TZ) skipjent fixedcore cont210 complete: 210M cap reached" >> "$PROG"
exit 0
