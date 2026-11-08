#!/usr/bin/env python3
"""Calibrate the entry_drain test's NOP pad, and run it.

Generates soc2_programs/entry_drain.s with a given pad length,
assembles it with tools/soc_asm.py, runs it on the soc2 Verilog
top compiled from a chosen core source, and reports the footer
registers (s0 = verdict: 0 pass, 1 bug, 2 miss; s1 = sstatus at
entry; s2 = sepc at entry; s3 = handler entered).

Usage (from the big32 directory):
  python3 tools/entry_drain_cal.py CORE.v PAD [PAD ...]
    Run single pads (e.g. 0, 1, 2) and print each result.
  python3 tools/entry_drain_cal.py CORE.v sweep [LO [HI]]
    Sweep pads LO..HI (default 0..200), stop at the first pad
    with s0 == 1 (aligned + clobbered = bug reproduced) and
    print it as HIT. On a fixed core the same sweep finds no
    s0 == 1; the aligned pad then shows s0 == 0.
The generated .s file is left with the LAST pad run; the
checked-in entry_drain.s carries the calibrated pad.
"""
import subprocess
import sys

TEMPLATE = "soc2_programs/entry_drain.s"


def build(pad):
    """Replace the pad in TEMPLATE with `pad` NOPs.

    Two forms are accepted, so the file stays regenerable:
    a lone `__PAD__` line (the as-written template) is replaced
    by the NOPs; otherwise the existing run of NOP lines
    between `li t1, 2000` and `drain:` is replaced, with
    surrounding comments preserved.
    """
    with open(TEMPLATE) as f:
        lines = f.read().splitlines(keepends=True)
    nops = ["    addi x0, x0, 0\n" for _ in range(pad)]
    for i, line in enumerate(lines):
        if line.strip() == "__PAD__":
            lines[i:i + 1] = nops
            break
    else:
        start = next(i for i, l in enumerate(lines)
                     if l.strip().startswith("li t1, 2000"))
        end = next(i for i, l in enumerate(lines)
                   if l.strip() == "drain:")
        nop_idx = [i for i in range(start, end)
                   if lines[i].strip() == "addi x0, x0, 0"]
        if nop_idx:
            first, last = nop_idx[0], nop_idx[-1]
            lines[first:last + 1] = nops
        else:
            lines[end:end] = nops
    with open(TEMPLATE, "w") as f:
        f.writelines(lines)


VVP = "/tmp/tb_soc2_cal.vvp"


def compile_once(core):
    subprocess.run(["iverilog", "-o", VVP, core,
                    "src/big32_soc2.v", "sim/tb_soc2.v"],
                   capture_output=True, text=True, check=True)


def run_one(core, pad):
    build(pad)
    r = subprocess.run(["python3", "tools/soc_asm.py", TEMPLATE,
                        "soc2_hex/entry_drain.hex"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return f"pad={pad}: ASSEMBLE FAIL\n{r.stdout}{r.stderr}"
    out = subprocess.run(["vvp", VVP,
                          "+HEX=soc2_hex/entry_drain.hex"],
                         capture_output=True, text=True, timeout=300)
    regs = halted = cycles = None
    for line in out.stdout.splitlines():
        if line.startswith("CYCLES:"):
            cycles = int(line[7:])
        elif line.startswith("HALTED:"):
            halted = int(line[7:])
        elif line.startswith("REGS:"):
            regs = [int(x) for x in line[5:].split()]
    if regs is None:
        return (f"pad={pad}: NO RESULT "
                f"(vvp output: {out.stdout[:300]!r} {out.stderr[:300]!r})")
    s0, s1, s2, s3 = regs[8], regs[9], regs[18], regs[19]
    if halted != 1:
        verdict = "NOHALT"
    else:
        verdict = {0: "PASS", 1: "BUG", 2: "MISS"}.get(s0, f"s0={s0}")
    return (f"pad={pad}: {verdict} (halted={halted}, s0={s0}, "
            f"s1=0x{s1:x}, s2=0x{s2:x}, s3={s3}, cycles={cycles})")


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    core = sys.argv[1]
    import os
    if not os.environ.get("ENTRY_DRAIN_NOCOMPILE"):
        compile_once(core)
    if sys.argv[2] == "sweep":
        lo = int(sys.argv[3]) if len(sys.argv) > 3 else 0
        hi = int(sys.argv[4]) if len(sys.argv) > 4 else 200
        for pad in range(lo, hi + 1):
            msg = run_one(core, pad)
            print(msg, flush=True)
            if ": BUG " in msg:
                print(f"HIT pad={pad}")
                return 0
        print("no BUG pad in range")
        return 1
    for arg in sys.argv[2:]:
        print(run_one(core, int(arg)), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
