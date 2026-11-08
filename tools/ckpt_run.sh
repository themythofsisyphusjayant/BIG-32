#!/bin/bash
# ckpt_run.sh -- wrapper for the checkpoint/resume kernel-boot harness.
# See sim/tb_kboot_ckpt.v and the "Restart-proof harness" section in
# LINUX_BOOT.md. Run from the big32 directory.
#
#   ./tools/ckpt_run.sh compile [1m|64m]
#       (Re)build the checkpoint testbench. 64m = 64 MiB RAM (the
#       kernel boot); 1m = 1 MiB (small soc2 test programs).
#       Elaboration takes ~3-4 min; the .vvp survives VM restarts,
#       so this is only needed when the sources change.
#   ./tools/ckpt_run.sh latest <ckptdir>
#       Print the newest checkpoint cycle that has a .done file
#       (i.e. a complete, trustworthy checkpoint), or nothing.
#   ./tools/ckpt_run.sh start <log> <ckptdir> <maxcycles> [plusargs...]
#       Fresh run, appending UART+footer to <log> (use >> semantics
#       via tee-like redirect: the caller redirects; this script
#       just execs vvp). Pass CKPTAT/CKPTEVERY in plusargs.
#   ./tools/ckpt_run.sh resume <log> <ckptdir> [plusargs...]
#       Resume from the newest complete checkpoint, APPENDING to
#       <log>. Plusargs must include the original launch args
#       (HEX/DISKHEX/DTBFILE/KIMGBIN/...) and a CKPTAT beyond
#       the resumed cycle if further checkpoints are wanted.
#   ./tools/ckpt_run.sh loop <log> <ckptdir> <segment> <maxiter> [plusargs...]
#       Segmented run: each iteration advances <segment> cycles
#       (checkpointing at the segment end, or halting), appending
#       to <log>. If an iteration is killed (VM restart, SIGKILL),
#       re-running `loop` with the same arguments resumes from
#       the newest complete checkpoint and continues. Stops when
#       the log shows HALTED: 1, when no progress is made, or
#       after <maxiter> iterations. NEVER pass MAXCYCLES in
#       plusargs for loop mode; the script sets it per segment.
# A checkpoint is only trusted if its .done file exists. A kill
# landing mid-dump leaves a torn set with no .done, and `latest`
# (hence `resume`/`loop`) skips it for the previous complete one.
set -u
cd "$(dirname "$0")/.."

VVP64=sim/tb_kboot_ckpt.vvp
VVP1M=sim/tb_kboot_ckpt_1m.vvp
DEB=iverilog_12.0-2build2_amd64.deb

ensure_iverilog() {
    if command -v iverilog >/dev/null 2>&1; then return 0; fi
    echo "iverilog missing (VM restart wipes apt installs); reinstalling from cached deb..."
    # Wait out the os-intent apt replay's dpkg lock; never force it.
    for _ in $(seq 1 60); do
        if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then break; fi
        sleep 10
    done
    dpkg -i "$DEB"
}

compile_tb() {
    local mem="$1" out="$2"
    ensure_iverilog
    iverilog -o "$out" -Ptb_kboot_ckpt.TB_MEM_BYTES="$mem" \
        src/big32_core_pipe.v src/big32_soc2.v sim/tb_kboot_ckpt.v
}

latest() {
    local dir="$1" f best=""
    for f in "$dir"/ckpt_*.done; do
        [ -f "$f" ] || continue
        local n="${f##*/ckpt_}"; n="${n%.done}"
        if [ -z "$best" ] || [ "$n" -gt "$best" ]; then best="$n"; fi
    done
    [ -n "$best" ] && echo "$best"
}

