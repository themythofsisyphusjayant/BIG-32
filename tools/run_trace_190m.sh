#!/bin/bash
# run_trace_190m.sh -- PC trace 190M->200M from a BYTE-EXACT copy of the
# FIXED-MODEL 190M checkpoint set in ckpt_skipjent_fixedcore_cont190/.
# Purpose (STEP 12): discriminate "progressing through late initcalls
# after virtio [357]" vs "stuck" for the 170M->190M silent window
# (ZERO new UART lines), exactly as the 100M/160M traces discriminated
# the jent loop. The trace testbench (sim/tb_kboot_ckpt_trace.v) differs
# from sim/tb_kboot_ckpt.v ONLY by trace additions (diff verified:
# 66 lines, all trace-only), so compiling it against the CURRENT
# sources yields a fixed-core + fixed-virtio-model trace binary.
# IMPORTANT: the old sim/tb_kboot_ckpt_trace_fixed.vvp (08:37 UTC
# 30 Oct) PREDATES the virtio model fix (soc2.v 09:42 UTC) and must
# NOT be reused -- this runner compiles a fresh binary
# sim/tb_kboot_ckpt_trace_fixed_v1.vvp from current sources.
# No checkpoint is taken by this run (no CKPTAT). The 190M header
# (rx2idx=50, rx2next=189100000) means the RX feed is fully consumed;
# no RX bytes land during the trace. Single explicit-cap segment
# (200M), never uncapped loop mode.
set -u
cd "$(dirname "$0")/.."

LOG=kernel/trace_190m_run.log
DIR=ckpt_trace_190m
PROG=kernel/trace_190m_progress.log
VVP=sim/tb_kboot_ckpt_trace_fixed_v1.vvp
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

# Byte-exact copy of the fixed-model 190M checkpoint set (once only).
if [ ! -f "$DIR/ckpt_190000000.done" ]; then
    cp ckpt_skipjent_fixedcore_cont190/ckpt_190000000.* "$DIR"/
    echo "$(date -u +%FT%TZ) copied fixed-model 190M checkpoint set into $DIR" >> "$PROG"
    diff ckpt_skipjent_fixedcore_cont190/ckpt_190000000.hdr "$DIR/ckpt_190000000.hdr" >> "$PROG" 2>&1 \
        && echo "$(date -u +%FT%TZ) header copy verified byte-identical" >> "$PROG"
    md5sum ckpt_skipjent_fixedcore_cont190/ckpt_190000000.ram "$DIR/ckpt_190000000.ram" >> "$PROG" 2>&1
fi

# Force a fresh compile against CURRENT sources (fixed core + fixed model).
echo "$(date -u +%FT%TZ) compiling trace testbench against current sources" >> "$PROG"
grep -n "v_feat_sel == 32'd1" src/big32_soc2.v >> "$PROG" 2>&1
iverilog -o "$VVP" -Ptb_kboot_ckpt_trace.TB_MEM_BYTES=67108864 \
    src/big32_core_pipe.v src/big32_soc2.v sim/tb_kboot_ckpt_trace.v >> "$PROG" 2>&1 || exit 1
echo "$(date -u +%FT%TZ) trace binary built: $(ls -la --time-style=full-iso "$VVP" | awk '{print $6, $7}')" >> "$PROG"

ensure_vvp || { echo "$(date -u +%FT%TZ) ERROR: vvp reinstall failed" >> "$PROG"; exit 1; }
echo "$(date -u +%FT%TZ) segment: pc trace resume 190000000 -> 200000000" >> "$PROG"
stdbuf -oL -eL vvp "$VVP" \
    +HEX=soc2_hex/kboot_fw.hex +DISKHEX=soc2_hex/rootfs_disk.hex \
    +DTBFILE="$DTB" +DTBOFF=131072 \
    +KIMGBIN=kernel/linux-6.6.52/arch/riscv/boot/Image +KIMGOFF=4194304 +NOCLEAR \
    +CKPTDIR="$DIR" +RESUME=190000000 +MAXCYCLES=200000000 \
    +TRACEFILE=kernel/pc_trace_190m.txt +TRACESNAPFILE=kernel/pc_trace_190m_snap.txt \
    +TRACEPERIOD=100 +SNAPPERIOD=500000 \
    >> "$LOG" 2>&1
echo "$(date -u +%FT%TZ) segment done: 190000000 -> 200000000" >> "$PROG"
grep -a "TRACE_SAMPLES\|CYCLES:\|CNT_INT" "$LOG" | tail -5 >> "$PROG" 2>&1
echo "$(date -u +%FT%TZ) latest UART lines:" >> "$PROG"
grep -a "^\[" "$LOG" | tail -5 >> "$PROG" 2>&1
exit 0
