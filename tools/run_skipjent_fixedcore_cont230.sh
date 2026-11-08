#!/bin/bash
# run_skipjent_fixedcore_cont230.sh -- attempt 18 STEP 17 continuation:
# skip-jent boot resumed from the banked 210M checkpoint under the
# FIXED core + FIXED virtio model (v1 fix + drain fix), explicit
# 230M cap, in two 10M segments (210M->220M, 220M->230M). Same
# skip-jent configuration as attempt 18 (blacklist DTB, 10 MHz,
# attempt-12 firmware, virtio-blk rootfs) -- this is NOT the
# full-config boot; the full-config grind from the banked 170M
# checkpoint in ckpt_cont160/ remains open and is untouched.
#
# Why this continuation, and why now: Step 16's virtio drain
# fix (IDLE re-scan only, src/big32_soc2.v:850) is PROVEN by a
# short resume: an unpatched copy of the 210M set resumed
# 210M->211M completed all 4 pending chains (used_idx 5->9,
# last_avail 9) with NO new kick and NO header patch, and the
# guest printed "devtmpfs: mounted" at 19.735 s -- PID 1's
# "dev" lookup completed. So the Step 15 park is cleared and
# the milestones judged here, in order, are: "devtmpfs:
# mounted" (re-confirming the drain fix in the full run),
# "Freeing unused kernel memory", "Run /init", init banner,
# big32# prompt, RX command outputs.
#
# CRITICAL: resume from the BANKED 210M checkpoint in
# ckpt_skipjent_fixedcore_cont210/ -- via the COPY dir
# ckpt_skipjent_fixedcore_cont230/ (the clean recipe; the
# 211M set in ckpt_drain_resume/ is a valid fallback only).
# NO virtio header patch -- the drain fix needs none. For RX
# only, the header-copy trick: the copy's 210M header has ONLY
# lines 2-3 changed (rx2idx 50->0, rx2next 209100000->
# 229000000); diff verified to show exactly those two lines,
# RAM md5 identical, all virtio header fields byte-identical.
# The original in ckpt_skipjent_fixedcore_cont210/ is untouched.
# RX feed therefore lands at 229M, 1 byte/2000 cycles, all 50
# bytes by 229.1M.
# Arming choice, documented: the devtmpfs park is cleared, so
# the prompt should fall inside this window; arming at 229M
# (last 1M of the window) means a prompt appearing any time
# before 229M is followed by a clean feed into a waiting
# shell, while feeding earlier risks bytes lost past the
# 16-byte FIFO before any shell exists. Trade-off: if the
# prompt appears AFTER 229M, the feed is moot and a
# header-copy re-arm from the 230M checkpoint is the follow-up.
# Caveat carried from earlier continuations: stale bytes from
# earlier feeds may still sit in the restored 16550 RX FIFO
# (it drops past 16, it does not clear), so a future shell
# could read stale bytes first. Judge command OUTPUT, not
# echo: the 209M feed's echo lines in Step 13 prove a console
# tty open with echo enabled, not a reader.
#
# Binary: sim/tb_kboot_ckpt.vvp built 30 Oct 14:42 UTC from
# the drain-fixed sources (fix line src/big32_soc2.v:850).
# Do NOT resume from ckpt_skipjent_cont150/ or
# ckpt_skipjent_repro110/ (110M panic-loop checkpoints), and do
# NOT resume from ckpt_skipjent_fixedcore_cont160/ (160M
# post-failure checkpoint, device removed).
#
# Two explicit-cap segments, never uncapped loop mode (loop's
# maxiter resets on relaunch and would overshoot). Survives VM
# restarts only by being re-run: it always resumes from the
# newest complete checkpoint in ckpt_skipjent_fixedcore_cont230/.
# Log: kernel/boot_attempt18_skipjent_fixedcore_cont230.log
# (NEW file -- all earlier logs untouched).
set -u
cd "$(dirname "$0")/.."

LOG=kernel/boot_attempt18_skipjent_fixedcore_cont230.log
DIR=ckpt_skipjent_fixedcore_cont230
PROG=kernel/skipjent_fixedcore_cont230_progress.log
VVP=sim/tb_kboot_ckpt.vvp
DTB=soc2_hex/big32_kboot_10mhz_rootfs_skipjent.dtb.txt

ensure_vvp() {
    if command -v vvp >/dev/null 2>&1; then return 0; fi
    if [ -x .iverilog-local/usr/bin/vvp ]; then
        export PATH="$PWD/.iverilog-local/usr/bin:$PATH"
        return 0
    fi
    echo "$(date -u +%FT%TZ) vvp missing (VM restart); extracting cached deb via dpkg-deb (no dpkg lock)" >> "$PROG"
    dpkg-deb -x iverilog_12.0-2build2_amd64.deb .iverilog-local >> "$PROG" 2>&1
    export PATH="$PWD/.iverilog-local/usr/bin:$PATH"
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
echo "$(date -u +%FT%TZ) skipjent fixedcore cont230 start; latest checkpoint: $(latest); vvp: $(ls -la --time-style=long-iso "$VVP" | awk '{print $6, $7}')" >> "$PROG"

run_one() {
    # $1 = target cycle
    local target="$1" before after
    before="$(latest)"
    ensure_vvp || { echo "$(date -u +%FT%TZ) ERROR: vvp unavailable" >> "$PROG"; exit 1; }
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

for target in 220000000 230000000; do
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

echo "$(date -u +%FT%TZ) skipjent fixedcore cont230 complete: 230M cap reached" >> "$PROG"
exit 0