# Common launch args for the attempt-13/16 kernel boot. Used by
# `loop` and documented for `start`/`resume`; small-program runs
# pass their own plusargs instead.
KBOOT_ARGS="+HEX=soc2_hex/kboot_fw.hex +DISKHEX=soc2_hex/rootfs_disk.hex +DTBFILE=soc2_hex/big32_kboot_10mhz_rootfs.dtb.txt +DTBOFF=131072 +KIMGBIN=kernel/linux-6.6.52/arch/riscv/boot/Image +KIMGOFF=4194304 +NOCLEAR"

cmd="$1"; shift
case "$cmd" in
compile)
    if [ "${1:-64m}" = "1m" ]; then compile_tb 1048576 "$VVP1M";
    else compile_tb 67108864 "$VVP64"; fi
    echo "compiled"
    ;;
latest)
    latest "$1"
    ;;
start)
    # start <log> <ckptdir> <maxcycles> [plusargs...]
    log="$1"; dir="$2"; max="$3"; shift 3
    mkdir -p "$dir"
    [ -x "$VVP64" ] || compile_tb 67108864 "$VVP64"
    # A same-cycle re-run must clear the old set first, so a
    # stale .done can never validate a new partial dump.
    stdbuf -oL -eL vvp "$VVP64" $KBOOT_ARGS +MAXCYCLES="$max" \
        +CKPTDIR="$dir" "$@" >>"$log" 2>&1
    ;;
resume)
    # resume <log> <ckptdir> [plusargs...]
    log="$1"; dir="$2"; shift 2
    cyc="$(latest "$dir")"
    [ -n "$cyc" ] || { echo "resume: no complete checkpoint in $dir" >&2; exit 1; }
    [ -x "$VVP64" ] || compile_tb 67108864 "$VVP64"
    echo "resuming from cycle $cyc (appending to $log)"
    stdbuf -oL -eL vvp "$VVP64" $KBOOT_ARGS +CKPTDIR="$dir" \
        +RESUME="$cyc" "$@" >>"$log" 2>&1
    ;;
loop)
    # loop <log> <ckptdir> <segment> <maxiter> [plusargs...]
    log="$1"; dir="$2"; seg="$3"; maxiter="$4"; shift 4
    mkdir -p "$dir"
    [ -x "$VVP64" ] || compile_tb 67108864 "$VVP64"
    touch "$log"
    iter=0
    while [ "$iter" -lt "$maxiter" ]; do
        if grep -a -q "HALTED: 1" "$log"; then
            echo "loop: HALTED, done"; exit 0
        fi
        cyc="$(latest "$dir")"
        if [ -n "$cyc" ]; then
            next=$((cyc + seg))
            echo "loop iter $iter: resume $cyc -> $next (append $log)"
            stdbuf -oL -eL vvp "$VVP64" $KBOOT_ARGS +CKPTDIR="$dir" \
                +RESUME="$cyc" +MAXCYCLES="$next" +CKPTAT="$next" \
                "$@" >>"$log" 2>&1
            newcyc="$(latest "$dir")"
            if [ "$newcyc" = "$cyc" ] && ! grep -a -q "HALTED: 1" "$log"; then
                echo "loop: no progress from $cyc; stopping" >&2; exit 1
            fi
        else
            echo "loop iter $iter: fresh 0 -> $seg (append $log)"
            stdbuf -oL -eL vvp "$VVP64" $KBOOT_ARGS +CKPTDIR="$dir" \
                +MAXCYCLES="$seg" +CKPTAT="$seg" "$@" >>"$log" 2>&1
        fi
        iter=$((iter + 1))
    done
    grep -a -q "HALTED: 1" "$log" && { echo "loop: HALTED, done"; exit 0; }
    echo "loop: iteration budget ($maxiter) exhausted; re-run to continue" >&2
    exit 2
    ;;
*)
    echo "usage: ckpt_run.sh {compile [1m|64m]|latest <dir>|start <log> <dir> <maxcycles> [plusargs]|resume <log> <dir> [plusargs]|loop <log> <dir> <segment> <maxiter> [plusargs]}" >&2
    exit 1
    ;;
esac
