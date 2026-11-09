#!/bin/bash
# run_cont250_open.sh -- Step 29 open-ended full-config grind from 250M.
# Resumes from ckpt_cont170_run/ckpt_250000000, banked by Step 28
# (12:33:22Z 8 Nov 2026, runner exit 0, verdict PARTIAL -- jent
# still grinding at 250M, ZERO new UART lines).
# Authorization: Jayant 8 Nov ~23:31 IST ("At the engine ultimate
# form" / "Grind until jent finishes, however long it takes").
# NO CAP: 10M segments 260/270/280/... computed dynamically as
# latest+10M (no fixed target list -- avoids the Steps 27/28
# retry-loop quirk of walking already-passed targets as no-ops
# after a relaunch). Stops ONLY on kernel panic, HALTED: 1, or
# a finish marker (prompt "big32# ", "[342] console [ttyS0]
# enabled", "Run /init", "Freeing unused kernel image").
# Disk: the banked 250M .disk payload md5 is
# c073ba7f766976b265d6b0057edb8d6f (1,048,576 bytes) == the
# current patched rootfs image; verified pre-flight by parsing
# the hex text back to binary (the .disk FILE md5
# 9da95d3bf4dea5887b9514e0f82ed845 matches ckpt_catecho210/'s).
# NO rewrite. ckpt_cont160/ and ckpt_catecho210/ stay pristine
# (baselines in work/step29_pristine_baseline.txt); checkpoints
# land in the SAME ckpt_cont170_run/ dir.
# Header untouched: rx2idx=50, rx2next=150100000 -- the
# attempt-17 feed rootfs/rx_cmds.txt is fully consumed, so no
# re-feed; judge prompt/banner/serial/virtio/root-mount only.
# Shell fixes explicitly NOT judged. Full-config DTB (NOT
# skipjent): soc2_hex/big32_kboot_10mhz_rootfs.dtb.txt.
# Each segment is one explicit-cap resume (never loop mode).
# Survives VM restarts only by being re-run: it always resumes
# from the newest complete checkpoint in ckpt_cont170_run/.
# Log: kernel/boot_attempt17_cont250_open.log (NEW file).
# Watermark: kernel/cont250_open_watermark.txt (baseline
# 250000000, updated per landed segment).
set -u
cd "$(dirname "$0")/.."

LOG=kernel/boot_attempt17_cont250_open.log
DIR=ckpt_cont170_run
PROG=kernel/cont250_open_progress.log
WM=kernel/cont250_open_watermark.txt
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

finished() {
    grep -a -q "Kernel panic" "$LOG" 2>/dev/null && { echo "kernel panic in log"; return 0; }
    grep -a -q "HALTED: 1" "$LOG" 2>/dev/null && { echo "HALTED: 1 in log"; return 0; }
    grep -a -q "big32# " "$LOG" 2>/dev/null && { echo "prompt in log"; return 0; }
    grep -a -q "console \[ttyS0\] enabled" "$LOG" 2>/dev/null && { echo "serial console enabled in log"; return 0; }
    grep -a -q "Run /init" "$LOG" 2>/dev/null && { echo "Run /init in log"; return 0; }
    grep -a -q "Freeing unused kernel image" "$LOG" 2>/dev/null && { echo "freeing unused kernel image in log"; return 0; }
    return 1
}

mkdir -p "$DIR"
touch "$LOG" "$PROG"
[ -f "$WM" ] || echo "250000000" > "$WM"
echo "$(date -u +%FT%TZ) cont250_open start; latest checkpoint: $(latest); vvp: $(ls -la --time-style=long-iso "$VVP" | awk '{print $6, $7}'); run dir ckpt_cont170_run (250M banked Step 28, .disk payload c073ba7f..., no rewrite); full-config DTB; OPEN-ENDED, no cap" >> "$PROG"

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
    echo "$after" > "$WM"
}

while true; do
    before="$(latest)"
    target=$((before + 10000000))
    tries=0
    while [ "$tries" -lt 3 ]; do
        run_one "$target"
        after="$(latest)"
        if [ "$after" != "$before" ]; then break; fi
        tries=$((tries + 1))
        echo "$(date -u +%FT%TZ) no progress, retry $tries/3 for $target" >> "$PROG"
    done
    after="$(latest)"
    if [ "$after" = "$before" ]; then
        echo "$(date -u +%FT%TZ) STOP: segment $target failed 3x with no progress -- needs human look, not silent retry" >> "$PROG"
        exit 1
    fi
    if reason="$(finished)"; then
        echo "$(date -u +%FT%TZ) STOP: finish criteria met ($reason) at $after" >> "$PROG"
        exit 0
    fi
    # Otherwise: still grinding, next 10M segment. No cap.
done
