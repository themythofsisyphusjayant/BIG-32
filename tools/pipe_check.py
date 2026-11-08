#!/usr/bin/env python3
"""Directed differential check for the pipelined big32 core.

For each directed program (the 15 v7 programs + pipe_hazards):
  - assemble the .s into pipe_hex/<prog>.hex (existing programs are
    NEVER reassembled into programs/*.hex, so v7 files are untouched),
  - run the Python model (semantic reference),
  - run the pipelined Verilog top (sim/tb_pipe.vvp, +HEX=...),
  - compare the full 32-register file, the UART transcript, and
    the scratch words at 0x100..0x10c, and report a0 + pipe cycles.
v7 cycle counts (from sim/tb_big32.v, recorded separately) are shown
alongside when available, from the V7_CYCLES table below.

Usage (from the big32 directory):
  python3 tools/pipe_check.py [prog ...]
With no arguments, all 16 programs are checked. The testbench must
already be compiled: see run_pipe.sh (it compiles it first).
"""
import re
import subprocess
import sys

sys.path.insert(0, "tools")
from model import run  # noqa: E402

PROGS = ["sum", "fib", "mul_loop", "call_demo", "mul_demo", "mulh_demo",
         "div_demo", "div_edge", "div_zero", "rem_zero", "amo_demo",
         "sc_fail", "csr_demo", "edge_cases", "kernel", "pipe_hazards",
         "misalign_demo"]
EXPECTED_A0 = {"sum": 55, "fib": 55, "mul_loop": 42, "call_demo": 112,
               "mul_demo": 83810205, "mulh_demo": 2, "div_demo": 1402,
               "div_edge": 2147483648, "div_zero": 4294967295,
               "rem_zero": 42, "amo_demo": 42, "sc_fail": 101,
               "csr_demo": 4660, "edge_cases": 0, "kernel": 10,
               "pipe_hazards": 1406, "misalign_demo": 420555360}
# v7 single-cycle counts, measured with sim/tb_big32.v 26 Oct 2026.
V7_CYCLES = {"sum": 35, "fib": 51, "mul_loop": 27, "call_demo": 16,
             "mul_demo": 7, "mulh_demo": 7, "div_demo": 9, "div_edge": 5,
             "div_zero": 5, "rem_zero": 5, "amo_demo": 9, "sc_fail": 7,
             "csr_demo": 7, "edge_cases": 116, "kernel": 290}


def run_pipe(hexp):
    out = subprocess.run(["vvp", "sim/tb_pipe.vvp", f"+HEX={hexp}"],
                         capture_output=True, text=True, timeout=120)
    regs = None
    cycles = None
    halted = None
    dmem = None
    uart_lines = []
    for line in out.stdout.splitlines():
        if line.startswith("REGS:"):
            regs = [int(x) for x in line[5:].split()]
        elif line.startswith("CYCLES:"):
            cycles = int(line[7:])
        elif line.startswith("HALTED:"):
            halted = int(line[7:])
        elif line.startswith("DMEM:"):
            dmem = [int(x) for x in line[5:].split()]
        elif line.startswith("WARNING:") or "$finish called" in line:
            continue  # Icarus $readmemh/$finish diagnostics, not UART
        else:
            uart_lines.append(line)
    uart = "\n".join(uart_lines)
    if uart_lines:
        uart += "\n"
    return regs, cycles, halted, dmem, uart, out.stdout, out.stderr


def main():
    progs = sys.argv[1:] or PROGS
    fails = 0
    print(f"{'program':12s} {'a0':>12s} {'pipe_cyc':>9s} {'v7_cyc':>7s}  result")
    for p in progs:
        src = f"programs/{p}.s" if p != "pipe_hazards" else "programs/pipe_hazards.s"
        hexp = f"pipe_hex/{p}.hex"
        subprocess.run(["python3", "tools/asm.py", src, hexp],
                       check=True, capture_output=True, text=True)
        m = run(hexp)
        mregs = [r & 0xFFFFFFFF for r in m["regs"]]
        mdmem = []
        for base in (0x100, 0x104, 0x108, 0x10C):
            mdmem.append(m["dmem"][base] | (m["dmem"][base + 1] << 8) |
                         (m["dmem"][base + 2] << 16) | (m["dmem"][base + 3] << 24))
        vregs, cycles, halted, dmem, uart, so, se = run_pipe(hexp)
        problems = []
        if vregs is None:
            problems.append(f"no Verilog output\n{so}\n{se}")
        else:
            if not halted:
                problems.append("did not halt")
            if vregs != mregs:
                for i, (a, b) in enumerate(zip(mregs, vregs)):
                    if a != b:
                        problems.append(f"x{i}: model={a} verilog={b}")
            if uart.encode() != m["uart"]:
                problems.append(f"uart mismatch: model={m['uart']!r} verilog={uart.encode()!r}")
            if dmem != mdmem:
                problems.append(f"dmem mismatch: model={mdmem} verilog={dmem}")
            if mregs[10] != EXPECTED_A0[p]:
                problems.append(f"model a0={mregs[10]} != hand-expected {EXPECTED_A0[p]}")
        v7 = V7_CYCLES.get(p, "-")
        if problems:
            fails += 1
            print(f"{p:12s} {mregs[10]:12d} {str(cycles):>9s} {str(v7):>7s}  FAIL: {'; '.join(problems)}")
        else:
            print(f"{p:12s} {mregs[10]:12d} {str(cycles):>9s} {str(v7):>7s}  PASS")
    print(f"directed pipe checks: {len(progs) - fails}/{len(progs)} passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
