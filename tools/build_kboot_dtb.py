#!/usr/bin/env python3
"""Build the DTB used for the Linux boot attempt.

Differs from the standard os_programs/big32.dts in two ways,
both documented simulation choices (not hardware claims):

- memory reg 0x00100000 (1 MiB) -> 0x04000000 (64 MiB):
  the kernel Image alone is ~38 MB, so the 1 MiB default
  RAM cannot hold it. The boot attempt runs soc2 with
  -Pbig32_soc2.MEM_BYTES=67108864, and the DTB must agree
  or the kernel will size memory wrong.
- timebase-frequency 10000000 (10 MHz) -> 100000 (100 kHz):
  mtime ticks 1/cycle in soc2, so a kernel second costs
  timebase-frequency cycles. At 10 MHz a single kernel
  second is 10M cycles (~25 wall minutes at Icarus speed);
  at 100 kHz it is 100K cycles. The SBI timer and rdtime
  both use the same mtime, so timekeeping stays
  self-consistent; kernel time simply runs 100x faster
  relative to cycles. Without this, a bounded boot attempt
  cannot get past the first second-scale timeout.

Writes soc2_hex/big32_kboot.dtb (+ .txt hex-byte file for
the testbench) and prints the size.

Usage (from the big32 directory):
  python3 tools/build_kboot_dtb.py [timebase_hz [output_basename]]
Defaults: timebase 100000 (100 kHz), output big32_kboot.
Attempt-9 variant (27 Oct 2026, tick-livelock fix): the
declared timebase is a simulation knob only — mtime still
ticks 1/cycle in soc2, so a 10 MHz declaration makes the
kernel program a 40,000-count tick period (10 MHz / HZ 250)
instead of 400, breaking the handler(3,673 cycles) >
period inequality proven by the finer tick-boundary trace.
The SBI timer and rdtime still use the same mtime, so
timekeeping stays self-consistent; the cost is that a
kernel second now costs 10M cycles instead of 100K.
  python3 tools/build_kboot_dtb.py 10000000 big32_kboot_10mhz
NOTE: "dtc" here is the kernel tree's own dtc
(kernel/linux-6.6.52/scripts/dtc/dtc) — the apt
device-tree-compiler package is not installed in this VM.
"""
import subprocess
import sys

timebase = sys.argv[1] if len(sys.argv) > 1 else "100000"
outbase = sys.argv[2] if len(sys.argv) > 2 else "big32_kboot"
bootargs = sys.argv[3] if len(sys.argv) > 3 else None
DTC = "kernel/linux-6.6.52/scripts/dtc/dtc"

src = open("os_programs/big32.dts").read()
assert "0x00100000" in src and "10000000" in src
src = src.replace("0x00100000", "0x04000000")
src = src.replace("timebase-frequency = <10000000>;",
                  f"timebase-frequency = <{timebase}>;")
if bootargs is not None:
    import re
    src, n = re.subn(r'bootargs = "[^"]*";',
                     f'bootargs = "{bootargs}";', src, count=1)
    assert n == 1, "bootargs line not found in big32.dts"
open("/tmp/big32_kboot.dts", "w").write(src)
r = subprocess.run([DTC, "-I", "dts", "-O", "dtb",
                    "/tmp/big32_kboot.dts",
                    "-o", f"soc2_hex/{outbase}.dtb"],
                   capture_output=True, text=True)
print(r.stdout.strip(), r.stderr.strip())
if r.returncode:
    sys.exit(r.returncode)
data = open(f"soc2_hex/{outbase}.dtb", "rb").read()
with open(f"soc2_hex/{outbase}.dtb.txt", "w") as fh:
    for b in data:
        fh.write(f"{b:02x}\n")
print(f"{outbase}.dtb: {len(data)} bytes")
