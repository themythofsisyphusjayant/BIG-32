#!/bin/bash
# run_cont170_220.sh -- Step 27 full-config grind 170M -> 220M.
# Resumes from ckpt_cont170_run/ckpt_170000000, a COPY of the banked
# 170M checkpoint in ckpt_cont160/ whose ONLY change is its .disk:
# rewritten from the current patched rootfs image (md5
# c073ba7f766976b265d6b0057edb8d6f) because the banked 170M .disk
# payload is the PRE-ephnum-fix image (md5 643e7c5f..., e_phnum
# byte 0x00) -- as-is, /init would ENOEXEC and no prompt could ever
# be judged even if jent finishes. Verification (Step 25 standard):
# copy payload md5 == current image, byte-identical; byte 21504 =
# 0x7f, byte 21548 = 0x01; header identical, RAM md5 identical,
# done/hdr/pix/vram identical; /init inode 15 size 3440 extents
# 21-22 in the current image. ckpt_cont160/ stays pristine.
# Header untouched: rx2idx=50, rx2next=150100000 -- the attempt-17
# feed rootfs/rx_cmds.txt is fully consumed, so no re-feed; the
# first 16 feed bytes may still sit in the 16550 RX FIFO, so any
# command output after a prompt is stale-FIFO artefact, NOT clean
# evidence. Judge prompt/banner/serial/virtio/root-mount only.
# Full-config DTB (NOT skipjent): soc2_hex/big32_kboot_10mhz_rootfs.dtb.txt.
# Each segment is one explicit-cap resume (never loop mode).
# Stops early on HALTED, kernel panic, or prompt + command output.
# Survives VM restarts only by being re-run: it always resumes
# from the newest complete checkpoint in ckpt_cont170_run/.
# Log: kernel/boot_attempt17_cont170_220.log (NEW file; the
# full-config story stays in kernel/boot_attempt17.log).
set -u
cd "$(dirname "$0")/.."

LOG=kernel/boot_attempt17_cont170_220.log
DIR=ckpt_cont170_run
PROG=kernel/cont170_220_progress.log
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
echo "$(date -u +%FT%TZ) cont170_220 start; latest checkpoint: $(latest); vvp: $(ls -la --time-style=long-iso "$VVP" | awk '{print $6, $7}'); run dir ckpt_cont170_run (copy of ckpt_cont160 170M, .disk rewritten to current image c073ba7f...); full-config DTB" >> "$PROG"

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

for target in 180000000 190000000 200000000 210000000 220000000; do
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

echo "$(date -u +%FT%TZ) cont170_220 complete: 220M cap reached" >> "$PROG"
exit 0
