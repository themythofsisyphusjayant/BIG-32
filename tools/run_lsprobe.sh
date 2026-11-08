#!/bin/bash
# run_lsprobe.sh -- short discriminating probe for the Step 22 `ls` failure.
# Resumes from a COPY of the intact 220M shell-alive set (ckpt_addrfix_run/,
# original untouched) with ONLY the 220M header rx2next changed (225M -> feed
# cycle given by PROBE_FEED, default 221M). Feeds PROBE_RX (default
# work/lsprobe/rx_lsprobe.txt: "ls /", "ls", "pwd") and stops at PROBE_CAP.
# Discriminator: if `ls /` lists the root directory while bare `ls` fails,
# openat+getdents64 work and the bug is purely the no-argument path
# (parse leaves s1 = linebuf when no space is found, so bare `ls` opens
# a file literally named "ls"). If `ls /` ALSO fails, the bug is deeper.
# Never uncapped loop mode; log is NEW (kernel/ls_probe1.log).
# Usage: PROBE_FEED=221000000 PROBE_CAP=223000000 PROBE_RX=work/lsprobe/rx_lsprobe.txt \
#   PROBE_DIR=work/lsprobe PROBE_LOG=kernel/ls_probe1.log tools/run_lsprobe.sh
set -u
cd "$(dirname "$0")/.."

DIR="${PROBE_DIR:-work/lsprobe}"
LOG="${PROBE_LOG:-kernel/ls_probe1.log}"
PROG="${PROBE_LOG:-kernel/ls_probe1.log}.progress"
VVP=sim/tb_kboot_ckpt.vvp
DTB=soc2_hex/big32_kboot_10mhz_rootfs_skipjent.dtb.txt
FEED="${PROBE_FEED:-221000000}"
CAP="${PROBE_CAP:-223000000}"
RXF="${PROBE_RX:-work/lsprobe/rx_lsprobe.txt}"

VVP_MFLAG=""
ensure_vvp() {
    if ! command -v vvp >/dev/null 2>&1; then
        if [ -x .iverilog-local/usr/bin/vvp ]; then
            export PATH="$PWD/.iverilog-local/usr/bin:$PATH"
        else
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

touch "$LOG" "$PROG"
ensure_vvp || { echo "$(date -u +%FT%TZ) ERROR: vvp unavailable" >> "$PROG"; exit 1; }
echo "$(date -u +%FT%TZ) ls probe start: resume 220M -> $CAP, feed $RXF at $FEED" >> "$PROG"
# shellcheck disable=SC2086
stdbuf -oL -eL vvp $VVP_MFLAG "$VVP" \
    +HEX=soc2_hex/kboot_fw.hex +DISKHEX=soc2_hex/rootfs_disk.hex \
    +DTBFILE="$DTB" +DTBOFF=131072 \
    +KIMGBIN=kernel/linux-6.6.52/arch/riscv/boot/Image +KIMGOFF=4194304 +NOCLEAR \
    +CKPTDIR="$DIR" +RESUME=220000000 +MAXCYCLES="$CAP" +CKPTAT="$CAP" \
    +RX2FILE="$RXF" +RX2PERIOD=2000 \
    >> "$LOG" 2>&1
echo "$(date -u +%FT%TZ) ls probe done" >> "$PROG"
ls "$DIR"/ckpt_"$CAP".done >> "$PROG" 2>&1
