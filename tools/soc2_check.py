#!/usr/bin/env python3
"""Phase 5 platform checker.

Assembles soc2_programs/*.s with tools/soc_asm.py, runs each on
the soc2 Verilog top (sim/tb_soc2.vvp, compiled by run_soc2.sh),
and checks a0 == 0 (fail count) plus expected UART substrings.
Usage (from the big32 directory):
  python3 tools/soc2_check.py [test ...]
With no arguments, runs all soc2 tests.
"""
import subprocess
import sys

TESTS = {
    "plic": {
        "uart": [],
        "rx2": "soc2_programs/rx_a.txt",
    },
    "uart16550": {
        "uart": ["U"],
        "rx2": "soc2_programs/rx_bc.txt",
    },
    "timer64": {
        "uart": [],
    },
    "virtio": {
        "uart": [],
    },
    # Attempt 18 Step 9: kernel's vm_get_features/vm_finalize
    # sequence for a version-2 device -- sel=1 feature word
    # must carry VIRTIO_F_VERSION_1, FEATURES_OK must stick,
    # then a sector read through the v1 queue path. FAILS
    # (a0==1) on the pre-fix model, PASSES on the fixed model.
    "virtio_v1": {
        "uart": [],
    },
    # Attempt 18 Step 16: one kick must drain ALL pending
    # chains. FAILS (a0>=1, used idx stuck at 1) on the
    # pre-fix model, PASSES on the fixed model.
    "virtio_drain": {
        "uart": [],
    },
    # Attempt 18 fix: interrupt entry with a csrrci sstatus in
    # EX at entry must leave the entry's SPP=1 intact (a0==0).
    # The checked-in .s carries the calibrated pad (122); the
    # test FAILS (a0==1) on the pre-fix core and PASSES on the
    # fixed core. See tools/entry_drain_cal.py for recalibration.
    "entry_drain": {
        "uart": [],
    },
}


def run_one(name):
    cfg = TESTS[name]
    r = subprocess.run(["python3", "tools/soc_asm.py",
                        f"soc2_programs/{name}.s",
                        f"soc2_hex/{name}.hex"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return f"{name}: ASSEMBLE FAIL\n{r.stdout}{r.stderr}"
    cmd = ["vvp", "sim/tb_soc2.vvp", f"+HEX=soc2_hex/{name}.hex"]
    if "rx2" in cfg:
        cmd += [f"+RX2FILE={cfg['rx2']}", "+RX2START=600",
                "+RX2PERIOD=600"]
    out = subprocess.run(cmd, capture_output=True, text=True,
                         timeout=300)
    regs = cycles = halted = None
    uart_lines = []
    for line in out.stdout.splitlines():
        # UART bytes print with no newline, so a UART byte can
        # merge with the following line ("UCYCLES: ...").
        if "CYCLES:" in line:
            # A UART byte printed with no newline merges with
            # this line ("SCYCLES: ..."): keep the byte as UART
            # instead of swallowing it with the cycles parse.
            prefix, _, suffix = line.partition("CYCLES:")
            if prefix and not prefix.startswith("WARNING:"):
                uart_lines.append(prefix)
            cycles = int(suffix)
        elif line.startswith("HALTED:"):
            halted = int(line[7:])
        elif line.startswith("REGS:"):
            regs = [int(x) for x in line[5:].split()]
        elif line.startswith("RAM:"):
            continue
        elif "$finish called" in line:
            continue
        else:
            uart_lines.append(line)
    uart = "".join(l + "\n" for l in uart_lines)
    problems = []
    if halted != 1:
        problems.append(f"halted={halted}")
    if regs is None or regs[10] != 0:
        problems.append(f"a0={regs[10] if regs else None} (expected 0)")
    for want in cfg["uart"]:
        if want not in uart:
            problems.append(f"UART missing {want!r} (got {uart!r})")
    if problems:
        return (f"{name}: FAIL ({'; '.join(problems)}) "
                f"[cycles={cycles}]\nUART:\n{uart}\n"
                f"RAW:\n{out.stdout}\n{out.stderr}")
    return f"{name}: PASS (cycles={cycles}, a0=0)"


def main():
    names = sys.argv[1:] or list(TESTS)
    ok = True
    for name in names:
        try:
            msg = run_one(name)
        except Exception as exc:  # noqa: BLE001
            msg = f"{name}: ERROR {exc}"
        print(msg)
        if "PASS" not in msg.split("(")[0]:
            ok = False
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
