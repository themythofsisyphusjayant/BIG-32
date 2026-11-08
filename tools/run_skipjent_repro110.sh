#!/bin/bash
# run_skipjent_repro110.sh -- panic DISCRIMINATOR: re-run 100M->110M from
# a BYTE-EXACT copy of the ORIGINAL 100M checkpoint set in ckpt_skipjent/.
# NOT the cont150 copy (its header lines 2-3 differ: rx2idx 0, rx2next
# 140M for the RX re-arm); NOT the cont150 110M checkpoint (panic loop).
# The original 100M header has rx2idx=50, rx2next=50100000, i.e. the
# attempt-18 RX feed is fully consumed, so this segment feeds nothing
# -- exactly what a panic comparison wants (no RX bytes in the way).
# Same skip-jent configuration as attempt 18 (blacklist DTB, 10 MHz,
# attempt-12 firmware, virtio-blk rootfs). Single explicit-cap segment,
# never uncapped loop mode. Log: kernel/boot_attempt18_skipjent_repro110.log
# (NEW file -- attempt-18 and cont150 logs untouched). ckpt_skipjent/
# itself is untouched: the resume runs from ckpt_skipjent_repro110/.
set -u
cd "$(dirname "$0")/.."

LOG=kernel/boot_attempt18_skipjent_repro110.log
DIR=ckpt_skipjent_repro110
PROG=kernel/skipjent_repro110_progress.log
VVP=sim/tb_kboot_ckpt.vvp
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

ensure_vvp || { echo "$(date -u +%FT%TZ) ERROR: vvp reinstall failed" >> "$PROG"; exit 1; }
echo "$(date -u +%FT%TZ) segment: resume 100000000 -> 110000000 (original checkpoint)" >> "$PROG"
stdbuf -oL -eL vvp "$VVP" \
    +HEX=soc2_hex/kboot_fw.hex +DISKHEX=soc2_hex/rootfs_disk.hex \
    +DTBFILE="$DTB" +DTBOFF=131072 \
    +KIMGBIN=kernel/linux-6.6.52/arch/riscv/boot/Image +KIMGOFF=4194304 +NOCLEAR \
    +CKPTDIR="$DIR" +RESUME=100000000 +MAXCYCLES=110000000 +CKPTAT=110000000 \
    >> "$LOG" 2>&1
echo "$(date -u +%FT%TZ) segment done: 100000000 -> 110000000" >> "$PROG"
ls "$DIR"/ckpt_110000000.done >> "$PROG" 2>&1
echo "$(date -u +%FT%TZ) latest UART lines:" >> "$PROG"
grep -a "^\[" "$LOG" | tail -5 >> "$PROG" 2>&1
if grep -a -q "Kernel panic" "$LOG"; then
    echo "$(date -u +%FT%TZ) RESULT: kernel panic in log" >> "$PROG"
elif grep -a -q "big32# " "$LOG"; then
    echo "$(date -u +%FT%TZ) RESULT: prompt seen" >> "$PROG"
else
    echo "$(date -u +%FT%TZ) RESULT: segment ended, no panic, no prompt" >> "$PROG"
fi
exit 0
