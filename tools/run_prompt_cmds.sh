#!/bin/bash
# run_prompt_cmds.sh -- Step 31: type commands at the full-config prompt.
# Resumes from the 520M checkpoint (banked Step 30, 09:22:35Z 9 Nov 2026:
# PROMPT REACHED -- unmodified Linux 6.6.52 boots to the big32# shell,
# VFS mounted root ext4 ro, Run /init, banner "userspace is up, PID 1").
# Authorization: Jayant 9 Nov ~16:23 IST ("Type commands at the prompt").
#
# THE HEADER TRICK (why this run uses ckpt_prompt_run/, not
# ckpt_cont170_run/ directly -- read before "fixing" it):
# The testbench takes rx2idx/rx2next from the checkpoint HEADER on
# resume (tb_kboot_ckpt.v do_resume, lines ~421-422); the +RX2START
# plusarg is only used in the FRESH-START branch (line ~829) and is
# IGNORED on resume. The banked 520M header says rx2idx=50,
# rx2next=150100000 -- the old attempt-17 feed is fully consumed, so
# with rx2idx=50 a new 49-byte feed would NEVER drip (rx2idx >= nrx2).
# So ckpt_prompt_run/ is a copy of the 520M set with ONLY header
# lines 2-3 changed (rx2idx 50->0, rx2next 150100000->521000000);
# diff shows exactly those two lines, and ram/disk/done/pix/vram are
# md5-identical to the banked set. The pristine 520M set in
# ckpt_cont170_run/ is untouched. Same trick as Step 26
# (ckpt_catecho_run/ vs ckpt_catecho210/).
#
# Feed: rootfs/rx_fullcfg.txt, hex byte per line, 49 bytes, armed at
# 521M (prompt already up at 520M), RX2PERIOD=2000 -- all bytes in
# by ~521.1M. Commands, in order: echo hello, ls, cat /hello.txt,
# uname, pwd, echo done. Bare cat/echo quirk tests NOT re-sent
# (proven Step 26). Shell commands: echo, ls, uname, cat, pwd.
# Disk: banked 520M .disk payload md5 c073ba7f766976b265d6b0057edb8d6f
# (1,048,576 bytes) == current patched rootfs.img; verified
# pre-flight by parsing the hex text back to binary. NO rewrite.
# ckpt_cont160/ and ckpt_catecho210/ stay pristine (baselines in
# work/step31_pristine_baseline.txt). Full-config DTB (NOT skipjent):
# soc2_hex/big32_kboot_10mhz_rootfs.dtb.txt.
# One explicit-cap segment 520M->530M, never loop mode, up to 3
# retries. Stops on panic / HALTED: 1 / cap. The 530M checkpoint
# lands in ckpt_prompt_run/ and is copied back into
# ckpt_cont170_run/ after the run, so the canonical dir stays
# complete. Log: kernel/boot_attempt17_prompt_cmds.log (NEW file).
# Watermark: kernel/cont_prompt_cmds_watermark.txt (baseline
# 520000000).
set -u
cd "$(dirname "$0")/.."

LOG=kernel/boot_attempt17_prompt_cmds.log
DIR=ckpt_prompt_run
PROG=kernel/cont_prompt_cmds_progress.log
WM=kernel/cont_prompt_cmds_watermark.txt
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
[ -f "$WM" ] || echo "520000000" > "$WM"
echo "$(date -u +%FT%TZ) prompt_cmds start; latest checkpoint: $(latest); vvp: $(ls -la --time-style=long-iso "$VVP" | awk '{print $6, $7}'); run dir ckpt_prompt_run (520M copy, header rx2idx=0/rx2next=521000000, .disk payload c073ba7f..., no rewrite); feed rootfs/rx_fullcfg.txt (49 bytes, RX2START=521000000, RX2PERIOD=2000); full-config DTB; single segment to 530M" >> "$PROG"

target=530000000
tries=0
while [ "$tries" -lt 3 ]; do
    before="$(latest)"
    ensure_vvp || { echo "$(date -u +%FT%TZ) ERROR: vvp unavailable" >> "$PROG"; exit 1; }
    echo "$(date -u +%FT%TZ) segment: resume $before -> $target" >> "$PROG"
    # shellcheck disable=SC2086
    stdbuf -oL -eL vvp $VVP_MFLAG "$VVP" \
        +HEX=soc2_hex/kboot_fw.hex +DISKHEX=soc2_hex/rootfs_disk.hex \
        +DTBFILE=soc2_hex/big32_kboot_10mhz_rootfs.dtb.txt +DTBOFF=131072 \
        +KIMGBIN=kernel/linux-6.6.52/arch/riscv/boot/Image +KIMGOFF=4194304 +NOCLEAR \
        +CKPTDIR="$DIR" +RESUME="$before" +MAXCYCLES="$target" +CKPTAT="$target" \
        +RX2FILE=rootfs/rx_fullcfg.txt +RX2START=521000000 +RX2PERIOD=2000 \
        >> "$LOG" 2>&1
    after="$(latest)"
    echo "$(date -u +%FT%TZ) segment done: $before -> $after" >> "$PROG"
    echo "$after" > "$WM"
    if [ "$after" != "$before" ]; then break; fi
    tries=$((tries + 1))
    echo "$(date -u +%FT%TZ) no progress, retry $tries/3 for $target" >> "$PROG"
done

after="$(latest)"
if [ "$after" = "$before" ]; then
    echo "$(date -u +%FT%TZ) STOP: segment $target failed 3x with no progress -- needs human look, not silent retry" >> "$PROG"
    exit 1
fi
if grep -a -q "Kernel panic" "$LOG"; then
    echo "$(date -u +%FT%TZ) STOP: kernel panic in log" >> "$PROG"; exit 0
fi
if grep -a -q "HALTED: 1" "$LOG"; then
    echo "$(date -u +%FT%TZ) STOP: HALTED" >> "$PROG"; exit 0
fi
echo "$(date -u +%FT%TZ) prompt_cmds complete: 530M cap reached at $after" >> "$PROG"
echo "--- UART tail (judge the six commands here) ---" >> "$PROG"
grep -a -v "^\[" "$LOG" | tail -30 >> "$PROG" 2>&1
exit 0
