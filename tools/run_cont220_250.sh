#!/bin/bash
# run_cont220_250.sh -- Step 28 full-config grind 220M -> 250M.
# Resumes from ckpt_cont170_run/ckpt_220000000, banked by Step 27
# (09:15:08Z 8 Nov 2026, runner exit 0, verdict PARTIAL -- jent
# still grinding at 220M, ZERO new UART lines).
# NO disk rewrite for this extension: the banked 220M .disk FILE
# md5 is 9da95d3bf4dea5887b9514e0f82ed845, identical to
# ckpt_catecho210/'s, and its payload md5 is
# c073ba7f766976b265d6b0057edb8d6f (1,048,576 bytes) == the
# current patched rootfs image. Verified pre-flight, Step 25
# standard not needed -- nothing was rewritten. ckpt_cont160/
# and ckpt_catecho210/ stay pristine; checkpoints land in the
# SAME ckpt_cont170_run/ dir (the resume point lives there).
# Header untouched: rx2idx=50, rx2next=150100000 -- the
# attempt-17 feed rootfs/rx_cmds.txt is fully consumed, so no
# re-feed; the first 16 feed bytes may still sit in the 16550
# RX FIFO, so any command output after a prompt is stale-FIFO
# artefact, NOT clean evidence. Judge prompt/banner/serial/
# virtio/root-mount only. Shell fixes explicitly NOT judged.
# Full-config DTB (NOT skipjent):
# soc2_hex/big32_kboot_10mhz_rootfs.dtb.txt.
# Each segment is one explicit-cap resume (never loop mode).
# Stops early on HALTED, kernel panic, or prompt + command
# output. Survives VM restarts only by being re-run: it always
# resumes from the newest complete checkpoint in
# ckpt_cont170_run/. NOTE the Step 27 retry-loop quirk: after a
# restart the runner walks its fixed target list [230,240,250]
# from the latest checkpoint, so targets already passed each
# "complete" instantly with no progress and burn 3 retries
# (~50s each) before the runner moves on. Harmless.
# Log: kernel/boot_attempt17_cont220_250.log (NEW file; the
# full-config story stays in kernel/boot_attempt17.log and
# kernel/boot_attempt17_cont170_220.log).
set -u
cd "$(dirname "$0")/.."

LOG=kernel/boot_attempt17_cont220_250.log
DIR=ckpt_cont170_run
PROG=kernel/cont220_250_progress.log
VVP=sim/tb_kboot_ckpt.vvp

VVP_MFLAG=""
ensure_vvp() {
    if command -v vvp >/dev/null 2>&1; then
        VVP_MFLAG=""; return 0
    fi
    if [ -x .iverilog-local/usr/bin/vvp ]; then
        export PATH="$PWD/.iverilog-local/usr/bin:$PATH"
    else
        echo "$(date -u +%FT%TZ) vvp missing (VM restart); extracting cached deb via dpkg-deb (no dpkg lock)" >> "$PROG"
        dpkg-deb -x iverilog_12.0-2build2_amd64.deb .iverilog-local >> "$PROG" 2>&1
        export PATH="$PWD/.iverilog-local/usr/bin:$PATH"
    fi
    case "$(command -v vvp)" in
        "$PWD"/.iverilog-local/*) VVP_MFLAG="-M $PWD/.iverilog-local/usr/lib/x86_64-linux-gnu/ivl" ;;
        *) VVP_MFLAG="" ;;
    esac
    if [ ! -e /usr/lib/x86_64-linux-gnu/ivl/system.vpi ] && [ -d .iverilog-local/usr/lib/x86_64-linux-gnu/ivl ]; then
        mkdir -p /usr/lib/x86_64-linux-gnu/ivl 2>/dev/null
        ln -sf "$PWD"/.iverilog-local/usr/lib/x86_64-linux-gnu/ivl/*.vpi /usr/lib/x86_64-linux-gnu/ivl/ 2>/dev/null
    fi
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
echo "$(date -u +%FT%TZ) cont220_250 start; latest checkpoint: $(latest); vvp: $(ls -la --time-style=long-iso "$VVP" | awk '{print $6, $7}'); run dir ckpt_cont170_run (220M banked Step 27, .disk already current image c073ba7f..., no rewrite); full-config DTB" >> "$PROG"

run_one() {
    local target="$1" before after
    before="$(latest)"
    ensure_vvp || { echo "$(date -u +%FT%TZ) ERROR: vvp unavailable" >> "$PROG"; exit 1; }
    echo "$(date -u +%FT%TZ) segment: resume $before -> $target" >> "$PROG"
    # shellcheck disable=SC2086
    stdbuf -oL -eL vvp $VVP_MFLAG "$VVP" \
        +HEX=soc2_hex/kboot_fw.hex +DISKHEX=soc2_hex/rootfs_disk.hex \
        +DTBFILE=soc2_hex/big32_kboot_10mhz_rootfs.dtb.txt +DTBOFF=131072 \
        +KIMGBIN=kernel/linux-6.6.52/arch/riscv/boot/Image +KIMGOFF=4194304 +NOCLEAR \
        +CKPTDIR="$DIR" +RESUME="$before" +MAXCYCLES="$target" +CKPTAT="$target" \
        +RX2FILE=rootfs/rx_cmds.txt +RX2START=170000000 +RX2PERIOD=2000 \
        >> "$LOG" 2>&1
    after="$(latest)"
    echo "$(date -u +%FT%TZ) segment done: $before -> $after" >> "$PROG"
    echo "$(date -u +%FT%TZ) latest UART lines:" >> "$PROG"
    grep -a "^\[" "$LOG" | tail -3 >> "$PROG" 2>&1
}

for target in 230000000 240000000 250000000; do
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
        echo "$(date -u +%FT%TZ) STOP: prompt + command output seen (stale-FIFO caveat applies -- see header)" >> "$PROG"; exit 0
    fi
    if grep -a -q "big32# " "$LOG"; then
        echo "$(date -u +%FT%TZ) NOTE: prompt seen, no command output yet; continuing" >> "$PROG"
    fi
done

echo "$(date -u +%FT%TZ) cont220_250 complete: 250M cap reached" >> "$PROG"
exit 0
