#!/bin/bash
# run_tty_trace_140m.sh -- PC trace 140M->150M from a BYTE-EXACT copy of
# the FIXED-CORE 140M checkpoint set in ckpt_skipjent_fixedcore/.
# Purpose: function attribution across the serial8250 [342] probe window
# (the "Serial:" line at ~147M, the "console [ttyS0] disabled" line at
# ~149M) to learn whether of_platform_serial_probe /
# serial8250_register_8250_port / uart_configure_port / uart_report_port /
# register_console execute, and where execution goes after the disable.
# The trace testbench (sim/tb_kboot_ckpt_trace.v, Oct-28 fork) differs
# from the current sim/tb_kboot_ckpt.v ONLY by trace additions (diff
# verified: all hunks are trace-only), so recompiling it against the
# CURRENT (fixed) core sources yields a fixed-core trace binary.
# No checkpoint is taken by this run (no CKPTAT). The 140M header
# (rx2idx=1, rx2next=140002000) means the RX feed's first byte landed
# at the checkpoint cycle; resuming from it replays the remaining feed
# exactly as the fixed-core run did -- moot, since no shell exists yet.
# Single explicit-cap segment (150M), never uncapped loop mode.
set -u
cd "$(dirname "$0")/.."

LOG=kernel/tty_trace_140m_run.log
DIR=ckpt_tty_trace
PROG=kernel/tty_trace_140m_progress.log
VVP=sim/tb_kboot_ckpt_trace_fixed.vvp
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

mkdir -p "$DIR"
touch "$LOG" "$PROG"

# Byte-exact copy of the fixed-core 140M checkpoint set (once only).
if [ ! -f "$DIR/ckpt_140000000.done" ]; then
    cp ckpt_skipjent_fixedcore/ckpt_140000000.* "$DIR"/
    echo "$(date -u +%FT%TZ) copied fixed-core 140M checkpoint set into $DIR" >> "$PROG"
    diff ckpt_skipjent_fixedcore/ckpt_140000000.hdr "$DIR/ckpt_140000000.hdr" >> "$PROG" 2>&1 \
        && echo "$(date -u +%FT%TZ) header copy verified byte-identical" >> "$PROG"
fi

if [ ! -x "$VVP" ]; then
    echo "$(date -u +%FT%TZ) compiling trace testbench against fixed core" >> "$PROG"
    iverilog -o "$VVP" -Ptb_kboot_ckpt_trace.TB_MEM_BYTES=67108864 \
        src/big32_core_pipe.v src/big32_soc2.v sim/tb_kboot_ckpt_trace.v >> "$PROG" 2>&1 || exit 1
fi

ensure_vvp || { echo "$(date -u +%FT%TZ) ERROR: vvp reinstall failed" >> "$PROG"; exit 1; }
echo "$(date -u +%FT%TZ) segment: tty trace resume 140000000 -> 150000000" >> "$PROG"
stdbuf -oL -eL vvp "$VVP" \
    +HEX=soc2_hex/kboot_fw.hex +DISKHEX=soc2_hex/rootfs_disk.hex \
    +DTBFILE="$DTB" +DTBOFF=131072 \
    +KIMGBIN=kernel/linux-6.6.52/arch/riscv/boot/Image +KIMGOFF=4194304 +NOCLEAR \
    +CKPTDIR="$DIR" +RESUME=140000000 +MAXCYCLES=150000000 \
    +TRACEFILE=kernel/pc_trace_tty.txt +TRACESNAPFILE=kernel/pc_trace_tty_snap.txt \
    +TRACEPERIOD=100 +SNAPPERIOD=500000 \
    >> "$LOG" 2>&1
echo "$(date -u +%FT%TZ) segment done: 140000000 -> 150000000" >> "$PROG"
grep -a "TRACE_SAMPLES\|CYCLES:" "$LOG" | tail -3 >> "$PROG" 2>&1
echo "$(date -u +%FT%TZ) latest UART lines:" >> "$PROG"
grep -a "^\[" "$LOG" | tail -5 >> "$PROG" 2>&1
exit 0
