#!/bin/bash
# run_ephnum_fixed_cont230.sh -- attempt 18 STEP 19 continuation:
# skip-jent boot resumed from the PATCHED 210M checkpoint under the
# FIXED core + FIXED virtio model (v1 fix + drain fix), explicit
# 230M cap, in two 10M segments (210M->220M, 220M->230M).
#
# Why this continuation, and why now: Step 17 reached furthest
# ever (devtmpfs mounted 19.735 s, Freeing 4152K 19.998 s, Run
# /init 20.009 s) then PANICKED with ENOEXEC -8 at 20.023 s
# because hand-built /init declared e_phnum=0 despite a valid
# PT_LOAD. Step 18 fixed mkelf.py (e_phnum 0->1), rebuilt
# /init (exactly one byte differs, file offset 44), patched
# the image IN PLACE at offset 21548, regenerated
# soc2_hex/rootfs_disk.hex (exactly one line differs, line
# 5388), and prepared ckpt_ephnum_fixed/ (copy of the 210M
# set with the same byte patched in its .disk payload;
# payload md5 = patched image md5 ae1cc627...).
#
# CRITICAL resume point: ckpt_ephnum_fixed_cont230/ is a copy
# of ckpt_ephnum_fixed/ with ONLY header lines 2-3 of the
# 210M header changed (rx2idx 50->0, rx2next 209100000->
# 229000000); diff verified to show exactly those two lines,
# RAM md5 identical, .disk md5 identical. ckpt_ephnum_fixed/
# stays pristine. Do NOT resume from the UNPATCHED 210M
# original (would re-panic with -8), the 220M panic-loop
# checkpoint, ckpt_skipjent_cont150/ or ckpt_skipjent_repro110/
# (110M panic loop), or ckpt_skipjent_fixedcore_cont160/
# (160M post-failure checkpoint).
#
# RX arming choice, documented: the prompt should fall inside
# this window now that the ENOEXEC blocker is fixed; arming
# at 229M (last 1M of the window) means a prompt appearing
# any time before 229M is followed by a clean feed into a
# waiting shell, while feeding earlier risks bytes lost past
# the 16-byte FIFO before any shell exists. Trade-off: if
# the prompt appears AFTER 229M, the feed is moot and a
# header-copy re-arm from the 230M checkpoint is the
# follow-up. Caveat: stale bytes from earlier feeds may
# still sit in the restored 16550 RX FIFO, so a future shell
# could read stale bytes first. Judge command OUTPUT, not
# echo: the Step 13 echoes prove a tty with echo enabled,
# not a reader. A re-panic with -8 means the patched disk
# did NOT take effect on resume -- report it as exactly
# that, not as a new kernel bug.
#
# Binary: sim/tb_kboot_ckpt.vvp built 30 Oct 14:42 UTC from
# the drain-fixed sources (fix line src/big32_soc2.v:850).
# Skip-jent configuration only; full-config grind from
# ckpt_cont160/ (170M) remains open and separate.
#
# Two explicit-cap segments, never uncapped loop mode.
# Survives VM restarts only by being re-run: it always
# resumes from the newest complete checkpoint in
# ckpt_ephnum_fixed_cont230/.
# Log: kernel/boot_attempt18_skipjent_fixedcore_cont230_fixedinit.log
# (NEW file -- all earlier logs untouched).
set -u
cd "$(dirname "$0")/.."

LOG=kernel/boot_attempt18_skipjent_fixedcore_cont230_fixedinit.log
DIR=ckpt_ephnum_fixed_cont230
PROG=kernel/skipjent_fixedcore_cont230_fixedinit_progress.log
VVP=sim/tb_kboot_ckpt.vvp
DTB=soc2_hex/big32_kboot_10mhz_rootfs_skipjent.dtb.txt

VVP_MFLAG=""
ensure_vvp() {
    # Whatever vvp resolves to, if it is the extracted-tree
    # binary it needs -M: its compiled-in VPI path points at
    # /usr/lib/... which does not exist here, so without -M
    # it loads no system tasks ($display undefined) and the
    # run dies in ~1 s. A system-installed vvp needs no flag.
    if ! command -v vvp >/dev/null 2>&1; then
        if [ -x .iverilog-local/usr/bin/vvp ]; then
            export PATH="$PWD/.iverilog-local/usr/bin:$PATH"
        else
            echo "$(date -u +%FT%TZ) vvp missing (VM restart); extracting cached deb via dpkg-deb (no dpkg lock)" >> "$PROG"
            dpkg-deb -x iverilog_12.0-2build2_amd64.deb .iverilog-local >> "$PROG" 2>&1
            export PATH="$PWD/.iverilog-local/usr/bin:$PATH"
        fi
    fi
    case "$(command -v vvp)" in
        "$PWD"/.iverilog-local/*) VVP_MFLAG="-M $PWD/.iverilog-local/usr/lib/x86_64-linux-gnu/ivl" ;;
        *) VVP_MFLAG="" ;;
    esac
    # The .vvp bakes absolute VPI paths (/usr/lib/.../ivl/*.vpi)
    # from compile time; the extracted tree does not satisfy
    # them, so vvp loads no system tasks and dies in ~1 s.
    # Symlink the extracted modules into place (no-op if
    # already there; /usr is ephemeral, so redo on restart).
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
echo "$(date -u +%FT%TZ) skipjent ephnum-fixed cont230 start; latest checkpoint: $(latest); vvp: $(ls -la --time-style=long-iso "$VVP" | awk '{print $6, $7}')" >> "$PROG"

run_one() {
    # $1 = target cycle
    local target="$1" before after
    before="$(latest)"
    ensure_vvp || { echo "$(date -u +%FT%TZ) ERROR: vvp unavailable" >> "$PROG"; exit 1; }
    echo "$(date -u +%FT%TZ) segment: resume $before -> $target" >> "$PROG"
    # shellcheck disable=SC2086
    stdbuf -oL -eL vvp $VVP_MFLAG "$VVP" \
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

echo "$(date -u +%FT%TZ) skipjent ephnum-fixed cont230 complete: 230M cap reached" >> "$PROG"
exit 0
