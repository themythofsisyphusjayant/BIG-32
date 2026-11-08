#!/bin/bash
# run_csr_trace_100m.sh -- CSR-write trace 100M->104.1M from a
# BYTE-EXACT copy of the ORIGINAL 100M checkpoint set in ckpt_skipjent/.
# NOT the cont150 copy, NOT the repro110 copy, NOT any 104.1M panic-loop
# checkpoint. The original 100M header has rx2idx=50, rx2next=50100000
# (attempt-18 RX feed fully consumed), so this segment feeds nothing.
# Same skip-jent configuration as attempt 18 (blacklist DTB, 10 MHz,
# attempt-12 firmware, virtio-blk rootfs). Single explicit-cap segment
# (104.1M), never uncapped loop mode. The priv-trace testbench
# (sim/tb_kboot_ckpt_csr.v) logs EVERY CSR write to sstatus/sepc to
# kernel/csr_trace_100m.txt (plus a priv cross-check log); the UART log goes to
# kernel/csr_trace_100m_run.log. ckpt_skipjent/ itself is untouched.
# No checkpoint is taken by this run (no CKPTAT): the 104.1M panic-loop
# state must NOT be banked over anything useful.
set -u
cd "$(dirname "$0")/.."

LOG=kernel/csr_trace_100m_run.log
DIR=ckpt_skipjent_csr
PROG=kernel/csr_trace_100m_progress.log
VVP=sim/tb_kboot_ckpt_csr.vvp
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

# Byte-exact copy of the original 100M checkpoint set (once only).
if [ ! -f "$DIR/ckpt_100000000.done" ]; then
    cp ckpt_skipjent/ckpt_100000000.* "$DIR"/
    echo "$(date -u +%FT%TZ) copied original 100M checkpoint set into $DIR" >> "$PROG"
    diff ckpt_skipjent/ckpt_100000000.hdr "$DIR/ckpt_100000000.hdr" >> "$PROG" 2>&1 \
        && echo "$(date -u +%FT%TZ) header copy verified byte-identical (rx2idx=50, rx2next=50100000)" >> "$PROG"
fi

if [ ! -x "$VVP" ]; then
    echo "$(date -u +%FT%TZ) compiling priv testbench" >> "$PROG"
    iverilog -o "$VVP" -Ptb_kboot_ckpt_csr.TB_MEM_BYTES=67108864 \
        src/big32_core_pipe.v src/big32_soc2.v sim/tb_kboot_ckpt_csr.v >> "$PROG" 2>&1 || exit 1
fi

ensure_vvp || { echo "$(date -u +%FT%TZ) ERROR: vvp reinstall failed" >> "$PROG"; exit 1; }
echo "$(date -u +%FT%TZ) segment: priv trace resume 100000000 -> 104100000 (original checkpoint)" >> "$PROG"
stdbuf -oL -eL vvp "$VVP" \
    +HEX=soc2_hex/kboot_fw.hex +DISKHEX=soc2_hex/rootfs_disk.hex \
    +DTBFILE="$DTB" +DTBOFF=131072 \
    +KIMGBIN=kernel/linux-6.6.52/arch/riscv/boot/Image +KIMGOFF=4194304 +NOCLEAR \
    +CKPTDIR="$DIR" +RESUME=100000000 +MAXCYCLES=104100000 \
    +TRACEFILE=kernel/pc_trace_csr.txt +TRACESNAPFILE=kernel/pc_trace_csr_snap.txt \
    +PRIVFILE=kernel/priv_trace_csr_run.txt +CSRFILE=kernel/csr_trace_100m.txt +SNAPPERIOD=0 \
    >> "$LOG" 2>&1
echo "$(date -u +%FT%TZ) segment done: 100000000 -> 104100000" >> "$PROG"
grep -a "CSR_EVENTS\|CYCLES:" "$LOG" | tail -3 >> "$PROG" 2>&1
grep -a "latest UART lines" "$LOG" >> "$PROG" 2>&1 || true
echo "$(date -u +%FT%TZ) latest UART lines:" >> "$PROG"
grep -a "^\[" "$LOG" | tail -5 >> "$PROG" 2>&1
if grep -a -q "Kernel panic" "$LOG"; then
    echo "$(date -u +%FT%TZ) RESULT: kernel panic in log (trace reached the fault)" >> "$PROG"
elif grep -a -q "big32# " "$LOG"; then
    echo "$(date -u +%FT%TZ) RESULT: prompt seen (unexpected)" >> "$PROG"
else
    echo "$(date -u +%FT%TZ) RESULT: segment ended, no panic, no prompt" >> "$PROG"
fi
exit 0
