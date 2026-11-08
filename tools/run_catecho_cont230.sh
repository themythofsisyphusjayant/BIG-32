#!/bin/bash
# run_catecho_cont230.sh -- attempt 18 STEP 26 continuation:
# skip-jent boot resumed from the CATECHO 210M checkpoint under
# the FIXED core + FIXED virtio model (v1 fix + drain fix),
# explicit 230M cap, in two 10M segments (210M->220M, 220M->230M).
#
# Why this continuation: Step 25 fixed the bare-`cat` / bare-`echo`
# no-arg quirk at file level only (do_echo: beq s1,s0,echo_nl;
# do_cat: beq s1,s0,cat_missing; init still 3440 bytes). This run
# boot-proves it (STEP 26).
#
# CRITICAL resume point: ckpt_catecho_run/ is a copy of
# ckpt_catecho210/ with ONLY header lines 2-3 of the 210M header
# changed (rx2idx 50->0, rx2next 209100000->225000000); diff
# verified to show exactly those two lines, RAM md5 identical,
# .disk payload md5 = patched image md5 c7f34183... .
# ckpt_catecho210/ stays pristine. Do NOT resume from ckpt_lsfix/
# (220M: old code resident in RAM, proves nothing), ckpt_lsfix_run/
# (230M: old code resident), the Step 17 220M panic-loop
# checkpoint, the unpatched 210M original, ckpt_skipjent_cont150/,
# ckpt_skipjent_repro110/, or ckpt_skipjent_fixedcore_cont160/.
#
# RX arming choice, documented: Run /init lands at ~219M and
# the banner + prompt follow immediately, so the shell is
# waiting well before 225M; arming at 225M means a clean feed
# into a waiting shell. Feed (hex-per-line, as the testbench's
# $fscanf "%h" requires): bare `cat`, bare `echo`, then
# `echo hello` and `cat /hello.txt` as controls (35 bytes).
# Stale bytes from earlier feeds may arrive first in segment 1
# (as in Step 22); judge the 225M feed's OUTPUT, not echo.
# Bare cat -> "cat: cat: cannot open" or bare echo -> "echo"
# means the fix did NOT take effect -- report it as exactly
# that, with resume-path evidence, not as a new kernel bug.
#
# Binary: sim/tb_kboot_ckpt.vvp built 30 Oct 14:42 UTC from
# the drain-fixed sources (soc2.v 14:26 UTC; fix line
# src/big32_soc2.v:850). Skip-jent configuration only;
# full-config grind from ckpt_cont160/ (170M) remains open
# and separate.
#
# Two explicit-cap segments, never uncapped loop mode.
# Survives VM restarts only by being re-run: it always
# resumes from the newest complete checkpoint in
# ckpt_catecho_run/.
# Log: kernel/boot_attempt18_skipjent_fixedcore_cont230_catecho.log
# (NEW file -- all earlier logs untouched).
set -u
cd "$(dirname "$0")/.."

LOG=kernel/boot_attempt18_skipjent_fixedcore_cont230_catecho.log
DIR=ckpt_catecho_run
PROG=kernel/skipjent_fixedcore_cont230_catecho_progress.log
VVP=sim/tb_kboot_ckpt.vvp
DTB=soc2_hex/big32_kboot_10mhz_rootfs_skipjent.dtb.txt

VVP_MFLAG=""
ensure_vvp() {
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
echo "$(date -u +%FT%TZ) skipjent catecho cont230 start; latest checkpoint: $(latest); vvp: $(ls -la --time-style=long-iso "$VVP" | awk '{print $6, $7}')" >> "$PROG"

run_one() {
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
        +RX2FILE=rootfs/rx_catecho.txt +RX2PERIOD=2000 \
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
done

echo "$(date -u +%FT%TZ) skipjent catecho cont230 complete: 230M cap reached" >> "$PROG"
exit 0
