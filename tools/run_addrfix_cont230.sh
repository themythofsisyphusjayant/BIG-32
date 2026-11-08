#!/bin/bash
# run_addrfix_cont230.sh -- attempt 18 STEP 22 continuation:
# skip-jent boot resumed from the ADDRFIX 210M checkpoint under
# the FIXED core + FIXED virtio model (v1 fix + drain fix),
# explicit 230M cap, in two 10M segments (210M->220M, 220M->230M).
#
# Why this continuation, and why now: Step 21 fixed mkelf.py's
# 84-byte address skew (layout() now starts at BASE+HDR, HDR=84;
# _start = 0x10054; every label VA = 0x10000 + file offset;
# filesz/memsz = 3440 whole file; e_phnum=1 KEPT). The image
# was patched IN PLACE (dd first 2048 bytes at offset 21504;
# inode 15, size 3440, extents 21-22 UNCHANGED), the disk hex
# regenerated (55 lines), and ckpt_addrfix/ built from
# ckpt_ephnum_fixed/'s 210M set with ONLY its 210M .disk
# payload replaced (payload md5 = patched image md5
# e60dd5b5...; ELF magic at payload byte 21504, e_phnum=1 at
# 21548). At 210M the kernel has mounted root but has NOT
# exec'd /init yet (Run /init comes at ~219M), so replacing
# the disk under the mounted-but-not-yet-exec'd root is safe.
#
# CRITICAL resume point: ckpt_addrfix_run/ is a copy of
# ckpt_addrfix/ with ONLY header lines 2-3 of the 210M header
# changed (rx2idx 50->0, rx2next 209100000->225000000); diff
# verified to show exactly those two lines, RAM md5
# identical, .disk md5 identical. ckpt_addrfix/ stays
# pristine. Do NOT resume from 230M for the fixed boot (its
# RAM holds the OLD init), the Step 17 220M panic-loop
# checkpoint, the unpatched 210M original,
# ckpt_skipjent_cont150/, ckpt_skipjent_repro110/, or
# ckpt_skipjent_fixedcore_cont160/.
#
# RX arming choice, documented: Run /init lands at ~219M and
# the banner + prompt follow immediately, so the shell is
# waiting well before 225M; arming at 225M means a clean feed
# into a waiting shell, with 5M cycles of margin to the cap
# for outputs. Feeding earlier would risk bytes lost past
# the 16-byte FIFO only if the prompt slipped past the feed;
# feeding at 225M keeps that risk negligible while leaving
# room to observe. Trade-off: if the prompt appears AFTER
# 225M, the feed is moot and a header-copy re-arm from the
# 230M checkpoint is the follow-up. Caveat: stale bytes from
# earlier feeds may still sit in the restored 16550 RX FIFO,
# so a future shell could read stale bytes first. Judge
# command OUTPUT, not echo: the Step 13/19 echoes prove a
# tty with echo enabled, not a reader. A re-panic with -8
# means the patched disk did NOT take effect on resume --
# report it as exactly that, not as a new kernel bug.
# Garbled output in the OLD shape (banner tail + fused
# suffix) means the skew fix did NOT take effect -- report
# it as exactly that, with byte evidence. Also check the
# Step 20 banner-tail comma once, either way.
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
# ckpt_addrfix_run/.
# Log: kernel/boot_attempt18_skipjent_fixedcore_cont230_addrfix.log
# (NEW file -- all earlier logs untouched).
set -u
cd "$(dirname "$0")/.."

LOG=kernel/boot_attempt18_skipjent_fixedcore_cont230_addrfix.log
DIR=ckpt_addrfix_run
PROG=kernel/skipjent_fixedcore_cont230_addrfix_progress.log
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
    # The .vvp bakes absolute VPI paths (/usr/lib/.../ivl/*.vpi)
    # from compile time; symlink the extracted modules into
    # place (no-op if already there; /usr is ephemeral).
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
echo "$(date -u +%FT%TZ) skipjent addrfix cont230 start; latest checkpoint: $(latest); vvp: $(ls -la --time-style=long-iso "$VVP" | awk '{print $6, $7}')" >> "$PROG"

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

echo "$(date -u +%FT%TZ) skipjent addrfix cont230 complete: 230M cap reached" >> "$PROG"
exit 0
