#!/bin/bash
# run_trace_210m.sh -- PC trace 210M->220M from a BYTE-EXACT copy of the
# FIXED-MODEL 210M checkpoint set in ckpt_skipjent_fixedcore_cont210/.
# Purpose (STEP 14): locate where the kernel is parked between
# root-mount (Step 13: EXT4 mounted, VFS root mounted, 18.815-18.819 s)
# and "Run /init" -- a NEW parking question, distinct from every
# earlier silence: do_initcalls are DONE (Step 12: [553]/555), so map
# samples against the kernel_init path (rest_init / kernel_init /
# kernel_init_freeable / prepare_namespace / mount_root /
# run_init_process / tty read), NOT the initcall table.
# The trace testbench (sim/tb_kboot_ckpt_trace.v) differs from
# sim/tb_kboot_ckpt.v ONLY by trace additions (diff verified at
# Step 12: 66 lines, all trace-only), so compiling it against the
# CURRENT sources yields a fixed-core + fixed-virtio-model trace
# binary. The old sim/tb_kboot_ckpt_trace_fixed.vvp PREDATES the
# virtio model fix and must NOT be reused -- this runner compiles
# a fresh binary sim/tb_kboot_ckpt_trace_fixed_v1.vvp from current
# sources and verifies the fix line first.
# No checkpoint is taken by this run (no CKPTAT). The 210M header
# (rx2idx=50, rx2next=209100000) means the RX feed is fully consumed;
# no RX bytes land during the trace. Single explicit-cap segment
# (220M), never uncapped loop mode.
# Icarus handling (Step 13 lesson): if a VM restart wiped the apt
# binaries, prefer the lock-free dpkg-deb -x extraction into
# .iverilog-local/ over waiting out the post-restart apt replay's
# dpkg lock (which held through 47+ attempts at Step 13).
set -u
cd "$(dirname "$0")/.."

LOG=kernel/trace_210m_run.log
DIR=ckpt_trace_210m
PROG=kernel/trace_210m_progress.log
VVP=sim/tb_kboot_ckpt_trace_fixed_v1.vvp
DTB=soc2_hex/big32_kboot_10mhz_rootfs_skipjent.dtb.txt

ensure_iverilog() {
    if command -v iverilog >/dev/null 2>&1 && command -v vvp >/dev/null 2>&1; then return 0; fi
    if [ -x .iverilog-local/usr/bin/vvp ] && [ -x .iverilog-local/usr/bin/iverilog ]; then
        export PATH="$PWD/.iverilog-local/usr/bin:$PATH"
        echo "$(date -u +%FT%TZ) using existing .iverilog-local extraction" >> "$PROG"
        return 0
    fi
    echo "$(date -u +%FT%TZ) iverilog/vvp missing; extracting cached deb (lock-free)" >> "$PROG"
    dpkg-deb -x iverilog_12.0-2build2_amd64.deb .iverilog-local >> "$PROG" 2>&1 || return 1
    export PATH="$PWD/.iverilog-local/usr/bin:$PATH"
    command -v vvp >/dev/null 2>&1
}

mkdir -p "$DIR"
touch "$LOG" "$PROG"

# Byte-exact copy of the fixed-model 210M checkpoint set (once only).
if [ ! -f "$DIR/ckpt_210000000.done" ]; then
    cp ckpt_skipjent_fixedcore_cont210/ckpt_210000000.* "$DIR"/
    echo "$(date -u +%FT%TZ) copied fixed-model 210M checkpoint set into $DIR" >> "$PROG"
    diff ckpt_skipjent_fixedcore_cont210/ckpt_210000000.hdr "$DIR/ckpt_210000000.hdr" >> "$PROG" 2>&1 \
        && echo "$(date -u +%FT%TZ) header copy verified byte-identical" >> "$PROG"
    md5sum ckpt_skipjent_fixedcore_cont210/ckpt_210000000.ram "$DIR/ckpt_210000000.ram" >> "$PROG" 2>&1
fi

ensure_iverilog || { echo "$(date -u +%FT%TZ) ERROR: iverilog recovery failed" >> "$PROG"; exit 1; }

# Force a fresh compile against CURRENT sources (fixed core + fixed model).
echo "$(date -u +%FT%TZ) compiling trace testbench against current sources" >> "$PROG"
grep -n "v_feat_sel == 32'd1" src/big32_soc2.v >> "$PROG" 2>&1
iverilog -o "$VVP" -Ptb_kboot_ckpt_trace.TB_MEM_BYTES=67108864 \
    src/big32_core_pipe.v src/big32_soc2.v sim/tb_kboot_ckpt_trace.v >> "$PROG" 2>&1 || exit 1
echo "$(date -u +%FT%TZ) trace binary built: $(ls -la --time-style=full-iso "$VVP" | awk '{print $6, $7}')" >> "$PROG"

echo "$(date -u +%FT%TZ) segment: pc trace resume 210000000 -> 220000000" >> "$PROG"
stdbuf -oL -eL vvp "$VVP" \
    +HEX=soc2_hex/kboot_fw.hex +DISKHEX=soc2_hex/rootfs_disk.hex \
    +DTBFILE="$DTB" +DTBOFF=131072 \
    +KIMGBIN=kernel/linux-6.6.52/arch/riscv/boot/Image +KIMGOFF=4194304 +NOCLEAR \
    +CKPTDIR="$DIR" +RESUME=210000000 +MAXCYCLES=220000000 \
    +TRACEFILE=kernel/pc_trace_210m.txt +TRACESNAPFILE=kernel/pc_trace_210m_snap.txt \
    +TRACEPERIOD=100 +SNAPPERIOD=500000 \
    >> "$LOG" 2>&1
echo "$(date -u +%FT%TZ) segment done: 210000000 -> 220000000" >> "$PROG"
grep -a "TRACE_SAMPLES\|CYCLES:\|CNT_INT" "$LOG" | tail -5 >> "$PROG" 2>&1
echo "$(date -u +%FT%TZ) latest UART lines:" >> "$PROG"
grep -a "^\[" "$LOG" | tail -5 >> "$PROG" 2>&1
exit 0
