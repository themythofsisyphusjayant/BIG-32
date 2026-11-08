# big32: toward a real Linux boot (Phase 5)

Status and honesty first: **Linux does not boot on big32 yet.**
This document records the Phase 5 platform (SBI, device tree,
PLIC, 16550 UART, 64-bit timer, virtio block, bootloader, TLB,
A/D bits, misaligned traps), what was actually tested, how to
build a kernel for this machine, and exactly what remains.
Everything here runs in simulation only (Icarus Verilog 12.0).
Not silicon, not production-ready, not RISCOF/formal-verified.

## Phase 5 platform (soc2): memory map

New top `src/big32_soc2.v`. The old top `src/big32_soc.v`
(Phases 2-4) is untouched; `./run_os.sh` still runs on it.

| Region | Address | Notes |
|---|---|---|
| ROM (2 instructions) | 0x00000000-0x00000FFF | `lui t0, 0x80000; jalr x0, 0(t0)`. The core resets pc to 0 and RAM lives at 0x80000000, which jal cannot reach, so the ROM is the only bridge. ROM reads return the ROM word; data writes ignored. |
| RAM | 0x80000000 + MEM_BYTES | Parameter, default 1 MiB (was 16 MiB in the first soc2 draft; lowered because Icarus elaboration/simulation at 16 MiB was impractical — see below). Override with `iverilog -Pbig32_soc2.MEM_BYTES=...`. A kernel needs megabytes: the boot attempt uses 32 MiB. |
| PLIC | 0x0C000000 | Standard layout (see below). |
| Legacy UART (core-driven) | 0x10000000 TX, 0x10000004 RX, 0x10000008 status | Kept for the SBI console and old programs. The core's load overrides hard-code these addresses, which is why the 16550 lives elsewhere. |
| SBI IPI register | 0x10002000 | Any nonzero write (mask bit 0) sets the core's `irq_soft` line; a zero write clears it. Backs SBI send_ipi on this single-hart machine. |
| virtio-mmio block | 0x10001000 | Device ID 2, version 2, queue 0 only (see below). |
| 16550 UART | 0x10010000 | ns16550a-compatible (see below). |
| CLINT | 0x02004000 mtimecmp, 0x0200BFF8 mtime | 64-bit each (low +0, high +4). mtime +1/cycle; timer pends while mtime >= mtimecmp (64-bit compare). |

Testbench: `sim/tb_soc2.v`. Plusargs: `+HEX` (word image),
`+DISKHEX` (disk words), `+DTBFILE`/`+DTBOFF` (default 131072 =
0x20000), `+RX2FILE`/`+RX2START`/`+RX2PERIOD` (16550 RX
injection), `+EXTAT`/`+EXTLEN` (external line), `+MAXCYCLES`
(default 2000000), `+KIMG`/`+KIMGOFF` (kernel image, Linux
attempt only, default offset 65536 = 0x10000).

## Why the RAM is a word array (Icarus lesson)

The first soc2 used a byte array with ~44 combinational read
ports (fetch, data, virtio descriptor/ring/header/used reads).
Icarus elaboration scaled with ports x depth with a huge
constant: 64 KiB took 3m43s, 1 MiB hung past 164 s. The fix:

- RAM is a word array `memw` (MEM_WORDS = MEM_BYTES/4).
  Fetch and data each do 2 word reads + an unaligned merge
  by addr[1:0]. CPU stores use a shift trick
  (`st_data64`, `st_mask8`) with word read-modify-write, so
  unaligned stores spanning two words, A/D writebacks, AMO
  writes, and UART byte stores all work.
- Virtio FSM reads use ONE synchronous port (`v_rd_addr` /
  `v_rd_data` / `v_rd_armed`, one cycle latency, states
  V_RD_AVAIL/V_RD_RING/V_RD_D0/V_RD_D2/V_RD_D3/V_RD_H0/
  V_RD_H2/V_RD_H3). Each such state waits one cycle, then
  consumes the latched word.
- Result: `iverilog` on core + soc2 + tb_soc2 exits 0 in
  0.062 s at the 1 MiB default (was >164 s).
- The testbench clear loop and main image load scale with
  `dut.MEM_WORDS`, so a `-P MEM_BYTES` override for a
  kernel-size RAM clears/loads the whole array (startup
  ~35 s at 32 MiB, measured by construction: 8M-word loop).

## SBI (`os_programs/sbi_firmware.s`, M-mode)

Entry at RAM base (via ROM jump). Sets mscratch =
0x8000E000 (handler stack), mtvec = handler, medeleg =
0xB9FF, mideleg = 0x888, then drops to S-mode (mstatus
MPP=S, mepc = test/kernel, a0 = hartid 0, a1 = DTB
address 0x80020000). S-ecalls land in M because medeleg
bit 9 (S-ecall) is 0 — the SBI design relies on this.

Implemented extensions (unknown extension/FID returns
SBI_ERR_INVALID_PARAM, -2):

- Base 0x10: FID 0 spec version 2.0 (a1 = 0x02000000),
  FID 1 implementation ID "BIG3" (a1 = 0x42494733),
  FID 2 implementation version 1, FID 3 probe (1 for
  0x10, 0x54494D45, 0x735049, 0x52464E43, 0x53525354,
  else 0), FIDs 4/5/6 return 0.
- Legacy 0x01: console putchar (byte in a0 to legacy UART).
- TIME 0x54494D45: FID 0 set_timer (a0 = mtimecmp low,
  a1 = high).
- sPI 0x735049: FID 0 send_ipi — a REAL single-hart IPI
  (not a no-op): if hart_mask_base (a1) is -1 (all harts)
  or base is 0 with mask bit 0 set (a0 & 1), it writes 1
  to the IPI register at 0x10002000, which asserts the
  core's `irq_soft` line. The S handler clears it by
  writing 0 to the same register (via its VA mapping).
- RFNC 0x52464E43: FID 0 fence_i (no-op success),
  FIDs 1/2 sfence_vma (executes `sfence.vma` in M, which
  flushes the TLB), FIDs 3-6 hfence variants (no-op
  success).
- SRST 0x53525354: FID 0 system_reset — restores the
  stack, clears mtvec, ecalls in M with mtvec == 0, so
  the core halts. A defensive `j halt_loop` follows.

Handler: swaps sp with mscratch, saves ra/a0-a7/t0-t6 on a
128-byte frame, dispatches, restores a2-a7/t0-t6 (NOT
a0/a1, which carry returns), mepc += 4, restores sp, mret.
Machine timer interrupt (0x80000007) sets mtimecmp far
future and mret without advancing mepc. Other traps print
'!' to the legacy UART and halt (the '!' is the firmware
trap flag the checkers assert is absent on success).

Firmware size: 252 words (limit 1024 words in the
build_smode layout — see "builders" below).

## Device tree (`os_programs/big32.dts`)

Built with `dtc -I dts -O dtb`. Root: compatible
"big32,phase5", model "big32 Phase 5", #address-cells 1,
#size-cells 1. Chosen: bootargs "earlycon", stdout-path
"/soc/uart@10010000". Memory: reg <0x80000000 0x00100000>
(1 MiB, matching the soc2 default — a kernel attempt
overrides RAM but the DTB memory size must then be
updated to match, or the kernel will size memory wrong).
CPU: cpu@0, compatible riscv, riscv,isa "rv32ima"
(no C: big32 has no compressed extension; no F: no FPU),
mmu-type "riscv,sv32", timebase-frequency 10000000
(10 MHz, QEMU's usual value; the kernel divides rdtime
ticks by it — see "counters" below).
SOC (simple-bus): uart@10010000 (ns16550a, interrupts <1>,
interrupt-parent PLIC, clock-frequency 1843200), plic
(riscv,plic0, #interrupt-cells 1, reg <0x0c000000
0x04000000>, riscv,ndev 3), clint@2000000 (riscv,clint0,
reg <0x02000000 0x00010000>, interrupts-extended <&cpu0 7
&cpu0 3>), virtio@10001000 (virtio,mmio, interrupts <2>,
interrupt-parent PLIC).

`tools/check_dtb.py` walks the DTB (magic, totalsize ==
file length, version >= 17, required nodes + memory reg +
uart/virtio compatibles). It proves a structurally valid
tree a kernel's libfdt can walk; it is NOT a substitute
for booting a kernel against it.

## PLIC (soc2)

Sources: 1 = UART16550, 2 = virtio block, 3 = external
line. Standard register layout, verified against the
PLIC spec section the kernel's sifive-plic driver uses:
priorities at 0x0C000000 + 4*source (3-bit priority
fields), pending at 0x0C001000, enables M at 0x0C002000
and S at 0x0C002080 (0x80 stride), M threshold
0x0C200000 / claim 0x0C200004, S threshold 0x0C201000 /
claim 0x0C201004. Claim resolution is combinational per
context: highest priority above threshold wins; ties go
to the LOWEST-numbered source (fixed in Phase 5 from an
earlier highest-id-wins loop). Pending is LEVEL: a source
stays pending while its device asserts it, so a handler
must drain/ack the device before completing, or the
interrupt retakes — correct PLIC behaviour for level
sources, not a bug. The core sees one `irq_ext` line,
asserted when EITHER context has a claimable interrupt;
the core's own M/S delegation (mideleg/sie/mie) then
decides which mode takes it. Claim marking is guarded by
`mem_load_w` (real MEM loads only), so speculative
fetch reads cannot claim. Complete writes clear
`plic_claimed[id]`.

Kernel note: if the kernel never programs priorities
(it leaves them 0), no PLIC interrupt is ever claimed
(priority 0 = never interrupt). Console OUTPUT still
works (the 8250 driver polls THRE for output); only
interrupt-driven INPUT would be missing. Not a boot
blocker for a boot-log attempt.

## 16550 UART (soc2, 0x10010000)

RBR/THR +0, IER +1, IIR/FCR +2, LCR +3, MCR +4, LSR +5,
MSR +6, SCR +7, DLL/DLM when LCR.DLAB = 1. SCR, DLL, DLM
are stored and read back (the 8250 autoconfig probes
them). IIR = 0xC4 for RDA (FIFO bits 11, ID 010),
0xC2 for THRE, 0xC1 for none. LSR = TEMT 1, THRE 1,
DR = RX FIFO non-empty (bit 0; an earlier draft had DR
at bit 1 and was fixed). FIFO is always on (documented
deviation: FCR bit 0 is stored but the FIFO does not
switch off). RX is a 16-byte FIFO fed by rx2 inputs;
16550 irq = (DR && IER[0]) || (THRE && IER[1]). THRE is
always 1 in simulation, so a driver enabling THRE
interrupts without handling them will spam — correct
16550 behaviour. MSR reads 0 (no modem lines). TX pulses
the top-level uart_tx on THR writes. Divisor values do
not affect TX timing in simulation (bytes go out
immediately).

## 64-bit timer (soc2 CLINT)

mtime/mtimecmp are 64-bit (low +0, high +4 at both
0x02004000 and 0x0200BFF8). mtime +1/cycle; the timer
pends while mtime >= mtimecmp (64-bit compare), so a
compare set across the 32-bit boundary fires when the
high word rolls over. The old SOC's 32-bit-only CLINT
(high words read 0, writes dropped) is gone on soc2.

## Counters (core): TIME/CYCLE/INSTRET

The kernel's riscv clocksource reads the TIME CSR
(rdtime). The core implements: CYCLE 0xC00 / CYCLEH
0xC80, TIME 0xC01 / TIMEH 0xC81, INSTRET 0xC02 /
INSTRETH 0xC82, all from one free-running 64-bit
`core_cycles` counter (+1/clock). INSTRET aliases the
cycle counter (simplification: no kernel boot path reads
instret, only perf tools do). Counters are readable in
all modes; mcounteren is not implemented (writes to it
are ignored, counter reads are never blocked) — a
documented permissive deviation. Before this fix, rdtime
returned a stuck 0, which would have wedged the kernel's
timekeeping.

## Virtio-mmio block (soc2, 0x10001000)

Chosen over a custom ramdisk-style MMIO device because
virtio-mmio block IS in mainline Linux (CONFIG_VIRTIO_MMIO
+ CONFIG_VIRTIO_BLK), whereas a custom device would need
a custom kernel driver. The ramdisk fallback was
considered and rejected for the Linux path.

Only queue 0, only block device, QueueNumMax 64. Driver
sequence: reset (Status = 0), ACKNOWLEDGE, DRIVER, read
features (0), FEATURES_OK, set queue addresses,
QUEUE_READY, DRIVER_OK, then QueueNotify. On notify the
FSM walks the descriptor chain from guest RAM, copies
data between RAM and the internal disk array (DISK_BYTES
default 1 MiB = 2048 sectors of 512 bytes), writes the
used ring, sets InterruptStatus bit 0, and asserts PLIC
source 2 until the driver acks. Disk initialises with a
checkable pattern (sector s, byte = s % 256) unless the
testbench overwrites it; sector 0's first 8 bytes are
magic EF BE AD DE 78 56 34 12 (words 0xDEADBEEF,
0x12345678 little-endian). Guest physical addresses in
descriptors are translated by subtracting RAM_BASE;
addresses outside RAM abort the request (used entry with
len 0, status byte 1). Descriptor word 1 (addr hi) and
header word 1 (reserved) are skipped (32-bit guest
addresses only).

## Bootloader (`os_programs/bootloader.s`)

M-mode program (356 words) that embeds the SBI handler
(copied verbatim from sbi_firmware.s — if the firmware
changes, this copy must be re-synced) and replaces the
firmware entry with: SBI setup (mscratch/mtvec/medeleg/
mideleg) + virtio identify/init + read sectors 0-1
(1024 bytes) into RAM at 0x80010000 + drop to the loaded
image in S-mode (mepc = 0x80010000, mstatus MPP = S,
a0 = 0, a1 = DTB 0x80020000). Queue buffers: desc
0x80002000, avail 0x80003000, used 0x80004000, header
0x80005000, status 0x80006000 (no overlap with the
firmware stack at 0x8000E000, the kernel at 0x80010000,
or the DTB at 0x80020000). Each read checks status byte
== 0 and used idx == sector+1; any failure (bad magic /
version / id, nonzero features, notify timeout, nonzero
status, wrong used idx, uncleared InterruptStatus)
prints '!' to the legacy UART and halts — the checker
treats '!' as a boot failure. The test kernel
(`soc2_programs/boot_kernel.s`, 55 words, loaded as the
disk image) checks the DTB magic, prints 'B' + 'K' via
SBI putchar, checks the SBI spec version, and shuts down
via SRST. `tools/boot_check.py` assembles both, builds
the DTB, and runs the testbench with the kernel as
+DISKHEX.

## Core semantic changes vs Phases 1-4

Every one of these changes behaviour that Phases 1-4 code
could observe. They are deliberate, tested, and required
for Linux; the old tests that encoded the old behaviour
were updated, not the core reverted.

1. **TLB (16 entries, fully associative, round-robin
   replacement).** Each entry: valid, VPN[19:0],
   PPN[19:0], R/W/X/U flags, D flag, superpage flag.
   ASID ignored (entries effectively global). Fetch
   lookup is pc-based; data lookup uses the raw virtual
   effective address. Permission mirrors the walker
   (load needs R, store/AMO needs W; W-without-R pages
   never reach the TLB — the walker faults them; S from
   a U page faults unless SUM; U from an S page faults).
   TLB-hit + permission fault: fetch faults into IF/ID,
   data faults cause 13 (load) / 15 (store/AMO) with tval
   = VA. Flushed by any sfence.vma in M/S and any satp
   write in WB (flush beats insert on the same edge).
   The old one-entry fetch cache (`fetch_pa`) still
   exists and is also cleared on sfence in M/S.
2. **A/D writeback (walker state 4).** When a leaf is
   accepted but A (PTE bit 6) is 0, or (store/AMO and D
   (bit 7) is 0), the walker stores the accept regs and
   goes to state 4, where the data port writes the
   updated PTE (PTE | 0x40 | (store ? 0x80 : 0)) and then
   completes the translation. TLB insert happens on
   immediate accept (only when A set and (not store or
   D set)) or on state-4 completion.
3. **D-miss re-walk (found by the ad test).** A load
   caches a TLB entry with D = 0; a later store hitting
   that entry must NOT silently store without setting D
   (the privileged spec requires D to be set or a fault).
   So TLB entries record D, and a store/AMO hitting an
   entry with W ok but D = 0 is a D-miss, not a fault:
   it re-walks (state 4 sets D) instead of faulting.
   Inserts invalidate older overlapping entries, so a
   fresh D = 1 entry can never be shadowed by the stale
   D = 0 entry it replaces (round-robin order would
   otherwise allow that).
4. **Misaligned traps.** Load half needs addr[0] == 0;
   load word / store word / AMO need addr[1:0] == 0;
   byte accesses never misaligned. Causes: load 4,
   store/AMO 6, except misaligned LR = 4 (LR detected
   via AMO funct5 00010). Misaligned outranks page
   fault (privileged-spec trap priority). The Phase 1-4
   behaviour (a misaligned access crossing a page
   boundary silently continued into the next physical
   page) is GONE. The old `mmu_cross` test encoded the
   old behaviour (expecting 0x44332211); it now expects
   the trap (cause 4, tval 0x40000FFE, a0 = 4).
   No walk starts for a misaligned access.
5. **Software interrupt.** New core input `irq_soft`;
   mip bit 3 = irq_soft. Priority: external > software >
   timer (privileged-spec order MEI > MSI > MTI, same
   for supervisor remaps). Codes: M software 3, S
   software 1. Old tops tie it to 0; soc2 drives it
   from the SBI IPI register.
6. **EX/MEM halt bubble (found by the misaligned
   work).** EX/MEM now also bubbles on `ex_halt`.
   Without this, a misaligned load (or an illegal CSR
   instruction) with mtvec == 0 would still commit its
   wrapped load / CSR write in WB after halting.
7. **SUM stall (found by the old OS boot).** A write to
   sstatus (0x100) or mstatus (0x300) pending in EX/MEM/
   WB stalls ID (bubbles ID/EX), mirroring satp_pending.
   Reason: a translated load/store/AMO checks
   sstatus.SUM combinationally on a TLB hit in EX, and
   CSR forwarding does not cover that check. Without
   this stall, a load two instructions after
   `csrs sstatus, SUM` reads the pre-csrs SUM value and
   faults on a U page (the old kernel's print path hit
   exactly this: cause 13 on the user string, cascading
   to cause 15 on the handler stack). The stall must
   include WB: the memory op reaches EX the cycle after
   the write leaves MEM, while the write is still in
   WB, and the check would still read stale. Writes to
   sstatus/mstatus are rare (kernel only), so the cost
   is negligible.
8. **WFI / fence as NOPs (no change, documented).**
   WFI executes as a NOP (it does not wait — the idle
   loop spins instead of sleeping; safe for boot, no
   power saving). fence / fence.i are NOPs (no caches,
   so fences are correctly no-ops).
9. **mem_load_o (new core output).** = ex_mem_is_load
   (MEM-stage load flag), for SOC tops whose register
   reads have side effects (16550 RBR pop, PLIC claim).
   Old tops leave it unconnected (legal for an output).

## Builders (the 0x1000 slot bug)

`tools/build_sbi.py` and `tools/build_smode.py` lay out
firmware + test with the test at byte offset 0x1000
(image word 1024). An earlier version padded to word 256
(0x400) while the firmware jumped to 0x80001000, so the
core fetched zeros there, took an illegal-instruction
trap with stvec still 0, and looped through ROM. Fixed
by padding to word 1024. The same class of bug bit the
PLIC/timer tests differently: they ended with `ecall`
while mtvec still pointed at the handler, so the ecall
trapped to the handler and mret returned to the same
ecall forever — fixed by clearing mtvec before the
final ecall in `soc2_programs/plic.s` and
`soc2_programs/timer64.s`. And the SBI test's timer
handler originally never masked the level timer
interrupt, so it retook forever (s1 = 5291 at 50K
cycles) — fixed by clearing STIE in sie on the first
tick.

## Test results (Phase 5, all green at push time)

- soc2 platform: plic PASS (32089 cycles, a0 = 0),
  uart16550 PASS (1220), timer64 PASS (20074),
  virtio PASS (2115).
- Core gaps: tlb PASS (242), ad PASS (193), misalign
  PASS (492), ipi PASS (258). (Cycle counts vary by a
  few cycles run to run with the SUM stall; a0/s0 = 0
  is the pass criterion.)
- SBI + DTB: sbi PASS (32623 cycles, s0 = 0, UART 'S',
  no '!'), dtb PASS (1294 bytes, version 17, 10 nodes,
  all required nodes present).
- Bootloader: boot PASS (1573 cycles, s0 = 0, UART 'BK').
- Regressions: `./run_os.sh` 78/78 PASS (os_boot PASS
  at 10174 cycles — was 28037 at Phase 4; the TLB
  caches translations so fewer walks run — plus SOC
  11/11, pipe 16/16, random 50/50). v7 (`./run.sh`)
  green, including call_demo sp restored to 65532.
- Full suite: `./run_soc2.sh` (soc2 + coregaps + sbi +
  dtb + boot + run_os.sh).
- Debug aids (kept in the repo, not part of the suite):
  `sim/tb_dbg.v` (soc2 pc/instruction + walker + ADDBG
  traces) and `sim/tb_soc_dbg.v` (old-SOC pc/priv trace
  + S-handler trap-register trace). These are how the
  SBI pad bug, the ad D-miss, and the OS-boot SUM stall
  were found; they print to stdout and are only useful
  with small +MAXCYCLES budgets.
- Icarus speed (measured): TB startup ~1.2 s per run at
  1 MiB; per-cycle ~0.11-0.17 ms. Do NOT run multiple
  vvp jobs concurrently on the 2-core VM; wall time
  inflates sharply.

## Building a Linux kernel for big32

Toolchain (free, apt): `gcc-riscv64-linux-gnu` (the
bare-metal `gcc-riscv64-unknown-elf` toolchain CANNOT
build the kernel: its ld rejects `-shared`, which the
riscv vDSO link needs — that failure is what forced the
switch). The kernel source used here: Linux 6.6.52
(LTS) from kernel.org. Config: start from
`rv32_defconfig`, then:

- Disable compressed instructions: CONFIG_RISCV_ISA_C
  must be off (big32 has no C extension). It is
  selected by CONFIG_EFI, so disable EFI first, then
  disable RISCV_ISA_C, then olddefconfig — in that
  order, or the select forces it back on.
- Disable the FPU: CONFIG_FPU off (no FPU in the core).
- Disable SMP (single CPU in the DTB), modules, and
  initramfs (the boot attempt has no root filesystem;
  the honest stopping point is the kernel's "no working
  init" panic, which still proves early boot got through
  setup, console, and driver init).
- Keep: CONFIG_SERIAL_8250 + CONFIG_SERIAL_8250_CONSOLE
  + CONFIG_SERIAL_EARLYCON (console via the 16550),
  CONFIG_VIRTIO_MMIO + CONFIG_VIRTIO_BLK (block
  device), CONFIG_SIFIVE_PLIC (PLIC), CONFIG_RISCV_SBI
  (SBI v0.2+ calls), CONFIG_RISCV_TIMER (rdtime
  clocksource — needs the TIME CSR above).

Build (from the kernel tree):

  make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- -j2 Image

Verify the result before any boot attempt:

- `file vmlinux` / `readelf -h vmlinux` must show
  ELF32, RISC-V.
- No compressed instructions: disassemble vmlinux and
  check no 16-bit encodings appear (any 4-hex-digit
  instruction word in objdump output would be a C
  instruction the core cannot execute).
- Note the Image size: it must fit in the RAM you give
  the simulation (32 MiB here) alongside the firmware,
  the DTB, and the kernel's own runtime allocations.

Boot attempt harness (test-only shortcut, documented):
the real path would use the bootloader (virtio -> RAM
-> S-mode). For the attempt, the testbench loads the
kernel Image directly (+KIMGBIN, the binary Image
itself, at +KIMGOFF=2097152 = 0x200000, the 2 MiB-aligned
load address the riscv kernel requires for its early
megapage mapping) and a firmware variant
(`tools/build_kboot.py`: the SBI firmware with ONLY
the drop target changed, mepc 0x80001000 -> 0x80200000)
drops to it in S-mode with a0 = 0, a1 = DTB. The DTB
is loaded at 0x80020000 (+DTBFILE/+DTBOFF) and is the
boot variant (`tools/build_kboot_dtb.py`: 64 MiB memory,
100 kHz timebase — see below). Compile with
`iverilog -Ptb_soc2.TB_MEM_BYTES=67108864` (64 MiB)
and run with a cycle budget; capture the UART
transcript and the final state.

Three harness lessons, all found by running, in the
order they bit:

1. **Icarus -P only overrides TOP-module parameters.**
   `-Pbig32_soc2.MEM_BYTES=...` and
   `-Ptb_soc2.dut.MEM_BYTES=...` are silently ignored
   (verified: a probe printed MEM_BYTES=1048576 after
   both). The size therefore lives on the testbench
   itself (`TB_MEM_BYTES`, default 1048576, passed down
   to dut), and the kernel attempt compiles with
   `-Ptb_soc2.TB_MEM_BYTES=67108864`. The 1 MiB default
   is unchanged, so all Phase 5 tests are unaffected.
2. **The firmware image load loop must be bounded by
   the img array, not by MEM_WORDS.** The old break
   (`i = 262144`) only exited the loop when MEM_WORDS
   was 262144 (the 1 MiB default). At 64 MiB it skipped
   to 262144 and then ran all 16.7M iterations, each
   hierarchical write re-evaluating the core/SOC
   combinational logic that reads memw — that was the
   15+ min "hang" in every 64 MiB run. Fixed by bounding
   the loop at 262144 (the img array size). The same
   class of bug does not affect the disk loop (already
   bounded by 262144) or the clear loop (skipped by
   +NOCLEAR on big-RAM runs).
3. **Do not load a multi-megabyte kernel with
   $readmemh.** Icarus's hex parser takes ~300 us per
   line: a 9.7M-line (87 MB) text hex needs 35-65 min
   before cycle 0. The kernel attempt instead uses
   $fread of the binary Image into a word array plus a
   byte-swap loop ($fread packs bytes big-endian into
   words; the RISC-V Image is little-endian), via
   +KIMGBIN. Measured pieces: 1M hierarchical writes
   in 0.75 s, 16M-word async reads in 0.38 s for 2000
   cycles — the file parsers, not the memory, are the
   bottleneck. +NOCLEAR skips the 16M-word RAM clear
   (same re-evaluation cost as the firmware loop bug)
   on big-RAM runs; the firmware, DTB, and kernel
   regions are written explicitly, and the kernel
   zeroes its own BSS before use.

Boot DTB choices (simulation, documented, not hardware
claims): memory 64 MiB (the trimmed Image alone is
34.4 MB; the 1 MiB default cannot hold it) and
timebase-frequency 100 kHz instead of 10 MHz (mtime
ticks 1/cycle, so a kernel second costs
timebase-frequency cycles: 100 kHz makes kernel time
run 100x faster relative to cycles, so second-scale
timeouts expire in 100K cycles instead of 10M; the
SBI timer and rdtime both use the same mtime, so
timekeeping stays self-consistent).

Kernel execution proof (debug run, 20000 cycles,
`sim/tb_kboot_dbg.v` trace, trimmed Image):
pc=80200000 instr=0d40006f (`j _start_kernel`) in
S-mode (priv=1), then sie/sip clears, then a memory
zeroing loop (sw zero, pointer +4, bound check) at
0x80200104-0x80200114, ~3990 iterations in the window,
a1=0x80020000 (DTB) preserved, no traps, no UART yet
(earlycon prints come after the assembly setup, MMU
on, and start_kernel — all after the zeroing loop).
The kernel is booting normally, just slowly: the
zeroing loop alone needs on the order of 1-2M cycles
for a multi-megabyte region, which is why the bounded
attempt below uses 5M cycles.

## Linux status (honest)

**Linux 6.6.52 boots and prints on big32 in simulation
(SBI probed, DTB parsed, earlycon enabled, memory/SLUB/
IRQ init reached), but does NOT reach a prompt or
userspace yet — no root filesystem is provided, and a
full boot needs far more cycles than Icarus delivers
in a session.** Attempts below, 26 Oct 2026, in order
(the first attempt used a 2MB-aligned load and died in
setup_vm; the 4MB-aligned attempts are the ones that
print). Debug testbenches used for the kernel runs:
`sim/tb_kboot_dbg.v` (filtered pc/instr trace) and
`sim/tb_kboot_dbg9.v` (trap-entry trigger + CSR footer:
sepc/scause/stval/stvec/satp/sstatus/sie/priv — the
tool that found the setup_vm ebreak).

- Kernel: Linux 6.6.52, rv32, no C / no FPU / no SMP,
  no VGA console (link fix), trimmed of DRM / sound /
  wireless / media / framebuffer (Image 34,402,300
  bytes, down from 38,746,188). vmlinux verified ELF32
  RISC-V; objdump of the whole vmlinux shows NO
  compressed instructions (the 14 four-hex-digit lines
  are the Image header fields and zero padding, not
  instructions; the entry is `j _start_kernel`, which
  jumps over the header).
- Attempt: 5,000,000 cycles, 64 MiB RAM, kboot firmware
  (SBI, mepc 0x80200000), boot DTB (64 MiB, 100 kHz
  timebase), kernel loaded via +KIMGBIN at 0x80200000.
  Result: CYCLES 5000000, HALTED 0, **no UART output**.
- What the 5M-cycle end state proves: the kernel got
  through _start_kernel, the memory zeroing loop, page
  table setup, and MMU enable, and is running C code:
  a2 = 0xC0000000 (PAGE_OFFSET), sp/s0 set
  (0x82201F50/0x82201F70), a0 = DTB (0x80020000)
  preserved, a5 = RAM base (0x80000000). No '!' (no
  M-mode firmware trap), no halt, priv stayed in S
  after the drop.
- What it does NOT prove: no printk reached the UART
  in 5M cycles, so earlycon/console output is
  unconfirmed — either setup_arch had not reached
  earlycon_init yet, or the kernel is spinning silently
  somewhere in setup. A follow-up end-window trace
  (last 100K cycles of a 5M run) was launched to tell
  spinning from progressing; its result goes here when
  it lands. Until kernel output appears, "Linux boots"
  is NOT claimed.
- **Exact blocking point found (dbg8 + dbg9, 26 Oct
  2026): the kernel parks in its temporary trap vector,
  it does NOT idle normally.** The last 100K cycles of
  a 5M run execute only the 2-instruction loop at
  0x802000cc (`wfi; j 0x802000cc`) — the third pc in
  the trace (0x802000d4, _start_kernel's first
  instruction) is a flushed speculative fetch after
  the jump, not a real execution. The trap-entry trace
  (dbg9) gives the cause: first entry at cycle 481118,
  sepc = 0x81204438, scause = 3 (EBREAK), stval = 0,
  stvec = 0x802000cc (the temporary vector),
  satp = 0 (MMU off), priv = 1 (S-mode). The ebreak
  is setup_vm+0x80 (vmlinux 0xC1004438), i.e. the
  second of the two sanity BUG_ONs at the top of
  setup_vm (arch/riscv/mm/init.c):
  `BUG_ON((kernel_map.phys_addr % PMD_SIZE) != 0)`.
  On Sv32 (folded PMD) PMD_SIZE = PGDIR_SIZE = 4 MB
  (PGDIR_SHIFT 22), and our load address 0x80200000
  is only 2MB-aligned (0x80200000 % 0x400000 =
  0x200000), so the BUG fires. The compiler implements
  the modulo check as `slli a5, a5, 10; beqz; ebreak`
  (a5 = the auipc-derived runtime _start). The core's
  auipc/slli/beq were all verified correct by small
  directed tests on the SOC (auipc with the negative
  0xFEFFC immediate included) — this is a platform
  load-address bug, NOT a core bug. **Fix: load the
  kernel at a 4MB-aligned address, 0x80400000
  (+KIMGOFF=4194304, kboot mepc updated; the 34.4 MB
  Image still fits in the 64 MB DTB memory).**
  Attempt 4 (5M cycles, 4MB-aligned load) tests this
  fix; its result goes here when it lands.
- **ATTEMPT 4 RESULT (26 Oct 2026): THE KERNEL BOOTS
  AND PRINTS.** 5,000,000 cycles, 64 MiB RAM, kboot
  firmware (mepc 0x80400000), boot DTB, Image via
  +KIMGBIN at 0x80400000. Full UART output:
  ```
  [    0.000000] Linux version 6.6.52 (root@htch-runtime)
    (riscv64-linux-gnu-gcc (Ubuntu 13.3.0-6ubuntu2~24.04.1)
    13.3.0, GNU ld (GNU Binutils for Ubuntu) 2.42) #3
    Mon Oct 26 17:33:35 UTC 2026
  [    0.000000] OF: fdt: Ignoring memory range
    0x80000000 - 0x80400000
  [    0.000000] Machine model: big32 Phase 5
  [    0.000000] SBI specification v2.0 detected
  [    0.000000] SBI implementation ID=0x42494733 Version=0x1
  [    0.000000] SBI TIME extension detected
  [    0.000000] SBI IPI extension detected
  [    0.000000] SBI RFENCE extension detected
  [    0.000000] SBI SRST extension detected
  [    0.000000] earlycon: ns16550a0 at MMIO 0x10010000
    (options '')
  [    0.000000] printk: bootconsole [ns16550a0] enabled
  ```
  What each line proves: the kernel parsed OUR device
  tree ("Machine model: big32 Phase 5" is our DTS
  model string); it probed OUR SBI (spec v2.0, impl
  ID 0x42494733 = "BIG3", our firmware's ID) and
  detected exactly the extensions we implemented
  (TIME, sPI, RFNC, SRST — and correctly NOT HSM,
  whose probe returns 0); earlycon registered on OUR
  16550 at 0x10010000 and the bootconsole is enabled.
  The run ended at the 5M-cycle budget (HALTED 0),
  still in early start_kernel — MMU on (a2 =
  0xC0000000 PAGE_OFFSET, sp/s0 in kernel VA space),
  no fault, no '!' flag. This is a real Linux kernel
  booting on big32 in simulation, not a stub: the
  4MB-alignment fix was the last blocker to first
  printk. A longer attempt (20M cycles) was run to
  push the log further; userspace is NOT reached
  yet (no root filesystem is provided — the expected
  end state without one is the kernel's "No working
  init found" panic, after driver init, which needs
  far more cycles than one session's budget).
- **ATTEMPT 5 RESULT (26 Oct 2026, PARTIAL — the run
  was killed mid-flight by a runtime/session reaping,
  not by the kernel: log ends mid-line at the PLIC
  warning trace, no CYCLES/HALTED footer; the 65
  lines it did flush are the evidence).** Same inputs
  as attempt 4 but 20M cycles. New output beyond
  attempt 4: Zone ranges (Normal 0x80400000–
  0x83FFFFFF, 60 MB — the DTB's 64 MB minus the 4 MB
  below the kernel load, as expected); "Found CPU
  without hart ID" (x2) + "Unable to find cpu node"
  + "Falling back to deprecated riscv,isa" (the DTS
  cpu node had no reg property — non-fatal fallback);
  "riscv: base ISA extensions" (empty — same cause);
  dentry/inode caches, 15225 total pages, virtual
  memory layout (fixmap/vmemmap/vmalloc/lowmem 60 MB),
  "Memory: 26168K/61440K available (13824K kernel
  code, 8963K rwdata, 4096K rodata, 4152K init, 375K
  bss, 35272K reserved)", SLUB, "NR_IRQS: 64", then
  a NON-FATAL WARNING at drivers/irqchip/
  irq-sifive-plic.c:449 in __plic_init (stack trace
  through plic_init -> of_irq_init -> irqchip_init
  -> init_IRQ -> start_kernel). Line 449 is
  `WARN_ON(!nr_contexts)` where nr_contexts =
  of_irq_count(node): our DTS PLIC node had NO
  interrupts-extended property, so the count is 0
  and PLIC init FAILS (driver unregistered; boot
  continues, but no UART/virtio external IRQs —
  timer IRQs via SBI are unaffected). **Fixes made
  to os_programs/big32.dts after attempt 5 (source
  only; a boot with the fixed DTB is a follow-up,
  NOT claimed here): cpu@0 gains `reg = <0>`
  (hartid), and the PLIC node gains
  `interrupts-extended = <&cpu0 11 &cpu0 9>`
  (M external 11, S external 9, hart 0).** The boot
  DTB builder (tools/build_kboot_dtb.py) copies the
  DTS, so the fixes propagate on rebuild.
- The binding constraint is simulation speed, not a
  missing platform piece found so far: at ~0.15
  ms/cycle, 5M cycles is ~12 min wall plus ~10 min
  image load, and a full boot needs hundreds of
  millions of cycles. No platform fault (trap, halt,
  '!' flag) has been observed in any kernel run.
- **ATTEMPT 6 RESULT (27 Oct 2026, fixed DTB — PLIC
  WARN_ON gone, but a NEW failure one step later).**
  20,000,000 cycles, 64 MiB RAM, kboot firmware (mepc
  0x80400000), rebuilt boot DTB (1334 bytes, verified
  by decompiling: cpu reg = <0>, PLIC
  interrupts-extended = <0x02 0x0b 0x02 0x09>, 64 MiB
  memory, 100 kHz timebase), Image via +KIMGBIN at
  0x80400000. Full log: `kernel/boot_attempt6.log`
  (run ends cleanly: CYCLES 20000000, HALTED 0,
  $finish). The kernel progresses PAST the attempt-5
  point: zone/memory setup, "Memory: 26168K/61440K
  available", SLUB, "NR_IRQS: 64" — and the attempt-5
  PLIC WARN_ON at irq-sifive-plic.c:449 does NOT
  reappear. The cpu reg = <0> fix also works: the
  "Found CPU without hart ID" / "Unable to find cpu
  node" lines are gone, and the kernel now parses
  "riscv: base ISA extensions aim" (the "Falling back
  to deprecated riscv,isa" line remains because the
  node has riscv,isa but no riscv,isa-extensions —
  non-fatal, isa parsed fine). Then the new failure:
  ```
  [    0.000000] OF: of_irq_init: children remain, but no parents
  [    0.000000] Kernel panic - not syncing: No interrupt controller found.
  [    0.000000] Call Trace: ... panic -> init_IRQ+0x44 -> start_kernel
  ```
  **Precise diagnosis (checked against the 6.6.52
  source in-tree):** `of_irq_init` (drivers/of/irq.c)
  processes interrupt controllers parent-first; a
  controller's parent comes from its
  interrupts-extended/interrupt-parent. The PLIC's
  interrupts-extended points at cpu@0, but cpu@0 is
  NOT an interrupt controller — it has no
  interrupt-controller property, no #interrupt-cells,
  and no cpu-intc child — so it never enters the
  parent list, the PLIC (and its children uart/virtio)
  are never initialised, and riscv `init_IRQ`
  (arch/riscv/kernel/irq.c) panics because
  handle_arch_irq is still NULL. The missing piece
  is the hart-level interrupt controller node the
  binding requires: cpu@0 must contain a child
  `cpu_intc: interrupt-controller` (compatible
  "riscv,cpu-intc", #interrupt-cells = <1>,
  interrupt-controller), and interrupts-extended
  must reference IT, not the cpu node — exactly as
  the sifive,plic binding example shows
  (`interrupts-extended = <&cpu0_intc 11>`).
  **Fix for a follow-up attempt (NOT done here —
  attempt 6 scope only):** add the cpu-intc child;
  PLIC interrupts-extended = <&cpu_intc 11 &cpu_intc
  9>; CLINT interrupts-extended = <&cpu_intc 7
  &cpu_intc 3> (it has the same defect); rebuild the
  boot DTB and re-run. Expected: cpu-intc registers
  as root, PLIC initialises, no panic at init_IRQ.
  The dtc warning seen when rebuilding ("Missing
  property '#interrupt-cells' in node /cpus/cpu@0
  ... referred from interrupts-extended") was this
  defect announcing itself in advance.
- Attempt 7 (27 Oct 2026, the cpu-intc fix, 20M-cycle
  budget, 64 MiB RAM, kboot firmware (mepc
  0x80400000), rebuilt boot DTB (1422 bytes, up
  from 1334: cpu-intc child added, PLIC
  interrupts-extended = <0x02 0x0b 0x02 0x09>,
  CLINT = <0x02 0x07 0x02 0x03>, cpu reg = <0>,
  64 MiB memory, 100 kHz timebase — all verified
  by decompiling the DTB; the cpu@0
  #interrupt-cells dtc warning is gone, only a
  pre-existing cosmetic simple-bus unit-address
  warning remains), Image via +KIMGBIN at
  0x80400000, line-buffered output. Full log:
  `kernel/boot_attempt7.log`. **The cpu-intc fix
  WORKED: the attempt-6 panic is gone.** Past
  init_IRQ the kernel prints:
  ```
  [    0.000000] riscv-intc: 32 local interrupts mapped
  [    0.000000] plic: plic@0c000000: mapped 3 interrupts with 1 handlers for 2 contexts.
  ```
  Then the NEXT failure, one step later in
  start_kernel (time_init, +0x468, vs init_IRQ
  +0x44 in attempt 6):
  ```
  [    0.000000] Kernel panic - not syncing: RISC-V system with no 'timebase-frequency' in DTS
  [    0.000000] Call Trace: ... panic -> time_init+0x4c -> start_kernel
  ```
  **Precise diagnosis (checked against the in-tree
  6.6.52 source):** `time_init`
  (arch/riscv/kernel/time.c) reads
  timebase-frequency from the `/cpus` node
  itself (`of_find_node_by_path("/cpus")`), NOT
  from cpu@0 — and the binding
  (Documentation/devicetree/bindings/riscv/cpus.yaml)
  says exactly that: "RISC-V requires
  'timebase-frequency' in /cpus, so disallow it
  here" (in the cpu-node schema). Our DTS puts
  timebase-frequency inside cpu@0 only, so the
  lookup fails and time_init panics
  unconditionally. This never bit before because
  no earlier attempt reached time_init (attempt 6
  died at init_IRQ, the step just before it).
  **Fix for a follow-up attempt (NOT done here —
  attempt 7 scope only):** move (or copy)
  timebase-frequency into the /cpus node
  (keeping the boot-DTB builder's 10 MHz -> 100
  kHz replacement working — it matches the
  literal string, so it applies wherever the
  property sits), rebuild the boot DTB, verify
  by decompiling that /cpus carries it, and
  re-run. Expected: time_init passes, timer
  probe runs, boot continues past start_kernel's
  early stage.
- Attempt-7 run notes (environmental, not kernel):
  the log ends at the panic line with no
  CYCLES/HALTED footer: the sim process is gone
  (a session/runtime restart during this run
  broke the launcher's process tracking, the same
  class of interruption as attempt 6's VM reboot).
  The result still stands — the panic is
  deterministic given the DTB (time_init panics
  unconditionally without the property, and it is
  reached early), so no cycle budget would have
  changed it; only the footer is missing, not the
  evidence. Line buffering again saved the log.
- Attempt 8 (27 Oct 2026, the timebase-frequency fix,
  20M-cycle budget, 64 MiB RAM, kboot firmware (mepc
  0x80400000), rebuilt boot DTB (1422 bytes, same size
  as attempt 7: the property MOVED from cpu@0 to /cpus,
  not added — verified by decompiling: /cpus
  timebase-frequency = <0x186a0> = 100000 = 100 kHz
  after the builder's literal-string replacement,
  cpu-intc phandle 0x02 intact, PLIC
  interrupts-extended = <0x02 0x0b 0x02 0x09>, CLINT
  = <0x02 0x07 0x02 0x03>, cpu reg = <0>, 64 MiB
  memory; only the pre-existing cosmetic simple-bus
  unit-address dtc warning remains), Image via
  +KIMGBIN at 0x80400000, line-buffered output, run
  ends cleanly: CYCLES 20000000, HALTED 0, $finish.
  Full log: `kernel/boot_attempt8.log`. **The
  time_init fix WORKED: attempt 7's panic is gone.**
  Past init_IRQ the kernel prints, as in attempt 7:
  ```
  [    0.000000] riscv-intc: 32 local interrupts mapped
  [    0.000000] plic: plic@0c000000: mapped 3 interrupts with 1 handlers for 2 contexts.
  ```
  and then, NEW — time_init passes and the clock
  runs:
  ```
  [    0.000000] clocksource: riscv_clocksource: mask: 0xffffffffffffffff max_cycles: 0x179dd7f66, max_idle_ns: 28210892933900 ns
  [    0.004710] sched_clock: 64 bits at 100kHz, resolution 10000ns, wraps every 35184372085000ns
  ```
  That 0.004710 timestamp is the first non-zero
  kernel timestamp in any attempt: kernel time is
  actually advancing on the 100 kHz timebase. After
  sched_clock there is NO further kernel output
  within the 20M-cycle budget — no panic, no trap,
  no halt, no driver-init or console output. This
  log alone cannot distinguish the two readings:
  (a) the post-sched_clock init (per-cpu,
  workqueues, RCU, timer calibration) is simply
  instruction-heavy under TLB misses and its next
  print lies beyond 20M cycles, or (b) the kernel
  is stalled/spinning somewhere silent (e.g.
  waiting on a timer interrupt that never arrives).
  The footer REGS give no pc, so where it spends
  its time is NOT established here — do not claim
  either reading. **Next step (NOT done here —
  attempt 8 scope only):** a bounded pc-trace
  debug run (like the Phase 5 dbg9 trap-entry
  trace) sampling pc after sched_clock, to tell
  progress from a spin; then, if it is progress,
  a larger cycle budget, and if it is a stall, the
  exact wait site and whether SBI timer delivery
  is the cause.
- PC-TRACE DEBUG RUN (27 Oct 2026, after attempt 8;
  testbench `sim/tb_kboot_trace.v`, a copy of
  tb_soc2.v that watches the UART stream for the
  "sched_clock" print and then samples dut.core.pc
  every 100 cycles into `kernel/pc_trace.txt`, plus
  interrupt/trap counters printed at $finish;
  analysis `kernel/analyze_trace.py`). Same kernel
  + DTB configuration as attempt 8, 20M-cycle
  budget. The run was cut short by a VM reboot at
  ~16.24M cycles (uptime reset; the $finish footer,
  snapshot file and interrupt counters were lost
  to buffering), but 36,659 pc samples over
  3,665,800 post-sched_clock cycles survived and
  are sufficient for the verdict. **VERDICT:
  STALLED, not progressing.** Evidence: (1) the
  sampled function set is frozen after the first
  ~366K post-sched cycles — the first bucket
  holds 184 functions (the tail of time_init plus
  random_init entropy work: blake2s/chacha,
  extract_entropy, pcpu_alloc, perf_event_init),
  while every later bucket holds the same ~88
  functions and adds ZERO new ones (only
  handle_exception and second_overflow appear
  after bucket 0, then nothing for ~2.9M cycles);
  (2) no sample at all in console_init,
  kmem_cache_init_late, lockdep_init,
  calibrate_delay/__delay, fork_init, pid_idr_init,
  sched_clock_init, rest_init, kernel_init or
  do_idle, and no new UART output in the whole
  window; (3) every bucket is the same timer-tick
  working set: timekeeping_advance alone is 7,248
  samples (~20%), plus timekeeping_update,
  ktime_get, tick_periodic, scheduler_tick,
  hrtimer_run_queues, clockevents_program_event,
  update_process_times, handle_riscv_irq/do_irq and
  spinlocks. **Timer delivery is NOT the problem:**
  timer interrupts arrive and are handled
  (riscv_timer_interrupt 251 samples,
  handle_riscv_irq 471), timekeeping advances every
  tick, the SBI timer is reprogrammed each tick
  (sbi_set_timer 374 + __sbi_set_timer_v02 157
  samples), and M-mode SBI handler code executes
  (636 samples, 62 distinct firmware pcs). The
  boot thread's only recurring footprint after
  bucket 0 is a single pc, start_kernel+0x4B8
  (0xC1000F44: the auipc of the call to
  kmem_cache_init_late, immediately after
  local_irq_enable's sstatus write, verified by
  hand-decoding the vmlinux bytes; kmem_cache_
  init_late itself is only 72 bytes and never
  samples): 52 samples, all in S-mode, every one
  with a tick-handler sample before it
  (irq_exit_rcu/handle_riscv_irq) and do_irq
  immediately after it. So the boot thread is
  parked at/around the local_irq_enable ->
  kmem_cache_init_late boundary, with interrupts
  enabled and ticking, and never observably enters
  kmem_cache_init_late, console_init or anything
  after. What 100-cycle pc sampling alone cannot
  resolve is the micro-mechanism at that boundary
  (why the call site re-samples while the callee
  never does) — one plausible mechanism, not
  established, is tick-handler livelock: HZ=250
  means a tick every 400 cycles at the 100 kHz
  timebase, and a tick handler thrashing the
  16-entry TLB could take most of each interval,
  starving the boot thread; but the samples do not
  prove that rate, so it is NOT claimed. **Next
  step (NOT done here):** a finer trace (per-cycle
  commit pc + tick-entry timestamps + trap
  causes) around a tick boundary to pin the exact
  wait mechanism. A longer cycle budget alone is
  NOT the next step: the function set was frozen
  for 3.67M cycles, so more cycles of the same
  would not advance init. (Re-run note: the
  reboot also removed apt-installed Icarus; the
  compiled `sim/tb_kboot_trace.vvp` survives, so
  the same trace binary can re-run without
  recompiling, but rebuilding it needs Icarus
  reinstalled.)
- Attempt-6 run notes (environmental, not kernel):
  the first fresh run of this session was killed at
  ~02:42 IST by a VM reboot (uptime reset; its
  partial log, ending at the SRST line, is kept as
  `kernel/boot_attempt6_vmreboot_partial.log`); the
  reboot also removed apt-installed Icarus, which
  was reinstalled from the surviving cached deb
  (iverilog_12.0-2build2) before relaunching. The
  previous session's 30M-cycle run was found still
  alive but writing to a deleted log file (an
  earlier `rm` had unlinked it) with stdio still
  buffered, so its output was unrecoverable and it
  was killed in favour of a fresh line-buffered
  (`stdbuf -oL -eL`) run — the log above is from
  that fresh run, and line buffering is now the
  documented way to run kernel attempts.

- FINER TICK-BOUNDARY TRACE (27 Oct 2026, after the pc-trace
  debug; testbench `sim/tb_kboot_fine.v`, a copy of
  tb_kboot_trace.v that logs per-cycle fetch pc, EX-stage pc,
  priv, pipe_stall, div_stall, ptw_state, int_take /
  int_take_tim / int_take_ext, int_code, ex_trap /
  ex_trap_cause, mtime and irq_timer after the sched_clock
  print; analysis `kernel/analyze_fine.py`; same kernel + DTB
  as attempt 8, 800,000-cycle fine window after sched_clock,
  run ends by the window limit with a clean $finish footer;
  full log `kernel/tick_trace.log`, trace
  `kernel/pc_trace_fine.txt`, 800,000 samples, cycles
  12,569,338–13,369,337). **VERDICT: the wait mechanism is
  PROVEN — a timer-tick livelock, and it is not the
  TLB-thrash hypothesis alone.** The boot thread's next
  instructions, decoded from vmlinux bytes: 0xC1000F40 is
  `csrrsi sstatus, 2` (local_irq_enable, set SIE), and
  0xC1000F44/0xC1000F48 are the call to
  kmem_cache_init_late (auipc ra + jalr ra, target
  0xC1013848, matching System.map). The repeating cycle,
  199 times in the window, is: (1) the boot thread
  fetches 0xC1000F44; its page is not in the 16-entry
  TLB, so the fetch runs a 3-cycle page-table walk
  (ptw_state 1,2,3; every one of the 199 BOOT-fetch
  episodes includes exactly one walk); (2) a timer
  interrupt has been pending throughout (mtime >=
  mtimecmp), and int_take is blocked during the walk
  by core design, so it fires on the first unblocked
  cycle after the walk completes; (3) the take flushes
  IF/ID, so 0xC1000F44 is discarded before it reaches
  EX — in 198 of 199 episodes it never even advances
  from fetch to 0xC1000F48, and in the remaining one it
  reaches ID and is flushed before EX; EX pc is
  0xC1000F44 in ZERO cycles and EX pc inside
  kmem_cache_init_late in ZERO cycles; (4) the handler
  (entered via handle_exception at 0xC0D81064) runs
  ~3,673 cycles and returns via sret to 0xC1000F44
  (int_mepc is the uncommitted fetch pc, since the
  auipc never committed), and the loop repeats. The
  boot thread gets a mean of 4.98 fetch cycles per
  tick window, all consumed by the fetch + walk. The
  handler's length is the root inequality: timer
  int_take intervals are 3,673–3,752 cycles (mean
  3,677.4), handler spans (take to next 0xC1000F44
  fetch) are 3,669–3,748 (mean 3,673.4), while the
  programmed tick period at CONFIG_HZ=250 on the
  100 kHz timebase is 400 counts — the handler takes
  ~9x the tick period, so the timer is permanently
  pending (mtimecmp 13,367,001 already behind mtime
  13,369,340 at the window end), and every handler
  return is immediately followed by another take.
  TLB thrash is real and quantified but secondary:
  each tick window's handler fetches from 41 distinct
  4 KiB pages (plus data pages), far over the 16
  TLB entries, with 22,508 walks / 67,523 PTW cycles
  in the window (9% of handler-window cycles) — so
  the freshly installed 0xC1000F44 entry is evicted
  during every handler, which is why the fetch walks
  every tick; but even with a TLB hit, a permanently
  pending timer taken at the first boundary would
  still flush the instruction from IF/ID, so a
  bigger TLB alone does NOT break the livelock.
  SBI timer delivery is healthy: the only traps in
  the window are 199 S-mode ecalls (cause 9, at
  __sbi_set_timer_v02+0x28), one per tick, reprogram-
  ming the timer; there are ZERO page-fault,
  misaligned, illegal or unknown traps, so the old
  do_trap_unknown samples were not real traps.
  (The first ecall precedes the first take by 55,148
  cycles: that is the initial timer programmed while
  interrupts were still disabled, before
  local_irq_enable — the first take fires as soon as
  SIE is set, at 0xC1000F44's flight.) **Minimal fix
  it points at (NOT implemented here — follow-up
  decision):** break the handler > period inequality.
  The simulation knobs that do it are a longer tick
  period — a higher declared timebase (1 MHz gives a
  4,000-count period, barely above the 3,673-cycle
  handler; 10 MHz gives 40,000, comfortable, at the
  cost of second-scale kernel timeouts taking 100x
  more cycles) or a lower HZ (HZ=100 gives 1,000,
  still below the handler and insufficient; HZ=10
  gives 10,000 and suffices, at the cost of 100 ms
  ticks) — or, properly but much bigger, a core fast
  enough that the tick handler fits inside 400
  cycles. A larger TLB helps the walk count but does
  not by itself unstick the boot. **Next step (NOT
  done here):** pick one of those knobs (or the core
  speedup) and re-run; the trace binary
  `sim/tb_kboot_fine.vvp` and analysis
  `kernel/analyze_fine.py` are reusable for
  verifying the fix (success = EX pc reaches
  0xC1000F44/0xC1000F48 and kmem_cache_init_late).

- ATTEMPT 9 (27 Oct 2026, the tick-period fix; log
  `kernel/boot_attempt9.log`, 20M-cycle budget, 64 MiB
  RAM, kboot firmware (mepc 0x80400000), Image via
  +KIMGBIN at 0x80400000, line-buffered output, clean
  $finish: CYCLES 20000000, HALTED 0). **Knob chosen:
  10 MHz declared timebase, NOT HZ=10 — and why:**
  kernel/Kconfig.hz offers only 100/250/300/1000, so
  HZ=10 would need a kernel-source Kconfig patch, and
  the riscv64 toolchain is absent from this VM (no
  riscv64-linux-gnu-gcc, no dpkg record), so a kernel
  rebuild would first need a toolchain reinstall
  through crawling apt mirrors. The timebase knob is
  DTB-only: kernel Image, SBI firmware and testbench
  untouched, and the SBI timer and rdtime still use
  the same mtime, so timekeeping stays
  self-consistent — the only cost is that a kernel
  second now costs 10M cycles instead of 100K.
  Implementation: `tools/build_kboot_dtb.py` now takes
  optional `[timebase_hz [output_basename]]` (defaults
  unchanged: 100000, big32_kboot); built with the
  kernel tree's own dtc
  (kernel/linux-6.6.52/scripts/dtc/dtc — the apt
  device-tree-compiler package is not installed in
  this VM). New DTB `soc2_hex/big32_kboot_10mhz.dtb`
  (+ .txt), 1422 bytes like attempt 8, verified by
  decompiling: /cpus timebase-frequency = <0x989680>
  = 10,000,000, cpu-intc with #interrupt-cells = 1
  intact, PLIC interrupts-extended =
  <0x02 0x0b 0x02 0x09>, CLINT = <0x02 0x07 0x02 0x03>,
  64 MiB memory; only the pre-existing cosmetic
  simple-bus unit-address warning. The attempt-8
  100 kHz DTB is untouched. **Result: the livelock
  is BROKEN.** The kernel prints, past the attempt-8
  stall:
  ```
  [    0.000047] sched_clock: 64 bits at 10MHz, resolution 100ns, wraps every 4398046511100ns
  [    0.016011] Console: colour dummy device 80x25
  [    0.018271] printk: console [tty0] enabled
  [    0.020389] printk: bootconsole [ns16550a0] disabled
  ```
  The tick period is now 40,000 counts (10 MHz /
  HZ 250) against the ~3,673-cycle handler, so the
  timer is no longer permanently pending. The
  console lines are the functional proof the stall
  is passed: in start_kernel (init/main.c)
  kmem_cache_init_late() is line 1003 and
  console_init() line 1010 — the boot thread cannot
  print console_init output without having executed
  and returned from the previously un-executable
  call. (This run used the plain tb_soc2 testbench,
  so EX-pc sampling was not repeated; the console
  lines subsume that criterion.) After the
  bootconsole-disable line there is NO further UART
  output to 20M cycles — no panic, no trap, no
  calibrate-delay line. That silence is a
  console-selection artifact, NOT evidence of a new
  stall: bootargs carry only "earlycon", so once
  the real console registers, printk's preferred
  console is the dummy tty0 (no VGA hardware), and
  output leaves the UART. **Next step (NOT done
  here — attempt-9 scope only):** add
  console=ttyS0 to the DTB chosen bootargs and
  re-run, so UART output continues past
  console_init and calibrate-delay/driver init
  become visible; note second-scale timeouts now
  cost 10M cycles, so later progress may need a
  larger cycle budget. Nothing pushed to GitHub,
  no rootfs built, bootloader sector loop untouched.

- ATTEMPT 10 (27 Oct 2026, the console=ttyS0 re-run;
  log `kernel/boot_attempt10.log`, 40M-cycle budget
  requested, 64 MiB RAM, kboot firmware (mepc
  0x80400000), Image via +KIMGBIN at 0x80400000,
  line-buffered output). **Bootargs change:**
  `os_programs/big32.dts` chosen bootargs
  "earlycon" -> "earlycon console=ttyS0"
  (earlycon retained; the SOC2 16550 at 0x10010000
  is the only serial port in the tree, so it is
  ttyS0; stdout-path already pointed at it;
  CONFIG_SERIAL_8250_CONSOLE=y confirmed).
  New DTB `soc2_hex/big32_kboot_10mhz_console.dtb`
  (+ .txt), 1434 bytes, verified by decompiling:
  bootargs = "earlycon console=ttyS0",
  /cpus timebase-frequency = <0x989680> =
  10,000,000, cpu-intc phandle 0x02 intact, PLIC
  interrupts-extended = <0x02 0x0b 0x02 0x09>,
  CLINT = <0x02 0x07 0x02 0x03>, 64 MiB memory;
  only the pre-existing cosmetic simple-bus
  warning. The attempt-9 DTB is untouched.
  **Run interruption, stated plainly:** the first
  launch was killed mid-run by a VM reboot (uptime
  reset; apt-installed Icarus lost again,
  reinstalled from the cached iverilog_12.0-2build2
  deb); its partial log is preserved as
  `kernel/boot_attempt10_interrupted.log` (18 lines,
  reached "Initmem setup node 0"). The run was
  then relaunched cleanly with the same inputs;
  the log below is the relaunched run. **Result:
  the console goal is MET — UART output continues
  far past console_init.** The kernel itself
  confirms the new bootargs live: "Kernel command
  line: earlycon console=ttyS0". Past attempt 9's
  endpoint, in order: "Console: colour dummy device
  80x25", "Calibrating delay loop (skipped), value
  calculated using timer frequency.. 20.00 BogoMIPS
  (lpj=40000)" (the calibrate-delay line attempt 9
  never showed), pid_max, LSM, mount caches, RCU,
  ASID allocator, devtmpfs, jiffies clocksource,
  futex, pinctrl, NET/NETLINK, DMA pool, audit,
  thermal, cpuidle — timestamps advancing
  0.016 -> 0.53 s. (Unlike attempt 9 there is no
  "console [tty0] enabled" / "bootconsole disabled"
  pair: with console=ttyS0 as the preferred console
  the bootconsole stays live on the same UART until
  the 8250 console registers, so output never
  leaves the UART.) **New blocker, precise, at
  kernel time 0.53 s — a PANIC, not a stall:**
  ```
  [    0.515190] Oops - Oops - load address misaligned [#1]
  [    0.515617] CPU: 0 PID: 1 Comm: swapper Not tainted 6.6.52 #3
  [    0.516737] epc : __riscv_copy_words_unaligned+0xc/0x5c
  [    0.517602]  ra : check_unaligned_access.part.0+0xe0/0x440
  [    0.524971] status: 00000120 badaddr: c249a003 cause: 00000004
  [    0.534799] Kernel panic - not syncing: Fatal exception in interrupt
  ```
  Stack: kernel_init -> kernel_init_freeable ->
  do_one_initcall -> check_unaligned_access_boot_cpu
  (arch_initcall). Diagnosis, checked against the
  6.6.52 source: the probe in
  arch/riscv/kernel/cpufeature.c deliberately does
  unaligned word loads (dst = page|0x1, src off by
  3) and assumes hardware misaligned support OR the
  kernel's S-mode misaligned-load emulation. Our
  Phase-5 core traps misaligned loads (cause 4,
  delegated via medeleg bit 4 — spec-correct), so
  the S-mode handler runs
  handle_misaligned_load (traps_misaligned.c) — and
  that function reads the fault address with
  `csr_read(mtval)`, the M-mode CSR. Our core
  correctly traps mtval reads from S-mode as
  illegal (CSR privilege gate, bits [9:8] = 11 ->
  M only), so the emulator cannot work as written
  on a platform that both traps misaligned accesses
  in hardware AND delegates them to S-mode (on
  real/QEMU platforms the probe never traps, or
  M-mode firmware emulates, so this emulator path
  never executes). The exact micro-step by which
  the emulator fails (nested illegal trap vs -1
  return) is NOT established from the UART log
  alone — it needs a targeted trap trace around
  the probe. The sim was stopped after the panic
  (terminal: the kernel spins in its panic loop;
  running to the 40M budget would add no output),
  so the log has no $finish footer — the panic end
  line is the final evidence. **Next step (NOT done
  here — attempt-10 scope only):** either (a)
  handle misaligned accesses in the core hardware
  (the architecturally normal path — the spec
  permits it, and the probe then never traps), or
  (b) trace the emulator failure precisely (mtval
  read + nested trap) before touching the core, or
  (c) stop delegating misaligned traps and emulate
  in M-mode firmware (OpenSBI-style, biggest work).
  Nothing pushed to GitHub, no rootfs built,
  bootloader sector loop untouched.

## Phase 6 — hardware misaligned load/store support (attempt 11)

Attempt 10's panic came from the core trapping every
misaligned load/store. The user picked option (a):
handle them in the core hardware (the architecturally
normal path — the RISC-V spec permits hardware
misaligned support, and the kernel's
check_unaligned_access probe then never traps).
Implemented 27 Oct 2026 in `src/big32_core_pipe.v`
only; the v7 single-cycle core is untouched and keeps
the old trap-everything behaviour.

### Why the core change is small

The simulation tops already delivered correct unaligned
bytes, so the core's EX trap was the main blocker:
- Pipe top (`src/big32_pipe.v`): byte-wise DMEM reads
  at addr..addr+3, relative-mask writes.
- SOC2 top (`src/big32_soc2.v`): RAM reads merge two
  words (`data_word_ram`); stores shift data and mask
  by addr[1:0] (`st_data64`, `st_mask8`), so an
  unaligned store spans two words correctly.
- Python model (`tools/model.py`): byte-addressed
  dmem, `load_word`/`store_word` assemble bytes at
  a..a+3 — already handles unaligned accesses.

### What changed in the core

- `ex_misaligned` no longer fires for regular
  loads/stores. It now fires only for:
  - a misaligned AMO/LR/SC (addr[1:0] != 0 — the spec
    requires natural alignment for atomics), or
  - a load/store crossing a 4 KiB page boundary under
    translation (the second page needs its own
    translation, not implemented).
- Cross-page detection: `ex_mem_size` from funct3[1:0]
  (1/2/4 bytes); `ex_cross_page` =
  addr[11:0] + size > 4096. The trap is decided only
  once a translation is known: on a TLB hit, or in
  the `ptw_data_done` cycle after a walk. While a walk
  is in flight neither size source is valid yet, so no
  trap fires and the walk proceeds.
- To decide the superpage question the data TLB lookup
  now also reports `tlb_data_super` (from
  `tlb_super[td]` on both hit branches), and the walker
  records `ptw_data_super` (1 on a level-1 leaf, 0 on a
  level-0 leaf, `ptw_accept_super` on state-4 A/D
  writeback for data walks). A cross-page access inside
  a 4 MB superpage does NOT trap — physical contiguity
  holds across the whole superpage.
- Trap-clear: if `ex_trap` and the EX instruction is a
  load/store/AMO, `ptw_data_done <= 0` after the walker
  case statement, so a cross-page trap leaves no stale
  translation for the next memory instruction.
- NOT touched, deliberately: the CSR privilege gate and
  the mtval restriction (both correct), and the trap
  behaviour for everything else. `ex_mis_cause` is
  unchanged (load/LR -> 4, store/SC/AMO -> 6) and trap
  tval remains the faulting VA.

### Coverage and limits (exact)

- Handled: within-page unaligned LB/LH/LW/LBU/LHU/
  SB/SH/SW, including word-boundary-crossing two-word
  merges, little-endian byte order, sign/zero
  extension; unaligned accesses within a 4 MB
  superpage; all unaligned loads/stores in bare mode
  (PA == VA, no translation).
- Still traps: any misaligned AMO/LR/SC; any
  load/store crossing a 4 KiB page boundary under
  translation. (Micro-detail: if that walk had to set
  A/D, the state-4 PTE writeback already happened
  before the trap fires — harmless on a writable page;
  the trap-clear then drops the translation itself, so
  the next memory instruction re-walks.)
- Not guaranteed / unchanged: unaligned accesses to
  MMIO/device or ROM regions (the tops do not
  byte-merge those the way RAM is merged);
  instruction-fetch misalignment (fetches are
  word-based; kernel code is aligned); the v7 core.

### Tests (27 Oct 2026, Icarus 12.0 reinstalled — see note)

- New directed program `programs/misalign_demo.s`
  (bare mode, pipe top; data at 0x200/0x300, clear of
  the pipe_check scratch words): lh/lhu/lw/lb/lbu at
  +1/+2/+3/+4 offsets over 0x11223344 / 0x55667788,
  sh then aligned re-load, sw then aligned and
  unaligned re-loads, and the kernel-probe shape
  (lw at base+1 and base+3 over 0xDEADBEEF /
  0x12345678). Expected a0 = 420555360, computed by an
  independent byte-level calculation (not just the
  model). Model and Verilog agree: 420555360.
- `soc2_programs/misalign.s` rewritten to the new
  semantics (the old version's premise — within-page
  unaligned accesses trap — is obsolete by design):
  cases 1–5 now require within-page unaligned
  lh/lw/lhu/sh/sw to SUCCEED with correct values and
  zero traps; cases 6–8 still require AMO/LR/SC at
  VA+2 to trap with the right cause/tval; new case 9
  requires a lw at VA 0x40000FFE crossing the page
  boundary to trap cause 4, tval 0x40000FFE; aligned
  lw/sw controls must not trap.
- Regression results, all green:
  pipe directed 17/17 (16 old + misalign_demo),
  random 50/50; SOC 11/11 (including mmu_cross: a
  misaligned cross-page lw from VA 0x40000FFE still
  traps cause 4, tval 0x40000FFE); SOC2 coregaps 4/4
  (including rewritten misalign, s0=0, 393 cycles),
  sbi PASS, dtb PASS (1434 bytes), boot PASS,
  os_boot PASS (10174 cycles); v7 ./run.sh PASS.
- Environment note: Icarus was again missing after a
  VM reboot; apt lists were crawling, so the deb was
  fetched directly from the azure archive mirror
  (iverilog_12.0-2build2_amd64.deb, 2,125,764 bytes)
  and installed with dpkg. A copy is kept at
  `iverilog_12.0-2build2_amd64.deb` in this directory
  for the next reinstall. The `dtc` binary is also
  missing (apt package not installed); sbi_check /
  boot_check were run with a PATH shim
  (`bin/dtc` -> kernel tree's own
  `scripts/dtc/dtc`, which build_kboot_dtb.py already
  uses). Neither gap is a regression from this change.

### Boot attempt 11 — DONE, probe NOT passed (failure moved)

- Fixed core + attempt-10 DTB
  (`soc2_hex/big32_kboot_10mhz_console.dtb`, 1434
  bytes: bootargs "earlycon console=ttyS0", /cpus
  timebase 10 MHz), kboot firmware
  (`soc2_hex/kboot_fw.hex`, mepc 0x80400000), kernel
  Image via +KIMGBIN at 0x80400000 (KIMGOFF
  4194304), 64 MiB RAM, +NOCLEAR, +MAXCYCLES
  40000000, line-buffered, log
  `kernel/boot_attempt11.log` from the start.
- Success criterion: no misaligned Oops at the
  check_unaligned_access probe site, kernel prints
  further into driver init and beyond. Outcome and
  quoted log lines to be filled in when the run
  finishes; nothing claimed until the log shows it.
- OUTCOME (log `kernel/boot_attempt11.log`): the
  probe is NOT passed — but the failure moved.
  The kernel boots identically to attempt 10 through
  cpuidle (0.498838 s), then Oopses at the probe:
  ```
  [    0.515464] Oops - Oops - load address misaligned [#1]
  [    0.515892] CPU: 0 PID: 1 Comm: swapper Not tainted 6.6.52 #3
  [    0.517011] epc : __riscv_copy_words_unaligned+0x28/0x5c
  [    0.517889]  ra : check_unaligned_access.part.0+0xe0/0x440
  [    0.518834] epc : c0001858 ra : c0002020 sp : c2437e40
  ```
  Attempt 10 faulted at +0xc (the FIRST unaligned
  load of the copy loop); attempt 11 faults at +0x28
  (the EIGHTH load). Reading
  `arch/riscv/kernel/copy-unaligned.S` (SZREG=4):
  +0xc is `lw a4, 0(a1)`, +0x28 is `lw t3, 28(a1)`.
  The probe (`cpufeature.c`, BUFFER 0x4000, COPY
  0x1F80, dst = page|0x1, src = dst + 0x2000 + 2)
  copies from src = buffer + 0x2003 in 32-byte
  steps; load addresses are congruent to 3, 7, 11,
  15, 19, 23, 27, 31 (mod 32). A 4-byte load
  straddles a page boundary only at page offsets
  0xFFD/0xFFE/0xFFF, i.e. mod-32 residues 29/30/31
  — only the +28 load (residue 31) can straddle,
  and it does so at iteration k=127, where a1 =
  buffer + 0x2FE3 and the +28 load sits at buffer +
  0x2FFF, one byte before the page end. So the
  remaining fault is exactly the documented Phase 6
  limitation: the page-boundary-crossing load traps
  (cause 4) even though the next page is mapped.
  Within-page unaligned support itself works — the
  first 7 loads of every iteration, and 127
  iterations, pass before this one load traps.
  SECOND ANOMALY (unexplained from the log alone):
  after the epc line the Oops register dump stalls
  — no further UART output for 6+ minutes while vvp
  burns ~92% CPU, so no badaddr/cause/panic lines
  are in the log (attempt 10 printed the full Oops
  including badaddr c249a003). The badaddr
  prediction (buffer + 0x2FFF) is therefore
  arithmetic, not log-confirmed. The run was
  stopped after the stall (no CYCLES/HALTED footer,
  same as attempt 10's panic-terminated log); the
  64-line log is the final evidence.
- NEXT STEP (decided 27 Oct 2026, DONE as Attempt 12
  below): emulate misaligned accesses in M-mode
  firmware. The cross-page core redesign stays off
  the table; the Phase 6 core is unchanged.

### Attempt 12 — M-mode firmware misaligned emulation

- Design (OpenSBI-style, `os_programs/sbi_firmware.s`,
  252 -> 765 words, still under the 1024-word slot
  before the S-mode test at 0x1000):
  - medeleg 0xB9FF -> 0xB9AF: bits 4 (load address
    misaligned) and 6 (store/AMO address misaligned)
    cleared, so those traps land in M-mode, where
    reading mtval is legal. Bit 0 (instruction
    address misaligned) stays delegated: a misaligned
    fetch is a control-flow error, not a data access.
    mideleg unchanged (0x888). S-ecall (cause 9) was
    already not delegated.
  - The M-mode handler (`misalign_entry`) decodes the
    faulting instruction from mepc: it first walks
    mepc through the trapped context's Sv32 tables
    (M-mode is always bare, so the walk result is a
    physical address read directly), then requires a
    4-byte load (opcode 0x03) or store (0x23) whose
    mcause matches (4/6). Anything else redirects
    (below). Compressed instructions are redirected:
    the kernel has no C code (vmlinux verified), and
    a 16-bit pattern must never be emulated as a
    32-bit access.
  - The access is performed BYTE BY BYTE (little-endian
    order, size 1/2/4 from funct3, sign/zero extension
    matching lb/lh/lw/lbu/lhu): each piece VA is
    translated separately through the trapped satp
    (`walk_va`: two-level Sv32, L1 superpage leaf or
    L1 pointer to an L0 leaf; permission checks mirror
    the core — V required, loads need R, stores need
    R+W, U page needs SUM for S-mode, S page faults
    for U-mode; M-mode trapped context and bare satp
    are physical, PA = VA). The cross-page case is
    just two pieces in different pages — no core
    change, no two-word merge. After the last piece,
    a load writes rd back and the handler mreTs with
    mepc advanced by 4.
  - Register access: the handler saves ra/a0-a7/t0-t6
    to its stack frame; `getreg` recovers any trapped
    register value (t-regs and ra from their slots,
    a0/a1/s0-s11/gp/tp live, sp from mscratch);
    `putreg` writes the load result where `ret_path`
    picks it up (slot for ra/a2-a7/t0-t6, live
    register for a0/a1/s0-s11/gp/tp, mscratch for
    sp, nothing for x0). The emulation uses only
    t0-t6 plus free frame slots 64..124, so the
    trapped s-registers survive untouched.
  - NOT emulated, redirected to S-mode instead:
    misaligned AMO/LR/SC (the spec requires them to
    trap), compressed instructions, unknown
    opcodes/funct3, mcause/opcode mismatch, and any
    piece whose page-table walk faults (redirect
    cause 13 for loads, 15 for stores, stval = the
    faulting piece VA). The redirect sets sepc =
    mepc (NOT advanced), scause, stval, and sstatus
    (SPP = trapped privilege from mstatus MPP, SPIE
    = old SIE, SIE = 0) exactly as a hardware trap
    entry to S would, forces mstatus MPP = S, and
    mrets to stvec (plus 4*cause if stvec is
    vectored) — so the kernel's S handler sees the
    trap as if hardware had delivered it, and can
    fix up a page fault and retry, or Oops.
  - Limits, stated plainly: the walk does NOT set
    A/D bits in PTEs (the next hardware access to
    the page sets them, as on a normal TLB miss);
    if a later store piece faults, earlier pieces
    are already written (re-execution after the
    kernel fixes the mapping rewrites the same bytes
    — idempotent on RAM; cross-page MMIO stores are
    not guaranteed); no UART output anywhere on the
    emulation path (the probe's timing loops would
    spam the console and corrupt the kernel log).
  - Real bug found and fixed by the directed test
    (not a core bug — a firmware bug): the old
    `ret_path` restored t2 from its slot and then
    clobbered it computing mepc+4, so every emulated
    load into t2 returned the next PC instead of the
    loaded value (debug: lw at 0xFFF returned
    0x800010C8/0x80001108, the two test lw
    instructions +4). SBI callers never noticed
    because SBI returns in a0/a1 and t2 is
    caller-saved scratch to them. Fix: `ret_path`
    now advances mepc FIRST, while t2 still holds
    handler scratch, and restores t2 afterwards —
    strictly preserving all restored registers.
    The core's memory path is untouched.
- Directed test: new `soc2_programs/emu_misalign.s`
  (S-mode via firmware, `build_smode.py` + tb_soc2):
  two mapped 4 KiB pages (page 1 added, unlike
  Phase-6 misalign.s). 16 cases + aligned controls,
  PASS (halted=1, s0=0, 6488 cycles):
  lw 2+2 / 1+3 (the exact probe shape) / 3+1
  straddles, lh/lhu/lb/lbu, sh 1+1, sw 2+2 and 1+3
  — all emulated with S-handler count 0 and correct
  values, with load rds varied across t2, a0, s2,
  t0, a1, and sp (the sp case leaves sp holding the
  loaded value 0xB0C0D004, as designed); amoadd/lr/sc
  within-page and cross-page amoadd all redirect
  (S count 1, cause 4/6, tval = faulting VA, memory
  untouched by the trapped AMO); within-page
  lh/lw/sh/sw and aligned lw/sw keep count 0.
  lb/lbu are hardware controls (size 1 never traps).
  Two test-expectation bugs were caught by the same
  runs and fixed (lw 2+2 value 0xCCDD6655 ->
  0xCCDD5566; sw 1+3 second word 0xAAAAB0C0 ->
  0xAAA0B0C0) — the emulation was right both times.
- Existing test updated for the new semantics:
  `soc2_programs/misalign.s` case 9 (cross-page lw)
  now expects emulation success (count 0, value
  0xCCDD0000) with page 1 mapped, instead of the
  Phase-6 trap expectation; cases 1-8 and controls
  unchanged (AMO/LR/SC still reach the S handler
  via redirect, transparently).
- Regressions, all green with the new firmware
  (765 words): pipe directed 17/17 (incl.
  misalign_demo 420555360), random pipe 50/50,
  SOC 11/11, SOC2 4/4 (plic, uart16550, timer64,
  virtio), coregaps 4/4 (tlb, ad, misalign, ipi),
  sbi PASS (SBI extensions intact), dtb PASS
  (1434 bytes), boot PASS, os_boot PASS (10174
  cycles), v7 `./run.sh` PASS. Environment notes:
  Icarus had vanished again (VM reboot) and was
  reinstalled from the cached deb; sbi/boot checks
  needed `bin/dtc` on PATH (kernel tree's own dtc).
- Boot attempt 12: new firmware as kboot image
  (`soc2_hex/kboot_fw.hex`, 765 words; verified to
  differ from the S-mode firmware image in exactly
  one word, the mepc drop target 0x80001000 ->
  0x80400000) + attempt-10 DTB
  (`soc2_hex/big32_kboot_10mhz_console.dtb`, 1434
  bytes, console=ttyS0, 10 MHz), kernel Image via
  +KIMGBIN at 0x80400000, 64 MiB RAM, +NOCLEAR,
  +MAXCYCLES 40000000, line-buffered, log
  `kernel/boot_attempt12.log` from the start.
- OUTCOME (log `kernel/boot_attempt12.log`, 71 lines):
  **PROBE PASSED.** The kernel boots identically to
  attempt 10/11 through cpuidle (0.498847 s), then:
  ```
  [    0.541960] cpu0: Ratio of byte access time to unaligned word access is 3.65, unaligned accesses are fast
  ```
  That is check_unaligned_access's success line: the
  copy loop ran to completion, including the
  cross-page straddling load at iteration 127 that
  Oopsed in attempts 10 (+0xc) and 11 (+0x28), and
  the kernel judged unaligned accesses fast. Zero
  Oops/panic lines in the whole log. The run was
  stopped by the operator after the verdict (no
  CYCLES/HALTED footer, same as attempts 10/11) —
  the log ends at 1.131779 s, NOT at a stall:
  ```
  [    0.646358] audit: type=2000 audit(0.388:1): state=initialized audit_enabled=0 res=1
  [    0.687458] HugeTLB: registered 4.00 MiB page size, pre-allocated 0 pages
  [    1.040287] raid6: using algorithm int32x4 gen() 2 MB/s
  [    1.119742] raid6: using intx1 recovery algorithm
  [    1.130404] iommu: Default domain type: Translated
  [    1.131779] iommu: DMA domain TLB invalidation policy: strict mode
  ```
  So the boot now gets through the probe and deep
  into driver init (audit, HugeTLB, raid6, iommu).
  The attempt-11 Oops-dump stall does not recur in
  any form — there is no Oops at all. One honest
  note: mid-run, the bootconsole -> Zone-ranges gap
  looked like a stall (no output for ~20 min), and
  a parallel A/B run with pre-Attempt-12 firmware
  was briefly launched on the spare core as a
  diagnostic; the main run then broke through to
  Initmem on its own, proving the gap was sim
  slowness, not a stall, so the A/B run was killed
  and its partial log removed. Nothing pushed to
  GitHub, no rootfs built, bootloader sector loop
  untouched, core memory path untouched.
- NEXT STEP (in order): rootfs + init (without it
  the kernel stops at the "no working init" panic);
  multi-MB bootloader sector loop (removes the
  +KIMGBIN shortcut); faster simulation/FPGA.

### Attempts 13/14 — rootfs + init BUILT, kernel freezes inside do_initcalls (27 Oct 2026)

No RISC-V toolchain exists in the VM (no riscv gcc/clang,
no BusyBox, no cpio), so userspace was hand-assembled:
`rootfs/init.asm` (RV32I only, no M/A/C) + `rootfs/mkelf.py`
(assembler + static ELF32 builder; encodings cross-checked
8/8 against `tools/asm.py`). The init is ET_EXEC, EM_RISCV,
entry 0x10000, 3,356-byte image, a real shell (help, echo,
ls via getdents64, cat, uname, pwd; mounts /proc + /sys)
plus /hello.txt — it has never executed yet. Initramfs was
rejected: CONFIG_BLK_DEV_INITRD is unset and no toolchain
exists to rebuild the kernel. Rootfs is ext4 on the virtio-blk
disk (`rootfs/rootfs.img` 1 MiB, `soc2_hex/rootfs_disk.hex`;
`mkfs.ext4 -F -m 0 -O ^has_journal,^resize_inode -b 1024`).
DTB variants: `soc2_hex/big32_kboot_10mhz_rootfs.dtb`
(1,486 bytes, bootargs "earlycon console=ttyS0 root=/dev/vda
rootfstype=ext4 rootwait ro init=/init") and the debug
variant `soc2_hex/big32_kboot_10mhz_rootfs_dbg.dtb`
(1,502 bytes, same + initcall_debug). RX commands for the
prompt test: `rootfs/rx_cmds.txt` (echo hello from big32,
ls, uname, cat /hello.txt, pwd).

Attempt 13 (log `kernel/boot_attempt13.log`, 85,597 lines,
10 MHz): probe passes (0.549720), kernel goes PAST attempt
12 (SCSI, usbcore, vgaarb), then FREEZES deterministically
at 1.332707 s at "clocksource: Switched to clocksource
riscv_clocksource" — no "Freeing unused kernel image", no
"Waiting for root device", no "Run /init", no VFS line, so
still inside do_initcalls, not at root-mount. No output
for 15+ min while the sim burned CPU. UART breakage ruled
out (LSR THRE/TEMT = 1, bootconsole flowing). Attempt 14
(2 MHz + initcall_debug, killed by a VM restart at
0.261 s) proved 2 MHz does NOT reintroduce the tick
livelock but is slower (46% tick overhead vs 9% at
10 MHz) — 10 MHz stays. Attempt 13/14 docs were not
written at the time; this section + Attempt 15 below
close that gap. Nothing pushed.

### Attempt 15 — initcall_debug boot: freeze REPRODUCES, stuck initcall NOT named (27 Oct 2026)

Launch (log `kernel/boot_attempt15.log`, fresh):
`vvp sim/tb_kboot_dbg15.vvp` (a copy of tb_kboot_dbg.v
with TB15 stage markers, original untouched) compiled
with `-Ptb_kboot_dbg.TB_MEM_BYTES=67108864`, +HEX
kboot_fw.hex, +DISKHEX rootfs_disk.hex, +DTBFILE
big32_kboot_10mhz_rootfs_dbg.dtb.txt, +DTBOFF=131072,
+KIMGBIN kernel Image at +KIMGOFF=4194304, +NOCLEAR,
+MAXCYCLES=100000000, +RX2FILE=rootfs/rx_cmds.txt,
+RX2START=45000000, +RX2PERIOD=600, line-buffered.

Environment, stated plainly: two VM restarts during this
session each wiped apt-installed Icarus and left the
os-intent apt replay holding the dpkg lock; Icarus was
reinstalled from the cached deb
(`iverilog_12.0-2build2_amd64.deb`) after the lock freed.
The first two launches of attempt 15 were silent for
35 and 39 min with only the $readmemh warning in the
log — diagnosed, not a kernel stall: the DTBFILE was
the BINARY .dtb, but the testbench reads DTBFILE with
$fscanf("%h") and expects the .txt hex-byte file (one
hex byte per line, as build_kboot_dtb.py writes
alongside every .dtb). On binary data the $fscanf loop
spins without advancing. LESSON, in capitals for the
next run: +DTBFILE takes the .dtb.txt file, never the
binary .dtb. The markers proved the rest of the load
path fast (FW DONE, DISK DONE in under 3 min; kernel
$fread + byte-swap loop finished, kbinn=8600575 words
= the full 34,402,300-byte Image) and the kernel banner
followed immediately after RST RELEASED.

Result: probe passes again (0.814157, "unaligned
accesses are fast"), boot runs through audit, HugeTLB,
raid6, iommu, SCSI, usbcore, vgaarb, and stops at
exactly the attempt-13 site:

```
[    1.907101] vgaarb: loaded
[    1.932466] clocksource: Switched to clocksource riscv_clocksource
```

No further output for 15+ min while the sim burned
~98% CPU (1h25m CPU time at kill); no "Freeing unused
kernel image", no "Waiting for root device", no
"Run /init", no VFS line. The freeze is reproduced,
not sim slowness. The run was then stopped by the
operator; the log is the evidence of record.

The stuck initcall is NOT named, and that failure is
itself a finding: initcall_debug produced ZERO trace
output despite the kernel command line being verified
in the log ("... init=/init initcall_debug") and the
source path being confirmed in-tree (init/main.c
do_one_initcall -> do_trace_initcall_start ->
trace_initcall_start_cb prints KERN_DEBUG "calling
%pS @ %i"; core_param bool parses a bare
"initcall_debug" as 1; CONSOLE_LOGLEVEL_DEFAULT=7).
No "calling" and no "initcall ... returned" line
appears anywhere in the log, even though do_initcalls
provably ran (the arch_initcall probe, SCSI, usbcore
and vgaarb initcalls all executed and printed). Do
NOT guess the stuck initcall from the suspects list
(8250 probe, virtio-mmio probe) — the log does not
name it. Next diagnostic (not started): a pc-trace at
the freeze, as was done for the attempt-8 stall, to
find the spinning PC and identify the initcall's code;
or resolving why the initcall_debug trace prints are
absent. Only after the kernel passes this point can
the prompt be tested (RX commands are timed for after
the prompt at 10 MHz). No userspace prompt is claimed.
Nothing pushed.

### pc-trace at the 1.33 s freeze — DONE 28 Oct 2026: the kernel is NOT stuck
   (authorised 28 Oct 2026 08:31 IST; diagnosis only, no fix attempted,
   nothing pushed)

   Harness: sim/tb_kboot_trace_freeze_m.v, adapted from the attempt-8
   sim/tb_kboot_trace.v (module renamed; trace to
   kernel/pc_trace_freeze.txt, snaps to
   kernel/pc_trace_freeze_snap.txt; plus a 500,000-cycle heartbeat
   printing cycle / fetch pc / fetched instr / IF pc / IF instr /
   IF valid / privilege). Analysis: kernel/analyze_trace_freeze.py
   (adapted from kernel/analyze_trace.py; same System.map resolver).
   Launch = attempt-13 config: non-debug rootfs DTB (.txt file,
   NEVER the binary .dtb), +NOCLEAR, 30M-cycle budget, line-buffered
   log. Two launch lessons, both paid for in this session:
   (1) Icarus -P is a COMPILE-time option: passing
   -Ptb_kboot_trace_freeze_m.TB_MEM_BYTES=67108864 to vvp at run time
   does NOTHING, leaving the 1 MiB default, so kernel-region fetches
   returned the SOC2 NOP constant 32'h00000013 and the fetch pc slid
   +4/cycle with a constant stride (first two runs: 18+ min of silence,
   then a heartbeat diagnosis proved instr was always 0x00000013).
   Correct line: iverilog -Ptb_kboot_trace_freeze_m.TB_MEM_BYTES=
   67108864 -o sim/tb_kboot_trace_freeze_m.vvp src/big32_core_pipe.v
   src/big32_soc2.v sim/tb_kboot_trace_freeze_m.v, then plain vvp.
   (2) A VM restart mid-run killed run 1 at 13M cycles (trace saved as
   kernel/pc_trace_freeze_partial1.txt, 3,686 samples, pre-freeze
   baseline only) and wiped Icarus again; reinstalled from the cached
   deb and relaunched on the surviving 64 MiB .vvp — no recompile
   needed. Run 2 is deterministic: every heartbeat matches run 1
   exactly (same pcs at same cycles).

   Run 2 evidence (log kernel/pc_trace_freeze_run2.log, trace
   kernel/pc_trace_freeze.txt, snaps kernel/pc_trace_freeze_snap.txt):
   173,198 samples, cycles 12,680,300..30,000,000, priv S-mode
   172,810 / M-mode 388, HALTED 0 (kernel still running at the cap).
   Footer: SCHED_CYCLE 12680213 (sched_clock trigger), CNT_INT_TIM
   436, CNT_INT_EXT 0, CNT_INT_SOF 0, CNT_TRAP 427, MTIME 30000003,
   MTIMECMP 30031670 (mtimecmp AHEAD of mtime by ~31,667 counts).
   The freeze REPRODUCES exactly: last UART lines are
   "[ 1.317317] vgaarb: loaded" then
   "[ 1.332707] clocksource: Switched to clocksource riscv_clocksource"
   — the 1.332707 s timestamp identical to attempt 13. No "Freeing
   unused kernel image", no "Waiting for root device", no "Run /init",
   no VFS line in 30M cycles.

   VERDICT — not a spin, not a livelock, not a wait on a dead device:
   (a) Timer-tick livelock (attempt-8 mechanism) RULED OUT: 436 timer
   interrupts over the run matches the expected ~432 ticks after
   time_init at a 40,000-cycle period; mtimecmp is ahead of mtime at
   every snap and at the end (attempt 8's signature was mtimecmp
   BEHIND); timekeeping_advance appears throughout; the boot thread
   commits instructions. (b) UART/serial probe spin RULED OUT:
   serial8250_init, uart_register_driver, tty_register_device have
   ZERO post-freeze samples; no 8250 code in the post-freeze top
   functions. (c) virtio-mmio wait RULED OUT: virtio_mmio_probe and
   virtio_probe have ZERO post-freeze samples; no virtio code in the
   post-freeze top functions. (d) Idle-wait with dead ticks RULED
   OUT: cpu_idle / default_idle / do_idle / cpu_startup_entry have
   ZERO post-freeze samples; ticks arrive and timekeeping advances.
   What the trace DOES show: the kernel is alive inside do_initcalls
   (do_one_initcall 31 post-freeze samples, initcall_blacklisted 14,
   and a scatter of initcalls completing 1-2 samples each), has NOT
   reached kernel_init / rest_init / run_init_process (all ZERO
   post-freeze), and has NOT reached userspace (ZERO priv-0 samples).
   Initcall progress is sequential: the 555-entry initcall table was
   extracted from the Image (__initcall_start 0xC140CD8C to
   __initcall_end 0xC140D638) and resolved against System.map; the
   trace marches [0] asids_init @14.18M -> [171] vga_arb_device_init
   (printed) -> [186] proc_locks_init @26.14M -> [205] chr_dev_init
   @27.16M, i.e. ~[210]/555 by 30M cycles. serial8250_init [342] and
   virtio_blk_init [357] have NOT run yet.
   Post-freeze activity profile (26M..30M, 40,001 samples, ~5,000
   distinct pcs per 1M-cycle slice, stable across all four slices):
   blake2s_compress_generic 4,000 (exactly 10.0%), memset 1,502,
   __might_resched 978, __might_sleep 973, memcpy 963, spinlocks,
   up_write / down_write, kmem_cache_alloc, kernfs_name_hash /
   __kernfs_new_node / kernfs_activate / idr_get_free / device_add
   (device/sysfs registration), chacha_permute 627, timekeeping_advance
   765, vsnprintf/format_decode (device naming). Final state at 30M
   cycles: pc __schedule+0x118, ra __schedule+0xE0, s5 schedule+0x60
   — the boot thread inside the scheduler (voluntary sleep between
   work), not spinning. UART silence after 1.332707 s is EXPECTED,
   not a console failure: the initcalls in the [183]-[230] range are
   registration-only and print nothing on success, and the bootconsole
   (earlycon) is still the active console — the real ttyS0 console
   only registers when serial8250_init [342] runs, which has not
   happened yet, so "no console [ttyS0] enabled line" is expected,
   not a bug.
   HONEST GAP: the coarse pc samples name the activity but NOT the
   exact initcall or wait-queue (they do not record do_one_initcall's
   function-pointer argument or the wait channel), and the caller of
   the blake2s+chacha activity is unpinned — leading hypothesis only,
   NOT asserted: random-subsystem pool hashing (random.c uses blake2s
   for the input pool and chacha for CRNG output; _get_random_bytes
   and crng_make_state appear in small numbers) interleaved with
   device/sysfs registration. A "probably the 8250 probe" verdict
   would have been wrong on every count above.
   NEXT STEP (not started): either (a) a longer run to reach
   serial8250 [342], virtio-blk [357] and root-mount — roughly 22M
   more cycles by the observed ~63k cycles/initcall average, i.e.
   ~90 min wall at the current shared-VM pace (extrapolation, not a
   promise) — or (b) a fine per-cycle trace (as for attempt 8) or a
   register-aware probe at the freeze to name the waiting thread and
   its wait channel. There is no stuck initcall to fix: the kernel
   is not stuck, it is slow.

### Attempt 16 — long boot to root-mount: furthest boot ever, killed by a VM restart (28 Oct 2026)

   (authorised 28 Oct 2026 12:04 IST; diagnosis + long boot only,
   no fix attempted, nothing pushed)

   Launch = attempt-13 config, 10 MHz rootfs DTB (.txt file,
   NEVER the binary .dtb), +NOCLEAR, +MAXCYCLES=100000000,
   +RX2FILE=rootfs/rx_cmds.txt, +RX2START=75000000,
   +RX2PERIOD=2000, log kernel/boot_attempt16.log. RX timing
   rationale, recorded because the SOC2 16550 RX FIFO is only
   16 bytes and bytes delivered while it is full are DROPPED:
   the prompt was estimated at ~55-65M cycles (pc-trace pace),
   so delivery at 75M cycles lands after the prompt, when the
   shell is blocked in read(); delivery before the prompt would
   keep only the first 16 bytes ("echo hello from " with no
   newline) and lose the rest. If a future run's prompt lands
   AFTER 75M cycles, that FIFO loss is the expected failure
   mode for the RX test, not a kernel bug.

   First launch reached 5M cycles (KDBG block complete, 85,532
   lines) and was killed by a VM restart (uptime 0 min after);
   its partial log is kernel/boot_attempt16_partial.log.
   Icarus had vanished again with the restart; reinstalled
   from the cached deb (dpkg lock was free — the os-intent
   apt replay had finished) and relaunched on the surviving
   sim/tb_kboot_dbg.vvp (compiled 27 Oct 17:50, after all
   sources; no recompile needed).

   Second launch, log kernel/boot_attempt16.log (85,597 lines
   + UART lines; killed by a second VM restart, no CYCLES/
   HALTED footer — the log is the evidence of record):
   probe passes again at 0.549720 (identical to attempt 13);
   past attempt 12 (iommu 1.140s); past the old "freeze"
   (vgaarb 1.317317, clocksource switch 1.332707, identical
   to attempts 13/15); then NEW territory — NET PF_INET
   2.218846, IP idents 2.237757, RPC/NFS/PCI/kvm 2.39-2.40s,
   Key/NFS/9p 2.52-2.54s — and killed at kernel time
   2.541246 ("9p: Installing v9fs 9p2000 file system
   support", i.e. init_v9fs [274] of 555). NO "console
   [ttyS0] enabled", NO virtio-blk probe, NO "Freeing
   unused kernel image", NO "Run /init", NO VFS line, NO
   prompt, NO command output. RX at 75M cycles never fired
   (death at ~57M cycles by the pc-trace mapping of
   ~22.5M cycles per kernel-second), so the RX path is
   still untested in both directions.

   Initcall table re-extracted independently for this
   session from vmlinux (ELF section mapping, nearest-
   symbol resolution) — confirms the pc-trace numbering:
   [342] serial8250_init, [357] virtio_blk_init; the
   stretch after [274] init_v9fs holds [287] jent_mod_init
   (jitterentropy), [290] calibrate_xor_blocks (XOR
   benchmarking at sim speed — the raid6 benchmarks
   earlier each took many wall-minutes), [298]
   blake2s_mod_init, clk/gpio/pcie drivers, [332]
   virtio_mmio_init, then [342]/[357]. The ~20 wall-
   minutes of UART silence after 2.541s is consistent
   with those heavy benchmark/entropy initcalls, NOT
   evidence of a new stall — but it is not proven
   progress either, since the run died before printing
   again. The verdict stands: sim speed + VM-restart
   fragility, not a stuck initcall, is the blocker;
   rootfs/init remain untested. A run that must survive
   ~3 hours of wall time needs either a restart-proof
   harness (checkpoint/resume, or a faster simulator)
   or several shorter hops — a single 100M-cycle Icarus
   run in this environment is a lottery ticket, and
   attempt 16 lost it twice.

## Restart-proof harness — checkpoint/resume (28 Oct 2026)

   Built after attempt 16, NOT a relaunch of it. The
   approach chosen is (a) testbench-level checkpoint/
   restore in Icarus. Option (b), a faster simulator,
   was rejected on evidence: no Verilator is installed,
   apt crawls in this VM, and porting the testbench to
   a C++ harness would be a rewrite of the whole launch
   path for an unproven gain. Option (c), a bare
   supervisor that relaunches, is NOT restart-proof on
   its own (a relaunch restarts from cycle zero) and is
   only used here combined with (a): tools/ckpt_run.sh
   `loop` mode re-runs from the newest complete
   checkpoint. The core and SOC sources are untouched;
   all checkpoint code lives in the new testbench.

   Files:
   - sim/tb_kboot_ckpt.v -- tb_kboot_dbg with a gated
     clock (run_clk; the clock holds at 0 during dump/
     restore, so no posedge is lost or invented), a
     checkpoint task and a resume task. Same launch
     plusargs as tb_kboot_dbg, plus +CKPTDIR, +CKPTAT,
     +CKPTEVERY, +RESUME, +CKPTONVSTATE (checkpoint on
     a virtio FSM state, V_COPY = 5), +CKPTONTX
     (checkpoint on the first UART TX pulse cycle).
   - sim/tb_kboot_ckpt.vvp (64 MiB, the kernel boot)
     and sim/tb_kboot_ckpt_1m.vvp (1 MiB, small soc2
     test programs). Both survive VM restarts (as the
     attempt-16 .vvp did); recompile takes ~3-4 min
     and is only needed when the sources change:
     ./tools/ckpt_run.sh compile [1m|64m].
   - tools/ckpt_run.sh -- compile / latest / start /
     resume / loop (see its header). It also reinstalls
     Icarus from the cached deb if a restart wiped it,
     waiting out the dpkg lock, never forcing it.

   What a checkpoint holds (per cycle N, under
   CKPTDIR): ckpt_<N>.hdr (tb cycles/rx2idx/rx2next
   + every scalar and small-array reg in dut.core and
   dut -- 148 core scalars, 10 core arrays, 78 SOC
   scalars, 6 SOC arrays, generated from the source
   reg lists, task-local temps excluded because they
   are recomputed every cycle), ckpt_<N>.ram (dut.memw
   via $writememh, 64 MiB -> ~165 MB hex, dump+reload
   measured ~37 s wall at full size), ckpt_<N>.disk
   (dut.disk), .vram, .pix, and ckpt_<N>.done -- the
   completion marker, written LAST. A checkpoint is
   only trusted if its .done exists.

   Checkpoint timing (the detail the whole proof rests
   on): a checkpoint is taken AFTER the negedge UART
   sample of its cycle, with the clock held at 0, so a
   TX pulse emitted that cycle is already printed and
   is not re-printed after resume (the restored
   tx_valid is cleared by the first resumed posedge
   before any negedge sample). Resume replays the
   normal loads (firmware/DTB/kernel/disk), runs a few
   reset cycles, holds the clock, overlays the
   checkpoint, then releases reset and the clock; the
   cycle counter resumes from the checkpoint cycle, so
   cycle numbering is continuous across the break.

   What is NOT restored (explicit gaps): the testbench
   clock phase (resume restarts clk at 0, which is
   cycle-exact because cycles are counted on posedges
   only); unconnected top-level pins (net/ptr inputs
   read as x in both runs, guarded by the SOC's
   x-checks); anything outside the simulated machine
   (the shell log file -- resume MUST append, >>,
   never overwrite, or the transcript is cut); and a
   checkpoint torn by a kill landing mid-dump (no
   .done -- the wrapper falls back to the previous
   complete checkpoint; same-cycle re-runs must clear
   the old set first so a stale .done can never
   validate a new partial dump). Icarus quirk found
   during the build: $fscanf straight into the [1:3]
   PLIC arrays fails ("vpiConstant not assignable");
   those two restores go through temp regs.

   Kill-and-resume verification, all in
   ckpt_verify/ (logs + headers kept; 64 MiB .ram
   images deleted after the proof to save space):
   1. Kernel boot, kill -9: uninterrupted 0 -> 2M
      cycles vs checkpoint at 1M, SIGKILL after the
      .done appeared, resume 1M -> 2M. UART transcript
      byte-for-byte IDENTICAL (718 bytes: banner +
      SBI lines), footer IDENTICAL (CYCLES 2000000,
      HALTED 0, REGS identical). A first attempt at
      50k/200k was vacuous (no UART yet in either run)
      and is not counted; the 1M/2M run is the proof.
      Control: the new testbench's footer at 200k is
      identical to tb_kboot_dbg's, so the harness did
      not change the machine.
   2. Virtio mid-transfer: soc2 virtio test, checkpoint
      triggered on V_COPY (cycle 122), resume -> halt
      at exactly 2115 cycles with REGS identical to the
      uninterrupted run. (That run had already finished
      before the kill landed, so leg 2 proves resume
      from a mid-copy checkpoint; the SIGKILL itself is
      proven by leg 1.)
   3. UART TX boundary: soc2 uart16550 test, checkpoint
      triggered on the first TX pulse (cycle 15).
      Part 1 already contains "U"; the resumed run
      prints NO further UART byte (no duplicate) and
      its footer is identical to the uninterrupted run
      (CYCLES 1220, HALTED 1).
   4. Torn checkpoint: the first kill test caught a
      0-byte .ram (kill during the dump). That failure
      is what the .done marker exists to catch; after
      the fix, only .done-complete sets are resumed.
   5. Wrapper loop mode: tools/ckpt_run.sh loop with
      200k segments ran fresh 0 -> 200k (checkpoint),
      then resume 200k -> 400k (checkpoint), one
      appended log, budget-exhausted exit 2 as
      designed (re-runnable).
   Virtio restore past the kernel's virtio-blk start
   (initcall [357], ~50M+ cycles) is implemented (all
   v_* regs + disk + RAM are dumped) but, like the
   kernel's own root-mount, is NOT yet exercised at
   kernel scale -- the bounded virtio leg above is the
   evidence for the mechanism. Timer/PLIC/UART/TLB/
   PTW/divider state restore IS exercised by legs 1-3.

   Attempt 17 under the new harness (NOW RUN — see the
   Attempt 17 section below; the command below is the
   one that was used):
     cd ~/workspace/big32
     ./tools/ckpt_run.sh loop kernel/boot_attempt17.log \
         ckpt_attempt17 10000000 20 \
         +RX2FILE=rootfs/rx_cmds.txt +RX2START=75000000 \
         +RX2PERIOD=2000
   That is: 10M-cycle segments (each ends in a
   checkpoint), up to 20 segments = 100M cycles, one
   appended log. After any VM restart, re-running the
   identical command resumes from the newest complete
   checkpoint; nothing before it is recomputed. A
   single segment costs roughly 15-25 min of wall time
   at the observed pace plus ~1 min of checkpoint I/O;
   if a segment's checkpoint cycle lands after the
   prompt, the RX bytes still land at 75M cycles as
   in attempt 16 (rx2idx/rx2next are in the header).
   NOTE: attempt 17's RX timing still carries the
   attempt-16 caveat -- if the prompt lands after 75M
   cycles, the 16-byte 16550 RX FIFO drops the rest;
   that would be an RX-test failure mode, not a
   kernel bug. Success is still strict: init banner +
   "big32# " prompt + at least one command's output
   in the appended log.

### Attempt 17 — long boot UNDER THE HARNESS to the 100M-cycle budget: NO prompt, NO blocker (28 Oct 2026)

   Launch (his "launch attempt 17 now", after the
   harness recommendation):
   ./tools/ckpt_run.sh loop kernel/boot_attempt17.log
   ckpt_attempt17 10000000 20 +RX2FILE=rootfs/rx_cmds.txt
   +RX2START=75000000 +RX2PERIOD=2000
   10M-cycle segments, one appended log, same 10 MHz
   rootfs DTB / attempt-12 firmware / virtio-blk
   rootfs as attempt 16. Log:
   kernel/boot_attempt17.log (209 lines; the UART
   content is 123 kernel-timestamp lines — the rest
   is segment footers, resume markers, and two
   harness-artifact lines: one "stdbuf: failed to run
   command 'vvp'" from a resume attempted before
   Icarus was reinstalled, and the repeated
   readmemh warnings).

   What the log shows, in order:
   - Probe passes again, deterministic:
     [    0.549720] cpu0: Ratio of byte access time
     to unaligned word access is 3.65, unaligned
     accesses are fast
   - Past attempt 12 (iommu 1.13 s) and the old
     "freeze" point, byte-identical to attempts
     13/15/16:
     [    1.317317] vgaarb: loaded
     [    1.332707] clocksource: Switched to
     clocksource riscv_clocksource
   - Then NET, RPC/NFS, PCI, kvm, keys, 9p — matching
     attempt 16's furthest line exactly:
     [    2.541246] 9p: Installing v9fs 9p2000 file
     system support
     (printed before the 40M checkpoint; attempt
     16's "~57M cycles" death estimate was rough —
     the kernel-time/cycle mapping is not linear
     across the heavy initcalls.)
   - After that line: NOTHING. Zero new UART lines
     from 40M through the 100M budget — six
     consecutive silent segments (40M-50M, 50M-60M,
     60M-70M, 70M-80M, 80M-90M, 90M-100M), each
     verified segment-by-segment in the log.
   - Explicitly absent at 100M cycles: no "console
     [ttyS0] enabled" (serial8250 [342] has NOT run),
     no virtio-blk probe ([357] not run), no
     "Freeing unused kernel image", no "Run /init",
     no VFS line, no init banner, no "big32# "
     prompt, no command output, and also NO Oops,
     NO panic, NO new failure line of any kind.
   - Final footer: CKPT: cycle 100000000 written to
     ckpt_attempt17, CYCLES: 100000000, HALTED: 0.
     The 100M checkpoint (.done) exists, so any
     follow-up starts at 100M, not at zero.

   RX: all 50 bytes of rootfs/rx_cmds.txt were fed
   starting at 75M cycles (80M checkpoint header:
   rx2idx=50) while no serial driver had probed —
   so the typed commands are effectively lost to
   the 16-byte 16550 RX FIFO (the documented
   attempt-16 caveat, now realized). No command
   echo appears anywhere in the log. This is an
   RX-test failure mode, NOT a kernel finding —
   but it is moot here because no prompt ever
   appeared to read them.

   Harness in production: THREE VM restarts hit
   this run (one during 10M-20M, one during
   40M-50M, one during 90M-100M). Each time the
   loop died with the VM, Icarus was reinstalled
   from the cached deb (dpkg lock waited out, never
   forced — once the os-intent apt replay chained
   several apt-get processes, 29 tries), and the
   run resumed from the newest complete checkpoint
   (10M, then 40M, then 90M). At most one segment
   of progress was ever lost. The checkpoint/resume
   design is PROVEN under real restarts, not just
   the kill-and-resume test.
   GOTCHA found and avoided: `loop`'s maxiter
   counter resets on every relaunch, so a blind
   loop relaunch after a restart would run 20 MORE
   segments past the intended budget (up to 240M
   total here). The final segment (90M-100M) was
   therefore run with `resume` mode and an explicit
   +MAXCYCLES=100000000 +CKPTAT=100000000, and
   the run STOPPED at the budget. Future
   continuation commands must carry an explicit
   cycle cap for the same reason.

   Verdict: budget exhausted WITHOUT a prompt and
   WITHOUT a blocker line. This is NOT the
   "partial progress" case (no new UART lines in
   the last 60M cycles) and NOT a proven stall
   either (every segment completed at its
   MAXCYCLES, and the checkpoint REGS footers
   differ substantially across boundaries, so the
   machine state moves — but differing registers
   do not prove initcall progress). The 60M-cycle
   silence after 2.54 s now EXCEEDS what the
   pc-trace analysis explained: the heavy
   initcalls after [274] (jent_mod_init [287],
   calibrate_xor_blocks [290], blake2s_mod_init
   [298], clk/gpio/pcie before virtio_mmio [332])
   were expected to be slow, but not 60M cycles
   slow without reaching serial8250 [342]. The
   leading UNPROVEN hypotheses (not findings):
   jitterentropy gathering on a deterministic
   simulator (constant timer deltas), or another
   long compute-bound initcall. What is needed
   next is a DIAGNOSTIC, not just more cycles:
   a pc-trace/sample run resumed from the 100M
   checkpoint to name the current PC distribution
   (which initcall, whether timer interrupts still
   fire, whether it spins or computes). Do NOT
   simply relaunch a longer blind loop — the
   100M budget already showed that more cycles
   without visibility buys nothing.

### pc-trace from the 100M checkpoint — DONE 29 Oct 2026: the kernel is COMPUTING inside jent, not stuck
   (authorised 29 Oct 2026 00:28 IST; diagnosis only, no fix attempted,
   nothing pushed)

   Harness: sim/tb_kboot_ckpt_trace.v (tb_kboot_ckpt plus PC sampling
   every 100 cycles, 500,000-cycle snapshots of pc/priv/mtime/mtimecmp/
   irq_timer/CSRs, timer/ext/soft/trap counters; core/SOC untouched;
   compiled sim/tb_kboot_ckpt_trace.vvp at 64 MiB). Analysis:
   kernel/analyze_trace_100m.py (System.map resolver + the 555-entry
   initcall table re-extracted from vmlinux .init.data into
   kernel/initcall_table.json — numbering confirmed identical to the
   attempt-16 extraction: [274] init_v9fs, [287] jent_mod_init,
   [290] calibrate_xor_blocks, [298] blake2s_mod_init,
   [332] virtio_mmio_init, [342] serial8250_init, [357] virtio_blk_init).
   Launch: resumed from ckpt_attempt17/ckpt_100000000 (.done verified
   first), explicit +MAXCYCLES=110000000, +CKPTAT=110000000, one
   appended run log. Two environment incidents, both handled:
   (1) a VM restart killed run 1 at 106,417,100 cycles (6.42M into the
   window; partial trace preserved as kernel/pc_trace_100m_partial1.txt,
   64,170 samples, same keccak profile — and the snap/counter evidence
   was lost to buffering, which is why the testbench now $fflush-es
   every 1000 samples and every snapshot); (2) the restart wiped
   Icarus while the package lock was held, so Icarus was run from a
   dpkg-deb extraction of the cached deb symlinked into place (no
   lock forced, no lock file touched) and the testbench recompiled.
   Run 2 (the full window) resumed deterministically: its first samples
   are byte-identical to run 1's.
   Run 2 evidence (log kernel/pc_trace_100m_run2.log, trace
   kernel/pc_trace_100m.txt, snaps kernel/pc_trace_100m_snap.txt,
   analysis kernel/pc_trace_100m_analysis.txt): 100,000 samples,
   cycles 100,000,100..110,000,000, priv S-mode 99,989 / M-mode 11,
   HALTED 0, footer CYCLES 110000000. ZERO new UART lines in the run
   log (jent prints nothing on success; a health failure would print
   only at the end). The 110M checkpoint (.done) exists, so any
   follow-up starts at 110M.
   VERDICT — (ii) COMPUTING, not stuck, not livelocked:
   (a) PC distribution: keccakf_round 79,186 (79.19%),
   crypto_sha3_final 2,981 (2.98%), crypto_sha3_update 414 (0.41%) —
   SHA3 total ~82.6%; the rest is timer/tick handling
   (timekeeping_advance exactly ~200 per 1M-cycle bucket), memset/
   memcpy, spinlocks. Distinct PCs 1,989 — a broad working set, NOT
   a single-PC spin (the top raw PCs have exactly 250 samples each:
   one per timer tick, the per-tick handler entries).
   (b) The profile is IDENTICAL in all 10 buckets (keccak
   7,906–7,939 per 10,000 samples; timekeeping_advance 200–201) and
   in first vs second half (keccak 39,587 vs 39,599) — a steady
   repeating compute loop, not a wait.
   (c) Timer healthy at exactly the expected rate: CNT_INT_TIM 250
   over 10M cycles = 1 tick per 40,000 cycles (10 MHz / HZ 250);
   CNT_INT_EXT 0, CNT_INT_SOF 0; mtime tracks cycles 1:1 (snap delta
   9,500,000 over 9,500,000 cycles); mtimecmp AHEAD of mtime at every
   snap (+11,671 to +31,671 — the attempt-8 livelock signature,
   mtimecmp behind, is absent); scause 80000005 (S-timer) at every
   snap; the 11 M-mode samples are firmware SBI timer calls
   (0x800001ec x10, 0x8000007c x1, ~1.04M cycles apart).
   (d) Zero-checks: ZERO samples in serial8250/uart/tty, virtio,
   idle, kernel_init/rest_init/run_init_process, do_one_initcall,
   schedule — the kernel has NOT reached [342]/[357], is NOT idling,
   is NOT sleeping in the scheduler.
   (e) Caller pinned: 382 jent-named samples, including
   jent_entropy_init 66, jent_hash_time 170, jent_condition_data 29,
   jent_delta 31, jent_stuck 26, and the APT/RCT health checks
   (apt/rct_insert, health_failure, apt/rct_failure) — the complete
   body of jent_entropy_init's loop. In-tree source confirms the
   mechanism: jent_mod_init [287] calls jent_entropy_init, a BOUNDED
   loop of TESTLOOPCOUNT(1024)+CLEARCACHE(100) = 1,124 iterations,
   each doing jent_condition_data → jent_hash_time with
   SHA3_HASH_LOOP = 8 SHA3-256 permutations — ~9,000 permutations
   total. The only other jent_entropy_init caller is
   jent_read_entropy's health-failure recovery path, which requires
   an already-registered RNG instance plus an explicit consumer and
   would show jent_gen_entropy/jent_measure_jitter prominently —
   both are ABSENT (one lone jent_memaccess sample is a
   nearest-symbol artifact, not a pattern). Elimination agrees:
   sha3_generic registration/self-tests were initcalls [82]/[119],
   long past; no other initcall in [275]–[342] uses SHA3
   (calibrate_xor is XOR, blake2s is blake2s — both ZERO samples).
   (f) State moves: REGS footers differ substantially between the
   100M and 110M checkpoints (stable pointer registers identical,
   working registers changed), and mtime advanced 10M.
   What this means: the 40M–110M UART silence is (at least in its
   later part) one initcall — jent_mod_init [287] — burning tens of
   millions of cycles on SHA3 at sim speed. It is FINITE (1,124
   iterations; a health failure would end it early with -EFAULT,
   non-fatal without fips=1), so there is nothing to fix in the
   kernel or the platform. Honest limit: PC samples alone cannot
   say how many of the 1,124 iterations remain — the window proves
   the loop is still running at 110M, not its progress fraction —
   so no tight "N more cycles" estimate is claimed. A
   blacklist shortcut was considered and REJECTED:
   initcall_blacklist=jent_mod_init would need a from-zero boot
   (a resumed checkpoint is already inside the call, past the
   blacklist check) and would test a different configuration, so
   it saves nothing over continuing.
   NEXT STEP (not started): continue from the 110M checkpoint under
   the harness (e.g. 110M→160M, restart-safe, explicit cycle cap)
   and let jent finish; serial8250 [342] / virtio-blk [357] /
   root-mount can only be judged after it. No code change, no
   rebuild, no new boot from zero.

## What remains before Linux boots

In rough order (to check, not assumed):

1. A kernel Image that actually builds for this machine
   (see above) and passes the no-C / ELF32 checks.
2. A boot attempt that produces kernel output, or an
   exact failure point (last UART output, trap cause,
   pc) — Icarus speed itself is a likely blocker: a
   full boot needs hundreds of millions of cycles, and
   at ~0.15 ms/cycle that is tens of hours in one
   session. A bounded attempt (fixed cycle budget) is
   the honest deliverable for this phase.
3. Platform gaps the kernel may expose, in the order
   they would bite: FPU (absent — CONFIG_FPU must stay
   off; any FP-using driver or userspace breaks),
   PMP (absent), a real TLB model with ASIDs (current
   TLB is global; the kernel uses ASIDs for
   performance but correctness does not require them),
   misaligned emulation (DONE by Attempt 12: the core
   handles within-page unaligned accesses in hardware
   (Phase 6); cross-page loads/stores are emulated in
   M-mode firmware; only AMO/LR/SC misalignment still
   traps, redirected to S-mode by the firmware — the
   kernel probe passes, see Attempt 12 section above),
   PLIC priority programming (if the kernel leaves
   priorities at 0, no PLIC interrupt is ever claimed),
   the HSM extension (absent — fine for 1 CPU, blocks
   any SMP attempt), SBI STA / debug console extensions
   (absent — the kernel probes and degrades gracefully).
4. A root filesystem (initramfs or virtio-blk root)
   with an init — BUILT as virtio-blk ext4 + hand-
   assembled init (Attempts 13/14 above), but never
   yet executed: the kernel does NOT freeze inside
   do_initcalls (pc-trace 28 Oct 2026 above proves it
   progresses sequentially through initcalls, ~[210]/555
   by 30M cycles, with healthy timers and no spin) —
   it is slow, and root-mount waits behind serial8250
   [342], virtio-blk [357] and ~280 further initcalls
   (attempt 16 reached [274] before a VM restart killed
   it; attempt 17 ran to the full 100M-cycle budget
   with 60M cycles of UART silence after 2.54 s and
   serial8250 STILL not run — see Attempt 17 above).
   The silence is now DIAGNOSED, not mysterious: the
   pc-trace from the 100M checkpoint (section above)
   proves the kernel is COMPUTING inside jent_mod_init
   [287] (SHA3 entropy-init loop, finite, healthy
   timers) through 110M cycles. The continuation
   110M→160M (section below, authorised 29 Oct 2026)
   then ran to the full 160M cap with ZERO new UART
   lines — the silence now spans 40M→160M cycles
   (120M cycles) with serial8250 [342] still not run,
   no prompt, no blocker, and no panic. A fresh pc-trace
   from the 160M checkpoint (section below, DONE 29 Oct
   2026) then settled it: STILL JENT — keccakf_round
   79.18% at 160M→170M, statistically identical to the
   100M trace, so jent [287] is still grinding, not
   finished. VM-restart
   fragility IS addressed by the checkpoint/resume
   harness above (proven under three real restarts in
   attempt 17, plus one more during this continuation);
   the rootfs/init remain untested.
5. Faster simulation (or an FPGA target) before any
   full-boot claim is practical: Icarus at this speed
   cannot boot Linux end-to-end in a session.
6. The bootloader loading a multi-megabyte kernel
   Image from virtio (currently it loads 2 sectors =
   1024 bytes; a real kernel needs thousands of
   sectors and a sector-count loop) — the test-harness
   +KIMG shortcut above is NOT the production path.
7. RAM/DTB sizing discipline: the DTB memory size must
   match the RAM actually given to the simulation, or
   the kernel will size memory wrong.
8. RISCOF/formal verification, a technology-mapped
   gate count, and any silicon claim — all still open,
   none claimed here.

### Continuation 110M→160M — DONE 29 Oct 2026: cap reached, NO prompt, NO blocker, still silent
   (authorised 29 Oct 2026 07:56 IST; continuation only, no fix,
   no new boot from zero, nothing pushed)

   Method: resumed from the banked 110M checkpoint under the
   harness, explicit 160M cap, 10M-cycle segments, one appended
   log (kernel/boot_attempt17.log — the continuation lives in
   the attempt-17 log, not a second log). Segment runner:
   tools/run_cont160.sh (loop driver; each segment one explicit-
   cap resume, never loop mode — loop's maxiter resets on
   relaunch and would overshoot the cap). Segments ran
   110→120→130→140→150M, each ~27 min wall, each checkpointed
   with .done (ckpt_cont160/ckpt_<N>.*).
   Environment incidents, both handled by the harness design:
   (1) a VM restart during the initial compile of a planned
   RX-rearm testbench variant (sim/tb_kboot_ckpt_rx.v, kept
   on disk, unused) — the variant was abandoned in favour of
   a no-recompile re-arm (below); (2) a VM restart killed the
   final 150→160M segment before its checkpoint — it was
   re-run from the surviving 150M checkpoint with the same
   explicit cap. Icarus was reinstalled from the cached deb
   after each restart (dpkg lock waited out, never forced).
   RX re-arm (worked as designed): the attempt-17 feed was
   already consumed (110M header rx2idx=50), and the proven
   testbench restores rx2idx/rx2next from the checkpoint
   header, so plain plusargs cannot re-feed. Instead a COPY
   of the 110M checkpoint set was made in ckpt_cont160/ with
   only header lines 2-3 changed (rx2idx 50→0, rx2next
   75100000→150000000); the original in ckpt_attempt17/ is
   untouched, and the copy differs from it in exactly those
   two lines. Feeding then ran 150M→150.1M (150M header shows
   rx2idx=1, rx2next=150002000 — byte 1 fed at exactly 150M
   before checkpointing; 160M header shows rx2idx=50,
   rx2next=150100000 — all 50 bytes fed). Caveat, recorded
   honestly: the first 16 bytes of the attempt-17 feed may
   still sit in the restored 16550 RX FIFO (push drops only
   past 16, it does not clear), so a future shell would read
   those stale bytes first, ahead of the re-armed file.
   Evidence (log kernel/boot_attempt17.log, progress
   kernel/cont160_progress.log): segment footers CYCLES
   120/130/140/150/160M, each HALTED 0; final footer CYCLES
   160000000, HALTED 0; 160M checkpoint (.done) exists, so
   any follow-up starts at 160M. Total kernel-timestamp UART
   lines in the whole log: still 123 — ZERO new UART lines
   across 110M→160M, so the silence now spans 40M→160M
   (120M cycles). Explicitly absent at 160M: no
   "console [ttyS0] enabled" ([342] not run), no virtio-blk
   probe ([357] not run), no "Freeing unused kernel image",
   no "Run /init", no VFS line, no init banner, no "big32# "
   prompt (grep count 0), no command output, and also no
   Oops, no panic, no new failure line of any kind. The
   last two REGS footers differ substantially, so machine
   state moves — this is not a frozen-state artifact.
   VERDICT — partial result, not success, not failure: the
   160M cap was reached with jent's silence unbroken. The
   100M-trace verdict (COMPUTING inside jent [287]) is NOT
   re-proven at 160M — jent may still be grinding, or may
   have finished silently into another quiet stretch.
   Exact next step (not started): a pc-trace/sample run
   resumed from the banked 160M checkpoint to name the
   current PC distribution — the only evidence that can
   distinguish "jent still running" from "jent done, next
   quiet initcall". Do NOT simply extend the blind loop
   again: 120M cycles of silence already show that more
   cycles without visibility buy nothing.

### pc-trace from the 160M checkpoint — DONE 29 Oct 2026: STILL JENT, not past it
   (authorised 29 Oct 2026 12:19 IST; diagnosis only, no fix attempted,
   nothing pushed)

   Question: is jent_mod_init [287] still grinding at 160M, or did it
   finish silently into a different quiet stretch? Answer: STILL JENT.
   Harness: sim/tb_kboot_ckpt_trace.v (same testbench as the 100M
   trace; core/SOC untouched), resumed from ckpt_cont160/ckpt_160000000
   (.done verified first), explicit +MAXCYCLES=170000000,
   +CKPTAT=170000000, one appended run log. Analysis reuses
   kernel/analyze_trace_100m.py with the 160M trace/snap files and
   the same kernel/initcall_table.json (555 entries).
   Environment incident, handled: a VM restart killed run 1 at
   167,319,500 cycles (73,195 samples, preserved as
   kernel/pc_trace_160m_partial1.txt — keccak 79.20%, matching run 2)
   and wiped Icarus; Icarus was reinstalled from the cached deb
   (dpkg lock waited out, never forced), the compiled trace .vvp
   survived, and run 2 resumed deterministically (first 1,000 samples
   byte-identical to run 1's).
   Run 2 evidence (log kernel/pc_trace_160m_run2.log, trace
   kernel/pc_trace_160m.txt, snaps kernel/pc_trace_160m_snap.txt,
   analysis kernel/pc_trace_160m_analysis.txt): 100,000 samples,
   cycles 160,000,100..170,000,000, priv S-mode 99,989 / M-mode 11,
   HALTED 0, footer CYCLES 170000000. ZERO new UART lines in the run
   log (jent prints nothing on success). The 170M checkpoint (.done)
   exists in ckpt_cont160/, so any follow-up starts at 170M.
   VERDICT — (i) STILL JENT, the 100M verdict holds at 160M–170M:
   (a) PC distribution, statistically identical to the 100M trace:
   keccakf_round 79,176 (79.18%, vs 79,186 / 79.19% at 100M),
   crypto_sha3_final 2,973 (2.97%), crypto_sha3_update 416 (0.42%)
   — SHA3 total ~82.6%; the rest is timer/tick handling
   (timekeeping_advance exactly ~200 per 1M-cycle bucket), memset/
   memcpy, spinlocks. Distinct PCs 2,066 — a broad working set, NOT
   a single-PC spin (top raw PCs have exactly ~250 samples each: one
   per timer tick, the per-tick handler entries).
   (b) The profile is IDENTICAL in all 10 buckets (keccak
   7,905–7,926 per 10,000 samples; timekeeping_advance 200–201) and
   in first vs second half (keccak 39,583 vs 39,593) — a steady
   repeating compute loop, not a wait.
   (c) Timer healthy at exactly the expected rate: CNT_INT_TIM 250
   over 10M cycles = 1 tick per 40,000 cycles (10 MHz / HZ 250);
   CNT_INT_EXT 0, CNT_INT_SOF 0; mtime tracks cycles 1:1 (snap delta
   9,500,000 over 9,500,000 cycles); mtimecmp AHEAD of mtime at every
   snap (+11,671 to +31,671 — the attempt-8 livelock signature,
   mtimecmp behind, is absent); scause 80000005 (S-timer) at every
   snap; the 11 M-mode samples are firmware SBI timer calls.
   (d) Zero-checks: ZERO samples in serial8250/uart/tty, virtio,
   idle, kernel_init/rest_init/run_init_process, do_one_initcall,
   schedule — the kernel has NOT reached [342]/[357], is NOT idling,
   is NOT sleeping in the scheduler. blake2s/chacha and
   calibrate_xor also ZERO, so no other heavy initcall has taken
   over.
   (e) Caller pinned, same body as at 100M: 374 jent-named samples,
   including jent_entropy_init 72, jent_hash_time 165,
   jent_condition_data 24, jent_delta 22, jent_stuck 36, and the
   APT/RCT health checks (apt/rct_insert, apt/rct_failure,
   health_failure) — the complete body of jent_entropy_init's loop.
   (f) State moves: REGS footers differ substantially between the
   160M and 170M checkpoints, and mtime advanced 10M.
   What this means: the 40M→170M UART silence is (at least in its
   later part, and now re-proven at 160M–170M) one initcall —
   jent_mod_init [287] — burning tens of millions of cycles on SHA3
   at sim speed. It is FINITE (1,124 iterations), so there is
   nothing to fix in the kernel or the platform. Honest limit, same
   as at 100M: PC samples prove the loop is still running at 170M,
   not what fraction of its 1,124 iterations remain — the share
   being unchanged across 60M cycles of trace windows says the loop
   is steady, not how near done it is — so no tight "N more cycles"
   estimate is claimed, and no progress fraction is asserted.
   NEXT STEP (not started): continue from the 170M checkpoint under
   the harness (e.g. 170M→220M, restart-safe, explicit cycle cap)
   and let jent finish; serial8250 [342] / virtio-blk [357] /
   root-mount can only be judged after it. No code change, no
   rebuild, no new boot from zero.

### Attempt 18 — skip-jent boot: fresh boot with jent_mod_init blacklisted, 100M cap reached, NO prompt, NO blocker (29 Oct 2026)
   (authorised 29 Oct 2026 13:35 IST — the user's choice after the
   160M trace: "try the boot that skips the loop", instead of
   grinding 170M→220M. Diagnosis/proof run only: no kernel fix, no
   rootfs redesign, nothing pushed.)

   CAVEAT, stated plainly: this boot tests a DIFFERENT configuration
   from attempts 16/17 and the continuation. A resumed checkpoint is
   already inside jent_mod_init, past the blacklist check, so
   blacklisting only works from cycle zero — hence this fresh boot.
   What it proves, if it reaches them, is the post-loop boot path
   (serial driver, block driver, root-mount, prompt). It does NOT
   prove the full-config boot, and the full-config grind from the
   banked 170M checkpoint in ckpt_cont160/ remains open and
   untouched by this run.

   The ONE change: bootargs gain initcall_blacklist=jent_mod_init
   alongside the existing "earlycon console=ttyS0 root=/dev/vda
   rootfstype=ext4 rootwait ro init=/init". New DTB built with the
   existing path (python3 tools/build_kboot_dtb.py 10000000
   big32_kboot_10mhz_rootfs_skipjent "<bootargs>"):
   soc2_hex/big32_kboot_10mhz_rootfs_skipjent.dtb (1522 bytes,
   plus .dtb.txt hex-byte file, 4566 bytes); decompiled check
   confirmed the bootargs string and timebase-frequency 0x989680
   = 10,000,000. Everything else identical to the attempt-17 recipe:
   64 MiB RAM, 10 MHz, attempt-12 SBI firmware (medeleg 0xB9AF),
   rootfs on virtio-blk (rootfs/rootfs.img,
   soc2_hex/rootfs_disk.hex), Linux 6.6.52 rv32 Image.
   Runner: tools/run_skipjent.sh (custom, because tools/ckpt_run.sh
   hardcodes +DTBFILE=soc2_hex/big32_kboot_10mhz_rootfs.dtb.txt
   and Icarus $value$plusargs takes the FIRST match, so appending a
   second +DTBFILE would not override it). Checkpoints in
   ckpt_skipjent/, progress in kernel/skipjent_progress.log,
   log in kernel/boot_attempt18_skipjent.log (NEW file; the
   full-config story stays in kernel/boot_attempt17.log).
   RX: rootfs/rx_cmds.txt (echo hello from big32, ls, uname,
   cat /hello.txt, pwd), fed from cycle 50,000,000, one byte per
   2000 cycles (all 50 bytes by 50.1M).

   Blacklist evidence (note the correction to the naive expectation:
   in kernel/linux-6.6.52/init/main.c, initcall_blacklist prints
   only pr_debug, invisible at the default loglevel, and
   do_one_initcall returns -EPERM silently for blacklisted calls —
   so there is NO "blacklisted initcall" log line to look for).
   Confirmation is the kernel's own command-line print plus
   behaviour:
   [    0.000000] Kernel command line: earlycon console=ttyS0 root=/dev/vda rootfstype=ext4 rootwait ro init=/init initcall_blacklist=jent_mod_init
   and the boot passing, in 40M cycles, the point where the full
   boot spent 100M+ cycles inside jent (furthest full-boot line
   9p at 2.541246 s; this boot passes 2.54 s during segment 4 and
   reaches 9p at 2.636085 s). The blacklist took effect.

   Run history (all times UTC; IST = UTC + 5:30): fresh start
   08:07:21Z. Segment 1 (0→10M) done 08:33:42Z, segment 2 (10M→20M)
   done 09:05:22Z. A VM restart (~09:20Z, uptime 0 min) killed
   segment 3 mid-flight (it had already printed to 1.100859 s) and
   wiped Icarus; Icarus was reinstalled from the cached deb
   (dpkg lock waited out, never forced) and the runner re-launched,
   resuming from the intact 20M checkpoint. Relaunch quirk, noted
   not hidden: the runner's loop burns its 3 retries on each
   already-passed target (each retry loads the checkpoint and exits
   immediately with no progress, appending only a footer) before
   reaching the real next segment — wasted wall time, no effect on
   the boot itself. Segment 3 (20M→30M) done 09:49:00Z, segment 4
   (30M→40M) done 10:12:10Z, segment 5 (40M→50M) done 10:33:30Z,
   segment 6 (50M→60M) done 10:54:47Z, segment 7 (60M→70M) done
   11:16:23Z, segment 8 (70M→80M) done 11:37:53Z. A second VM
   restart (~11:38Z) killed segment 9 at launch; same recovery
   (reinstall from cached deb, re-launch, retries on passed
   targets, resume from the intact 80M checkpoint). Segment 9
   (80M→90M) done 12:23:45Z, segment 10 (90M→100M) done
   12:46:04Z. Runner reports "skipjent complete: 100M cap
   reached". Final footer: CYCLES: 100000000, HALTED: 0.

   What the log shows, in order (118 kernel-timestamp lines, no
   panic, no Oops):
   - Blacklist: confirmed (command line above + behaviour above).
   - Serial driver: NOT reached. No "console [ttyS0] enabled" line
     (serial8250 [342] not yet run). Earlycon only:
     [    0.000000] earlycon: ns16550a0 at MMIO 0x10010000 (options '')
     [    0.000000] printk: bootconsole [ns16550a0] enabled
   - Virtio-blk / root-mount: NOT reached. No virtio probe lines,
     no VFS line, no "Freeing unused kernel memory", no
     "Run /init".
   - Init / prompt: NOT reached. No init banner, no "big32# ".
   - RX commands: NO output. The feed ran at 50M–50.1M, long before
     any prompt existed; the bytes were never consumed by a shell.
     If a prompt appears in a continuation, the header-copy re-arm
     trick from the 160M continuation applies (as in attempt 17's
     RX loss to the 16-byte FIFO, the feed timing, not the shell,
     is the open item).
   - Randomness wrinkle watched for: NONE. Zero lines matching
     random/crng/entropy/getrandom/urandom — skipping jent did not
     produce a visible randomness block or entropy warning in this
     window.
   - Furthest line:
     [    8.114278] io scheduler bfq registered
     (kernel time 8.114 s; the boot's own furthest point, well past
     the full boot's 2.541246 s).

   The new long pole, measured, not assumed: calibrate_xor_blocks
   [290]. After the quiet registration stretch, the log shows
   [    2.664282] xor: measuring software checksum speed
   then one result line per ~1.36 kernel seconds (~13.6M cycles
   each): 8regs 7 MB/sec at 4.023267 s, 8regs_prefetch 7 MB/sec at
   5.383065 s, 32regs 7 MB/sec at 6.740548 s, 32regs_prefetch
   7 MB/sec at 8.099402 s, then
   [    8.100764] xor: using function: 32regs_prefetch (7 MB/sec)
   followed by block-layer lines (bsg driver 8.107294 s,
   mq-deadline 8.109257 s, kyber 8.111302 s, bfq 8.114278 s).
   So jent was not the only benchmark-shaped initcall in the path:
   xor alone consumed roughly segments 5–10's worth of the budget
   (from ~2.66 s to ~8.10 s kernel time). The remaining initcalls
   before the serial driver — blake2s [298], clk/gpio/pcie,
   virtio_mmio [332], serial8250 [342], virtio_blk [357] — were
   still ahead when the cap hit. The kernel was NOT shown stuck:
   it printed steadily through xor and the block layer, and the
   cap, not a failure line, ended the run.

   VERDICT: cap reached, not success and not a blocker. The
   skip-jent configuration boots cleanly past jent's old stall
   point and through the XOR benchmark to kernel time 8.114 s,
   with no panic, no randomness block, and no new failure line —
   but serial8250, virtio-blk, root-mount, init, and the prompt
   are all still unproven. The 100M checkpoint (.done) exists in
   ckpt_skipjent/, so a continuation starts at 100M.
   NEXT STEP (not started, needs a call): either continue this
   skip-jent boot from the 100M checkpoint under the harness
   (e.g. 100M→150M, explicit cycle cap) toward serial8250 [342] /
   virtio-blk [357] / root-mount / prompt, with the RX re-arm
   follow-up once a prompt appears — or run a pc-trace from the
   100M checkpoint first to pin down exactly which initcall the
   kernel is in after bfq, as was done at 100M/160M for jent.
   Either way, the full-config grind from ckpt_cont160/'s 170M
   checkpoint stays open alongside, not replaced by, this run.

### Attempt 18 continuation — skip-jent 100M→150M: STOPPED on a genuine blocker, kernel panic in PID 1 (29 Oct 2026, run 29 Oct ~20:24–20:55 IST)

   Runner: tools/run_skipjent_cont150.sh (new file; same skip-jent
   DTB/firmware/rootfs as attempt 18). Log:
   kernel/boot_attempt18_skipjent_cont150.log (NEW file -- the
   attempt-18 record in boot_attempt18_skipjent.log is untouched).
   Progress: kernel/skipjent_cont150_progress.log.
   Explicit cap 150M in 10M segments; the run STOPPED after the
   first segment by its own panic rule, so 110M→150M never ran.

   RX re-arm (why it worked this time): the testbench restores
   rx2idx/rx2next from the checkpoint header on resume, and the
   100M header had rx2idx=50 (attempt 18's feed fully consumed),
   so plain plusargs could not re-feed. ckpt_skipjent_cont150/ is
   a COPY of the 100M checkpoint set with ONLY header lines 2-3
   changed (rx2idx 50->0, rx2next 50100000->140000000; the
   original in ckpt_skipjent/ is untouched, diff verified to show
   exactly those two lines). The feed was therefore armed for
   140M, 1 byte/2000 cycles -- but the run died at 110M, before
   the feed, so RX timing is still untested. Caveat carried from
   the 160M continuation: the first 16 bytes of the attempt-18
   feed may still sit in the restored 16550 RX FIFO (it drops
   past 16, it does not clear), so a future shell could read
   those stale bytes first.

   What the continuation log shows, in full (22 lines + footer --
   verified by grep, nothing else is in the file):
   - Serial driver -- NOT reached in print: no
     "console [ttyS0] enabled" (serial8250 [342] print absent).
   - Virtio-blk / root-mount -- NOT reached in print: no virtio
     probe lines, no VFS line, no "Freeing unused kernel memory",
     no "Run /init".
   - Init / prompt -- NOT reached: no init banner, no "big32# "
     prompt, no RX command output (feed armed for 140M, run died
     at 110M). No prompt or userspace is claimed.
   - Randomness -- no lines matching random/crng/entropy: skipping
     jent produced no visible randomness block in this window
     either.
   - The blocker, quoted verbatim (kernel time 9.129-9.162 s, in
     the 100M->110M segment):
     [    9.129927] Unable to handle kernel paging request at virtual address c01f24f4
     [    9.131792] Oops [#1]
     [    9.132817] CPU: 0 PID: 1 Comm: swapper Not tainted 6.6.52 #3
     [    9.136042] epc : c01f24f4 ra : c01f2890 sp : c2437c00
     [    9.153694] status: 00000020 badaddr: c01f24f4 cause: 0000000c
     [    9.160458] Kernel panic - not syncing: Attempted to kill init! exitcode=0x0000000b
     Final footer: CYCLES: 110000000, HALTED: 0. The 110M
     checkpoint (.done) is banked in ckpt_skipjent_cont150/ --
     but it holds the kernel spinning in the panic loop, so
     resuming from it only continues the panic, it does not
     retry the boot.

   What the fault IS, measured, not assumed (System.map from the
   same kernel tree): epc c01f24f4 = kmem_cache_alloc+0xe0, and
   ra c01f2890 = kmem_cache_alloc+0x47c. Cause 0xc is an
   instruction page fault: the CPU tried to FETCH from an
   address inside kmem_cache_alloc itself and faulted, i.e. the
   page was not executable-mapped at that moment. Exit code
   0xb is SIGSEGV delivered to PID 1, whose death is the panic
   ("Attempted to kill init"). No Call Trace lines were printed
   by the Oops (the block goes straight from Code to end
   trace), so the caller chain above kmem_cache_alloc is NOT
   in the log -- do not invent one.

   What PID 1 PROVES, and what it does NOT: PID 1 (kernel_init)
   exists only after rest_init, which runs after do_initcalls
   completes -- so in execution terms the kernel got PAST all
   initcalls, including serial8250 [342] and virtio_blk [357],
   further than any previous boot. But their expected prints
   are ABSENT from both the attempt-18 log and this log, as are
   the VFS/root-mount/"Run /init" prints that should follow.
   That absence is an open puzzle, NOT explained by the log:
   do not claim the drivers probed successfully, and do not
   claim root mounted -- only that execution reached kernel_init
   and faulted there, in the SLUB allocation path, before any
   init banner or prompt.

   HYPOTHESES ONLY (not findings -- each needs its own test):
   (a) a stale/wrong TLB entry or page-table corruption made a
   kernel-text page non-executable (fits cause 0xc with epc
   inside kernel text); our core's TLB/sfence.vma behaviour and
   the firmware emulation walk's missing A/D-bit updates are
   the prime suspects to audit, not the kernel. (b) A resume
   artifact: this panic landed in the FIRST segment resumed
   from a checkpoint -- if the checkpoint restore mishandles
   TLB state, the fault could be harness-caused, not
   kernel/core-caused. Discriminator (cheap, ~20 min): re-run
   100M->110M from the ORIGINAL 100M checkpoint in
   ckpt_skipjent/ and see whether the panic reproduces at the
   same kernel time. Identical reproduction => real behaviour;
   divergence => resume artifact. That re-run is the
   recommended next step, NOT started here.
   VERDICT: genuine blocker, not success and not a cap outcome.
   The skip-jent configuration reaches kernel_init and then
   dies in kmem_cache_alloc -- serial, block, root-mount, init,
   and prompt are all still unproven, and the 110M checkpoint
   is a panic-loop checkpoint, not a boot checkpoint. The
   full-config grind from ckpt_cont160/'s 170M checkpoint stays
   open alongside, not replaced by, this run.

### Attempt 18 discriminator — re-run 100M→110M from the ORIGINAL 100M checkpoint: PANIC REPRODUCES, resume artifact ruled out (30 Oct 2026, run 30 Oct ~08:01–08:24 IST)

   Question: was the cont150 PID 1 panic real, or an artifact of
   resuming from a checkpoint? Runner:
   tools/run_skipjent_repro110.sh (new file). Log:
   kernel/boot_attempt18_skipjent_repro110.log (NEW file --
   attempt-18 and cont150 logs untouched). Progress:
   kernel/skipjent_repro110_progress.log. Single explicit-cap
   segment, 100M->110M, same skip-jent DTB/firmware/kernel/rootfs
   as attempt 18. Resumed from ckpt_skipjent_repro110/, a
   BYTE-EXACT copy of the original 100M checkpoint set in
   ckpt_skipjent/ (header copy verified identical: rx2idx=50,
   rx2next=50100000 -- the attempt-18 feed is fully consumed,
   so this segment fed NO RX bytes, which is what a panic
   comparison wants). NOT the cont150 copy (its header differs:
   rx2idx 0, rx2next 140M) and NOT the cont150 110M checkpoint
   (panic loop). ckpt_skipjent/ itself is untouched (no 110M
   set in it after this run); the repro 110M checkpoint (.done)
   sits in ckpt_skipjent_repro110/ and, like cont150's, holds
   the panic loop -- do NOT resume from it.

   VERDICT: REPRODUCES. The repro run's UART lines are
   byte-identical to the cont150 panic (diff of the two logs'
   bracketed lines: empty). Same kernel times, same fault,
   same registers, same exit:
   [    9.129927] Unable to handle kernel paging request at virtual address c01f24f4
   [    9.131792] Oops [#1]
   [    9.132817] CPU: 0 PID: 1 Comm: swapper Not tainted 6.6.52 #3
   [    9.136042] epc : c01f24f4 ra : c01f2890 sp : c2437c00
   [    9.153694] status: 00000020 badaddr: c01f24f4 cause: 0000000c
   [    9.160458] Kernel panic - not syncing: Attempted to kill init! exitcode=0x0000000b
   Footer: CYCLES: 110000000, HALTED: 0. Zero lines matching
   prompt, "Run /init", "console [ttyS0] enabled", "Freeing
   unused", or VFS -- the serial/virtio/root-mount print
   absence reproduces too.

   What this rules out: the checkpoint-resume artifact
   hypothesis (b). Two independent resumes -- one from the
   RX-re-armed cont150 copy, one from a byte-exact copy of
   the original -- land on the identical fault at the
   identical kernel time with identical registers. A restore
   bug would have to be perfectly deterministic across
   different header contents to do that, and the simpler
   reading is that the fault is in the machine state itself.
   What it does NOT prove on its own: WHICH component is at
   fault (core TLB/sfence.vma vs firmware walk A/D updates
   vs something else) -- that is the fault investigation,
   NOT started here. Next step: investigate the fault, with
   the prime suspects as named in the continuation section.
   The skip-jent configuration reaches kernel_init and dies
   in kmem_cache_alloc; serial, block, root-mount, init, and
   prompt remain unproven. No prompt or userspace is claimed.
   Nothing pushed.

### Attempt 18 fault investigation — PID 1 panic root cause: a genuine U-mode fetch of kernel text; core and firmware EXONERATED, no fix warranted (30 Oct 2026)

   Job: step 2 of the day's push. Scope: find the root cause of
   the instruction page fault; implement a minimal fix ONLY if
   clear and directed-tested. No kernel boot launched, nothing
   pushed, rootfs untouched, MAC-wait sim untouched.

   THE FAULT, PINNED PRECISELY. Virtual page: c01f24f4 sits in
   the 4K page VA 0xC01F2000. Kernel text mapping (walked from
   the checkpoint RAM images, satp 0x800824d3, root PA
   0x824D3000): L1 PTE [vpn1=0x300] @PA 0x824D3C00 = 0x20FFDC01
   [V] pointer to L0 table base PA 0x83FF7000; L0 PTE
   [vpn0=0x1F2] @PA 0x83FF77C8 = 0x2017C8EB [V,R,X,G,A,D]
   LEAF, U=0, ppn 0x805F2 -> 4K page PA 0x805F24F4. Neighbours
   0x1F0-0x1F4 identical in pattern. Identical at 100M and
   at 110M (panic state). Consequence: an S-mode fetch of
   c01f24f4 CANNOT fault on these tables via a correct walk
   -- the tables are ruled out, including the firmware-walk
   A/D theory (firmware writes no page tables) and "the
   kernel corrupted its own tables". The kernel's Code: dump
   also proves the page is readable via the DATA path
   (instruction bytes printed from that exact address) --
   only instruction fetch faulted. The faulting instruction
   decodes from the Code: dump (a703) 0009 = word 0x0009A703
   = LW a4, 0(s5); it never executed (its fetch faulted).
   kmem_cache_alloc spans c01f2414-c01f2b00 (next symbol
   validate_slab), so epc = +0xE0 and ra = +0x47C are both
   inside it; ra-inside-the-same-function is normal SLUB
   retry-loop staleness, not evidence of anything. Oops
   registers s10 = kernfs_node_cache+0x0, s8 =
   __kernfs_new_node+0x8c: the allocation in progress was a
   kernfs node (sysfs/device registration) -- consistent
   with an initcall in [297]-[341] doing device/sysfs
   registration (candidates include virtio_mmio [332], whose
   DTB node exists; bus/class registrations in [301]-[302]
   also create kernfs nodes). This locates WHERE in boot,
   not the fetch mechanism.

   CORRECTION to the continuation section's reading: PID 1
   does NOT prove execution passed do_initcalls. PID 1 is
   kernel_init, which RUNS do_initcalls via
   kernel_init_freeable -> do_basic_setup -> do_initcalls.
   The fault happened DURING initcalls, in some initcall in
   the window after bfq [296] and before serial8250 [342] --
   i.e. in [297] io_uring_init ... [341] pty_init, including
   blake2s [298], clk/gpio/pcie drivers, virtio_mmio [332].
   Serial8250 [342] / virtio_blk [357] prints and VFS /
   Run /init lines are absent because those initcalls had
   not run yet (or, for virtio_mmio [332], ran quietly) --
   do NOT claim drivers probed or root mounted.

   THE SPP LINCHPIN, PROVEN BY CONSTRUCTION AND BY DIRECTED
   TEST. The core's S-trap entry (src/big32_core_pipe.v)
   sets sstatus.SPP = 1 iff priv == 1 (S) at the trapping
   marker's EX cycle. priv is assigned in exactly 7 places:
   reset -> M; mret -> MPP; sret -> SPP; S-trap entry -> S;
   M-trap entry -> M; S-interrupt entry -> S; M-interrupt
   entry -> M. Every one of mret/sret/trap/interrupt flushes
   IF/ID and ID/EX, so a fetch-fault marker in flight cannot
   survive a priv change; CSR writes never assign priv
   (mstatus MPP and sstatus SPP are not priv). Therefore
   priv at EX trap = priv at fetch time, and the panic Oops
   status 0x20 (SPP=0, SPIE=1) means priv was U (0) when
   c01f24f4 was fetched. (Attempt-10's status 0x120 does NOT
   prove the core's direct S-trap SPP write: that trap went
   to M and was REDIRECTED by firmware, which constructs
   sstatus with SPP=MPP=S. So the linchpin needed the
   directed test, which follows.)

   DIRECTED TESTS (new, soc2_programs/, run on tb_soc2.vvp;
   bare M-mode start, medeleg bit 12 set, drop to S via
   mret, own tables, satp on, sfence):
   - fault_spp_ctrl.s (CONTROL): S-mode indirect jump to a
     translated executable VA; copied stub (li + ecall only,
     copy-safe: la is auipc-based and is NOT copy-safe) sets
     s5 = 0x5A5A and halts. PASS: cycles 103, halted 1,
     s0 = 0, s5 = 23130. Proves the VA jump + identity
     mapping work, so the fault tests below are meaningful.
   - fault_spp.s (TEST A): S-mode jump to VA 0xC0001000
     mapped V,R,X=0. PASS: cycles 105, halted 1, s0 = 0,
     sstatus = 0x100 (SPP=1), scause = 12, stval = sepc =
     0xC0001000. A genuine S-mode fetch fault shows SPP=1.
   - fault_spp_u.s (TEST B): S-mode sets SPIE=1, SPP=0,
     sepc = 0xC0000000 (executable S page), sret -> U-mode
     fetch fault. PASS: cycles 119, halted 1, s0 = 0,
     sstatus = 0x20, scause = 12, stval = sepc =
     0xC0000000. The panic Oops signature (status 0x20,
     cause 0xc, badaddr = epc) is reproduced byte-for-byte
     by a genuine U-mode fetch of an S page. (First run
     showed sstatus 0x00, not 0x20: the test had set SIE,
     not SPIE, and the core's spec-correct sret copies SPIE
     to SIE -- SIE=SPIE, SPIE=1, SPP=0 -- so post-sret SIE
     was 0 and the trap's SPIE was 0. Setting SPIE before
     sret fixed the test, not the core.)
   The core's sret is spec-correct (SIE=SPIE, SPIE=1,
   SPP=0); sret validity is priv != U only.

   PRIME SUSPECTS, AUDITED AND RULED OUT.
   (a) Core TLB/sfence.vma: TLB fetch-hit and PTW perm
   checks both implement the spec exactly (X required;
   S-fetch from a U page faults; U-fetch from an S page
   faults; SUM does not apply to fetches) -- and tests A/B
   confirm the behaviour end to end. sfence.vma flushes all
   TLB entries and invalidates fetch_pa (over-flush, safe).
   TLB state at both checkpoints: all 16 entries 4K
   (super=0); text pages R1 W0 X1 U0, data pages R1 W1 X0
   U0; PPN mapping consistent with va_pa_offset 0x3FC00000;
   NO TLB entry covers VPN 0xC01F2 at either checkpoint
   (expected -- 16 entries vs thousands of text pages;
   refilled by walk on demand). TLB state at checkpoint
   time does not show the fault, and a stale TLB entry for
   this page would still carry X=1, U=0, which faults only
   under priv=U anyway. RULED OUT as the mechanism.
   (b) Firmware emulation walk A/D omission: the walk does
   NOT set A/D bits in PTEs, but firmware writes no page
   tables at all, and the tables are proven perfect at both
   checkpoints -- so the omission cannot have produced this
   fault. Firmware MPP paths audited: handler entry swaps
   sp/mscratch and saves registers; timer path (int_path /
   ret_int) restores and mrets WITHOUT touching mstatus
   (MPP comes from trap entry = old priv); SBI dispatch
   returns via ret_path (advances mepc+4, restores, mret)
   without touching mstatus; misaligned redirect
   EXPLICITLY forces mstatus MPP=S and constructs sstatus
   with SPP=MPP, SPIE=old SIE, SIE=0 -- correct; "Drop to
   S" initial path sets MPP=S. Firmware writes mstatus in
   exactly those two places, both forcing MPP=S. No firmware
   MPP=U path found by reading. RULED OUT.
   (c) Superpage vs 4K boundary / X-bit error: the faulting
   page is a 4K leaf, not a superpage edge, and its X bit
   is set. The walker's super/4K insert paths read correct
   (overlapping-entry invalidation handled in both).
   RULED OUT.
   (d) fetch_pa cache staleness: fetch_pa BYPASSES
   translation entirely (if_addr_o = fetch_pa when valid),
   so a stale fetch_pa produces wrong-code execution, never
   a cause-0xc translation trap. RULED OUT.
   (e) Checkpoint-resume priv restore: dump and restore
   order in sim/tb_kboot_ckpt.v match field-for-field for
   priv and the surrounding CSRs, and attempt 18's own
   20M/80M resumes continued correctly (new UART lines
   after each). A systematic resume-priv bug is ruled out;
   the discriminator's two independent resumes agreeing
   rules out a copy-specific one. RULED OUT.

   LATENT BUG FOUND, NOT THE CAUSE (do not fix under this
   job's banner): a STALE fetch_fault_pending can survive
   a JAL redirect -- the PTW block drops pending on
   ex_redirect / int_take / satp-write but NOT on an
   ID-stage JAL (which flushes IF but leaves pending set).
   If pc later equals the stale fetch_fault_pc again, the
   IF/ID pending branch fires a marker with no walk and no
   TLB involvement. Reachability for THIS panic fails on
   the precondition: it needs an EARLIER genuine walk fault
   for c01f24f4, but kernel text is always mapped and never
   faulted before. (The JAL-in-ID-at-capture shape is
   itself contrived: it needs the JAL at Y-4 with target Y
   held through the walk by pipe_stall.) Correct minimal
   fix, sketched for a separate change: clear
   fetch_fault_pending when IF/ID takes the JAL branch
   (safe: if the JAL target IS the faulting address, the
   re-fetch re-walks and faults genuinely; if not, the
   abandoned fault is correctly dropped). NOT implemented
   here: it is not the panic's mechanism, and changing the
   core would invalidate the banked checkpoints (below)
   for no benefit to this fault.

   ROOT CAUSE (stated precisely): at the faulting fetch,
   the core's privilege was U (0), so the fetch of the
   supervisor-only (U=0), executable kernel-text page
   0xC01F2000 faulted with cause 0xc, exactly as the spec
   requires. The allocator had run many times before in
   S-mode; what changed at THIS fetch was not the mapping
   (identical at 100M and 110M), not the TLB, not the
   firmware, not the resume -- it was the privilege under
   which kernel_init's code executed. The core and firmware
   are exonerated on every audited path: no core or
   firmware fix is warranted, and none was made (NO source
   file was modified by this investigation; only three new
   soc2_programs/*.s tests and their soc2_hex/*.hex builds
   were added). What remains unknown is kernel-side: WHAT
   put kernel_init's execution in U-mode -- i.e. which
   sret, with what trap frame, in initcalls [297]-[341].
   That is a kernel trap-frame question, not a core bug,
   and it is the only open item.

   REGRESSION EVIDENCE: the three new directed tests PASS
   (above); the existing soc2 suite still passes
   (plic 32089 cycles, uart16550 1220, timer64 20074,
   virtio 2115, all a0=0). The pipe/random/SOC/SOC2/
   coregaps/sbi/dtb/boot/os_boot suites were last green at
   attempt 12 and are unaffected (no source touched); they
   are NOT re-run here because there is no fix to regress.

   CHECKPOINT-VALIDITY CONSEQUENCE: because NO core or
   firmware change was made, the banked 100M checkpoint in
   ckpt_skipjent/ REMAINS VALID -- it was produced by the
   current machine, and the next boot may resume from it
   without concern. (If a core/firmware fix IS ever applied,
   a resume from a pre-fix checkpoint becomes INVALID: the
   checkpoint captures microarchitectural state -- TLB,
   fetch_pa, pending flags, priv -- produced by the old
   logic, and resuming it under new logic could replay the
   old bug's state or violate the new logic's invariants.
   In that case the next boot must start fresh from cycle
   0; resuming from an earlier checkpoint is only safe if
   that checkpoint predates the faulty state, which cannot
   be shown while the trigger is unknown.)

   EXACT NEXT EXPERIMENT (discriminating, and the only one
   that can close the remaining question): an event-logging
   trace from the banked 100M checkpoint over 100M->110M
   (the fault reproduces inside that segment) that logs
   EVERY privilege transition -- cycle, event type
   (sret / mret / S-trap / M-trap / interrupt), old priv,
   new priv, sstatus.SPP, pc -- not a PC sample. The last
   transition before the panic names the mechanism: an
   sret with SPP=0 points at the kernel trap frame that
   carried it (then read that frame's sstatus off the
   kernel stack in the 110M checkpoint RAM); any other
   last transition reopens the core question with a
   concrete event to explain. Do NOT launch a kernel boot
   to get it under this job; the trace is the follow-up
   job's first step. No prompt or userspace is claimed.
   Nothing pushed.

### Attempt 18 privilege-transition trace 100M->110M: the mechanism is a kernel trap-frame sret to U-mode; core NOT reopened (30 Oct 2026)

   Job: step 3 of the day's push. Scope: log every privilege
   transition over 100M->110M from the banked 100M checkpoint
   and name the mechanism that put the CPU in U-mode at the
   PID 1 panic. No boot past 110M, no fix, no push, MAC-wait
   sim untouched, full-config grind untouched.

   HARNESS. New testbench sim/tb_kboot_ckpt_priv.v (copy of
   tb_kboot_ckpt_trace.v plus a posedge event logger that
   reads pre-edge values, the same pattern as the existing
   trap counters: at the committing posedge, dut.core.priv
   is still the OLD privilege and the ex_is_*/ex_trap/
   int_take wires describe the committing event; only
   genuine changes are logged, and a same-cycle interrupt
   uses the post-return privilege as its old value, as the
   core does). Runner tools/run_priv_trace_100m.sh resumes
   from a byte-exact copy of the ORIGINAL 100M checkpoint
   in ckpt_skipjent_priv/ (header verified identical,
   rx2idx=50, rx2next=50100000, feed fully consumed), same
   skip-jent configuration, explicit 110M cap, no CKPTAT
   (no new checkpoint banked). Log
   kernel/priv_trace_100m.txt (490 events), UART log
   kernel/priv_trace_100m_run.log (panic reproduced),
   progress kernel/priv_trace_100m_progress.log. Positive
   control first: a fresh-boot smoke run logs the firmware
   M->S mret at cycle 29 (pc=80000048, MPP=1) -- the logger
   is proven to see real transitions. GOTCHA (fixed
   mid-job): the first full run reached the panic print
   but was killed by a VM restart before $finish, and the
   event log was truncated at 105.24M because it flushed
   only every 1000 events (events total 490, so no flush
   ever fired). Fix: flush on EVERY logged event
   (transitions are rare; cost negligible). The replay
   after the restart is deterministic and complete.

   THE LAST TRANSITION BEFORE THE PANIC (quoted verbatim
   from kernel/priv_trace_100m.txt, line 203):
   ```
   104002170 1->0 sret pc=c0d8121c spp_pre=0 spp_after=0 sepc=c01f24f4 mepc=c00054f0
   ```
   pc 0xC0D8121C = ret_from_exception + 0xA8 (System.map),
   the kernel's generic trap-return path. It is the ONLY
   sret in the entire 100M->110M segment (grep count 1) --
   there was NO U-mode execution before it in this segment.
   The very next event, 11 cycles later (line 204):
   ```
   104002181 0->1 S-trap pc=c01f24f4 cause=12 tval=c01f24f4 spp_pre=0 spp_after=0 sepc=c01f24f4 mepc=c00054f0
   ```
   i.e. the U-mode fetch of c01f24f4 faulted with cause
   12 (instruction page fault), trapped to S with SPP=0
   -- exactly the Oops signature (status 0x20, cause 0xc).
   The fault therefore happens at cycle 104,002,181, not
   near 110M; the remaining ~6M cycles are the panic print
   plus the panic loop (post-panic trace events are only
   the periodic SBI timer ecall pairs, SPP=1, as expected
   for S-mode traps). The two preceding events complete
   the picture (SBI set_timer ecall, __sbi_set_timer_v02
   +0x28 at 0xC00054EC):
   ```
   104001778 1->3 M-trap pc=c00054ec cause=9 spp_pre=0 sepc=c01f24f4
   104001844 3->1 mret pc=800003b4 mpp=1 spp_pre=0 sepc=c01f24f4
   ```
   The CSRs were ALREADY in the fatal state (SPP=0,
   sepc=c01f24f4) before that ecall. The flip happened in
   the ~40k-cycle window after 103961861 (last event with
   spp_pre=1) with NO privilege transition -- i.e. via a
   kernel CSR write (csrw sstatus/sepc from a frame),
   not via any trap/interrupt entry (S-entry sets SPP=1;
   firmware redirect sets SPP=MPP, and a redirect from S
   would give SPP=1, not 0).

   WHY THIS IS A KERNEL TRAP-FRAME ISSUE, NOT A CORE
   ISSUE. ret_from_exception (disassembled from the
   Image, 0xC0D81174) restores sstatus from pt_regs
   offset 128 and sepc from pt_regs offset 0, then
   restores all GPRs and srets -- no masking. So the
   frame it restored HAD status SPP=0 and epc=c01f24f4.
   The core then did exactly what the CSRs told it:
   sret took priv <- SPP = U (spec-correct), and the
   U-fetch of the supervisor-only page faulted with
   cause 12 (spec-correct). No new core evidence of any
   kind: the core question is NOT reopened. And the frame
   cannot be genuine: no genuine U-mode trap can have
   epc in kernel text (0xC01F24F4 is inside
   kmem_cache_alloc, mid-allocation of a kernfs node),
   and no genuine S-mode trap frame has SPP=0 -- while
   the segment proves the CPU never ran in U before this
   sret, so no U-trap could have created the frame.

   THE FRAME ITSELF IS UNRECOVERABLE FROM THE 110M RAM
   (attempted, and the reason is proven, not assumed).
   The fault frame in the 110M checkpoint RAM (read-only
   analysis of ckpt_skipjent_repro110/ckpt_110000000.ram;
   memw index = (PA-0x80000000)/4, page-walk verified:
   VA 0xC2437B70 -> PA 0x82837B70, offset 0x3FC00000)
   decodes field-for-field against the Oops print (ra
   c01f2890, sp c2437c00, gp c20cdb80, tp c2438000,
   s0 c2437c40, a0-a7, s2-s11, t3-t6, status 0x20,
   badaddr c01f24f4, cause 0xc). Its slot is
   [0xC2437B70, 0xC2437C00) = [kernel_sp-144,
   kernel_sp), where kernel_sp = 0xC2437C00 is exactly
   what the fatal exit path's own SPP==0 branch stores
   (exit sp + PT_SIZE, entry.S ret_from_exception).
   The fault trap therefore overwrote the consumed frame
   in its own slot -- a ±4KB scan around the fault frame
   finds only the fault frame and misaligned windows, no
   second genuine frame. The trace itself is the record
   of what the kernel set: SPP=0, sepc=c01f24f4, at the
   sret commit.

   WHAT REMAINS UNKNOWN (stated plainly): WHICH trap
   created, or what kernel code modified, the frame the
   exit path restored -- i.e. the frame's origin. The
   candidates narrow to kernel code that writes
   pt_regs.status/epc (trap-exit restore from a stale or
   wrong stack location, or a fabricated frame), NOT to
   any core/firmware path (all audited and exonerated,
   and this trace adds no core evidence). EXACT NEXT
   EXPERIMENT (not started): a CSR-write trace over
   100M->104.1M logging every csrw to sstatus/sepc with
   committing pc and value -- that names the exact
   instruction that wrote SPP=0 / sepc=c01f24f4, which
   this transition trace cannot see (CSR writes are not
   privilege transitions). Alternative: a stack-dumping
   trace that captures the pt_regs at every
   ret_from_exception sret. Either closes the origin
   question; neither is a fix. No prompt or userspace is
   claimed. Nothing pushed.

### Attempt 18 CSR-write trace 100M->104.1M: the fatal frame was written by a draining csrrci that clobbered interrupt entry -- a CORE pipeline bug, origin closed (30 Oct 2026)

   Job: step 4 of the day's push. Scope: log every committing
   csrw to sstatus/sepc over 100M->104.1M from the banked 100M
   checkpoint and name the exact instruction that wrote the
   fatal trap-frame values (SPP=0, sepc=0xC01F24F4). No boot
   past 104.1M, no fix, no push, MAC-wait sim untouched,
   full-config grind untouched.

   HARNESS. New testbench sim/tb_kboot_ckpt_csr.v (copy of
   tb_kboot_ckpt_priv.v plus a CSR logger; the priv logger
   is kept as a cross-check). The core has no WB-stage PC
   register, so the logger shadows the MEM-stage CSR
   instruction: at the posedge ending the MEM cycle,
   ex_mem_* holds the instruction that MEM/WB copies
   unconditionally, so at the next posedge (the WB commit
   edge, pre-edge mem_wb_csr_write high) the shadow PC is
   the committing instruction's PC. Trap/interrupt entries
   and sret commits log id_ex_pc directly (EX-stage
   events). Cycle counting mirrors the priv logger exactly
   (resumecyc, +1 per posedge while trace_on); the
   cross-check priv log reproduces the fatal sret at
   exactly 104002170, so the two logs line up cycle for
   cycle. Runner tools/run_csr_trace_100m.sh resumes from
   a byte-exact copy of the ORIGINAL 100M checkpoint in
   ckpt_skipjent_csr/ (header verified identical,
   rx2idx=50, rx2next=50100000, feed fully consumed),
   same skip-jent configuration, explicit 104.1M cap, no
   CKPTAT (no new checkpoint banked). Log
   kernel/csr_trace_100m.txt (5427 events: 5225 CSRW,
   100 INT-S, 101 SRET, 1 TRAP-S), UART log
   kernel/csr_trace_100m_run.log, analysis
   kernel/analyze_csr.py (System.map resolution +
   instruction decode from the Image at file offset
   VA-0xC0000000; the sret word at 0xC0D8121C checks out
   exactly, which pins the decode formula). Original
   ckpt_skipjent/ untouched.

   THE EXACT INSTRUCTIONS THAT WROTE THE FATAL VALUES
   (quoted verbatim from kernel/csr_trace_100m.txt):
   ```
   103996873 INT-S mepc=c01f24f4 sepc<=c01f24f4 spp<=1
   103996874 CSRW pc=c01f24f0 csr=100 raw=00000020 spp=0
   103996923 CSRW pc=c0d81100 csr=100 raw=00000020 spp=0
   104002134 CSRW pc=c0d81198 csr=100 raw=00000020 spp=0
   104002138 CSRW pc=c0d8119c csr=141 raw=c01f24f4 spp=0
   104002170 SRET pc=c0d8121c spp_before=0 sepc=c01f24f4
   104002181 TRAP-S pc=c01f24f4 cause=12 sepc<=c01f24f4 spp<=0
   ```
   Decoded (Image words verified):
   - pc 0xC01F24F0 = kmem_cache_alloc+0xdc, word
     0x100177f3 = csrrci sstatus, 2 (local_irq_disable
     inlined). It computed new = old & ~2 = 0x20 from a
     pre-interrupt old sstatus of 0x22 (SPIE=1, SIE=1,
     SPP=0, the normal post-sret kernel-flow value).
   - pc 0xC0D81100 = _save_context+0x8c, word
     0x1002b4f3 = csrrc sstatus, t0 (t0 = 0x46600 =
     SUM|FS|VS mask). It READ the already-clobbered
     sstatus (0x20) and stored it to pt_regs+128 at
     0xC0D81118 (sw s1, 128(sp)) -- that store is what
     put SPP=0 into the frame's status slot.
   - pc 0xC0D81198 = ret_from_exception+0x24, word
     0x10051073 = csrw sstatus, a0 (a0 = frame status
     0x20); pc 0xC0D8119C = ret_from_exception+0x28,
     word 0x14161073 = csrw sepc, a2 (a2 = frame epc
     0xC01F24F4). ret_from_exception is the messenger,
     not the culprit: it faithfully restored a frame
     that was already corrupt.

   THE MECHANISM, COMPLETE. The kernel, in normal S-mode
   flow (SPP=0 after the previous sret, SIE=1), executed
   local_irq_disable (csrrci sstatus, 2) at 0xC01F24F0
   inside kmem_cache_alloc, mid-allocation of a kernfs
   node. The timer tick arrived while that csrrci was in
   MEM: interrupt entry at 103996873 correctly set
   sepc = 0xC01F24F4 (the next, not-yet-executed
   instruction) and SPP = 1. But the core takes
   interrupts at the EX boundary while MEM/WB keep
   draining, and the csrrci committed at the NEXT
   posedge (103996874), overwriting sstatus wholesale
   with its pre-entry computed value 0x20 -- SPP 1 -> 0
   (SIE/SPIE also reverted to pre-entry computation).
   _save_context then saved that clobbered value into
   the frame (status 0x20, epc 0xC01F24F4, the latter
   genuine: the tick really did interrupt at
   0xC01F24F4). The handler ran normally (RCU, spin
   locks, SBI set_timer ecall at 104001778/104001844,
   priv log showing sepc=c01f24f4 and spp_pre=0
   throughout, consistent with the clobber). The
   return restored sstatus 0x20 / sepc 0xC01F24F4 and
   sret at 104002170 took priv <- SPP = U; the U-fetch
   of supervisor-only page 0xC01F2000 faulted cause 12
   at 104002181, killing PID 1 -- the panic.

   WHY ONLY THIS INTERRUPT DIED. A pattern check over
   the whole log: of all 100 INT-S events, EXACTLY ONE
   has a draining sstatus/sepc CSRW within +1/+2
   cycles -- the fatal one (drain at +1 cycle). The
   other 99 _save_context csrrc reads are all raw
   0x120 (SPP=1); only the fatal entry's read (and the
   fault trap's own entry at 104002226, correctly
   SPP=0 for a U-mode fault) read 0x20. The race needs
   an sstatus/sepc CSR write in MEM exactly at entry
   (a 1-cycle window); sstatus writes occur about once
   per 784 cycles in this window, so roughly 0.25% per
   tick -- one hit in 101 interrupts is consistent,
   not a contradiction. Same-edge WB commits are safe
   (the sequential block orders the WB CSR write at
   line 1840 before the interrupt-entry block at 1937,
   so entry wins); only the NEXT-cycle MEM drain is
   uncovered.

   VERDICT, PLAINLY. This is a CORE pipeline bug, not a
   kernel bug: trap/interrupt entry CSR writes are not
   protected against in-flight (draining) CSR writes
   from older instructions. The kernel's csrrci was a
   legitimate older instruction that, under precise-
   trap ordering, should have committed BEFORE the
   trap entry's updates (or been suppressed for the
   entry's CSRs); the core let it commit after. This
   reopens the core NARROWLY on entry-vs-drain
   ordering ONLY. Everything previously exonerated
   stands: sret semantics (SPP <- SPP, spec-correct),
   the fetch fault itself (U-fetch of a supervisor-
   only page, cause 12, spec-correct), TLB/sfence,
   firmware A/D updates, page tables (byte-identical),
   and checkpoint-resume (panic reproduced from two
   independent resumes). The fault trap's own entry is
   clean (no drain after 104002181), consistent with
   the earlier finding that the 110M fault frame is
   genuine.

   EXACT NEXT STEP (not started): fix the entry-vs-
   drain ordering in src/big32_core_pipe.v -- either
   (a) suppress a MEM/WB CSR write to any CSR the entry
   updates when a trap/interrupt is taken (keeping its
   rd write, which is just the old-value read), or (b)
   delay entry by one cycle when a CSR write sits in
   MEM, letting it commit first and then applying the
   entry writes after. The fix must cover all entry
   paths (S-trap, M-trap, S-interrupt, M-interrupt),
   not just the timer case, and it needs a directed
   regression test: interrupt taken with a csrrc
   sstatus in MEM at entry must leave entry SPP=1
   intact and return to S. No prompt or userspace is
   claimed. Nothing pushed.

## Step 5 -- entry-vs-drain fix (30 Oct 2026, DONE)

   ROOT CAUSE RECAP (from the CSR-write trace, above): the
   timer tick arrived while a csrrci sstatus, 2
   (local_irq_disable, pc 0xC01F24F0) sat in MEM. Entry at
   103996873 correctly set sepc = 0xC01F24F4, SPP = 1, but
   the csrrci committed at the next posedge (103996874)
   and overwrote sstatus wholesale with its pre-entry
   value 0x20 (SPP 1 -> 0). _save_context stored 0x20 to
   pt_regs+128; ret_from_exception faithfully restored
   it; sret at 104002170 took priv <- SPP = U; the U-fetch
   of supervisor-only page 0xC01F2000 faulted cause 12 at
   104002181, killing PID 1. A CORE pipeline bug, not a
   kernel bug: entry CSR writes were not protected against
   in-flight draining CSR writes from older instructions.

   FIX IMPLEMENTED in src/big32_core_pipe.v (v7
   single-cycle core untouched): option (a) suppression,
   chosen over option (b) delaying entry by a cycle --
   smaller blast radius (no pipeline stall, no sepc
   accounting hazard: delaying entry would need to freeze
   the EX instruction so no instruction is skipped, and
   re-evaluating after the drain could mean no entry at
   all if SIE dropped, changing interrupt latency
   observably), and consistent with the core's existing
   same-cycle rule (entry already wins over a same-cycle
   WB write to the same CSR; this extends that rule to
   the next-cycle drains). Four combinational wires only,
   no new registers: entry_to_s / entry_to_m (trap or
   interrupt entry to S / M), mem_csr_entry_conflict
   (CSR write in MEM at entry targeting an entry CSR),
   ex_csr_entry_conflict (same, for EX). Two capture
   lines changed: EX/MEM captures ex_mem_csr_write as
   ex_csr_write && !ex_csr_entry_conflict; MEM/WB
   captures mem_wb_csr_write as ex_mem_csr_write &&
   !mem_csr_entry_conflict (addr/new still copied; the
   draining instruction's rd write still commits -- it
   read the pre-entry CSR value, which is correct; CSR
   writes to CSRs the entry does not touch drain
   normally). Covers all four entry paths (S-trap,
   S-interrupt, M-trap, M-interrupt) and BOTH drain
   stages (MEM and EX): the directed test proved the EX
   stage is a live hazard too (below), so a MEM-only fix
   would have been incomplete. A CSR write already in WB
   at entry is safe (state block orders WB before entry,
   so entry wins); a CSR write still in ID at entry is
   flushed with the ID stage. Honest wart, shared with
   the same-cycle rule and documented in the code: a
   suppressed CSR write is dropped outright rather than
   forwarded into the entry's status computation, so a
   draining irq-disable's SIE bit is not reflected in
   the SPIE the handler's sret restores (the critical
   section then runs with interrupts on, but the
   entry-vs-drain ordering is safe, so the worst case is
   another safe interrupt, not a panic or corruption).
   Forwarding the draining value into the entry
   computation would close that wart but touches every
   entry variant; it is a separate change, not folded in
   here. Pre-fix source preserved at
   /tmp/big32_core_pipe_orig.v (not a workspace file;
   the diff is wires + two capture lines only, verified
   by diff).

   DIRECTED REGRESSION TEST (new): soc2_programs/
   entry_drain.s + tools/entry_drain_cal.py, integrated
   into tools/soc2_check.py as "entry_drain" (checked-in
   .s carries the calibrated pad 122). M-mode setup
   delegates the timer to S, arms mtimecmp = mtime+150,
   mrets to S; S-mode enables SIE, slides through a NOP
   pad, then executes `drain: csrrci x0, sstatus, 2` and
   a wait loop. The handler records sstatus (s1), sepc
   (s2), entered (s3); verdict: sepc must equal drain+4
   (at entry, drain is in EX and ID holds the next
   instruction, which the entry saves as sepc --
   trace-verified, see below), then SPP = bit 8 of s1:
   1 = PASS (s0=0), 0 = BUG (s0=1), sepc mismatch or no
   handler = MISS (s0=2). EVIDENCE, by direct runs (not
   reasoning): on the UNFIXED core, pad 121 PASS
   (s1=0x120: drain in WB at entry, same-edge rule
   already safe) and pads 122/123 BUG (s1=0x0, s2 =
   drain+4, s3=1: entry SPP=1 clobbered to 0). On the
   FIXED core, pads 121/122/123 all PASS (s1=0x120,
   s2=drain+4, s3=1, cycles=220). FAILS-BEFORE /
   PASSES-AFTER PROVEN. Two calibration lessons, both
   from a cycle trace (testbench /tmp/tb_soc2_trace.v,
   logs /tmp/trace_pad12[123].log): (1) the verdict's
   first sepc expectation (drain+8) was wrong -- it
   assumed drain in MEM during the entry cycle, but the
   tick aligns with drain in EX, so sepc = drain+4;
   the test reported MISS until the expectation was
   corrected to the traced value; (2) the trace showed
   pads 122/123 are an EX-stage drain (not the kernel's
   MEM-stage drain), which forced the fix to cover the
   EX/MEM capture as well as MEM/WB. The tick-to-drain
   phase is not simply pad-linear (pads 122 and 123
   share the EX alignment; pad 124 lands drain in ID
   at entry, flushed, sepc=drain); the sweep empirically
   finds the bug pads, and the verdict logic (not a
   pad-count model) is what the suite relies on. The
   fault_spp*.s directed tests from the investigation
   remain as files but are NOT suite-integrated; only
   entry_drain is the regression test for this fix.

   REGRESSION RESULTS (full chain ./run_soc2.sh on the
   fixed core, log /tmp/run_soc2_fixed.log, EXIT=0):
   SOC2 5/5 (plic, uart16550, timer64, virtio,
   entry_drain PASS cycles=220 a0=0); coregaps 4/4 (tlb,
   ad, misalign, ipi); sbi PASS; dtb PASS; boot PASS;
   os_boot PASS; SOC 11/11; pipe directed 17/17
   (including misalign_demo, the Phase 6 path); random
   pipe 50/50. NO REGRESSION. Any future failure here
   stops the line; it is not worked around by weakening
   the test.

   CHECKPOINT-VALIDITY VERDICT: the banked 100M
   checkpoint in ckpt_skipjent/ REMAINS VALID under the
   fixed core. Reason: the fix adds combinational wires
   only and changes two capture assignments; it adds no
   register, changes no reset value, no CSR layout, no
   TLB array, no RAM format. The checkpoint testbench
   (sim/tb_kboot_ckpt.v) dumps/restores ex_mem_csr_* and
   mem_wb_csr_* by name, and those registers still exist
   with the same names, widths, and meanings -- only the
   VALUES they take on future entry cycles can differ
   (suppressed=0 instead of 1), which is exactly the
   intended behaviour change. The 100M state itself was
   produced before the panic (panic at ~104M) and is a
   clean architectural state; restoring it verbatim
   under the fixed core is correct, and the run will
   diverge from the unfixed trajectory precisely at the
   first entry-vs-drain hazard (the ~104M timer entry),
   where the fixed core suppresses the clobber instead
   of panicking. That divergence is the point of the
   fix, not an invalidity. OPERATIONAL NOTE: the
   checkpoint DATA (.hdr/.ram, .done present) is valid,
   but the simulation BINARY must be rebuilt -- the
   banked sim/tb_kboot_ckpt.vvp was compiled from the
   unfixed core. tools/ckpt_run.sh compiles from
   src/big32_core_pipe.v (line 57), so its compile step
   picks up the fixed core automatically; do NOT reuse a
   stale .vvp for the post-fix boot.

   EXACT NEXT STEP (not started by this job): resume
   the skip-jent boot from the banked 100M checkpoint in
   ckpt_skipjent/ under the FIXED core (recompiled
   testbench), explicit cap, watching for the ~104M
   timer entry to pass without panic, then serial8250
   [342], virtio-blk [357], root-mount, init banner,
   big32# prompt, and RX command output. No kernel boot
   was launched by this job, and nothing was pushed.
   No prompt or userspace is claimed.

### Attempt 18 fixed-core resume -- skip-jent 100M->150M under the FIXED core: 104M entry PASSES, serial8250 [342] REACHED, then ttyS0 DISABLED -- a NEW finding, NOT success (30 Oct 2026, run 30 Oct 05:31-08:15 UTC / 11:01-13:45 IST)

   THE JOB THE FIX SECTION ABOVE POINTED AT, DONE.
   Runner tools/run_skipjent_fixedcore.sh (modelled on
   run_skipjent_cont150.sh), log
   kernel/boot_attempt18_skipjent_fixedcore.log,
   progress kernel/skipjent_fixedcore_progress.log,
   checkpoints ckpt_skipjent_fixedcore/. Same
   configuration as attempt 18: skip-jent DTB
   (initcall_blacklist=jent_mod_init, earlycon
   console=ttyS0, root=/dev/vda rootfstype=ext4
   rootwait ro init=/init), 64 MiB RAM, 10 MHz,
   attempt-12 SBI firmware (medeleg 0xB9AF), virtio-blk
   rootfs, Linux 6.6.52 rv32 Image. Testbench rebuilt
   from the fixed core before launch
   (tools/ckpt_run.sh compile 64m, 30 Oct 05:30 UTC;
   new sim/tb_kboot_ckpt.vvp 7,941,306 bytes vs the
   pre-fix build 7,932,233 bytes -- the pre-fix binary
   was NOT reused). Explicit 150M cap in 10M segments;
   never uncapped loop mode.

   RX RE-ARM: the original 100M checkpoint header in
   ckpt_skipjent/ is 100000000 / 50 / 50100000
   (rx2idx=50, already consumed in attempt 18).
   ckpt_skipjent_fixedcore/ was created as a copy of
   the 100M set with ONLY header lines 2-3 changed
   (rx2idx 50->0, rx2next 50100000->140000000); diff
   verified to show exactly those two lines; the
   original in ckpt_skipjent/ is untouched. Feed:
   rootfs/rx_cmds.txt, +RX2START=140000000
   +RX2PERIOD=2000, all 50 bytes by 140.1M. The 150M
   header confirms rx2idx=50, rx2next=140100000 --
   the whole feed was consumed. It fed into the 16550
   RX FIFO before any shell existed, so it is moot
   for this run; the stale-16-bytes FIFO caveat from
   the 160M continuation still applies to any future
   shell.

   SEGMENTS (all HALTED 0, .done banked each):
   100M->110M done 06:03:23 UTC; 110M->120M done
   06:32:10 UTC; 120M->130M done 06:56:33 UTC;
   130M->140M done 07:22:24 UTC; 140M->150M done
   08:15:27 UTC. Final footer CYCLES: 150000000,
   HALTED: 0. Runner printed "skipjent fixedcore
   complete: 150M cap reached".

   104M ENTRY OUTCOME -- THE FIX'S PROOF IN THE REAL
   BOOT: the 100M->110M segment printed ZERO panic
   lines and ZERO bracketed UART lines. On the unfixed
   core this exact segment printed the PID 1 panic at
   kernel time 9.13 s (badaddr c01f24f4, cause 0xc,
   exitcode 0xb). Under the fixed core the ~104M timer
   entry passed clean. The entry-vs-drain fix is proven
   in the real boot, not just in the directed test.

   NEW UART LINES (the fixedcore log contains exactly
   these two bracketed lines in total; everything
   before them is the attempt-18 story, furthest line
   "[    8.114278] io scheduler bfq registered"):
   [   13.499527] Serial: 8250/16550 driver, 4 ports,
   IRQ sharing disabled
   [   13.695891] printk: console [ttyS0] disabled
   The first line is serial8250_init [342] running --
   the boot got past the quiet initcall stretch that
   swallowed 100M->~149M with no output at all. The
   second line is the OPPOSITE of the expected
   "console [ttyS0] enabled": a registered console was
   UNREGISTERED (unregister_console prints exactly
   "console [%s%d] disabled"). No "enabled" line and
   no "bootconsole [ns16550a0] disabled" line appear
   anywhere in the log. So the 8250 driver, having
   started, then dropped ttyS0. Cause NOT established
   by this run -- candidates to investigate, not
   findings: the 8250 probe/autoconfig sequence
   against our 16550 model (divisor-latch pattern
   test, FCR/IIR FIFO bits, EFR access, IRQ
   registration), or a DTB serial-node problem.
   NOTE on what follows: only ~1M cycles elapsed
   between the disabled line (~149M) and the 150M cap,
   so whether the earlycon bootconsole is still alive
   and later output resumes is UNRESOLVED -- the
   silence after 13.695 s proves nothing yet, and the
   kernel may be progressing quietly past [342] with
   no console to print to.

   NOT REACHED / NOT SHOWN: "console [ttyS0]
   enabled", virtio-blk probe [357], VFS/root-mount,
   "Freeing unused kernel memory", "Run /init", init
   banner, big32# prompt, any RX command output. No
   Oops, no panic, no failure line of any kind. This
   is a kernel-only boot at the cap, NOT success under
   the strict criterion (prompt + at least one command
   output). A prompt without command output would be
   a major milestone; neither is present.

   INCIDENTS (handled, no effect on the boot itself):
   TWO VM restarts. The first killed the initial
   100M->110M segment at ~05:38 UTC (log had only the
   resume overlay print); Icarus wiped, reinstalled
   from the cached deb, segment relaunched 05:39 UTC
   from the 100M checkpoint. The second killed the
   140M->150M segment mid-flight at ~07:35 UTC
   (uptime 0 min at check); the 140M checkpoint was
   intact. The relaunch at 07:35 UTC died immediately
   on a dpkg frontend lock race (post-restart apt
   replay, pid 2205, grabbed the lock between the
   runner's fuser check and its dpkg run) -- and a
   manual wait loop then self-matched its own pgrep
   pattern and never broke; both are recorded here so
   the next relaunch waits on the lock WITHOUT grepping
   for a pattern present in its own command line.
   Icarus was reinstalled directly once the lock was
   free (vvp verified present), and the runner was
   relaunched 07:42 UTC; it burned its documented
   retries on the already-passed targets (resume
   140M->target<140M, load + immediate exit, footer
   only, ~50 s each; 12 retries, ~10 min wall) and
   then ran the real 140M->150M segment from
   07:51:59 UTC. No checkpoint was overwritten by the
   retry-burn (passed-target runs exit before any
   CKPTAT).

   CAVEAT (unchanged): this is the SKIP-JENT
   configuration. It proves everything after the
   jitterentropy loop, not the full boot. The
   full-config grind from the banked 170M checkpoint
   in ckpt_cont160/ is still open, and the
   "continue 170M to 220M" choice was never tapped.

   EXACT NEXT STEP: investigate the ttyS0 disable
   before judging anything past [342]. Concretely:
   (a) audit the 16550 model against the kernel 8250
   autoconfig sequence (what the driver reads back
   from divisor-latch, FCR/IIR, EFR, and IRQ paths --
   a directed probe test on the model, or a pc-trace
   from the banked 150M checkpoint, will show which
   step rejects the port); (b) continue 150M->160M
   from the banked 150M checkpoint in
   ckpt_skipjent_fixedcore/ to learn whether earlycon
   output resumes and whether virtio-blk [357],
   root-mount, and init follow -- but if the console
   is genuinely gone, that continuation will stay
   silent even if the kernel progresses, so (a) comes
   first or alongside, not after a long silent grind.
   After the console is fixed, the RX feed needs a
   fresh re-arm (header-copy trick, feed armed after
   the then-known prompt time). Do NOT resume from
   the 110M panic-loop checkpoints in
   ckpt_skipjent_cont150/ or ckpt_skipjent_repro110/.
   Nothing was pushed.

### STEP 6 -- ttyS0-disable investigation: VERDICT -- the
console was NEVER rejected; the 150M cap cut the run
mid-registration (30 Oct 2026, run 30 Oct 08:37-09:06 UTC)

   THE JOB THE FIXED-CORE SECTION ABOVE POINTED AT,
   DONE. This supersedes that section's "EXACT NEXT
   STEP": the disable is explained, no fix is needed,
   and a continuation past 150M is now MEANINGFUL
   (previously held as "silent if the console is
   genuinely gone" -- the console is NOT gone).

   VERDICT IN ONE LINE: the "console [ttyS0]
   disabled" line is the 8250 driver's NORMAL
   legacy-slot takeover by the OF probe, NOT a
   rejection; and the missing "enabled"/report lines
   are because the 150M cap hit ~2,400 cycles after
   the report printk was stored in the ringbuffer and
   BEFORE its UART flush and BEFORE register_console
   ran. Nothing is broken. No model fix, no DTB fix,
   no driver fix. The boot was cut off at the worst
   possible moment -- mid-console-registration -- not
   stuck.

   EVIDENCE 1 -- THE TRACE. Runner
   tools/run_tty_trace_140m.sh (new, modelled on
   run_priv_trace_100m.sh), trace testbench
   sim/tb_kboot_ckpt_trace_fixed.vvp compiled 30 Oct
   08:37 UTC from the CURRENT (fixed) core sources
   (the Oct-28 trace fork differs from the current
   tb_kboot_ckpt.v ONLY by trace additions -- diff
   verified trace-only -- so recompiling it picks up
   the fix; the pre-fix trace binary was NOT reused).
   Resumed from a BYTE-EXACT copy of the fixed-core
   140M checkpoint set in ckpt_tty_trace/ (original
   ckpt_skipjent_fixedcore/ untouched; header copy
   verified identical). Single explicit-cap segment
   140M->150M, sample period 100 cycles, no CKPTAT
   (the trace run wrote NO checkpoint). Files:
   kernel/pc_trace_tty.txt (100,000 samples,
   cycles 140,000,100-150,000,000),
   kernel/pc_trace_tty_snap.txt,
   kernel/pc_trace_tty_analysis.txt (existing
   analyzer, trace/snap args),
   kernel/tty_trace_140m_run.log (footer
   TRACE_SAMPLES: 100000, CYCLES: 150000000),
   kernel/tty_trace_140m_progress.log. The trace
   run's UART log reproduces the fixed-core run
   EXACTLY (same two lines, same kernel times
   13.499527 s and 13.695891 s) -- deterministic
   replay holds, so the original 150M checkpoint in
   ckpt_skipjent_fixedcore/ is the valid resume
   point for any continuation.

   EVIDENCE 2 -- THE SEQUENCE, cycle by cycle
   (System.map attribution; uart_configure_port and
   uart_report_port are static/inlined, so their
   samples resolve inside serial_core_register_port;
   register_console is a separate symbol and is the
   control):
   - ~147,703,400-147,714,200: console_flush_all +
     uart_console_write + serial_putc +
     serial8250_early_out -- the "Serial: 8250/16550
     driver, 4 ports" line printed via the EARLYCON
     by serial8250_init [342]. [342] itself has 0
     direct samples (short init fn, missed by
     100-cycle sampling) but its effects are sampled:
     four legacy register_port rounds at
     147,794,800-148,990,100 (ctrl_add, port_add,
     tty_register_device_attr) -- the legacy slots
     get dev set, their configures early-return (no
     resources), no report lines. Correct.
   - 149,105,000: serial_pci_driver_init [343]
     (no devices, no-op).
   - 149,303,300-149,371,300:
     of_platform_serial_probe, 5 samples -- THE OF
     PROBE RUNS at [347]. (Initcall order from
     initcall_table.json: [342] serial8250_init,
     [347] of_platform_serial_driver_init -- 8250
     first, OF second, which is why the legacy slot
     exists to be taken over.)
   - 149,374,500: uart_match_port; 149,374,600:
     serial8250_register_8250_port -- find_match_or_
     unused returns legacy slot 0 (dev set).
   - 149,374,900: tty_unregister_device; 149,662,100:
     serial_core_unregister_port; 149,662,300-400:
     unregister_console; 149,669,700+:
     console_flush_all + early_out -- the "console
     [ttyS0] disabled" line flushed through the
     bootconsole. 149,728,200: serial_port_remove;
     149,762,800: unregister returns.
   - 149,762,900-149,816,900: re-add in
     serial8250_register_8250_port -- field copy,
     uart_get_rs485_mode (PASSES, no error),
     serial8250_set_defaults.
   - 149,817,100-149,899,100: serial_core_register_
     port (the re-add's uart_add_one_port) --
     serial_base_ctrl_add (new ctrl device),
     serial_base_port_add (new port device).
   - 149,986,100-149,988,000: __request_resource
     (request_mem_region) + generic_ioremap_prot +
     alloc_vmap_area + ioremap_page_range +
     serial8250_request_std_resource+0xe0 -- THE
     RESOURCE REQUEST AND IOMAP SUCCEEDED.
   - 149,988,200: console_flush_all (console_unlock
     after config_port; prints nothing new).
   - 149,989,200-149,997,600: vsnprintf +
     format_decode + vprintk_emit + vprintk_store +
     prb_reserve + data_alloc + prb_final_commit --
     A PRINTK FORMATTED AND STORED inside the
     re-add's configure: this is uart_report_port's
     dev_info ("ttyS0 at MMIO..."), the only printk
     on that path before register_console.
   - 149,997,700-150,000,000: timer interrupt
     (_save_context, hrtimer_interrupt,
     timekeeping_advance) -- then the cap. The
     report's UART flush, console_lock, change_pm,
     set_mctrl, rs485_config, console_unlock, and
     register_console ("enabled" + bootconsole
     unregister) ALL fall just past 150M.
   - register_console: ZERO samples in the whole
     trace. It sits AFTER report+pm+mctrl+rs485 in
     uart_configure_port (serial_core.c) -- it
     simply had not run yet. virtio: 0 samples
     ([357] not reached by 150M -- expected; the
     [342]-[347]+probe sequence consumed the
     window). No Oops, no panic, no fault.

   EVIDENCE 3 -- THE CODE READINGS THAT CLOSE THE
   ALTERNATIVES (all in kernel/linux-6.6.52/):
   - unregister_console_locked (printk.c) prints
     "disabled" FIRST, unconditionally, BEFORE its
     console_is_registered check (which then returns
     -ENODEV). So "disabled" proves NOTHING about
     the console ever having been live. The legacy
     slot's console never was live: its
     console_initcall setup failed with -ENODEV
     (legacy slot has no base -- RISC-V has no
     arch/riscv serial.h, SERIAL_PORT_DFNS empty,
     all 4 static slots type UNKNOWN, iobase 0,
     mapbase 0), so no "enabled" ever printed for
     it. One "disabled", zero "enabled" is exactly
     what the normal takeover of a never-live slot
     looks like.
   - The OF port is sound: 8250_of.c sets
     UPF_SHARE_IRQ | UPF_BOOT_AUTOCONF |
     UPF_FIXED_PORT | UPF_FIXED_TYPE (+ UPF_IOREMAP
     for mem), type = PORT_16550A for "ns16550a"
     (match table), mapbase 0x10010000, PLIC irq 1,
     uartclk 1843200. of_platform_serial_probe
     passes PORT_16550A (never PORT_UNKNOWN, which
     would -EINVAL). rs485/mctrl gates pass for a
     node with no gpio/rs485 props (verified by
     reading; the trace shows rs485 returning
     normally).
   - FIXED_TYPE means autoconfig NEVER runs for the
     OF port (uart_configure_port skips the
     PORT_UNKNOWN reset and the UART_CONFIG_TYPE
     flag; serial8250_config_port with flags=0 does
     request_std_resource, no autoconfig, no
     autoconfig_irq, and CANNOT reset type to
     UNKNOWN even on resource failure). THEREFORE
     every model-quirk theory is DEAD for this path:
     the divisor-latch pattern test, FCR-write
     dropping, IIR FIFO bits (0xC1/0xC4/0xC2), MSR
     constant 0x00, and EFR access are never
     exercised by the OF probe. The earlycon path
     (which uses the same THR/LCR registers) provably
     works -- it printed every line so far.
   - The model is NOT on the failing path at all
     (there is no failing path): the re-add's only
     hardware-adjacent steps are request_mem_region
     (bookkeeping) and ioremap (no HW access), both
     sampled succeeding. A directed probe test on
     the model therefore CANNOT reproduce this --
     the task's "if you can" condition does not
     obtain -- and the trace above IS the
     discriminating experiment. No directed model
     test was built, deliberately: it would test a
     path the driver never takes.
   - DTB exonerated: decompiled
     soc2_hex/big32_kboot_10mhz_rootfs_skipjent.dtb
     -- /soc compatible "simple-bus" (so the OF bus
     creates the device), uart@10010000 "ns16550a",
     reg <0x10010000 0x100>, interrupts <0x01>
     (PLIC), clock-frequency 1843200, status okay,
     no aliases (line defaults to 0, matching
     console=ttyS0). The probe ran, setup
     succeeded, resources were granted.
   - register_console's own gates (printk.c) would
     have passed had it run: preferred console
     ttyS0 index 0 matches univ8250_console name
     ttyS0 index 0; setup would find membase set
     (ioremap done). No silent -ENODEV lurks there.

   WHAT WAS WRONG WITH THE EARLIER READING: the
   fixed-core section called the second line "the
   OPPOSITE of the expected enabled: a registered
   console was UNREGISTERED". Corrected: no console
   was ever registered, and "disabled" is printed
   unconditionally on the remove path. The run was
   not failing at [342]; it was 2,400 cycles short
   of showing the report.

   NO FIX IMPLEMENTED -- correctly. Nothing is
   broken, so any "fix" (model register change, DTB
   node change) would be a change in search of a
   bug. The core and firmware are untouched by this
   job; the only new files are the trace runner,
   the trace outputs, and this section. Nothing
   pushed.

   EXACT NEXT STEP (for the user's call, NOT
   launched here): a SHORT continuation from the
   ORIGINAL 150M checkpoint in
   ckpt_skipjent_fixedcore/ (the trace run wrote no
   checkpoint, so this is the only 150M set).
   Even 150M->151M should show, in order: the
   "ttyS0 at MMIO 0x10010000..." report line,
   "console [ttyS0] enabled", "bootconsole
   [ns16550a0] disabled". A longer continuation
   (150M->160M on the established pattern) is what
   reaches virtio-blk [357], VFS/root-mount, "Run
   /init", and the prompt -- the remaining strict
   success criterion (prompt + at least one command
   output) is unchanged. After the console is live,
   the RX feed needs a fresh re-arm (header-copy
   trick, feed armed after the then-known prompt
   time); the stale-16-bytes FIFO caveat still
   applies to any future shell. Do NOT resume from
   the 110M panic-loop checkpoints in
   ckpt_skipjent_cont150/ or ckpt_skipjent_repro110/.
   The full-config grind from ckpt_cont160/ (170M)
   remains open and separate; this verdict covers
   the skip-jent configuration only.

### STEP 8 -- continuation 150M->160M under the FIXED core:
console LIVE, virtio-blk probe FAILS -22 (NEW blocker, 30 Oct 2026,
run 30 Oct 09:10-09:33 UTC)

   THE CONTINUATION THE STEP 6 VERDICT POINTED AT, DONE.
   Resumed from the banked 150M checkpoint in
   ckpt_skipjent_fixedcore/ (original untouched) via a
   header-copy re-arm in ckpt_skipjent_fixedcore_cont160/
   (ONLY header lines 2-3 changed: rx2idx 50->0, rx2next
   140100000->159000000; diff verified exactly those two
   lines). Runner tools/run_skipjent_fixedcore_cont160.sh
   (new, modelled on run_skipjent_fixedcore.sh). Single
   explicit-cap segment 150M->160M under the FIXED core
   (sim/tb_kboot_ckpt.vvp, built 30 Oct 05:30 UTC from
   the fixed core sources -- binary newer than the
   05:16 UTC core source, so no rebuild was needed).
   Log kernel/boot_attempt18_skipjent_fixedcore_cont160.log
   (14 bracketed lines, verified complete), progress
   kernel/skipjent_fixedcore_cont160_progress.log.
   Footer CYCLES: 160000000, HALTED: 0. 160M checkpoint
   (.done) banked in ckpt_skipjent_fixedcore_cont160/.
   No VM restart during the segment; wall 09:10:59-
   09:33:55 UTC (~23 min for 10M cycles).

   RX ARMING CHOICE, DOCUMENTED: feed armed at 159M
   (50 bytes, 1 byte/2000 cycles, done by 159.1M).
   Reasoning: the prompt, if it appeared in this
   window, most plausibly appeared before 159M ([347]
   probe done at ~149.4M, remaining initcalls +
   root-mount still to run), so a 159M feed lands
   after most plausible prompt times while staying
   inside the cap. As it turned out, no prompt
   existed at feed time (kernel still in initcalls
   at 160M), so the feed is moot for this segment;
   the stale-16-bytes FIFO caveat still applies to
   any future shell.

   WHAT THE LOG SHOWS, IN ORDER (all quoted verbatim):
   - ttyS0 report line, EXACTLY as STEP 6 predicted:
     "[   13.728659] 10010000.uart: ttyS0 at MMIO
     0x10010000 (irq = 2, base_baud = 115200) is a
     16550A"
   - "[   13.732585] printk: console [ttyS0] enabled"
     (appears TWICE in the log, identical timestamp;
     same for the disabled line below -- the lines
     are present either way; the duplication is
     recorded, not explained, here)
   - "[   13.735548] printk: bootconsole [ns16550a0]
     disabled" (also twice, identical timestamp)
   - "[   13.770614] SuperH (H)SCI(F) driver
     initialized"
   - "[   14.322230] loop: module loaded"
   - virtio-blk [357] RAN -- and its probe FAILED:
     "[   14.327223] virtio_blk virtio0: New
     virtio-mmio devices (version 2) must provide
     VIRTIO_F_VERSION_1 feature!"
     "[   14.330804] virtio_blk: probe of virtio0
     failed with error -22"
   - "[   14.627432] e1000e: Intel(R) PRO/1000 Network
     Driver" + copyright line
   - "[   14.692838] usbcore: registered new interface
     driver uas"
   - "[   14.698679] usbcore: registered new interface
     driver usb-storage"
   - FURTHEST LINE: "[   14.724876] mousedev: PS/2
     mouse device common for all mice"
   - NOT REACHED / NOT SHOWN: VFS/root-mount,
     "Freeing unused kernel memory", "Run /init",
     init banner, big32# prompt, any RX command
     output. No Oops, no panic of any kind -- the
     old entry-vs-drain panic does NOT recur in
     this segment either; the fix holds.

   VERDICT: a NEW, PRECISE BLOCKER, not a cap
   shrug. The kernel's modern virtio_blk driver
   refuses our virtio-mmio device because the
   model does not advertise VIRTIO_F_VERSION_1
   (bit 32) in its device features while
   presenting as an MMIO version-2 device, so
   probe fails with -EINVAL and no /dev/vda ever
   exists. Root-mount on /dev/vda CANNOT succeed
   on this path until the model negotiates v1.
   This is a MODEL gap, not a core or firmware
   bug, and it is distinct from the old panic
   (different cycle, different cause, no fault).
   The earlier soc2 virtio directed test passing
   does not contradict this: that test exercised
   the model, not the kernel driver's v1
   negotiation check.

   SUCCESS CRITERION: NOT MET. No init banner, no
   prompt, no command output. A prompt without
   command output would be a major milestone;
   neither is present. This is a kernel-only boot
   at the cap with a named blocker, NOT success.

   EXACT NEXT STEP (for the user's call, NOT
   launched here): audit the virtio-mmio model in
   src/big32_soc2.v against the v1 feature
   negotiation (advertise VIRTIO_F_VERSION_1 in
   device features) AND the v1 queue layout the
   driver will then use; fix minimally, prove it
   with a directed test, then continue from a
   checkpoint that predates the virtio probe.
   OPEN QUESTION FOR THAT JOB, flagged not
   answered: the checkpoint restores SOC state,
   so resuming from 150M or 160M with a fixed
   model may restore the OLD feature bits -- the
   job must establish whether the fix takes
   effect on resume, whether the checkpoint's
   virtio feature field needs patching, or
   whether the next boot must start fresh.
   Do NOT resume from the 110M panic-loop
   checkpoints in ckpt_skipjent_cont150/ or
   ckpt_skipjent_repro110/. The full-config grind
   from ckpt_cont160/ (170M) remains open and
   separate; this verdict covers the skip-jent
   configuration only. Nothing pushed.

### STEP 9 -- virtio v1 fix: VIRTIO_F_VERSION_1 advertised, directed
test fails-before / passes-after, checkpoint verdict: resume from
150M picks the fix up (30 Oct 2026)

   THE MODEL GAP FROM STEP 8, CLOSED. The kernel's
   virtio-mmio driver (drivers/virtio/virtio_mmio.c,
   vm_get_features / vm_finalize_features, Linux 6.6.52)
   reads DeviceFeatures with DeviceFeaturesSel=1 first
   (high word, shifted << 32) and then sel=0, and
   refuses a version-2 device without bit 32
   (VIRTIO_F_VERSION_1) with -EINVAL. Our model
   returned 0 from DeviceFeatures (0x010) for every
   select value -- v_feat_sel was stored by writes to
   0x014 but never consulted by the read function --
   so the probe failed exactly as logged in Step 8.

   QUEUE-PATH AUDIT (both halves checked before
   changing anything): no v1 queue change was needed.
   The split-queue layout (16-byte descriptors, avail
   ring, used ring) and the Desc/Driver/Device Low/High
   address registers (0x080-0x0A4) are shared by legacy
   and v1; the guest is little-endian as v1 requires;
   legacy QueuePFN (0x040) is never used by a v1
   driver; the kernel's vm_setup_vq uses QueueNumMax
   (64 here) as the queue size and the Low/High
   registers, all of which the FSM already implements.
   The FSM never reads the driver-features register,
   so its sel-blind storage cannot affect negotiation.

   FIX (src/big32_soc2.v only; core and firmware
   untouched): DeviceFeatures now returns
   (v_feat_sel == 1) ? 32'h00000001 : 32'd0 --
   sel=1 bit 0 is VIRTIO_F_VERSION_1, sel=0 stays 0
   (no legacy block feature is offered, so the driver
   uses default block behaviour, which the FSM already
   implements). The virtio header comment was updated
   to record the v1 negotiation. No other feature bit
   is advertised: offering more (e.g. EVENT_IDX,
   INDIRECT_DESC) would only widen the surface the
   FSM must then honour.

   DIRECTED TEST (soc2_programs/virtio_v1.s, wired
   into tools/soc2_check.py as "virtio_v1"): mirrors
   the kernel's exact sequence -- identify, reset,
   ACK|DRIVER, sel=1 read (expect 1), sel=0 read
   (expect 0), accept VERSION_1 via DriverFeatures
   sel=1/0, Status=0xB with FEATURES_OK read back
   sticking, queue setup (desc 0x80020000, avail
   0x80021000, used 0x80022000, QueueNum 8, READY,
   DRIVER_OK), then a READ of sector 5 through the
   v1 queue path (status byte 0, used idx 1, len 512,
   data 0x05050505) plus InterruptACK clearing.
   FAILS-BEFORE: on the unfixed model the test halts
   with a0=1 after 39 cycles -- exactly one failure,
   the sel=1 advertisement check (the identify checks
   are shared with the passing virtio.s test).
   PASSES-AFTER: on the fixed model, virtio_v1 PASS
   (cycles=690, a0=0) and the old virtio test still
   PASSES (cycles=2115, a0=0).

   REGRESSIONS (all with their own exit codes, not a
   pipeline's): soc2_check EXIT=0 (all tests incl.
   virtio, virtio_v1, entry_drain); coregaps_check
   EXIT=0; check_dtb EXIT=0; sbi_check EXIT=0;
   boot_check EXIT=0; os_check (os_boot) EXIT=0;
   run_soc.sh EXIT=0 (SOC 11/11, pipe directed PASS,
   random 50/50). NOTE: sbi_check and boot_check
   first failed with FileNotFoundError 'dtc' -- the
   apt dtc binary is gone after a VM restart, a
   pre-existing environment gap, NOT a regression
   from this change (both fail before any simulation,
   at DTB compilation). Both pass with the checked-in
   kernel dtc on PATH (bin/dtc symlinks to
   kernel/linux-6.6.52/scripts/dtc/dtc, the same
   fallback LINUX_BOOT.md already records). No
   regression failure was worked around by weakening
   a test.

   CHECKPOINT VERDICT -- the fix TAKES EFFECT on
   resume from a pre-probe checkpoint; NO checkpoint
   patching is needed; the next boot must resume
   from 150M, NOT from 160M. Evidence, in order:
   (a) The checkpoint dump and restore field
   sequences in sim/tb_kboot_ckpt.v (do_checkpoint
   vs do_resume) are IDENTICAL -- 246 fields each,
   including all 44 virtio fields (v_status,
   v_feat_sel, v_drv_feat, v_drv_feat_sel, queue
   regs, FSM state) in the same order -- so a resume
   restores v_feat_sel field-for-field.
   (b) The DeviceFeatures read is purely
   combinational on v_feat_sel plus model code: no
   feature value is stored anywhere else, so the
   restored scalar plus the fixed model yields the
   fixed bit on the first read after resume.
   (c) The kernel's vm_get_features ALWAYS writes
   DeviceFeaturesSel before each read, so the
   restored sel value itself cannot defeat the fix.
   (d) The 150M checkpoint in ckpt_skipjent_fixedcore/
   PREDATES the blk probe (the probe failed during
   the 150M->160M segment), so resuming from it
   re-runs the probe against the fixed model. The
   160M checkpoint in ckpt_skipjent_fixedcore_cont160/
   POSTDATES the failure: the kernel's RAM state
   already records the failed probe (device removed),
   so a resume from 160M would NOT re-probe and
   must not be used for this. The 150M original is
   untouched; the checkpoint format is unchanged by
   this fix, so old checkpoints remain readable.
   The kernel checkpoint testbench sim/tb_kboot_ckpt.vvp
   was REBUILT from the fixed model (64 MiB,
   30 Oct 10:01 UTC) so the next boot actually uses
   the fix; the pre-fix binary is superseded (it can
   be rebuilt from sources at any time).

   EXACT NEXT STEP (for the user's call, NOT launched
   here): continue the fixed-core skip-jent boot from
   the 150M checkpoint in ckpt_skipjent_fixedcore/
   under the REBUILT tb_kboot_ckpt.vvp, explicit cap,
   RX re-armed after the then-known prompt time
   (stale-16-bytes FIFO caveat still applies), and
   judge virtio-blk [357] probe success, VFS /
   root-mount, "Run /init", init banner, big32#
   prompt, and RX command outputs. Do NOT resume
   from 160M (probe already failed there), and do
   NOT resume from the 110M panic-loop checkpoints
   in ckpt_skipjent_cont150/ or
   ckpt_skipjent_repro110/. The full-config grind
   from ckpt_cont160/ (170M) remains open and
   separate; this verdict covers the skip-jent
   configuration only. Nothing pushed.

### STEP 10 -- continuation 150M->170M under the FIXED virtio model:
   virtio-blk probe SUCCEEDS (Step 9 fix proven in the real boot);
   cap reached, NO prompt, NO blocker (30 Oct 2026)

   Resumed from the banked 150M checkpoint in
   ckpt_skipjent_fixedcore/ under the REBUILT tb_kboot_ckpt.vvp
   (verified before running: binary 30 Oct 10:01:52 UTC, built
   AFTER the fixed soc2.v at 09:42 UTC; fix line present at
   src/big32_soc2.v:525; iverilog/vvp present, no reinstall
   needed; no VM restart during the run). Two explicit-cap
   segments, never uncapped loop mode: 150M->160M
   (10:03:38Z->10:26:42Z) and 160M->170M (->10:48:54Z).
   Runner tools/run_skipjent_fixedcore_cont170.sh; progress
   kernel/skipjent_fixedcore_cont170_progress.log; NEW log
   kernel/boot_attempt18_skipjent_fixedcore_cont170.log
   (35 kernel-timestamp lines; earlier logs untouched).
   RX re-arm: ckpt_skipjent_fixedcore_cont170/ is a COPY of
   the 150M checkpoint set with ONLY header lines 2-3
   changed (rx2idx 50->0, rx2next 140100000->167000000;
   diff verified to show exactly those two lines, RAM md5
   identical); the original in ckpt_skipjent_fixedcore/ is
   untouched. Feed therefore landed at 167M, 1 byte/2000
   cycles, all 50 bytes by 167.1M (170M header confirms
   rx2idx=50, rx2next=167100000). Arming rationale,
   documented in the runner: Step 8 reached kernel time
   14.724 s by 160M, so a prompt, if it appeared, most
   plausibly appeared before 167M. NOTE on resume RX
   mechanics, verified in source this run: on RESUME the
   testbench restores rx2idx/rx2next from the checkpoint
   header (sim/tb_kboot_ckpt.v do_resume); the RX2START
   plusarg is honoured ONLY on a fresh start, so the
   header copy -- not the plusarg -- is what re-arms a
   resumed feed (the cont160 runner's RX2START plusarg
   was harmless but ineffective).

   VIRTIO PROBE -- SUCCEEDS (the Step 9 fix works in the
   real boot, not just the directed test):
   [   14.327357] virtio_blk virtio0: 1/0/0 default/read/poll queues
   [   14.345852] virtio_blk virtio0: [vda] 2048 512-byte logical blocks (1.05 MB/1.00 MiB)
   Zero occurrences in the new log of the Step 8 failure
   lines ("VERSION_1 feature!", "error -22", "probe of
   virtio0 failed"). The old -22 blocker is GONE; any
   later virtio failure would be a new finding, and none
   appeared. Console lines from Step 8 re-appear as the
   resumed run re-executes that stretch (ttyS0 at MMIO
   0x10010000 is a 16550A at 13.728 s, console [ttyS0]
   enabled at 13.732 s, bootconsole disabled at 13.735 s).

   NOT REACHED (grep count 0 for every one of these):
   VFS/root-mount, "Freeing unused kernel memory",
   "Run /init", init banner, "big32# " prompt, any RX
   command output. No panic, no Oops, no kernel failure
   line of any kind. Furthest line:
   [   15.276944] Key type dns_resolver registered
   Final footer: CYCLES: 170000000, HALTED: 0.
   170M checkpoint (.done) banked in
   ckpt_skipjent_fixedcore_cont170/.

   RX STATUS (still untested): the 167M feed landed
   before any prompt existed, so no shell consumed it;
   the restored 16550 RX FIFO holds at most the first
   16 bytes and drops the rest, so a future shell would
   read a truncated first command (plus the standing
   stale-bytes caveat from earlier feeds). A header-copy
   re-arm from a post-prompt checkpoint remains the
   follow-up once a prompt appears; feeding before the
   shell exists cannot produce command output.

   VERDICT: cap outcome, NOT success (prompt + command
   output criterion unmet) and NOT a blocker. The boot
   is travelling cleanly past the two blockers that
   stopped every earlier run (the PID 1 panic, fixed by
   the core fix; the virtio -22, fixed by the model
   fix) and is now in the late initcall stretch after
   the block device, with root-mount still ahead.

   EXACT NEXT STEP (for the user's call, NOT launched
   here): continue from the banked 170M checkpoint in
   ckpt_skipjent_fixedcore_cont170/ under the same
   fixed model, explicit cap (e.g. 170M->190M), RX
   re-armed after the then-known prompt time, and judge
   VFS/root-mount, "Run /init", init banner, big32#
   prompt, and RX command outputs. This is the
   skip-jent configuration only; the full-config grind
   from ckpt_cont160/ (170M) remains open and separate.
   Do NOT resume from ckpt_skipjent_cont150/ or
   ckpt_skipjent_repro110/ (110M panic-loop
   checkpoints), and do NOT resume from
   ckpt_skipjent_fixedcore_cont160/ (160M post-failure
   checkpoint, device removed). Nothing pushed.

### STEP 11 -- continuation 170M->190M under the FIXED virtio model:
   cap reached, NO prompt, NO blocker, ZERO new UART lines (30 Oct 2026)

   Resumed from the banked 170M checkpoint in
   ckpt_skipjent_fixedcore_cont170/ under the REBUILT tb_kboot_ckpt.vvp
   (verified before running: binary 30 Oct 10:01 UTC, built AFTER
   the fixed soc2.v at 09:42 UTC; fix line present at
   src/big32_soc2.v:525; iverilog/vvp present, no reinstall
   needed; no VM restart during the run). Two explicit-cap
   segments, never uncapped loop mode: 170M->180M
   (10:50:26Z->11:12:28Z, ~22 min) and 180M->190M
   (->11:35:34Z, ~23 min; second segment slower, sim
   confirmed alive at ~98% CPU -- heavier initcalls in
   this stretch, not a stall). Runner
   tools/run_skipjent_fixedcore_cont190.sh; progress
   kernel/skipjent_fixedcore_cont190_progress.log; NEW log
   kernel/boot_attempt18_skipjent_fixedcore_cont190.log
   (16 lines total, earlier logs untouched). RX re-arm:
   ckpt_skipjent_fixedcore_cont190/ is a COPY of the
   170M checkpoint set with ONLY header lines 2-3
   changed (rx2idx 50->0, rx2next 167100000->189000000;
   diff verified to show exactly those two lines, RAM md5
   identical); the original in ckpt_skipjent_fixedcore_cont170/
   is untouched. Feed therefore landed at 189M, 1 byte/2000
   cycles, all 50 bytes by 189.1M (190M header confirms
   rx2idx=50, rx2next=189100000). Arming rationale,
   documented in the runner: Step 10 reached kernel time
   15.277 s by 170M with initcalls still running, so prompt
   timing was unknown; arming at 189M (last 1M of the
   window) means a prompt appearing any time before 189M
   is followed by a clean feed into a waiting shell, while
   feeding earlier risks the Step 10 outcome (bytes lost
   past the 16-byte FIFO before any shell exists).

   RESULT -- ZERO new UART lines in the entire 20M-cycle
   window (grep count 0 for every bracketed line, and the
   only non-testbench content in the 16-line log is the
   CKPT/REGS/RAM footers of the two segments). NOT reached
   (grep count 0 for every one of these): VFS/root-mount,
   EXT4, "Freeing unused kernel memory", "Run /init", init
   banner, "big32# " prompt, any RX command output. No
   panic, no Oops, no kernel failure line of any kind.
   Final footer: CYCLES: 190000000, HALTED: 0.
   190M checkpoint (.done) banked in
   ckpt_skipjent_fixedcore_cont190/.

   RX STATUS (still untested): the 189M feed landed
   before any prompt existed, so no shell consumed it;
   the restored 16550 RX FIFO holds at most the first
   16 bytes and drops the rest, so a future shell would
   read a truncated first command (plus the standing
   stale-bytes caveat from earlier feeds). A header-copy
   re-arm from a post-prompt checkpoint remains the
   follow-up once a prompt appears; feeding before the
   shell exists cannot produce command output.

   VERDICT: cap outcome, NOT success (prompt + command
   output criterion unmet) and NOT a blocker. The boot is
   travelling cleanly past every blocker fixed so far
   (the PID 1 panic, the virtio -22) and is now in a
   silent late-initcall stretch after the block device:
   20M cycles with no kernel print at all is consistent
   with registration-only initcalls that print nothing
   on success (the same pattern as the 40M->100M silence
   in attempt 17, which also proved to be progress, not
   a stall), but it is NOT proven progress -- a pc-trace
   from 190M would be the discriminator if the silence
   persists, exactly as the 100M and 160M traces
   discriminated the jent loop. No new failure mode was
   introduced by the virtio fix: the -22 lines are
   absent, and the vda device from Step 10 stands.

   EXACT NEXT STEP (for the user's call, NOT launched
   here): continue from the banked 190M checkpoint in
   ckpt_skipjent_fixedcore_cont190/ under the same
   fixed model, explicit cap (e.g. 190M->210M), RX
   re-armed after the then-known prompt time, and judge
   VFS/root-mount, "Run /init", init banner, big32#
   prompt, and RX command outputs -- or, if the silence
   is judged suspicious, a pc-trace from 190M first to
   confirm the kernel is still in initcalls before
   spending another 20M cycles blind. This is the
   skip-jent configuration only; the full-config grind
   from ckpt_cont160/ (170M) remains open and separate.
   Do NOT resume from ckpt_skipjent_cont150/ or
   ckpt_skipjent_repro110/ (110M panic-loop
   checkpoints), and do NOT resume from
   ckpt_skipjent_fixedcore_cont160/ (160M post-failure
   checkpoint, device removed). Nothing pushed.

### STEP 12 -- pc-trace 190M->200M under the FIXED core + FIXED virtio
   model: VERDICT -- PROGRESSING, nearly at the end of initcalls
   (30 Oct 2026)

   Question: the 170M->190M window produced ZERO new UART lines.
   Was the kernel still marching through late initcalls, or parked?
   (Same discrimination the 100M/160M traces did for the jent loop.)
   Method: resume from a BYTE-EXACT copy of the fixed-model 190M
   checkpoint set in ckpt_trace_190m/ (header diff verified
   byte-identical, RAM md5 ff7de7bdb7bb4ee1d44de06bdbb6b68b
   identical both copies; original in
   ckpt_skipjent_fixedcore_cont190/ untouched -- it still holds
   only the 170M/180M/190M sets, no new checkpoint written by
   this run, no CKPTAT). Trace testbench sim/tb_kboot_ckpt_trace.v
   differs from sim/tb_kboot_ckpt.v ONLY by trace additions
   (diff verified: 66 lines, all trace-only), so its checkpoint
   restore covers all fields identically. The old trace binary
   sim/tb_kboot_ckpt_trace_fixed.vvp (08:37 UTC 30 Oct) PREDATED
   the virtio model fix (soc2.v 09:42 UTC) and was NOT reused:
   this run compiled a fresh binary
   sim/tb_kboot_ckpt_trace_fixed_v1.vvp from current sources
   (fix line confirmed at src/big32_soc2.v:525 before compile).
   Runner tools/run_trace_190m.sh; run log
   kernel/trace_190m_run.log; trace kernel/pc_trace_190m.txt
   (100,000 samples, cycles 190000100..200000000, TRACEPERIOD
   100); snapshots kernel/pc_trace_190m_snap.txt (20, every
   500k cycles); analysis kernel/pc_trace_190m_analysis.txt
   (kernel/analyze_trace_100m.py reused with trace/snap args).
   Segment 190M->200M, explicit cap, 11:43:41Z->12:07:49Z
   (~24 min), no VM restart, iverilog/vvp present.

   RESULT -- the trace run itself PRINTED again, which settles
   the silence question two ways at once. New UART lines in the
   trace run log (kernel time now 18.4-18.7 s, consistent with
   ~1 s kernel time per 10M cycles from 15.277 s at 170M):
   "[   18.446656] debug_vm_pgtable: Validating architecture
   page table helpers", "[   18.648323] Btrfs loaded, zoned=no,
   fsverity=no", "[   18.705879] Legacy PMU implementation is
   available", "[   18.724300] clk: Disabling unused clocks".
   These match initcalls seen in the trace ([521]
   debug_vm_pgtable, [523] init_btrfs_fs, [551]
   clk_disable_unused). The 170M->190M silence was therefore
   registration-only initcalls printing nothing (kernel time
   ~15.3->~17.3 s with no prints), exactly the attempt-17
   pattern -- NOT a stall.

   TRACE EVIDENCE -- marching, not parked:
   - 100,000 samples, 9,676 distinct PCs, broad working set.
     Top single PC strlen+0x10 at 849 samples (0.85%) -- no
     single-PC spin, no dominant loop (contrast jent traces:
     79% keccakf_round).
   - Top functions: idr_get_free 5.46%, kernfs_name_hash 4.93%,
     up_write 4.83%, __kernfs_new_node 4.29%, __might_resched
     4.25%, down_write 4.15%, kmem_cache_alloc 4.05%,
     __might_sleep 3.87%, memset 3.55%, kernfs_link_sibling
     2.99%, kernfs_add_one 2.77% -- sysfs/kernfs registration
     plus allocator/sleep helpers, the signature of late
     initcalls creating device/sysfs nodes, not a loop.
   - Per-bucket movement (10 x 1M-cycle buckets): buckets 0-6
     steady idr/kernfs/up_write mix; bucket 7 memset/
     format_decode/vsnprintf (the new printk lines being
     formatted); bucket 9 blake2s_compress_generic 1,372 +
     get_symbol_offset 537 (random-pool hashing + symbol
     resolution in the final initcalls). The working set
     CHANGES across the window -- a parked kernel would not.
   - Initcall functions seen in trace (index: name): [520]
     slab_sysfs_init, [521] debug_vm_pgtable, [522]
     check_early_ioremap_leak, [523] init_btrfs_fs, [525]
     init_profile_hash, [526] integrity_fs_init, [531]
     clk_debug_init, [533] deferred_probe_initcall, [534]
     genpd_debug_init, [535] vxlan_init_module, [539]
     bpf_kfunc_init, [543] bpf_prog_test_run_init, [545]
     udp_tunnel_nic_init_module, [546] ip_auto_config, [548]
     udp_bpf_v4_build_proto, [549] lockup_detector_check,
     [551] clk_disable_unused, [553] genpd_power_off_unused.
     Max index seen: 553 of 555 entries (indices 0-554).
     Only [554] of_platform_sync_state_init is unobserved --
     sampling granularity (1 sample per 100 cycles), not
     evidence it did not run.
   - Zero-checks: serial8250/uart/tty 120 (console output
     path, consistent with the new UART lines); virtio 0
     (already probed, nothing to re-do); idle 0 (no dead-tick
     idle); jent/jitterentropy 0 (blacklisted, as designed);
     calibrate_xor/xor 0; kernel_init/rest_init/
     run_init_process 44 (kernel_init itself running
     do_one_initcall -- 29 samples -- PID 1 has NOT yet
     reached run_init_process); schedule/__schedule 28
     (voluntary sleeps, not spinning).
   - Priv: 99,947 S-mode, 53 M-mode (firmware timer ecall
     handling) -- normal.
   - Timer health: snapshots show mtimecmp alternating ahead
     (e.g. +16,873 at 190.5M) and behind by one tick with
     irq_timer pending (191M, 200M: mtime 199,999,999,
     mtimecmp 199,996,872, 3,127 behind, irq pending) --
     normal tick behaviour, NO runaway lag, old tick-livelock
     signature absent. CNT_INT_TIM 293 over the window vs
     nominal 250 (one per 40,000 cycles) -- modestly above
     nominal, reported as observed; it does not change the
     verdict, since the initcall march [520]->[553] plus
     fresh UART lines proves forward progress regardless
     of the exact tick count.

   HONEST LIMIT: coarse samples (1 per 100 cycles) do not pin
   the exact initcall executing at 200M, and do not prove
   [554] has run. What they prove is the kernel marched from
   initcall ~[520] to ~[553] across the window and printed
   again -- the silence is over, and the next milestones are
   immediately ahead.

   VERDICT: (a) PROGRESSING. The kernel is at the END of
   do_initcalls (553/555 seen). The next step is a blind
   continuation from the banked 190M checkpoint -- NOT from
   this trace run, which wrote no checkpoint -- with an
   explicit cap (e.g. 190M->210M), RX re-armed after the
   then-known prompt time (header-copy trick; RX2START
   plusarg ineffective on resume), judging in order:
   "Freeing unused kernel memory", VFS/root-mount, "Run
   /init", init banner, big32# prompt, RX command outputs.
   This is the skip-jent configuration only; the full-config
   grind from ckpt_cont160/ (170M) remains open and
   separate. Do NOT resume from ckpt_skipjent_cont150/ or
   ckpt_skipjent_repro110/ (110M panic-loop checkpoints),
   and do NOT resume from ckpt_skipjent_fixedcore_cont160/
   (160M post-failure checkpoint, device removed).
   Nothing pushed; core, firmware, model, rootfs untouched.
### STEP 13 -- continuation 190M->210M under the FIXED model:
   ROOT MOUNTED (first ever), cap reached, NO prompt, NO
   blocker -- but a NEW parking question past the mount.

   Run: resumed from the BANKED 190M checkpoint in
   ckpt_skipjent_fixedcore_cont190/ (NOT from the Step 12
   trace run, which wrote no checkpoint), under the rebuilt
   tb_kboot_ckpt.vvp (30 Oct 10:01 UTC, fixed model, fix
   line at src/big32_soc2.v:525), explicit 210M cap in two
   10M segments (190M->200M, 200M->210M), never uncapped
   loop mode. Log:
   kernel/boot_attempt18_skipjent_fixedcore_cont210.log
   (footers CYCLES: 200000000 then CYCLES: 210000000,
   both HALTED: 0; 210M checkpoint .done banked in
   ckpt_skipjent_fixedcore_cont210/). Runner:
   tools/run_skipjent_fixedcore_cont210.sh; progress:
   kernel/skipjent_fixedcore_cont210_progress.log.
   Original 190M set in ckpt_skipjent_fixedcore_cont190/
   untouched; the run used a copy with ONLY header lines
   2-3 changed (rx2idx 50->0, rx2next 189100000->
   209000000; diff verified, RAM md5 identical). RX feed
   therefore landed at 209M, 1 byte/2000 cycles, all 50
   bytes by 209.1M (210M header confirms rx2idx=50).

   INCIDENTS (environment, not kernel): a VM restart at
   ~12:32 UTC killed the first launch's segment 1
   (190M->200M) mid-flight -- no 200M checkpoint, no
   segment-done line, runner session gone. Recovery:
   iverilog/vvp were wiped by the restart as usual, but
   the post-restart os-intent apt replay respawned
   continuously (pids 1851, 4388, 8215, 13098, ...) and
   held the dpkg frontend lock through 47+ install
   attempts (60 s spacing, then 10 s spacing -- both
   kept missing the brief gaps between replay
   transactions). Workaround, lock-free and db-free:
   extracted the cached deb with dpkg-deb -x into
   .iverilog-local/ (no dpkg lock, no database touched)
   and ran the extracted vvp 12.0 (smoke-tested on
   sim/tb_soc2.vvp: it executed, failing only on that
   testbench's missing soc2_current.hex input, not on
   modules). Relaunched the runner with PATH prefixed
   to .iverilog-local/usr/bin; the real segment ran at
   ~91-98% CPU. Lesson for future relaunches: when the
   replay holds the lock, dpkg-deb -x extraction beats
   waiting it out. The extracted tree is left in place
   for the next restart (it is a build artifact, not a
   repo file -- do NOT push it).

   WHAT THE LOG SHOWS, IN ORDER:
   - Segment 1 deterministically replayed the Step 12
     trace stretch, same lines, same kernel times:
     "[   18.446656] debug_vm_pgtable: Validating
     architecture page table helpers",
     "[   18.648323] Btrfs loaded, zoned=no,
     fsverity=no",
     "[   18.705879] Legacy PMU implementation is
     available",
     "[   18.724300] clk: Disabling unused clocks".
     200M checkpoint banked.
   - Segment 2, NEW territory past the trace window:
     "[   18.815773] EXT4-fs (vda): mounted filesystem
     5ea807f7-5749-46d1-aa34-43b8ccd8dbeb ro without
     journal. Quota mode: disabled."
     "[   18.819714] VFS: Mounted root (ext4 filesystem)
     readonly on device 254:0."
     ROOT MOUNTED -- the first time in the whole
     attempt series the kernel has mounted the root
     filesystem. The virtio-blk device proven in Step
     10, the ext4 image, and the root=/dev/vda bootargs
     all agree.
   - NOT reached (grep count 0 for each): "Freeing
     unused kernel memory", "Run /init", init banner
     ("\nbig32 init: userspace is up (PID 1, RV32I, no
     libc)\n" per rootfs/init.asm), "big32# " prompt,
     any command output. NO prompt or userspace is
     claimed. No panic, no Oops, no new virtio failure;
     the Step 8 -22 lines are absent.
   - RX feed, read correctly: the 209M feed bytes
     appear in the log as ECHOES, not outputs --
     "echo hello from big32", "ls", "uname",
     "cat /hello.txt", "pwd", each on its own line.
     These are the tty line discipline echoing input
     back to the console; they are NOT the shell
     executing anything (no "hello from big32" output
     line, no ls listing, no uname output, no
     hello.txt content). Echo proves a console tty is
     open with echo enabled and is receiving input;
     it does NOT prove a reader has consumed the
     lines. The earlier fragment "ho hello from "
     (seen just before the EXT4 line) is now readable
     in context: the tty echoing the stale 16-byte
     FIFO content ("echo hello from ") left by the
     189M feed. The missing "ec" prefix is recorded
     as observed, not explained; and the 209M feed's
     lines echo cleanly one per line, so the stale
     bytes were NOT still sitting in the input buffer
     when the new feed arrived (consumed or flushed
     in between -- not established which).

   INTERPRETATION -- honest, not inflated: the kernel
   is parked somewhere between root-mount and
   "Run /init" (or init is parked before its first
   read) for the ~8M cycles from the mount to the
   210M cap, with no print in between. That is a NEW
   parking question, distinct from every earlier
   silence: all previous silent stretches were inside
   do_initcalls, which is now complete (Step 12:
   [553]/555). The mount itself proves the block
   device, the ext4 driver, and the VFS path all
   work; what is unproven is the step from mounted
   root to running init. Candidates are NOT asserted
   (slow unprinted work vs a genuine stall in the
   kernel_init path vs init blocked before its
   banner -- the log alone does not discriminate).

   VERDICT: cap outcome, NOT success, NOT a panic
   blocker. Milestone banked: ROOT MOUNTED. Success
   criterion NOT met: no prompt, no command output.
   The next step is a pc-trace from the banked 210M
   checkpoint (copy, original untouched, fixed-core
   + fixed-model trace binary) to locate where the
   kernel is parked -- the same discrimination Step
   12 did for the initcall silence -- BEFORE spending
   another blind continuation. A blind 210M->230M
   run is NOT recommended until the trace says what
   the kernel is doing between mount and Run /init.
   This is the skip-jent configuration only; the
   full-config grind from ckpt_cont160/ (170M)
   remains open and separate. Do NOT resume from
   ckpt_skipjent_cont150/ or ckpt_skipjent_repro110/
   (110M panic-loop checkpoints), and do NOT resume
   from ckpt_skipjent_fixedcore_cont160/ (160M
   post-failure checkpoint, device removed).
   Nothing pushed; core, firmware, model, rootfs
   untouched (except the local .iverilog-local/
   extraction, which is not a repo file).

### STEP 14 -- pc-trace 210M->220M under the FIXED model:
   VERDICT: STUCK -- parked in do_idle, PID 1 blocked
   somewhere invisible to pc sampling. NOT progressing
   slowly, NOT a spin, NOT a tick livelock.

   Run: resumed from a BYTE-EXACT COPY of the fixed-model
   210M checkpoint set in ckpt_trace_210m/ (header diff
   verified, RAM md5 identical; original in
   ckpt_skipjent_fixedcore_cont210/ untouched), under a
   FRESH trace binary sim/tb_kboot_ckpt_trace_fixed_v1.vvp
   compiled from current sources (fix line verified at
   src/big32_soc2.v:525; the old
   sim/tb_kboot_ckpt_trace_fixed.vvp predates the virtio
   fix and was NOT reused). Explicit 220M cap, single
   segment 210M->220M, never uncapped loop mode. Trace:
   kernel/pc_trace_210m.txt (100,000 samples,
   210000100..220000000), snapshots
   kernel/pc_trace_210m_snap.txt (20), analysis
   kernel/pc_trace_210m_analysis.txt (analyzer:
   kernel/analyze_trace_210m.py, kernel_init-path
   variant of the Step 12 analyzer -- initcalls are
   DONE, so it maps against rest_init / kernel_init /
   run_init_process / tty read instead). Runner:
   tools/run_trace_210m.sh; progress:
   kernel/trace_210m_progress.log; run log:
   kernel/trace_210m_run.log (footers TRACE_SAMPLES:
   100000, CYCLES: 220000000). No checkpoint written
   by the trace run (ckpt_trace_210m/ holds only the
   210M set) -- the next boot still resumes from the
   banked 210M checkpoint in
   ckpt_skipjent_fixedcore_cont210/. Icarus was present
   (no VM restart during this run); the runner carries
   the Step 13 dpkg-deb -x fallback into
   .iverilog-local/ if a restart wipes it. Runtime
   13:38:46Z->14:01:51Z (~23 min), no restart.

   WHAT THE TRACE SHOWS:
   - Top functions, ALL idle/nohz: tick_nohz_idle_
     stop_tick 15.27%, tick_nohz_next_event.constprop.0
     14.20%, get_next_timer_interrupt 9.82%,
     do_raw_spin_unlock 7.66%, do_idle 7.36%,
     do_raw_spin_lock 7.07%, hrtimer_get_next_event
     5.83%, timekeeping_max_deferment 4.26%,
     default_idle_call 3.36%, cpuidle_not_available
     3.14%. Top single PC 0xc0073d40
     (do_raw_spin_lock+0x1c) just 1.06% -- no
     single-PC spin, no dominant loop (contrast the
     jent traces at 79% keccakf_round).
   - kernel_init-path counts, ALL ZERO: kernel_init 0,
     rest_init 0, run_init_process 0,
     kernel_init_freeable 0, prepare_namespace 0,
     mount_root 0, free_initmem 0, tty_read 0,
     uart/serial8250 0, virtio 0. Schedule 21
     (noise-level). Low-PC samples (userspace text)
     0 -- init is NOT running, NOT blocked in a
     console read, and has NOT printed its banner.
   - Buckets: essentially IDENTICAL across all 10
     buckets (266-271 distinct PCs, same top counts
     +-few; buckets 4/5/9 slightly higher at 692/500/
     498 from rare timer/housekeeping bursts). No
     movement, no working-set change -- the opposite
     of Step 12's marching buckets. A slowly
     progressing kernel would change its working set;
     this one does not.
   - Non-idle tail is single-digit noise: occasional
     timer-interrupt housekeeping (hrtimer_interrupt
     2, scheduler_tick 1), a few scheduler passes
     (__schedule 9, __switch_to 3), one worker_thread
     sample, complete 1, finish_wait 1. No sustained
     worker execution anywhere -- if async work were
     progressing, kworker threads would appear.
   - Timer health: snapshots show mtimecmp-mtime
     +4,056,873 -> +4,796,873 (next event pushed
     further out each nohz cycle -- tick stopped by
     design, reprogrammed further, NOT stuck);
     irq_timer=0 in ALL 20 snapshots; run log
     CNT_INT_TIM: 3 in 10M cycles (vs nominal 250
     ticks) -- tick essentially stopped, as nohz
     idle intends. Old tick-livelock signature
     absent. Priv: 99,996 S-mode, 4 M-mode
     (firmware timer ecall handling) -- normal.
   - Trace run log: ZERO new UART lines. No "Freeing
     unused kernel memory", no "Run /init", no init
     banner, no prompt. The park already spans ~8M
     cycles from mount to the 210M cap PLUS this
     10M-cycle window: 18M+ cycles of idle.

   WHERE THE PARK IS, BY SOURCE ORDER (in-tree
   kernel/linux-6.6.52/init/main.c, read, not
   assumed): kernel_init() runs kernel_init_freeable()
   (do_basic_setup = initcalls, DONE per Step 12;
   console_on_rootfs; prepare_namespace -> mount,
   PRINTED at 18.819 s in Step 13; integrity_load_
   keys), then BACK in kernel_init():
   async_synchronize_full(), then SYSTEM_FREEING_
   INITMEM, then free_initmem() -- whose print
   ("Freeing unused kernel memory") NEVER appeared.
   So the park window is narrow and named: AFTER
   prepare_namespace() returns, BEFORE free_initmem()
   prints. Inside it sit exactly two candidates:
   (1) PRIME SUSPECT: async_synchronize_full() -- a
   PURE WAIT for all async init work to complete.
   A blocked waiter executes nothing, which is
   exactly consistent with zero kernel_init samples
   and a CPU in idle; and async work progressing
   would show kworker samples, which are absent
   beyond single-digit noise. (2) integrity_load_
   keys() (end of kernel_init_freeable; CONFIG_KEYS
   =y, CONFIG_INTEGRITY=y in .config) -- but if it
   were actively working it would show I/O samples;
   none appear. The trace PROVES the CPU is idle
   and PID 1 is executing nowhere on the kernel_init
   path; it does NOT by itself name the wait channel
   -- a blocked thread's wait queue is invisible to
   pc sampling, and that limitation is stated, not
   papered over.
   Ruled OUT as the park mechanism: tick livelock
   (timers healthy), single-PC spin (top PC 1.06%),
   init blocked in a console read (tty_read = 0),
   userspace running (low-PC = 0, no banner),
   firmware-helper deadlock class (CONFIG_FW_LOADER_
   USER_HELPER is not set in .config, so firmware
   requests fail fast rather than waiting for a
   userspace that does not exist yet).
   ECHO EVIDENCE, closed for this window: no RX
   bytes arrived during 210M->220M (feed consumed
   at 209.1M), tty_read = 0 -- the trace shows
   NEITHER a reader consuming input NOR echo
   activity here. Step 13's reading stands: echo
   proves a console tty open with echo enabled,
   NOT a reader. New negative: init is not waiting
   on console input.

   VERDICT: (b) STUCK. A blind 220M+ continuation
   would just idle further -- 18M+ cycles of idle
   already banked, with zero worker execution -- and
   is NOT recommended. The exact next step is
   checkpoint-RAM forensics on PID 1's blocked
   stack: read PID 1's task_struct / kernel stack
   from the banked 210M checkpoint's .ram in
   ckpt_skipjent_fixedcore_cont210/ (with
   task_struct offsets derived from the kernel
   source -- vmlinux carries symbols but NO DWARF
   debug sections, checked via readelf, so offsets
   must come from include/linux/sched.h + the RISC-V
   thread layout, not from debug info) to name the
   wait function async_synchronize_full is stuck
   behind (or to exonerate it in favour of
   integrity_load_keys). Only that names the wait
   channel; the pc-trace has taken this question as
   far as sampling can. This is the skip-jent
   configuration only; the full-config grind from
   ckpt_cont160/ (170M) remains open and separate.
   Do NOT resume from ckpt_skipjent_cont150/ or
   ckpt_skipjent_repro110/ (110M panic-loop
   checkpoints), and do NOT resume from
   ckpt_skipjent_fixedcore_cont160/ (160M
   post-failure checkpoint, device removed).
   Nothing pushed; core, firmware, model, rootfs
   untouched.

Step 15 -- checkpoint-RAM forensics on PID 1's blocked stack
   (30 Oct, from the banked 210M checkpoint only; NO boot, NO trace,
   NO push; core, firmware, model, rootfs untouched)

   METHOD. Worked only from ckpt_skipjent_fixedcore_cont210/
   (ckpt_210000000.ram, .hdr, .disk, .vram, .pix; .done present;
   nothing written into that directory, nothing resumed).
   The .ram is a $writememh dump of dut.memw (64 MiB, ~165 MB
   hex; `xxxxxxxx` lines = unwritten RAM, treated as 0 when
   parsing); word index i -> PA 0x80000000 + 4i. Sv32 walk
   from checkpoint satp 0x800824d3 (root PT PA 0x824d3000,
   confirmed by header ptw_root_base). vmlinux carries symbols
   but NO DWARF (readelf: 0 debug sections), so every offset
   below was derived from the in-tree source and then validated
   empirically against the dump -- never assumed from another
   arch or version, and never from a fixed VA->PA offset
   (kernel text maps to the 0x80400000 load region while data
   uses other mappings; every VA below was walked).

   OFFSETS DERIVED (6.6.52 rv32, this build; all validated):
   thread_info is FIRST in task_struct (CONFIG_THREAD_INFO_IN_TASK=y):
   flags@0, preempt_count@4, kernel_sp@8, user_sp@12, cpu@16,
   syscall_work@20 (24 bytes total); __state@24; task->stack@28
   (= 0xc2000000 = init_thread_union for idle, exact match);
   usage@32, flags@36, on_rq@44, prio/static_prio/normal_prio@48/52/56
   (= 120 for idle). tasks list_head@512: walking from init_task
   visits 37 tasks and returns to init_task (init_task, PID 1,
   kthreadd, pool_workqueue_, kworker variants, rcu_tasks_trace,
   ksoftirqd/0, kdevtmpfs, kauditd, khungtaskd, oom_reaper,
   kcompactd0, watchdogd, kswapd0, ..., last kworker/R-ext4-).
   comm@940 (TASK_COMM_LEN 16; init_task comm = "swapper").
   pid@608, tgid@612 (validated by three-task cross-check:
   PID 0 = 0/0, PID 1 = 1/1, kthreadd = 2/2).
   thread_struct@1456 in task_struct (arch/riscv processor.h:
   ra, sp, s[12], ...; arch/riscv entry.S __switch_to saves
   ra/sp/s0-s11 into prev->thread).
   struct buffer_head (include/linux/buffer_head.h, rv32 u64
   alignment = 8): b_state@0, b_this_page@4, b_page@8,
   PAD@12-15, b_blocknr u64@16, b_size@24, b_data@28,
   b_bdev@32, b_end_io@36, b_private@40, b_assoc_buffers
   next/prev@44/48, b_assoc_map@52, b_count@56, b_uptodate_lock@60.
   struct wait_bit_queue_entry (include/linux/wait_bit.h):
   key.flags@0, key.bit_nr@4, key.timeout@8, then wq_entry
   flags@12, private@16, func@20, entry next/prev@24/28.

   PID 1 IDENTIFIED. Second task in the list, VA 0xc2438000,
   comm "swapper" (kernel_init thread keeps the swapper comm),
   __state@24 = 2 (TASK_UNINTERRUPTIBLE), on_rq = 0 (not on
   runqueue -- blocked, not runnable), kernel stack VA
   0xc2436000 (8192 bytes, THREAD_SIZE_ORDER=1; task_struct
   sits at the stack top, 0xc2438000).
   thread_struct@1456: thread.ra = 0xc0d79344 = __schedule+0x24c
   (return into __schedule after context_switch/__switch_to --
   the task was switched out from __schedule);
   thread.sp = 0xc2437b70 (blocked task's kernel stack pointer
   at switch time); thread.s0 = 0xc2437bb0 (frame pointer);
   s1 = 0xc24cc880, s2 = 1, s3 = 0xc2438000 (PID 1 task itself).

   BLOCKED STACK DECODED (return addresses in [sp, stack top],
   decoded against kernel/linux-6.6.52/System.map; the __init
   text range 0xc1000000-0xc103df7c had to be INCLUDED -- a
   text-only scan misses the initcall/init_mount/devtmpfs
   frames). Innermost -> outermost:
     __schedule -> schedule+0x60 -> io_schedule+0x44
     -> __wait_on_bit+0xd4 -> out_of_line_wait_on_bit+0x84
     -> __wait_on_buffer+0x58 -> __ext4_find_entry+0x334
     -> ext4_lookup+0xb0 -> __lookup_slow+0xc0
     -> walk_component+0x158 -> path_lookupat+0x94
     -> filename_lookup+0xb8 -> kern_path+0x44
     -> init_mount+0x60 -> devtmpfs_mount+0x50
     -> prepare_namespace+0x250 -> kernel_init_freeable+0x230
     -> kernel_init+0x28
   (plus thread-birth values kernel_init+0x0 at stack+0x1f68
   and ret_from_fork+0x14 at +0x1f68+4). Other stack values
   corroborating, not part of the live chain: bit_wait_io+0x0
   (wait action pointer), wake_bit_function+0x0
   (wait_queue_entry.func), legitimize_links+0x18,
   __might_sleep+0x50, ignore_unknown_bootoption+0x0 (twice --
   stale/rodata-adjacent values).

   WAIT CHANNEL, NAMED. PID 1 is blocked in __wait_on_buffer()
   waiting on a buffer-head lock, inside devtmpfs_mount()'s
   init_mount("devtmpfs", "dev", "devtmpfs", ...) -> kern_path
   ("dev", LOOKUP_FOLLOW, ...) lookup of component "dev" in
   the ext4 root directory. Sources read: drivers/base/devtmpfs.c
   devtmpfs_mount calls init_mount with dir_name "dev";
   fs/init.c init_mount resolves dir_name via kern_path, then
   path_mount; init/do_mounts.c prepare_namespace order is
   mount_root -> devtmpfs_mount -> init_mount(".") ->
   init_chroot("."). This is INSIDE prepare_namespace, BEFORE
   it returns -- so the Step 14 park window ("after
   prepare_namespace returns, before free_initmem prints") is
   CORRECTED by this evidence: the park is inside
   prepare_namespace's devtmpfs_mount, after the mount print
   but before prepare_namespace returns.

   WAIT-QUEUE ENTRY (on PID 1's stack at VA 0xc2437c18, decoded
   with the wait_bit_queue_entry layout above): key.flags@0x1c0c
   = 0xc28644b0 = &bh->b_state; key.bit_nr@0x1c10 = 2 =
   BH_Lock (enum bh_state_bits: BH_Uptodate=0, BH_Dirty=1,
   BH_Lock=2, BH_Req=3, BH_Mapped=4); key.timeout@0x1c14 = 0
   (no timeout -- the wait has NO expiry); wq_entry.private@0x1c1c
   = 0xc2438000 (PID 1 task); wq_entry.func@0x1c20 =
   wake_bit_function+0x0; wq_entry.entry.next/prev@0x1c24/0x1c28
   = 0xc20048a8 = bit_wait_table bucket head (System.map:
   bit_wait_table at 0xc2004040; the bucket head list points
   back to the entry at 0xc2437c24 -- single waiter, a
   genuine bit-wait, not a stale entry).

   THE WAITED BUFFER_HEAD (VA 0xc28644b0, validated field by
   field against the layout above): b_state@+0 = 0x1c
   (Lock + Req + Mapped -- I/O submitted, locked, mapped);
   b_this_page@+4 = 0xc2864460 (nearby, circular-list
   plausible); b_page@+8 = 0xc392fd78; b_blocknr u64@+16 =
   4 (fs block 4 -- see rootfs check below); b_size@+24 =
   0x400 (1024); b_data@+28 = 0xc3bee000, which the page
   walk translates to PA 0x83fee000 (see virtio section --
   exactly the pending chain's data buffer); b_bdev@+32 =
   0xc2806ac0; b_end_io@+36 = end_buffer_read_sync+0x0
   (the classic __bread sync-read completion); b_private@+40
   = 0; b_assoc_buffers next/prev@+44/+48 = 0xc28644dc
   self-pointing (empty list); b_count@+56 = 3;
   b_uptodate_lock@+60 = 1. The b_data page reads as all
   zeros -- consistent with a read that never delivered data.
   Layout note: the 4-byte pad at +12 is REQUIRED -- without
   it (textbook 4-byte u64 layout) size/data/end_io all read
   as nonsense; with 8-byte u64 alignment everything fits.

   ROOTFS CROSS-CHECK (independent of RAM): rootfs/rootfs.img
   is a 1 MiB ext4 image with 1024-byte blocks; block 4
   (byte offset 4096) IS the root directory block, containing
   entries ".", "..", "lost+found", "proc", "sys", "dev"
   (inode 14), "init", "hello.txt". So fs block 4 -> sectors
   8-9 (1024-byte block = 2 sectors), and the waited read is
   the first 1024 bytes of that block = sector 8. The "dev"
   lookup reads the root directory block; the buffer it waits
   on is that block's buffer.

   VIRTIO MODEL STATE AT 210M (from ckpt_210000000.hdr, field
   order parsed from the dump task in sim/tb_kboot_ckpt.v --
   571 fields = 571 header lines, verified): v_status =
   0x0000000f (ACK|DRIVER|DRIVER_OK|FEATURES_OK), v_feat_sel = 0,
   v_drv_feat = 0, v_drv_feat_sel = 0, v_queue_sel = 0,
   v_queue_num = 0x40 (64), v_queue_ready = 1,
   v_desc_lo/hi = 0x83026000/0, v_drv_lo/hi (avail) =
   0x83026400/0, v_dev_lo/hi (used) = 0x83027000/0,
   v_int_status = 0 (no interrupt pending), v_notify_q = 0
   (no kick pending), v_state = 0 = V_IDLE, v_avail_idx = 9,
   v_used_idx = 5, v_cur_desc = 5, v_last_avail = 5,
   v_req_type = 0 (read), v_req_sector_lo/hi = 0x48/0
   (last completed request = sector 72), v_data_addr =
   0x830303b8, v_data_len = 1 (stale/last-chain field),
   v_data_off = 0x400 (1024), v_used_len = 0x400 (1024),
   v_disk_off = 0x9000 (= 72*512, consistent), v_chain_len = 1,
   v_req_write = 0, v_req_error = 0, v_status_addr =
   0x830303b8, v_hdr0 = 0, v_hdr2 = 0x48. PLIC S-side:
   plic_enable_s = 0x6, plic_claim_s = 0. UART:
   u16550_ier = 0x05, u16550_count = 0, rx_count = 0.
   mtime_r = 0x0c845880, mtimecmp_r = 0x0cc9e0c8.

   GUEST VIRTQUEUE RINGS (physical addresses, read from the
   210M .ram): desc table 0x83026000 (16 B entries: addr u64,
   len u32, flags u16, next u16); chains are 3-descriptor
   (header len 16 flags NEXT, data len 1024 flags NEXT|WRITE
   for reads, status len 1 flags WRITE). Avail ring at
   0x83026400: flags = 0, idx = 9, ring heads = [0, 0, 0, 0, 3,
   6, 9, 12] for slots 0-7 (slot 8 = 0, a reused head-0 chain).
   Used ring at 0x83027000: flags = 0, idx = 5, entries
   (id, len) = (0, 4096), (0, 1024), (0, 1024), (0, 1024),
   (3, 1024) -- these match processed submissions #0-#4
   with heads [0, 0, 0, 0, 3] exactly (the earlier apparent
   one-slot lag was a misread of the avail u16 layout:
   u16[0] = flags, u16[1] = idx, ring starts at u16[2]).
   Last completed chain = head 3 = sector 72 read (header
   buffer at 0x830303a8: type 0, ioprio 0x4004, sector 72;
   data buffer 0x83137000; status byte at 0x830303b8 = 0
   success) -- consistent with model regs.

   PENDING (UNPROCESSED) VIRTIO CHAINS -- THE COMPLETER GAP:
   submissions #5 (head 6, header 0x830304a8, data
   0x83137400, status 0x830304b8, sector 74), #6 (head 9,
   header 0x830305a8, data 0x83137800, status 0x830305b8,
   sector 76), #7 (head 12, header 0x830306a8, data
   0x83137c00, status 0x830306b8, sector 78), #8 (head 0
   reused, header 0x830308a8, data 0x83fee000, status
   0x830308b8, sector 8) -- all type 0 (read), ioprio 0x4004,
   status bytes all 0 (not yet written -- reads never ran;
   data buffers all zeros). Model FSM semantics (from
   src/big32_soc2.v): V_IDLE starts work ONLY when
   v_notify_q (QueueNotify write) AND v_queue_ready AND
   v_status[2] (DRIVER_OK); it reads avail idx, and if
   v_last_avail == avail idx goes back idle, else processes
   EXACTLY ONE chain (ring entry at v_last_avail), then
   V_USED writes the used entry, sets v_int_status = 1,
   increments v_last_avail and v_used_idx, returns to V_IDLE.
   V_RD_RING reads the head from the avail ring halfword
   (v_ring_pos = v_last_avail % qnum; even -> low halfword,
   odd -> high halfword of the word at v_drv_idx + 4 +
   (ring_pos/2)*4) -- no off-by-one in the ring read.
   V_USED writes id = v_desc_addr (the chain head) and
   len = v_used_len. Current state therefore: 4 chains
   queued (avail 9) but only 5 processed (last_avail 5),
   model IDLE, no kick pending, no interrupt pending -- the
   queued reads will never complete without another
   QueueNotify, and the driver has no reason to kick again
   (it kicks when queueing; the completions it is waiting on
   are the ones stuck). Whether the kicks for #5-#8 were lost
   in the 1-cycle V_IDLE clear race, coalesced into a single
   kick the model consumed while avail idx had not yet been
   updated, or never issued for a batched submission is NOT
   established -- do not assert a mechanism beyond "no kick
   pending, model idle, avail > last_avail". What IS
   established: v_notify_q is a single bit, so concurrent
   kicks coalesce, and the model processes exactly one chain
   per kick -- a batch of queued reads needs as many kicks
   as chains, and no further kick is forthcoming (PID 1
   blocked, other tasks idle, trace shows no sustained
   worker execution). Even a single future kick would
   process only the OLDEST pending chain (#5, sector 74),
   not PID 1's #8 -- PID 1 needs four kicks to be reached.

   ASYNC SIDE (prime-suspect check, from RAM): async_global_pending
   (System.map 0xc20cd450) next/prev both = its own address
   -> pending list EMPTY; async_dfl_domain (0xc200b89c)
   words show empty domain/pending lists. Even if PID 1 had
   been in async_synchronize_full, there was no pending async
   work to wait on. And PID 1's stack contains no async
   frames at all.

   VERDICT: (a) WAIT CHANNEL NAMED. PID 1 is blocked in
   __wait_on_buffer() on BH_Lock of the root-directory block
   buffer (fs block 4, sector 8), inside devtmpfs_mount()'s
   "dev" lookup in prepare_namespace -- with the completer
   gap being the 4 unprocessed virtio-blk read chains
   (sectors 74, 76, 78, 8), the model idle with no kick
   pending. This is a wait with NO COMPLETER, not a wait
   that needs more cycles: a blind continuation past 220M
   would idle forever, not slowly progress. (b) PRIME
   SUSPECT EXONERATED: async_synchronize_full() is not on
   PID 1's stack (PID 1 never reached kernel_init's
   async_synchronize_full call -- it is still inside
   kernel_init_freeable -> prepare_namespace), and the
   async pending list is empty anyway. integrity_load_keys()
   is likewise not the park (it runs only after
   prepare_namespace returns; prepare_namespace has not
   returned). The Step 14 park window is corrected: inside
   prepare_namespace, not after it.

   EXACT NEXT STEP (not taken here -- user calls it):
   fix the virtio model so a kick drains ALL pending chains
   (loop back to V_RD_AVAIL after V_USED instead of idling,
   or re-scan avail in V_IDLE without requiring a new kick),
   prove with a directed test (queue N chains, kick once,
   all N complete), then resume from the banked 210M
   checkpoint -- noting the resume question the fix must
   answer: on resume, will the fixed model process the
   already-queued chains #5-#8 without a new kick (IDLE
   re-scan), or does the checkpoint's v_notify_q need to be
   patched to 1 (header-copy re-arm, as with RX)? The fix
   should include the IDLE re-scan, or the resume must carry
   the kick. Do NOT resume from ckpt_skipjent_cont150/,
   ckpt_skipjent_repro110/ (panic loop), or
   ckpt_skipjent_fixedcore_cont160/ (post-failure).
   Nothing pushed; core, firmware, model, rootfs untouched
   by this forensics job.

### STEP 16 -- virtio drain fix: one kick drains ALL pending chains,
### resume from 210M needs NO kick and NO header patch (PROVEN)

   MODEL GAP (from Step 15): the virtio FSM in src/big32_soc2.v
   processed exactly one chain per QueueNotify kick: V_IDLE
   consumed the single-bit v_notify_q, ran one chain through
   V_RD_AVAIL -> V_RD_RING -> ... -> V_USED, and V_USED
   returned unconditionally to V_IDLE. The 210M park had 4
   queued reads (avail 9 > last_avail 5), model idle, no kick
   pending -- a wait with no completer. A blind continuation
   past 220M would have idled forever.

   FIX (src/big32_soc2.v ONLY, V_IDLE condition; core and
   firmware untouched): IDLE re-scan, NOT a V_USED loop-back.
   V_IDLE now enters V_RD_AVAIL when queue_ready and
   DRIVER_OK (status[2]) and EITHER a kick is pending OR
   last_avail trails the last-read avail idx:
       (v_notify_q || (v_last_avail != v_avail_idx))
   Why this alone suffices: v_avail_idx stays at the last-read
   value while last_avail climbs one chain at a time, so one
   kick drains every chain queued at kick time; and a resumed
   model whose avail idx was already read (the 210M case:
   avail_idx 9) drains without any new kick. Why no
   busy-poll: V_RD_AVAIL returns to V_IDLE exactly when
   last_avail == avail idx, which also falsifies the re-scan
   condition -- the model is quiescent when caught up. The
   one case this does not rescue is a kick lost BEFORE any
   model read (stale v_avail_idx == last_avail with new
   entries queued); that is the pre-existing kick contract
   (the driver always kicks after queueing), not the 210M
   case, and no loop-back variant would rescue it either,
   since loop-back only runs after a kick starts a drain.
   Kick-loss mechanism itself remains NOT established (see
   Step 15) and is not claimed here.

   DIRECTED TEST (soc2_programs/virtio_drain.s, wired into
   tools/soc2_check.py as virtio_drain): queue 4 read chains
   up front (sectors 5,6,7,8; distinct desc triples 3i/3i+1/
   3i+2, headers, data buffers, status bytes; avail ring
   0,3,6,9; avail idx 4), kick ONCE, poll used idx to 4,
   then check all 4 used entries (ids 0,3,6,9; len 512),
   all 4 status bytes 0, all 4 data words (sector-pattern
   0x0N0N0N0N). Poll bound 20000 iterations (~80x the drain
   time) -- it bounds the wait only; the check is used idx.
   FAILS on the unfixed model: tb_soc2.vvp built 30 Oct
   09:49 UTC (pre-fix) halts a0=1 after 160281 cycles (poll
   timeout; used idx stuck at 1). PASSES on the fixed model:
   virtio_drain PASS (cycles=2615, a0=0). Old tests still
   pass on the fixed model: virtio PASS (2115), virtio_v1
   PASS (690).

   REGRESSIONS: ./run_soc2.sh EXIT=0, log /tmp/run_soc2_drain.log
   (copied results only; the /tmp log itself is ephemeral).
   soc2 7/7 (plic, uart16550, timer64, virtio, virtio_v1,
   virtio_drain, entry_drain), coregaps 4/4 (tlb, ad,
   misalign, ipi), sbi PASS, dtb PASS (1434 bytes), boot
   PASS, os_boot PASS (10174), SOC 11/11, pipe directed
   PASS, random pipe 50/50. No FAIL/ERROR lines. No test
   was weakened: the only test change was the poll bound
   200000 -> 20000 iterations (still ~80x drain time),
   made because the fail path otherwise burns minutes in
   the simulator's slow poll loop.

   RESUME VERDICT (proven by a short resume, not opinion):
   the fixed model processes the already-queued chains #5-#8
   on resume from the banked 210M checkpoint WITHOUT a new
   kick and WITHOUT any header patch. Method: byte-exact
   copy of the 210M set into ckpt_drain_resume/ (header
   diff empty, RAM md5 identical), resumed UNPATCHED under
   the rebuilt tb_kboot_ckpt.vvp (30 Oct 14:42 UTC, drain
   fix confirmed at src/big32_soc2.v:850) for 210M->211M
   only, log kernel/drain_resume_test.log (NEW file).
   210M header (verified by a parser that reproduces the
   571-line header exactly): v_status 0xf, v_queue_ready 1,
   v_notify_q 0, v_state 0 (V_IDLE), v_avail_idx 9,
   v_used_idx 5, v_last_avail 5. After 1M cycles, 211M
   header in the COPY dir: v_notify_q 0, v_state 0,
   v_avail_idx 9, v_used_idx 9, v_last_avail 9 -- all four
   pending chains completed, model idle and caught up.
   Guest-side proof in the same run: "[ 19.735295] devtmpfs:
   mounted" -- PID 1's "dev" lookup completed, i.e. chain
   #8 (sector 8, PID 1's waited buffer) delivered and the
   completion interrupt acked (int_status back to 0).
   Footer CYCLES: 211000000, HALTED: 0; 211M .done exists
   in ckpt_drain_resume/. Original 210M set in
   ckpt_skipjent_fixedcore_cont210/ untouched (its header
   md5 unchanged after the test).

   EXACT NEXT STEP (not launched here -- user calls it):
   continue the skip-jent boot from the banked 210M
   checkpoint in ckpt_skipjent_fixedcore_cont210/ under
   the REBUILT sim/tb_kboot_ckpt.vvp (30 Oct 14:42 UTC),
   NO header patch, explicit cap (e.g. 210M->230M), RX
   re-armed via the header-copy trick only if a prompt is
   expected in the window (stale-16-bytes FIFO caveat still
   applies), judging in order: "Freeing unused kernel
   memory", VFS/root-mount already done, "Run /init", init
   banner, big32# prompt, RX command outputs. (The 211M
   set in ckpt_drain_resume/ is also a valid resume point,
   1M cycles ahead, but the 210M original is the clean
   recipe since this test proved exactly that path.)
   Skip-jent configuration only; full-config grind from
   ckpt_cont160/ (170M) remains open and separate. Do NOT
   resume from ckpt_skipjent_cont150/ or
   ckpt_skipjent_repro110/ (110M panic loop) or
   ckpt_skipjent_fixedcore_cont160/ (160M post-failure).
   Nothing pushed; core, firmware, rootfs untouched by
   this fix job; .iverilog-local/ and ckpt_drain_resume/
   are build/test artifacts, not repo files.

### STEP 17 -- continuation 210M->230M: drain fix re-confirmed,
### then a NEW blocker -- /init exec fails with ENOEXEC (-8),
### root cause in OUR ELF header (mkelf.py e_phnum = 0)

   RUN (tools/run_skipjent_fixedcore_cont230.sh, log
   kernel/boot_attempt18_skipjent_fixedcore_cont230.log,
   NEW file; runner STOPPED after segment 1 on the panic
   check at 15:09:49Z; segment 2 never ran, so the 230M cap
   was NOT reached): resumed from a COPY of the banked
   210M checkpoint in ckpt_skipjent_fixedcore_cont230/
   (only header lines 2-3 changed: rx2idx 50->0, rx2next
   209100000->229000000; diff verified exactly those two
   lines, RAM md5 identical, all virtio fields
   byte-identical; NO virtio header patch, per Step 16).
   Binary sim/tb_kboot_ckpt.vvp (30 Oct 14:42 UTC,
   drain fix at src/big32_soc2.v:850). Icarus present,
   no reinstall needed; .iverilog-local/usr/bin/vvp
   fallback in place. Original 210M set untouched
   (header md5 10480f7d8ddcded09abf3a1832099bb8, RAM md5
   938293f594dc69ce6dcf478055228673, unchanged after
   the run).

   LOG, IN ORDER (all lines quoted verbatim):
   "[   19.735295] devtmpfs: mounted" -- drain fix
   RE-CONFIRMED in the full run (same timestamp as the
   Step 16 short resume: deterministic replay).
   "[   19.998534] Freeing unused kernel image (initmem)
   memory: 4152K"
   "[   20.009314] Run /init as init process"
   "[   20.023757] Kernel panic - not syncing: Requested
   init /init failed (error -8)."
   Call Trace: dump_backtrace, show_stack, dump_stack_lvl,
   dump_stack, panic+0x140/0x324, kernel_init+0xec/0x138,
   ret_from_fork+0x14/0x24; "---[ end Kernel panic -
   not syncing: Requested init /init failed (error -8).
   ]---". Footer CYCLES: 220000000, HALTED: 0; 220M
   checkpoint .done exists in the copy dir but HOLDS THE
   PANIC LOOP -- do NOT resume from it. NOT reached:
   init banner, big32# prompt, any command output
   (RX feed armed at 229M never landed: the run stopped
   at 220M). No prompt or userspace is claimed. This is
   a genuine NEW blocker (different cycle, different
   cause from the old entry-vs-drain panic and the
   virtio -22), not a cap outcome.

   ROOT CAUSE (identified, NOT yet fixed -- fix + proof
   is the next job): error -8 is ENOEXEC, and the
   kernel's ELF loader (CONFIG_BINFMT_ELF=y, verified
   in the kernel .config) rejected OUR /init. Evidence,
   all checked on the actual files:
   - readelf on rootfs/init: "possibly corrupt ELF
     header - it has a non-zero program header offset,
     but no program headers": e_phoff = 52,
     e_phentsize = 32, but e_phnum = 0.
   - The bytes at offset 52 ARE a valid PT_LOAD:
     type 1, off 0, vaddr = paddr = 0x10000, filesz =
     memsz = 3356, flags 7 (RWX), align 4096. The
     loader never sees it because the header declares
     zero program headers: no loadable segment, so
     execve fails with ENOEXEC.
   - The bug is in rootfs/mkelf.py: the ehdr pack
     passes e_phnum = 0 (the tenth value in the
     "<16sHHIIIIIHHHHHH" pack: type 2, machine 243,
     version 1, entry, phoff 52, shoff 0, flags 0,
     ehsize 52, phentsize 32, phnum 0, shentsize 0,
     shnum 0, shstrndx 0).
   - The /init inside the ext4 image is byte-identical
     to rootfs/init (debugfs dump md5
     0f7c8be56126ad61649ede905cc7f314, both files),
     so the image is not stale and no virtio read
     corruption is involved (a read error would be
     EIO, -5, not -8; root mount + devtmpfs + free
     initmem all succeeded).
   Ruled out: core, firmware, virtio model (all three
   delivered PID 1 this far); stale image; missing
   ELF support.

   RECIPE FOR THE NEXT JOB (established, not executed
   here): fix mkelf.py e_phnum 0 -> 1, rebuild
   rootfs/init, verify the rebuilt file differs from
   the old one ONLY in the e_phnum byte, then patch
   the image IN PLACE (do NOT rebuild rootfs.img with
   mkfs -- block layout must not shift): /init starts
   at image offset 21504 (ext4 block 21, block size
   1024, blocks 21-22 per debugfs), so the e_phnum
   byte is image offset 21548 (21504 + 44): 0x00 ->
   0x01. Regenerate soc2_hex/rootfs_disk.hex from the
   patched image. CRITICAL checkpoint subtlety, proven
   from the testbench source: do_resume() runs AFTER
   the initial DISKHEX load and $readmemh's the
   checkpoint .disk OVER it (sim/tb_kboot_ckpt.v
   line ~693), so a plain resume from 210M would
   restore the OLD disk and panic again. The 210M
   checkpoint .disk is byte-identical to rootfs.img
   (1,048,576 bytes, verified equal), so patch the
   SAME byte offset in the 210M checkpoint copy's
   .disk (verifying the .disk line-to-byte mapping
   first: comment header line, then one hex byte per
   line) before resuming from 210M under the fixed
   model, explicit cap, RX re-armed via header copy.
   Then judge: init banner, big32# prompt, RX command
   OUTPUTS (not echo).
   Skip-jent configuration only; full-config grind from
   ckpt_cont160/ (170M) remains open and separate. Do
   NOT resume from ckpt_skipjent_fixedcore_cont230/
   220M (panic loop) or ckpt_skipjent_cont150/ or
   ckpt_skipjent_repro110/ (110M panic loop) or
   ckpt_skipjent_fixedcore_cont160/ (160M post-failure).
   Nothing pushed; core, firmware, model untouched by
   this continuation; rootfs/init and rootfs.img NOT
   yet modified.

### STEP 18 -- /init ENOEXEC fix: mkelf.py e_phnum 0 -> 1,
### image patched IN PLACE, disk hex regenerated,
### patched checkpoint copy prepared (NO long boot launched)

   FIX (rootfs/mkelf.py only; core, firmware, virtio model
   untouched): the ELF header pack
   "<16sHHIIIIIHHHHHH" passed e_phnum = 0 (the tenth
   value after e_ident: type 2, machine 243, version 1,
   entry, phoff 52, shoff 0, flags 0, ehsize 52,
   phentsize 32, phnum 0, shentsize 0, shnum 0,
   shstrndx 0). Changed that one value 0 -> 1; the
   docstring already said "one PT_LOAD". Rebuilt
   rootfs/init with the fixed script (python3
   rootfs/mkelf.py rootfs/init.asm rootfs/init):
   entry still 0x10000, file size still 3440 bytes,
   PT_LOAD bytes at offset 52 untouched.

   BYTE-LEVEL DIFF, old vs rebuilt init (old md5
   0f7c8be56126ad61649ede905cc7f314, new md5
   ed1a5dc038e3725d7f83370312e9836c): EXACTLY ONE
   byte differs -- file offset 44 (e_phnum low byte),
   0x00 -> 0x01. Any other difference would have
   stopped the job; there was none.

   READELF VERIFICATION on the rebuilt init: "Number
   of program headers: 1" (the old "possibly corrupt
   ELF header" warning is GONE), LOAD offset 0x000000,
   VirtAddr = PhysAddr = 0x00010000, FileSiz = MemSiz
   = 0x00d1c (3356), flags RWE, align 0x1000. Entry
   point 0x10000 unchanged.

   IMAGE PATCHED IN PLACE (no mkfs rebuild, so the
   block layout cannot shift): backup
   rootfs/rootfs.img.pre_ephnum_fix (md5
   643e7c5f6aa421d67c9322a175b5ed9c, the pre-patch
   image, so the change is reversible). One byte
   written at image offset 21548 (21504 + 44: /init's
   first extent starts at image offset 21504, fs block
   21, and e_phnum sits at file offset 44, inside the
   first 2048-byte block -- the later /init blocks are
   non-contiguous, which is why a naive 3440-byte
   region compare mismatches past offset 2048; the
   debugfs dump is the authoritative check):
   0x00 -> 0x01. Whole-image diff old vs new: ONLY
   offset 21548. New image md5
   ae1cc627753f949d2e8965e186418a64. Verification:
   debugfs dump of /init from the patched image is
   byte-identical to the rebuilt rootfs/init (md5
   ed1a5dc038e3725d7f83370312e9836c, both files).

   DISK HEX REGENERATED (python3 tools/img2hex.py
   rootfs/rootfs.img soc2_hex/rootfs_disk.hex;
   1,048,576 bytes -> 262,144 words): diff old vs new
   hex is EXACTLY ONE line -- line 5388 (word index
   5387 = image byte 21548 / 4), "00000000" ->
   "00000001". As expected: the patched byte is the
   low byte of that little-endian word.

   CHECKPOINT COPY (the subtlety that would otherwise
   re-panic the next boot): do_resume() runs AFTER
   the initial DISKHEX load and $readmemh's the
   checkpoint .disk OVER it (sim/tb_kboot_ckpt.v:693),
   so a plain resume from 210M would restore the OLD
   disk and panic again with -8. Prepared copy dir
   ckpt_ephnum_fixed/ (full copy of
   ckpt_skipjent_fixedcore_cont210/). .disk format
   verified empirically first: 1,114,112 lines =
   65,536 "// 0x..." comment lines (one per 16 payload
   bytes, gap 17) + 1,048,576 byte lines; stripping
   comments, the original 210M .disk payload is
   byte-identical to the pre-patch image (md5
   643e7c5f6aa421d67c9322a175b5ed9c). Patched the
   SAME byte in the copy's ckpt_210000000.disk: raw
   line 22895 (the line for payload byte 21548;
   payload byte 21504 line verified as '7f', the ELF
   magic, before patching), '00' -> '01'. Copy-vs-
   original diff over all 18 files: ONLY that one
   line differs; the copy's .disk payload is now
   byte-identical to the PATCHED image (md5
   ae1cc627753f949d2e8965e186418a64). The 190M/200M
   sets inside the copy are unpatched (irrelevant --
   the resume point is 210M). Original 210M set
   verified UNTOUCHED after the job: .hdr md5
   10480f7d8ddcded09abf3a1832099bb8, .ram md5
   938293f594dc69ce6dcf478055228673, .disk md5
   9c24caf9b26e025a03c950899e6d4358 -- all identical
   to their pre-job values. (Note: a mid-job service
   restart wiped /tmp, including the md5 list file;
   the original-set check was redone from the Step 17
   recorded values, and the copy patch was re-verified
   after the restart rather than assumed.)

   RESUME RECIPE FOR THE NEXT BOOT (not launched
   here): resume from ckpt_ephnum_fixed/'s 210M set
   under sim/tb_kboot_ckpt.vvp (verified drain-fixed
   build, 30 Oct 14:42 UTC, newer than src/big32_soc2.v
   14:26 UTC with the IDLE re-scan at line 850), with
   soc2_hex/rootfs_disk.hex (the regenerated hex;
   the checkpoint .disk overlay is what actually
   matters on resume, but keep both consistent),
   explicit cycle cap, RX re-armed via the header-copy
   trick (copy ckpt_ephnum_fixed/ to the run dir and
   change ONLY rx2idx/rx2next header lines there, so
   ckpt_ephnum_fixed/ stays pristine; the RX2START
   plusarg is ineffective on resume). NO virtio
   header patch needed (the Step 16 verdict stands).
   Then judge, in order: init banner, big32# prompt,
   RX command OUTPUTS (not echo). Skip-jent
   configuration only; full-config grind from
   ckpt_cont160/ (170M) remains open and separate.
   Do NOT resume from ckpt_skipjent_fixedcore_cont230/
   220M (panic loop) or ckpt_skipjent_cont150/ or
   ckpt_skipjent_repro110/ (110M panic loop) or
   ckpt_skipjent_fixedcore_cont160/ (160M post-failure)
   or the UNPATCHED 210M original (would re-panic
   with -8). Nothing pushed; no long boot launched;
   MAC-wait sim untouched. The Step 17 closing line
   "rootfs/init and rootfs.img NOT yet modified" is
   now SUPERSEDED by this section.

### STEP 19 -- continuation 210M -> 230M from the PATCHED
### checkpoint: ENOEXEC fix PROVEN in the real boot, init
### loop cycling, userspace output garbled (NEW phenomenon,
### NOT success, NOT a panic)
#
#   Runner: tools/run_ephnum_fixed_cont230.sh (adapted from
#   the Step 17 cont230 runner). Log:
#   kernel/boot_attempt18_skipjent_fixedcore_cont230_fixedinit.log
#   (NEW file); progress:
#   kernel/skipjent_fixedcore_cont230_fixedinit_progress.log.
#   Resume point: ckpt_ephnum_fixed_cont230/ (copy of
#   ckpt_ephnum_fixed/ with ONLY 210M header lines 2-3
#   changed, rx2idx 50 -> 0, rx2next 209100000 ->
#   229000000; diff verified exactly those two lines, RAM
#   md5 identical, .disk md5 identical).
#   ckpt_ephnum_fixed/ verified PRISTINE after the run
#   (header still 50/209100000, .disk payload byte 21548
#   = 0x01). Binary: sim/tb_kboot_ckpt.vvp (30 Oct 14:42
#   UTC, drain-fixed). Two explicit-cap segments, never
#   uncapped loop: 210M -> 220M (15:19:26Z -> 15:45:16Z,
#   26 min), 220M -> 230M (15:45:16Z -> 16:11:02Z).
#   Footers CYCLES: 220000000 then 230000000, HALTED: 0.
#   230M checkpoint .done banked in
#   ckpt_ephnum_fixed_cont230/ (CLEAN -- no panic, unlike
#   Step 17's 220M panic-loop set; this 230M set is the
#   resume point for the follow-up).
#
#   LAUNCH GOTCHA (fixed in the runner, record for the
#   next run): the first two launches died in ~5 s with
#   "Unable to find module file
#   /usr/lib/x86_64-linux-gnu/ivl/system.vpi" and 562
#   "$display() is not defined" errors. Root cause: the
#   .vvp BAKES absolute VPI paths from compile time
#   (":vpi_module /usr/lib/x86_64-linux-gnu/ivl/..."),
#   and vvp -M does NOT redirect them (verified by
#   direct test). Fix: symlink the extracted modules
#   into place (mkdir -p /usr/lib/x86_64-linux-gnu/ivl;
#   ln -sf .iverilog-local/.../*.vpi there); the runner's
#   ensure_vvp() now does this whenever the extracted
#   vvp is in use, since /usr is ephemeral and a VM
#   restart wipes the symlinks. The dpkg-deb -x
#   extraction alone is NOT sufficient -- this is the
#   correction to the Step 13 environment note.
#
#   KERNEL LINES, in order (verified by grep): "[   19.735295]
#   devtmpfs: mounted" (deterministic replay of the
#   drain fix), "[   19.998534] Freeing unused kernel
#   image (initmem) memory: 4152K", "[   20.009314] Run
#   /init as init process". Then NO further kernel line
#   through 230M. Panic count 0, Oops count 0.
#
#   HEADLINE 1 -- ENOEXEC FIX PROVEN: no -8 re-panic
#   anywhere in 210M -> 230M, whereas Step 17 panicked
#   0.014 s kernel-time after Run /init. The patched
#   disk TOOK EFFECT on resume (the .disk overlay path
#   from Step 18 works as designed). Exec of /init
#   SUCCEEDED: had it failed with -8 the kernel would
#   have panicked, and had PID 1 died the kernel would
#   have panicked "Attempted to kill init". PID 1 is
#   alive through 230M.
#
#   HEADLINE 2 -- INIT LOOP IS CYCLING: segment 1 (no
#   fresh feed) shows per-command fragments in order
#   ho, ls, uname, cat, pwd -- the shell consumed the
#   STALE lines buffered by the tty line discipline
#   (the Step 13 feed lines, echoed in Step 13, held
#   by the line buffer until a reader arrived). Segment
#   2 shows the clean echo of the fresh 229M feed
#   ("echo hello from big32", "ls", "uname",
#   "cat /hello.txt", "pwd", all 50 bytes; 230M header
#   confirms rx2idx=50, rx2next=229100000) followed by
#   per-command fragments in order echo, ls, uname,
#   cat, pwd. A hung or dead init would not cycle
#   through commands like this.
#
#   HEADLINE 3 -- USERSPACE OUTPUT GARBLED, strict
#   success criterion NOT met: "big32# " count 0, exact
#   "hello from big32" output line count 0, no ls
#   listing, no uname output, no cat contents, no pwd
#   output cleanly visible. What IS visible, per
#   command turn, is the banner TAIL "ce is up (PID 1,
#   RV32I, no libc)" (banner minus its first ~19 chars,
#   preceded by non-ASCII garbage bytes on the first
#   print) followed by "<cmd>2I, no libc)" (command
#   word fused with the banner's last 12 chars).
#   Kernel printk lines are CLEAN; userspace writes
#   are not. This is a NEW phenomenon in the
#   userspace console write path (tty line discipline
#   + 8250 driver interaction, the 16550 TX model
#   under console-write/echo traffic, or the testbench
#   TX capture merging streams) -- it is NOT a prompt
#   failure (the loop runs) and NOT a new kernel bug
#   (no panic, no Oops). Ruled out by reading
#   rootfs/init.asm: linebuf sits AFTER all strings
#   in the layout (banner line 288, prompt 290,
#   linebuf 336), so no linebuf/banner memory overlap
#   explains it; the shell loop itself is sound
#   (banner once, prompt per iteration, read/parse/
#   dispatch, outputs via puts).
#
#   HONEST CAVEAT: the fragments COULD in principle be
#   a testbench capture artifact rather than real
#   guest output corruption -- the next investigation
#   must discriminate wire bytes from log capture
#   before asserting a model bug.
#
#   EXACT NEXT STEP (not launched): targeted
#   investigation of the userspace output garbling
#   from the clean 230M checkpoint (or a short
#   trace), THEN a continuation with a re-armed RX
#   feed (header-copy trick from the 230M set) once
#   the output path is understood. Judge: clean
#   "big32# " prompt + at least one command's output.
#   Skip-jent configuration only; full-config grind
#   from ckpt_cont160/ (170M) remains open and
#   separate. Do NOT resume from the Step 17 220M
#   panic-loop checkpoint, the unpatched 210M
#   original, ckpt_skipjent_cont150/,
#   ckpt_skipjent_repro110/, or
#   ckpt_skipjent_fixedcore_cont160/. Nothing pushed;
#   core, firmware, virtio model, mkelf/init untouched
#   by this step (runner + doc only, plus the /usr
#   VPI symlinks, which are environment, not repo).

## STEP 20 — VERDICT: REAL CORRUPTION, GUEST-SIDE (mkelf 84-byte address skew) — 30 Oct 2026

Verdict, one line: (b) REAL CORRUPTION — the wire is faithful, the bytes are
wrong at the source. NOT a capture artifact, NOT a UART/tty model bug. Stage:
the guest binary itself — rootfs/mkelf.py lays out the ELF segment as if it
started at the code, while the program header says p_offset=0, so the kernel
maps the file 84 bytes lower than the code assumes, and every string address
in init reads 84 bytes before its string. Fix direction (NOT implemented in
this job): make mkelf's label addresses match the kernel's mapping, i.e.
symbol VA = 0x10000 + file_offset (not 0x10000 + file_offset - 84), and set
e_entry to the code start (0x10054), not 0x10000. The 230M checkpoint's RAM
holds the OLD init, so the fix needs a fresh exec — resume from the 210M
checkpoint with a rebuilt disk image (root not yet exec'd /init at 210M), NOT
a resume from 230M. Nothing in this step modified the core, firmware, virtio
model, mkelf, or init; nothing pushed; no long boot launched.

### Capture path reading — EXONERATED
sim/tb_kboot_ckpt.v captures TX per byte: $write("%c", uart_tx) on the
negedge when uart_tx_valid. No line buffering, no buffer reset, no stream
merging in the testbench. The probe testbench (work/garble_probe/tb_probe.v,
copy of tb_kboot_ckpt.v plus cycle-stamped hex logging to tx_hex.log) proved
it: hex bytes == text bytes exactly over the probe window, so the assembled
log IS the wire stream. The garbling is upstream of the testbench $write.

### 16550 TX model reading — EXONERATED
src/big32_soc2.v: THR write sets u16550_tx / u16550_tx_valid (set wins over
the per-cycle clear in the single clocked block); LSR reports THRE=TEMT=1
always; top-level mux forwards u16550_tx when valid. The core legacy UART is
likewise a clean 1-cycle pulse. The model's TX byte stream reaches the
testbench unaltered. Kernel printk through the same model and the same log
path is clean, which independently clears the model and the capture.

### init.asm output path reading — SOUND, strings intact in RAM
puts(a1) measures the NUL-terminated length, then a write(1) loop handling
short writes; banner once at startup, prompt per iteration, read/parse/
dispatch, outputs via puts. Guest .rodata is INTACT in the probe's 232M RAM:
full banner at PA 0x8180b4c1 (second copy 0x8180c4c1, exactly +0x1000), prompt
"big32# " at 0x8180b4f8 / 0x8180c4f8, help and all command strings intact in
order. Guest memory is NOT corrupted. The 93 85 15 "garbage" bytes are RISC-V
instruction bytes (word 0x00158593 = addi a1,a1,1, in code just before the
banner string) — the wire emits CODE bytes, not random noise.

### Discriminating experiment — probe 230M -> 232M (work/garble_probe/)
From a COPY of the clean 230M set (ckpt_garble_probe/, header lines 2-3 only
changed: rx2idx 50->0, rx2next 229100000->230500000; RAM md5
ef968f1585f270d6cc6e22449945f1cd and disk md5 15e7c28c1768129dd10fcec0ef884d97
identical to the original; original in ckpt_ephnum_fixed_cont230/ untouched).
One distinctive command, "echo ABCDEFGHIJ\n", fed at 230.5M as hex-per-line
(the testbench reads RX feed with $fscanf(fd, "%h") — an ASCII feed file
spun the first probe launch forever at ~97% CPU with rchar frozen; hex feed
relaunched cleanly; lesson: RX feed files MUST be hex-per-line). Log
work/garble_probe/probe_run.log, hex log work/garble_probe/tx_hex.log
(72 lines), 232M checkpoint.done banked in ckpt_garble_probe/.
Result: garbling REPRODUCES on a single clean turn — systematic, not
feed-overlap. Wire bytes: "echo ABCDEFGHIJ\r\n" (clean input echo) +
"ce is up (PID 1 RV32I, no libc)\r\n" (banner tail, comma dropped this once
at a burst boundary — see secondary note) + "echo2I, no libc)\r\n" +
"\x93\x85\x15" (next turn's prompt print, cut by the cap). Prompt "big32# "
NEVER appears. Cycle timing: uniform 65-cycle spacing inside every byte
group (driver per-byte cost), multi-thousand-cycle gaps between groups
(separate write episodes). Echoes trickle one byte at a time; process writes
are bulk, drained in bursts of up to 16 (tx_loadsz=16) — but echoes and
process writes SHARE the same circ buffer (uart_put_char vs uart_write ->
same xmit buffer, same tx_chars drain), so the path is shared and the
difference is write size/timing, not the path.

### The mechanism — mkelf p_offset=0 vs code addresses off by 84
readelf on rootfs/init (3,440 bytes): ET_EXEC EM_RISCV, entry 0x10000,
1 program header: LOAD offset 0x0, vaddr 0x10000, filesz 0xd1c = 3356, RWE.
File layout: 84-byte ELF header + phdr, then code at file offset 0x54,
strings at 0x4c0 (banner), 0x4f8 (prompt), 0x500 (help), 0x528 (unk_prefix),
0x53c (newline), 0x578-0x598 (cmd strings). But the code's li addresses
assume the segment starts at the code: banner li = 0x1046C (= 0x10000 + 0x46C,
i.e. file offset 0x4c0 MINUS 84), prompt li = 0x104A4 (file 0x4f8 - 84),
unk_prefix li = 0x104D4 (file 0x528 - 84), newline li = 0x104E8
(file 0x53c - 84), all six dispatch cmd li's = cmd file offset - 84.
The kernel honors p_offset=0: it maps file[0:3356] to VA 0x10000. So every
li reads 84 bytes before its string, verified byte-for-byte from the file:
- puts(banner) reads file 0x46c = 13 05 10 00 -> prints "13 05 10" (3 bytes,
  stops at NUL). That is the first turn's extra garbage.
- puts(prompt) reads file 0x4a4 = 93 85 15 00 -> prints "93 85 15" (3 bytes).
  That is the per-turn garbage prefix.
- puts(unk_prefix) reads file 0x4d4 = "ce is up (PID 1, RV32I, no libc)\n"
  = banner[20:]. That is the banner tail on every turn.
- puts(newline) reads file 0x4e8 = "2I, no libc)\n" = banner[40:]. That is
  the fused suffix after every command word.
- Every dispatch streq fails: the six cmd li's land on file 0x524
  ("\n\0\0\0unknown "), 0x52c ("own command:"), 0x534 ("and: ..."), 0x538
  (" ..."), 0x53c ("\n..."), 0x544 ("?\n\0\0proc...") — none equal
  "help"/"echo"/"ls"/"cat"/"uname"/"pwd". So EVERY command falls through to
  the unknown-command handler, which prints unk_prefix + linebuf (first
  word only, post-split) + newline — i.e. banner[20:] + cmdword +
  banner[40:]. Exactly the observed per-turn shape. Linebuf itself is
  self-consistent (read and puts use the same VA), which is why input echo
  and parsing work while every literal read misses.
Why init survives entry at the header: entry 0x10000 points at the ELF
header bytes, but the core has NO general illegal-opcode trap — ex_illegal
covers only mret-in-non-M and illegal CSRs; unknown opcodes fall through
decode defaults as inert operations. Execution slides through the 84 header
bytes (21 words, including 0x00000000 words) into the real code at VA
0x10054, then runs under the -84 mapping. The first Step 19 line
(6 garbage bytes + banner tail) is puts(banner) 3 bytes + puts(prompt)
3 bytes + puts(unk_prefix) banner tail, on one line (no newlines in the
garbage prints).

### Kernel-vs-userspace asymmetry — EXPLAINED
Kernel printk uses the kernel's own correct virtual addresses through the
console driver (serial8250_console_write, polling, one byte at a time) —
the kernel never touches mkelf's addresses. Userspace writes go through
init's puts with addresses 84 bytes low. Same UART, same model, same log
path; the asymmetry is entirely that the guest binary's addresses are
wrong. A mechanism that blamed the UART model, the tty driver, or the
testbench could not explain clean printk alongside garbled userspace
output — and all three are exonerated by the evidence above.

### Secondary note (NOT the cause, one directed check later)
In the probe turn only, the banner tail lost its comma at a 16-byte burst
boundary (first burst 15 bytes "ce is up (PID 1", second burst " RV32I,
no libc)"); Step 19's tails HAVE the comma. Single-byte, intermittent,
at a burst boundary — possibly a tty/driver burst edge worth one directed
check after the mkelf fix lands. It explains nothing about the garbling
(the -84 shift explains every byte of it) and must not be mistaken for
the cause.

### What this step did NOT do (per the job's bounds)
No fix implemented, no long boot launched, no push. Core, firmware, virtio
model, mkelf/init untouched (probe testbench + checkpoint copy live in
scratch: work/garble_probe/, ckpt_garble_probe/). Original 230M set in
ckpt_ephnum_fixed_cont230/ verified untouched (RAM/disk md5 identical).
Do NOT resume from: Step 17 220M panic-loop set, unpatched 210M original,
ckpt_skipjent_cont150/, ckpt_skipjent_repro110/,
ckpt_skipjent_fixedcore_cont160/.

## STEP 21 — mkelf 84-byte address-skew FIX: rebuilt /init, image patched in place, patched checkpoint copy ready (NO long boot launched) — 30 Oct 2026

Fix for the Step 20 verdict (b). Root cause restated in one line:
rootfs/mkelf.py laid out labels as if the code image started at VA BASE,
but the PT_LOAD has p_offset=0, so the kernel maps file byte F to VA
BASE+F and the image (which sits 84 bytes into the file, after the ELF
header + phdr) actually starts at VA BASE+84. Every li address was
exactly 84 low, and e_entry pointed at the ELF header bytes themselves.

### Fix (rootfs/mkelf.py only; core, firmware, virtio model untouched)
- New constant HDR = 84 (52-byte ehdr + 32-byte phdr), with a comment
  stating the mapping rule: label VA = BASE + file_offset.
- layout() now starts at BASE + HDR instead of BASE, so _start =
  0x10054 and every label VA = 0x10000 + its file offset. Branch/jump
  targets are PC-relative and all labels shifted uniformly, so branch
  encodings are unchanged (verified by the diff classification below).
- build() image offsets are now addr - (BASE+HDR), so the image content
  length is unchanged (3356 bytes).
- PT_LOAD filesz/memsz are now len(image)+HDR = 3440 (the whole file),
  not len(image) = 3356. This matters, not just tidiness: with the old
  filesz, the last 84 image bytes (the tail buffers: cwdbuf ends at file
  offset 0x0d70) sat beyond the declared segment. The old filesz only
  worked by accident of the single-page mapping.
- Step 18 fix KEPT: e_phnum = 1 (byte at file offset 44 unchanged by
  this fix; the header diff below touches only entry + filesz/memsz).
- The print arithmetic bug (len+83) was fixed to len+HDR as a drive-by.

Before/after, auditable:
- BEFORE: _start label 0x10000, banner li 0x1046c, prompt li 0x104a4,
  unk_prefix li 0x104d4, newline li 0x104e8; e_entry 0x10000;
  filesz=memsz=3356.
- AFTER: _start 0x10054, banner li 0x104c0 (= 0x10000 + file 0x4c0),
  prompt li 0x104f8 (= 0x10000 + file 0x4f8), unk_prefix li 0x10528
  (= 0x10000 + file 0x528), newline li 0x1053c (= 0x10000 + file
  0x53c); e_entry 0x10054; filesz=memsz=3440.

### Rebuilt-init verification (python3 rootfs/mkelf.py rootfs/init.asm rootfs/init)
- readelf-equivalent parse: size 3440 bytes (IDENTICAL to the old init
  -- required for the layout-safe in-place patch; a size change would
  have stopped the job), e_entry 0x10054, e_phnum 1, one LOAD, offset
  0, vaddr 0x10000, filesz=memsz=3440.
- Decoded lui+addi pairs in the rebuilt code: all ten checked li
  addresses present at their code sites (banner 0x104c0, prompt
  0x104f8, unk_prefix 0x10528, newline 0x1053c, cmd_help 0x10578,
  cmd_echo 0x10580, cmd_ls 0x10588, cmd_cat 0x1058c, cmd_uname
  0x10590, cmd_pwd 0x10598), each equal to 0x10000 + its target
  string's actual file offset in the rebuilt file; NONE of the old
  skewed VAs (0x1046c, 0x104a4, 0x104d4, 0x104e8) remains.
- Old-vs-new byte diff: exactly 107 bytes -- 3 header bytes (file
  offset 24: entry low byte 0x00->0x54; offset 68: filesz low byte
  0x1c->0x70; offset 72: memsz low byte, same) + 104 code bytes, and
  EVERY differing code word is a lui/addi immediate (no branch, jump,
  or other encoding changed). Strings region (file 0x4c0..end)
  byte-identical. Old init md5 ed1a5dc038e3725d7f83370312e9836c,
  new init md5 3aa10b1a85334d06c5281b77c1334ef3.

### Image patched IN PLACE (no mkfs rebuild)
- debugfs stat BEFORE patch: /init inode 15, size 3440, extents
  (0-1):21-22, block size 1024 -> first data at image offset 21504.
  Backup rootfs/rootfs.img.pre_addrfix (md5
  ae1cc627753f949d2e8965e186418a64, the e_phnum-patched image).
- Gotcha hit and handled: debugfs `write` REFUSES to overwrite
  ("Ext2 file already exists") -- it only creates. So the patch went
  through raw dd, which is safe here for a verified reason: all 107
  differing init bytes lie in file bytes 0..2047 (max diff offset
  1091), and the init tail (2048..3439) is identical all-zero buffers
  in old and new. The tail bytes live in a sparse hole (Blockcount 4
  = 2048 bytes allocated; extents cover only blocks 21-22), which is
  why a naive 3440-byte contiguous write/compare past offset 2048 is
  meaningless -- the Step 18 gotcha, same shape. dd wrote exactly the
  first 2048 bytes at image offset 21504 (bs=1024 seek=21 count=2).
- Verification: debugfs dump of /init from the patched image is
  byte-identical to the rebuilt rootfs/init (md5 3aa10b1a85334d06c5281b77c1334ef3,
  both files). Whole-image diff backup-vs-patched: exactly 107
  bytes, all in image offsets 21504..23552 (21528..22595). New image
  md5 e60dd5b5ed752d26c93203567e00ab83.
- debugfs stat AFTER patch: inode 15, size 3440, extents (0-1):21-22
  -- inode, size, and block layout UNCHANGED, as required for the
  checkpoint recipe below.

### Disk hex regenerated
python3 tools/img2hex.py rootfs/rootfs.img soc2_hex/rootfs_disk.hex
(1,048,576 bytes -> 262,144 words). Diff old-vs-new hex: exactly 55
lines, all within /init's word lines 5377..5888 (image bytes
21504..23551 / 4). New hex md5 b5a422558856e4fa517e3542ed13d001.
(The 107 changed bytes collapse to 55 words; some words hold two
changed bytes.)

### Checkpoint copy for the next boot (ckpt_addrfix/)
- Built as a full copy of ckpt_ephnum_fixed/ (the e_phnum-patched
  210M set -- NOT the unpatched 210M original in
  ckpt_skipjent_fixedcore_cont210/).
- .disk line-to-byte mapping re-verified empirically on the current
  set before patching: 1,114,112 lines = 65,536 "// 0x..." comment
  lines (gap 17) + 1,048,576 byte lines; payload byte 21504 -> line
  22850 = '7f' (ELF magic); payload byte 21548 -> line 22896 = '01'
  (the e_phnum fix, confirming this is the patched set). Stripped
  payload of the original 210M .disk is byte-identical to the
  pre-addrfix image (md5 ae1cc627753f949d2e8965e186418a64).
- In the copy, ONLY ckpt_210000000.disk was rewritten: comment lines
  preserved exactly, byte lines replaced from the NEW patched image.
  Copy-vs-original diff over all files: ONLY that one .disk (214
  diff lines = 107 changed bytes x < and >). The copy's 210M .disk
  payload is now byte-identical to the NEW patched image (md5
  e60dd5b5ed752d26c93203567e00ab83). Line count preserved.
- Originals verified UNTOUCHED after the job: ckpt_ephnum_fixed/
  210M .hdr md5 10480f7d8ddcded09abf3a1832099bb8, .ram md5
  938293f594dc69ce6dcf478055228673, .disk md5
  15e7c28c1768129dd10fcec0ef884d97 (all identical to pre-job
  values); unpatched 210M original .disk md5
  9c24caf9b26e025a03c950899e6d4358 unchanged.
- Rationale, with its verification: at 210M the kernel has mounted
  root but has NOT exec'd /init yet (Run /init comes at ~219M), so
  replacing the disk image under a mounted-but-not-yet-exec'd root
  is safe PROVIDED /init's inode, size, and block layout are
  unchanged -- verified above (inode 15, size 3440, extents 21-22,
  before and after). The kernel will read /init's (unchanged) inode
  at exec time and get the NEW bytes.

### Resume recipe for the next boot (not launched here)
Resume from ckpt_addrfix/'s 210M set under the fixed core + fixed
virtio model, with soc2_hex/rootfs_disk.hex (the regenerated hex;
the checkpoint .disk overlay is what actually matters on resume, per
the Step 18 subtlety -- do_resume() $readmemh's the checkpoint .disk
OVER the initial DISKHEX load), explicit cycle cap, RX re-armed via
the header-copy trick (copy ckpt_addrfix/ to the run dir and change
ONLY rx2idx/rx2next header lines there, so ckpt_addrfix/ stays
pristine; the RX2START plusarg is ineffective on resume). Then judge,
in order: init banner, clean big32# prompt, RX command OUTPUTS (not
echo). Do NOT resume from 230M for the fixed boot -- its RAM holds
the OLD init. Skip-jent configuration only; full-config grind from
ckpt_cont160/ (170M) remains open and separate. Nothing pushed;
core, firmware, virtio model untouched by this job. Secondary note
from Step 20 stands: the probe's one dropped banner-tail comma at a
16-byte burst boundary is worth one directed check AFTER the fix
lands in a real boot, not before.

## STEP 22 — addrfix boot 210M→230M: CLEAN BANNER, CLEAN PROMPT, REAL COMMAND OUTPUTS — strict success MET (run killed mid-segment-2 by an external kill, after the verdict was already in the log) — 30 Oct 2026

Resume from ckpt_addrfix/'s 210M set (Step 21 recipe) under the
fixed core + fixed virtio model (tb_kboot_ckpt.vvp built 30 Oct
14:42 UTC from the drain-fixed sources, soc2.v 14:26 UTC, fix
line src/big32_soc2.v:850), regenerated soc2_hex/rootfs_disk.hex
(md5 b5a422558856e4fa517e3542ed13d001). Run copy
ckpt_addrfix_run/ = copy of ckpt_addrfix/ with ONLY 210M header
lines 2-3 changed (rx2idx 50->0, rx2next 209100000->225000000);
diff verified to show exactly those two lines, RAM md5
identical, .disk md5 identical. RX feed (rootfs/rx_cmds.txt:
echo hello from big32, ls, uname, cat /hello.txt, pwd) armed
at 225M: Run /init lands at ~219M and the banner + prompt
follow immediately, so the shell is waiting well before
225M, with 5M cycles of margin to the cap. Runner:
tools/run_addrfix_cont230.sh. Log:
kernel/boot_attempt18_skipjent_fixedcore_cont230_addrfix.log
(NEW file; all earlier logs untouched).

### Segment 1: 210M→220M (17:05:10Z→17:30:50Z, clean)
- [   19.735295] devtmpfs: mounted
- [   19.998534] Freeing unused kernel image (initmem) memory: 4152K
- [   20.009314] Run /init as init process
- NO panic, NO -8: the patched disk took effect on resume.
  A re-panic with -8 would have meant the patch did not take
  effect; it did not happen.
- Banner, CLEAN and COMPLETE (log line 7, with the leading
  blank line from init's puts):
  "big32 init: userspace is up (PID 1, RV32I, no libc)"
  No garbled tail, no fused suffix, no code bytes: the
  84-byte skew fix has landed in a real boot.
- Step 20 comma check: PRESENT, not dropped. Both banner-tail
  commas are there ("PID 1, RV32I, no libc"). The probe's one
  dropped comma at a 16-byte burst boundary did not recur.
- Clean prompt "big32# " and real command outputs -- but
  from STALE input bytes already sitting in the restored
  UART/tty buffer, not from the armed feed (which fires at
  225M, in segment 2): "unknown command: ho" (first word of
  the stale first line arrived with its first two bytes
  missing -- the standing stale-bytes caveat, exactly as
  warned), "ls: cannot open directory", "Linux 6.6.52
  riscv32" (uname), both /hello.txt lines (cat), "/" (pwd).
  Dispatch works: the old shape (every command falling to
  the unknown handler) is gone.

### Segment 2: 220M→230M -- clean-feed verdict, then an external kill
- The 225M feed fired and the tty echoed all five fed lines
  (log line 22 onward: "echo hello from big32", "ls",
  "uname", "cat /hello.txt", "pwd"). Judge OUTPUT, not echo
  -- and the outputs are clean:
  - echo -> "hello from big32" (log line 27)
  - ls -> "ls: cannot open directory" (line 28) -- AGAIN,
    on a clean line. The segment-1 ls failure is NOT a
    stale-input artifact; it is a real, minor userspace
    blemish (init's ls opens "." via openat(AT_FDCWD);
    whether PID 1's cwd is not "/" or the open itself
    fails is NOT established here -- named, not diagnosed).
  - uname -> "Linux 6.6.52 riscv32" (line 29)
  - cat /hello.txt -> "Hello from the big32 root filesystem."
    + "This file lives on the virtio disk, mounted as / by
    Linux 6.6.52." (lines 30-31)
  - pwd -> "/" (line 32), then a clean trailing "big32# "
    prompt (line 33): the shell is waiting for more input.
- Segment 2 was then KILLED mid-flight before the 230M cap:
  at 17:50 UTC no runner or vvp process remained, and the
  waiting watcher process had itself been SIGTERMed at
  ~17:47 UTC. The pattern (both sim processes gone,
  filesystem intact) is consistent with a VM restart, which
  has repeatedly killed sims before -- stated as consistent,
  not proven. This is NOT a sim failure: the log already
  held the full verdict before the kill. NO 230M checkpoint
  was banked; the 220M set in ckpt_addrfix_run/ is complete
  (.done present). ckpt_addrfix/ itself verified pristine
  after the run (210M header 210000000/50/209100000, RAM
  md5 938293f594dc69ce6dcf478055228673, both unchanged).
- Whole-log grep: ZERO "Kernel panic", ZERO "Oops", ZERO
  -8 lines.

### Verdict: STRICT SUCCESS, with one named blemish
Success criterion met: init running (clean banner) + CLEAN
"big32# " prompt + real RX command outputs (echo, uname,
cat, pwd -- all clean, all from the armed 225M feed, not
just the stale bytes). This is the first clean userspace
on big32: a from-scratch RV32 CPU running real Linux
6.6.52 to a working shell on its own virtio disk.
Blemish, not a blocker: `ls` fails with "cannot open
directory" on a clean line -- the one remaining userspace
item, worth one targeted look (cwd vs openat), but it does
not touch the verdict: four of five commands produce
correct output and the shell is alive at the prompt.
Skip-jent configuration only; full-config grind from
ckpt_cont160/ (170M) remains open and separate. Nothing
pushed; core, firmware, virtio model, mkelf/init untouched
by this job.

## STEP 23 — `ls` failure diagnosed (parse leaves s1 = command word), one-word fix, checkpoint copies ready (fix NOT yet boot-proven) — 30 Oct 2026

### Diagnosis (code first, then probe)

Step 22's one blemish: bare `ls` fails with "ls: cannot open
directory" in both segments. The error string fires ONLY at
ls_fail, which is reached ONLY from openat's `blt a0, zero`
in do_ls (rootfs/init.asm) -- so openat itself returned
negative; getdents64 is never reached. `li a0, -100`
(AT_FDCWD) is correctly encoded (addi a0, zero, -100 =
0xF9C00513, present at both do_ls and do_cat in the rebuilt
binary), openat is syscall 56, flags 0 (O_RDONLY), and pwd
printed "/" in Step 22 -- so cwd is "/" and the directory
open path itself is not suspect. The suspect is the PATH
argument, s1.

Root cause, read from parse: the shell splits the first word
from its args by scanning for a space; `li s1, linebuf` is
set at parse start, and split_loop's no-space exit (`beq t1,
zero, dispatch`) leaves s1 = linebuf. So for a line with NO
space, s1 points at the COMMAND WORD, not at an empty
argument. do_ls then does `lbu t1, 0(s1)` -- for bare `ls`
that reads 'l' (nonzero) -- so it skips the `li s1, dot`
default and calls openat(AT_FDCWD, "ls", 0): there is no
file named "ls" in / -> ENOENT -> ls_fail. The same latent
pattern sits in do_cat (bare `cat` would open "cat") and
do_echo (bare `echo` would print "echo"); only ls was fixed
here, the rest are noted as follow-up, not silently changed.

### Discriminating probe (from a copy of the intact 220M set)

Probe 1b: resumed from a copy of ckpt_addrfix_run/'s 220M
set (original untouched), header rx2next 225M -> 221M only,
fed (hex-per-line RX2FILE format, as the testbench's
$fscanf "%h" requires) `ls /`, `ls`, `pwd`, cap 223M. Log
kernel/ls_probe1b.log, runner tools/run_lsprobe.sh, probe
dir work/lsprobe/ (223M checkpoint banked there, scratch).
Result, exactly as the code predicted:
  `ls /` -> hello.txt, dev, sys, .., lost+found, init, proc, .
  bare `ls` -> "ls: cannot open directory"
  `pwd` -> "/"
So openat + getdents64 on directories WORK, cwd IS "/", and
only the no-argument path fails. Diagnosis closed.

Probe gotcha, recorded: the first probe launch fed a RAW
text RX file; the testbench parses RX2FILE as one hex byte
per line, so it read zero bytes and the shell sat in read()
with no output for 20+ minutes (sim alive at 93% CPU). The
run was killed, the file rewritten in hex-per-line format
(6c 73 20 2f 0a ...), and the probe re-run clean. Second
gotcha in the same job: a pkill pattern containing the
testbench filename self-matched the exec shell's own
command line and SIGTERMed it -- never pkill a pattern that
appears in your own command line.

### Fix (rootfs/init.asm only; mkelf.py untouched)

One instruction word changed in do_ls: the no-argument test
is now a pointer comparison instead of a byte test:
  old: bne t1, zero, ls_open   (t1 = *s1; 'l' for bare ls)
  new: bne s1, s0, ls_open     (s0 = linebuf, set once at
       _start and never reassigned; puts/streq clobber only
       a0-a2,t0-t2, so s0 == linebuf still holds at do_ls)
s1 == s0 holds exactly when parse found no space, i.e. no
argument; then control falls through to `li s1, dot` as
before. The old lbu line is retained, harmless (reads a
valid byte, no side effect), so the binary layout is
byte-identical in size. Step 18 (e_phnum=1) and Step 21
(HDR=84, entry 0x10054, filesz/memsz=3440) fixes intact.

File-level verification of the rebuilt rootfs/init:
- Size 3440 bytes, IDENTICAL to the old init (required for
  the layout-safe in-place patch).
- Old-vs-new diff: EXACTLY ONE word, file offset 0x2ec:
  0x00031663 -> 0x000849663, i.e. bne t1(6), zero(0), +12
  -> bne s1(9), s0(8), +12, same target ls_open = 0x102f8
  (decoded programmatically from both words, not by hand).
- Header: entry 0x10054, e_phnum 1, one LOAD, offset 0,
  vaddr 0x10000, filesz = memsz = 3440. dot label
  0x1059c = 0x10000 + file offset 0x59c, bytes ".\0".
- New init md5 e1a108e766449da56c3be43208ce81f9 (old
  3aa10b1a85334d06c5281b77c1334ef3).

Image patch (in place, NO mkfs rebuild): /init inode 15,
size 3440, extents 21-22, first data at image offset 21504
(re-verified by debugfs stat before patching). Backup kept:
rootfs/rootfs.img.pre_lsfix (md5 e60dd5b5...). The two
differing init bytes (file 0x2ed, 0x2ee) were written at
image offsets 22253, 22254. Whole-image diff backup-vs-
patched: EXACTLY those two bytes. New image md5
c7f34183f1bc64555b36e8789f9d2bc9. Verification: debugfs
dump of /init from the patched image is byte-identical to
the rebuilt init (md5 e1a108e7...); stat after patch:
inode 15, size 3440, extents 21-22 -- UNCHANGED. Disk hex
regenerated (tools/img2hex.py): diff is exactly ONE line,
line 5564, 00031663 -> 00849663. New hex md5
a4cc0b4d497384391e778f22fce9bf72.

### Checkpoint copies -- and a CORRECTION to the 220M rationale

Two copies were built (comment lines preserved exactly in
both .disk rewrites; both payloads verified by md5):
- ckpt_lsfix/ from ckpt_addrfix_run/'s 220M set, .disk
  payload = new image (md5 c7f34183...). Originals
  verified untouched (all six 220M files md5 OK).
- ckpt_lsfix210/ from ckpt_addrfix/'s 210M set, .disk
  payload = new image (md5 c7f34183...). Originals
  verified untouched (all six 210M files md5 OK); its
  210M header still carries rx2idx=50, rx2next=209100000
  for the next boot's runner to re-arm by header copy.

CORRECTION (important): the 220M-based copy CANNOT test
this fix, despite the "live shell resumes and immediately
tests ls" rationale. At 220M PID 1 is already exec'd and
running: its text pages -- including the do_ls branch at
0x102ec, which executed (and failed) in Steps 22/23 -- are
resident in RAM. Replacing the .disk changes only future
file reads; the running shell keeps executing OLD code.
A resume from ckpt_lsfix/ would still print "cannot open
directory" and would prove nothing about the fix. The
CORRECT next-boot resume point is ckpt_lsfix210/: at 210M
the kernel has mounted root but has NOT exec'd /init yet
(Run /init comes at ~219M), so exec reads the new bytes
through the unchanged inode -- the same Step 21 argument,
which held. Do NOT use ckpt_lsfix/ as the ls-test resume
point.

### Status and exact next step (not launched)

Fix is FILE-PROVEN (one-word diff, correct target, size
and layout identical, image + hex + both checkpoint
copies verified) but NOT BOOT-PROVEN: no run yet shows
bare `ls` listing a directory, and none is claimed here.
Next boot (user's call): resume from ckpt_lsfix210/'s
210M set under the fixed core + fixed virtio model, with
the regenerated soc2_hex/rootfs_disk.hex, explicit cap,
RX re-armed via the header-copy trick (copy ckpt_lsfix210/
to the run dir and change ONLY rx2idx/rx2next header
lines there, so ckpt_lsfix210/ stays pristine). Judge, in
order: clean banner, clean big32# prompt, bare `ls`
listing the root directory (hello.txt, dev, sys, proc,
init, lost+found, ., ..) with NO "cannot open directory"
line. Kernel-side cause ruled out by the probe (ls /
works); no kernel fix was attempted or is needed.
Skip-jent configuration only; full-config grind from
ckpt_cont160/ (170M) remains open and separate. Nothing
pushed; core, firmware, virtio model untouched by this job.

## STEP 24 -- ls proof boot 210M->230M from ckpt_lsfix210/: BARE `ls` LISTS THE ROOT -- fix BOOT-PROVEN -- 30-31 Oct 2026

Pre-flight (all verified before running, not assumed):
- ckpt_lsfix210/'s 210M .disk payload md5 = patched image md5
  c7f34183...; payload byte 21504 = 7f (ELF magic), byte 21548
  = 0x01 (e_phnum fix present); soc2_hex/rootfs_disk.hex md5 =
  a4cc0b4d... (the lsfix hex); testbench sim/tb_kboot_ckpt.vvp
  built 30 Oct 14:42 UTC from the drain-fixed sources (soc2.v
  14:26 UTC; fix line src/big32_soc2.v:850).
- Run copy ckpt_lsfix_run/ differed from pristine ckpt_lsfix210/
  by ONLY the 210M header lines 2-3 (rx2idx 50->0, rx2next
  209100000->225000000); RAM md5 identical. ckpt_lsfix210/
  verified pristine after the run (header still
  210000000/50/209100000; .disk payload md5 still c7f34183...).

Run: tools/run_lsfix_cont230.sh, log
kernel/boot_attempt18_skipjent_fixedcore_cont230_lsfix.log,
progress kernel/skipjent_fixedcore_cont230_lsfix_progress.log.
Two explicit-cap segments, never uncapped loop mode. Feed
(hex-per-line, as the testbench's $fscanf "%h" requires)
armed at 225M: bare `ls`, then `pwd` and `cat /hello.txt`
as controls.

Segment 1, 210M->220M (18:38:35Z->19:01:12Z, clean):
  [   19.735295] devtmpfs: mounted
  [   19.998534] Freeing unused kernel image (initmem) memory: 4152K
  [   20.009314] Run /init as init process
  big32 init: userspace is up (PID 1, RV32I, no libc)
  big32# unknown command: ho
  big32# hello.txt
  dev
  sys
  ..
  lost+found
  init
  proc
  .
  big32# Linux 6.6.52 riscv32
  big32# Hello from the big32 root filesystem.
  This file lives on the virtio disk, mounted as / by Linux 6.6.52.
  big32# /
The stale line-buffer turns already prove the fix: the
truncated first stale word fails as "unknown command: ho"
(as before), then the stale bare `ls` lists the root --
NO "cannot open directory" -- followed by the stale uname,
cat, and pwd outputs, all correct.

Segment 2, 220M->230M -- the clean-feed verdict, in order:
  ls            (echo)
  pwd           (echo)
  cat /hello.txt (echo)
  hello.txt
  dev
  sys
  ..
  lost+found
  init
  proc
  .
  big32# /
  big32# Hello from the big32 root filesystem.
  This file lives on the virtio disk, mounted as / by Linux 6.6.52.
Bare `ls` from the clean 225M feed lists the root directory;
pwd and cat controls both pass. Whole-log grep: ZERO
"cannot open directory", ZERO "Kernel panic", ZERO "Oops";
11 prompt lines; footers CYCLES: 220000000 then
CYCLES: 230000000, both HALTED: 0. The 230M header confirms
all 22 feed bytes consumed (rx2idx=22, rx2next=225044000).

Incident (environment, not kernel): segment 2 was killed
mid-flight by a VM restart (uptime 1 min at 19:15:42Z; log
last written 19:13:37Z; no runner or vvp process remained)
-- the same pattern as Step 22's segment-2 kill. The verdict
was already in the log before the kill. Recovery: the runner
was re-run; it resumed from the intact 220M set (its
220M-target pass made no progress and retried 3x, harmless,
then ran 220M->230M), replaying the 225M feed
deterministically with the same listing, and banked the
230M checkpoint (ckpt_lsfix_run/ckpt_230000000.done,
19:40:42Z "230M cap reached"). The 225M-feed outputs
therefore appear twice in the log (pre-kill and replay);
both copies are identical.

Verdict: the Step 23 one-word do_ls fix is BOOT-PROVEN.
The shell's five commands all work now: echo, ls, uname,
cat, pwd. The same latent no-arg pattern in do_cat and
do_echo remains NOT fixed (follow-up, not silently changed).
Nothing pushed; core, firmware, virtio model, mkelf/init
untouched by this job. Skip-jent configuration only;
full-config grind from ckpt_cont160/ (170M) remains open
and separate.

## STEP 25 -- do_cat / do_echo no-argument quirk: diagnosed, fixed at
## file level, checkpoint copy ready. NOT boot-proven -- 1 Nov 2026
## (BOOT-PROVEN by Step 26, 6 Nov 2026 -- see below; this step's text otherwise unchanged)

Step 23 left a note, deliberately not silently changed then: the
same latent no-arg pattern sat in do_cat and do_echo. This step
fixes both, the same way, at file level only. No long boot, no
push, no core/firmware/virtio change.

Diagnosis (code evidence; no probe run -- the code is conclusive,
and a probe from the 230M set could only confirm current buggy
behaviour, not test a fix, since its RAM holds the current code):
parse leaves s1 = linebuf (s0) when a line has no space, and
dispatch preserves s1 (puts/streq clobber a0-a2,t0-t1 only).
- do_cat: `lbu t1, 0(s1); beq t1, zero, cat_missing`. Bare `cat`
  has *s1 = 'c' (nonzero), so it skips cat_missing and calls
  openat(AT_FDCWD, "cat", 0) -- no file named "cat" in / -->
  ENOENT --> cat_fail prints "cat: cat: cannot open". The Step 23
  claim holds for cat exactly.
- do_echo: `mv a1, s1; jal puts; li a1, newline; jal puts`.
  Bare `echo` has s1 = linebuf = "echo", so it prints "echo"
  followed by a newline. The Step 23 claim holds for echo exactly.
Chosen behaviour (stated, not assumed): bare `cat` prints the
usage line "cat: missing file" (cat_usage already existed, only
reachable on an empty-string arg before); bare `echo` prints just
a newline. Neither opens/prints the command word.

Fix (rootfs/init.asm only; mkelf.py untouched; Step 18 e_phnum=1,
Step 21 HDR, Step 23 do_ls fixes intact):
- do_echo: insert `beq s1, s0, echo_nl` before `mv a1, s1`, and
  tag the newline li as echo_nl. Bare echo branches straight to
  the newline print. Trailing-space `echo ` also yields just a
  newline (skip_spaces leaves s1 on the NUL, so puts prints empty).
- do_cat: replace `lbu t1, 0(s1); beq t1, zero, cat_missing`
  with single `beq s1, s0, cat_missing`. The old lbu is dropped,
  not retained: its value was dead (cat_read overwrites t1 with
  the read count before any read, cat_fail only calls puts), and
  dropping it exactly offsets the extra word added in do_echo,
  keeping the rebuilt init at 3440 bytes. Trailing-space `cat `
  still reaches cat_fail with an empty path, i.e. an error line,
  not the usage line -- same as the Step 23 do_ls behaviour for
  trailing-space `ls `.

File-level verification (rootfs/init rebuilt from rootfs/init.asm):
- Baseline first: reassembling the saved lsfix init.asm with the
  current mkelf reproduces the lsfix binary byte-identically
  (md5 e1a108e766449da56c3be43208ce81f9) -- toolchain
  deterministic, baseline solid.
- Size 3440 bytes, IDENTICAL to the lsfix init (required for the
  layout-safe in-place patch). New md5 1c8759bc5e4eb190ad2b099d5f498c61.
- Header: entry 0x10054, e_phnum 1, one LOAD, offset 0, vaddr
  0x10000, filesz = memsz = 3440 (0xd70).
- Strongest check, not a byte count: the two edits were applied
  to the old item list (insert beq at do_echo, replace lbu+beq
  at do_cat, tag echo_nl), re-laid-out and re-encoded with the
  new labels -- the synthetic image is byte-identical to the new
  binary image. So the new binary is the old binary plus exactly
  these two edits (plus automatic branch/jump offset recompute).
  Label check matches the mechanism: only do_uname..do_cat shift
  +4 (the echo insertion, before the cat deletion restores net
  zero); all data labels identical.
- Decoded edited words from the new binary: do_echo first word
  beq s1(9), s0(8) -> echo_nl 0x1023c; do_cat first word beq
  s1(9), s0(8) -> cat_missing 0x10418. (An early decode attempt
  read the wrong file offset -- VA - BASE is the file offset
  per the Step 21 rule, not 84 + (VA - BASE) -- and was corrected
  before any claim was made.)
- Old-vs-new init diff: 334 file bytes, offsets 0x1a5..0x386,
  all < 2048 -- the shifted window (dispatch branches to shifted
  targets, echo/cat edits, offset recompute), covered by the
  synthetic proof above, not by the byte count.

Image patch (in place, NO mkfs rebuild): /init inode 15, size
3440, extents 21-22, first data at image offset 21504
(re-verified before patching). Backup kept:
rootfs/rootfs.img.pre_catecho_fix (md5 c7f34183f1bc64555b36e8789f9d2bc9,
the lsfix image). dd wrote the first 2048 bytes of the new init
at 21504 (all 334 differing init bytes lie < 2048; the tail is
identical all-zero buffers in a sparse hole, Blockcount 4).
Verification: debugfs dump of /init from the patched image is
byte-identical to the rebuilt init (md5 1c8759bc...); stat after
patch: inode 15, size 3440, extents 21-22 -- unchanged;
whole-image diff is exactly those 334 bytes, and image diff
offsets == 21504 + init-file diff offsets. New image md5
c073ba7f766976b265d6b0057edb8d6f.
Disk hex regenerated (tools/img2hex.py, 1048576 bytes ->
262144 words): positional diff is 90 lines, lines 5482..5602,
all within /init's word lines 5377..5888; hex-vs-image check
is 0 mismatches over all 262144 words (the plain diff tool
reported fewer lines by realigning repeated words -- the
positional check is authoritative). New hex md5
f51454d4487a12f9f64b4bc5836cc81f.

Checkpoint-copy recipe for the next boot:
- New copy ckpt_catecho210/ built from ckpt_lsfix210/'s 210M set
  (the pre-exec point -- NOT from any 220M/230M set, whose RAM
  holds old code, by the Step 23 argument). .disk mapping
  re-verified empirically first: 1114112 lines = 65536 comment
  lines (gap 17) + 1048576 byte lines; payload byte 21504 ->
  raw line 22850 = 7f (ELF magic); byte 21548 -> raw line 22896
  = 01 (the e_phnum fix, still present); stripped payload of
  the original = lsfix image md5 c7f34183....
- In the copy, ONLY ckpt_210000000.disk was rewritten (comment
  lines preserved exactly, byte lines replaced from the new
  image). The copy's 210M .disk payload is byte-identical to
  the new patched image (md5 c073ba7f...). Copy-vs-original
  diff: only that one .disk. Originals verified untouched (all
  six 210M files md5 OK). Copy header: 210000000 / 50 /
  209100000 (pre-exec, RX state as banked).
- Safety rationale, same Step 21/23 argument, which held: at
  210M the kernel has mounted root but has NOT exec'd /init yet
  (Run /init comes at ~219M), so exec reads the new bytes
  through the unchanged inode (inode, size, block layout all
  verified unchanged above).

Status: fix is FILE-PROVEN (two-edit synthetic proof, size and
layout identical, image + hex + checkpoint copy verified) but
NOT boot-proven: no run yet shows bare `cat` printing usage or
bare `echo` printing just a newline, and none is claimed here.
Next boot (user's call): resume from ckpt_catecho210/'s 210M set
under the fixed core + fixed virtio model, with the regenerated
soc2_hex/rootfs_disk.hex, explicit cap, RX re-armed via the
header-copy trick (copy ckpt_catecho210/ to the run dir and
change ONLY rx2idx/rx2next header lines there, so
ckpt_catecho210/ stays pristine). Judge, in order: clean banner,
clean `big32# ` prompt, bare `cat` -> "cat: missing file",
bare `echo` -> a bare newline, plus controls (`echo hello`,
`cat /hello.txt`) still working. Do NOT resume from ckpt_lsfix/
(220M, old code resident), ckpt_lsfix_run/ (230M, old code
resident), the Step 17 220M panic-loop checkpoint, the
unpatched 210M original, ckpt_skipjent_cont150/,
ckpt_skipjent_repro110/, or ckpt_skipjent_fixedcore_cont160/.
Skip-jent configuration only; full-config grind from
ckpt_cont160/ (170M) remains open and separate.

## STEP 26 -- cat/echo no-arg fix BOOT-PROVEN (Step 25 file fix, boot proof) -- 6 Nov 2026

Pre-flight (all verified before running, not assumed):
- ckpt_catecho210/'s 210M .disk payload md5 = patched image md5
  c073ba7f766976b265d6b0057edb8d6f (1,048,576 payload bytes, payload
  == rootfs/rootfs.img byte-identically); payload byte 21504 =
  0x7f (ELF magic), byte 21548 = 0x01 (e_phnum fix present);
  rootfs/init md5 = 1c8759bc5e4eb190ad2b099d5f498c61 (3440 bytes);
  soc2_hex/rootfs_disk.hex md5 = f51454d4487a12f9f64b4bc5836cc81f;
  testbench sim/tb_kboot_ckpt.vvp built 30 Oct 14:42 UTC from
  the drain-fixed sources (src/big32_soc2.v 14:26 UTC; fix line
  src/big32_soc2.v:850). DTB
  soc2_hex/big32_kboot_10mhz_rootfs_skipjent.dtb.txt and kernel
  linux-6.6.52/arch/riscv/boot/Image present. No vvp sim running
  at launch (ps clean).
- Run copy ckpt_catecho_run/ differed from pristine
  ckpt_catecho210/ by ONLY the 210M header lines 2-3 (rx2idx
  50->0, rx2next 209100000->225000000); RAM md5 identical
  (938293f594dc69ce6dcf478055228673). ckpt_catecho210/ verified
  pristine after the run (all six 210M md5s identical to
  pre-flight: disk 9da95d3b..., done 2a1ae8ed..., hdr 10480f7d...,
  pix ecf1850c..., ram 938293f5..., vram 51860758...).

Run: tools/run_catecho_cont230.sh (minimal adaptation of the
Step 24 runner: same ensure_vvp logic, same vvp args, RX file
rootfs/rx_catecho.txt), log
kernel/boot_attempt18_skipjent_fixedcore_cont230_catecho.log,
progress kernel/skipjent_fixedcore_cont230_catecho_progress.log.
Two explicit-cap segments, never uncapped loop mode. Feed
(hex-per-line, as the testbench's $fscanf "%h" requires)
armed at 225M: bare `cat`, bare `echo`, then `echo hello`
and `cat /hello.txt` as controls (35 bytes total).

Segment 1, 210M->220M (17:14:40Z->17:42:36Z, clean):
  [   19.735295] devtmpfs: mounted
  [   19.998534] Freeing unused kernel image (initmem) memory: 4152K
  [   20.009314] Run /init as init process
  big32 init: userspace is up (PID 1, RV32I, no libc)
  big32# unknown command: ho
  big32# hello.txt
  dev
  sys
  ..
  lost+found
  init
  proc
  .
  big32# Linux 6.6.52 riscv32
  big32# Hello from the big32 root filesystem.
  This file lives on the virtio disk, mounted as / by Linux 6.6.52.
  big32# /
The stale line-buffer turns, identical to Step 24's, prove
nothing about the new fix (they are the old feed replaying
from the checkpoint's RX state); they are recorded here only
to show segment 1 reached the prompt cleanly, as before.

Segment 2, 220M->230M -- the clean-feed verdict, in order:
  cat             (echo)
  echo            (echo)
  echo hello      (echo)
  cat /hello.txt  (echo)
  cat: missing file
  big32#
  big32# hello
  big32# Hello from the big32 root filesystem.
  This file lives on the virtio disk, mounted as / by Linux 6.6.52.
  big32#
Bare `cat` from the clean 225M feed prints exactly
"cat: missing file" -- the usage line, not "cat: cat: cannot
open". Bare `echo` prints just a newline -- no "echo" appears
as shell output anywhere in the log (the only "echo" lines
are the RX echoes of the feed itself) -- and the next prompt
follows on the next line. Controls both pass: `echo hello`
-> "hello", `cat /hello.txt` -> the two-line hello file.
Whole-log grep: ZERO "cannot open directory", ZERO "Kernel
panic", ZERO "Oops", ZERO "cat: cat: cannot open"; 10 prompt
lines; footers CYCLES: 220000000 then CYCLES: 230000000, both
HALTED: 0. The 230M header confirms all 35 feed bytes
consumed (rx2idx=35, rx2next=225070000 = 225000000 + 35*2000).
230M checkpoint banked (ckpt_catecho_run/ckpt_230000000.done,
18:13:01Z "230M cap reached").

Incident: none. Both segments ran clean first try, no
retries, no VM-restart kill (unlike Step 24's segment 2).
Runner exit 0 after ~58 minutes (17:14:40Z->18:13:01Z).

Verdict: the Step 25 do_cat / do_echo no-arg fix is
BOOT-PROVEN. Step 25 is therefore no longer file-proven
only. The shell's five commands all work now, including
bare `cat` and bare `echo` behaving as chosen in Step 25.
Nothing pushed; core, firmware, virtio model, mkelf/init
untouched by this job. Skip-jent configuration only;
full-config grind from ckpt_cont160/ (170M) remains open
and separate.

## STEP 27 -- full-config grind 170M->220M from ckpt_cont170_run/: 220M CAP REACHED, jent STILL GRINDING -- PARTIAL, no new UART lines -- 8 Nov 2026

Pre-flight (all verified before running, not assumed):
- ckpt_cont170_run/ is a copy of the banked ckpt_cont160/
  170M set whose ONLY change is its .disk: rewritten from
  the current patched rootfs image (md5
  c073ba7f766976b265d6b0057edb8d6f) because the banked 170M
  .disk payload is the PRE-ephnum-fix image (md5
  643e7c5f..., e_phnum byte 0x00) -- as-is, /init would
  ENOEXEC and no prompt could ever be judged even if jent
  finishes. (Runner header, tools/run_cont170_220.sh.)
- Smoke test 05:49:40Z: resume 170M -> 170.5M in a scratch
  copy, CKPT 170500000 .done, HALTED 0, exit 0, ~194s wall
  for 0.5M cycles (~65 min per 10M at this rate, ~2x slower
  than the 27 min/10M of cont160 -- VM load; 50M grind ~5h
  wall, restart-safe via 10M checkpoints). REGS differ
  substantially from the 170M footer -- state moves.
  Scratch copy deleted.
- Full-config DTB (NOT skipjent):
  soc2_hex/big32_kboot_10mhz_rootfs.dtb.txt; testbench
  sim/tb_kboot_ckpt.vvp built 30 Oct 14:42 UTC from the
  drain-fixed sources (src/big32_soc2.v 14:26 UTC; fix line
  src/big32_soc2.v:850). Header untouched: rx2idx=50,
  rx2next=150100000 -- the attempt-17 feed
  rootfs/rx_cmds.txt is fully consumed, so no re-feed;
  judge prompt/banner/serial/virtio/root-mount only (any
  command output after a prompt would be stale-FIFO
  artefact, NOT clean evidence).
- Post-run verification (this check): 200M, 210M and 220M
  .disk payload md5s all = c073ba7f... (1,048,576 payload
  bytes each); payload byte 21504 = 0x7f (ELF magic), byte
  21548 = 0x01 (e_phnum fix present) in all three.

Run: tools/run_cont170_220.sh, log
kernel/boot_attempt17_cont170_220.log, progress
kernel/cont170_220_progress.log. Five explicit-cap 10M
segments, never uncapped loop mode. Stops early on HALTED,
kernel panic, or prompt + command output.

Segment 1, 170M->180M (05:49:43Z->06:20:54Z, 31m11s, clean).
Segment 2, 180M->190M (06:20:54Z->06:47:09Z, 26m15s, clean).
Segment 3, 190M->200M (06:47:09Z->07:13:41Z, 26m32s, clean).
Each segment footer CYCLES: <target>, HALTED: 0; "latest
UART lines:" empty after every segment -- no new UART
output at any checkpoint.

Incident 1 -- VM reboot ~07:14Z (12:44 IST): segment 4
(200M->210M) had just been armed when the runner died; no
runner or vvp process remained. Recovery: this job
relaunched the runner 07:51:17Z; it resumed from the
intact 200M checkpoint.
Incident 2 -- runner death ~07:55Z (13:25 IST, cause
unknown): the 07:51:17Z relaunch was itself killed
mid-retry-loop. Recovery: relaunched again 07:56:39Z;
resumed from the intact 200M checkpoint.
Retry-loop quirk (runner, not kernel): after each restart
the runner walks its fixed target list [180,190,200,210,
220] from the latest checkpoint, so targets already passed
(180M/190M/200M) each "complete" instantly with no
progress and burn 3 retries (~50s each) before the runner
moves on -- ~4.5 min wasted in restart #1, ~7.5 min in
restart #2 (07:56:39Z->08:04:12Z). Harmless, but a restart
after passing a target always pays it. Fourteen
CYCLES: 200000000 footers in the log are these no-progress
passes, not real segments.

Segment 4, 200M->210M (08:04:12Z->08:38:05Z, 33m53s, clean).
Segment 5, 210M->220M (08:38:05Z->09:15:08Z, 37m03s, clean).
220M checkpoint banked (ckpt_cont170_run/ckpt_220000000.done,
09:15:08Z "cont170_220 complete: 220M cap reached"); runner
exit 0. Total wall 05:49:43Z->09:15:08Z = 3h25m25s. A third
VM restart landed ~09:15Z, just after the run completed
(uptime 36 min at 09:51:55Z); no relaunch needed, the run
was already finished.

Whole-log grep: ZERO "Kernel panic", ZERO "HALTED: 1",
ZERO "big32# ", ZERO "[ " kernel-timestamp lines; 1x
CYCLES: 220000000 footer, HALTED: 0. Headers at 200M/210M/
220M all still rx2idx=50, rx2next=150100000 (feed fully
consumed, nothing new). REGS change between every
checkpoint footer (e.g. 220M footer x5=1019104113,
x6=2605295299 vs 210M x5=3259201885, x6=18185) -- the CPU
is still executing, not wedged on one instruction.

Verdict: PARTIAL -- the 220M cap was reached with jent
still grinding. None of the Step 27 finish criteria
appeared: no "[342] console [ttyS0] enabled", no "[357]
virtio-blk", no "Freeing unused kernel image", no
"Run /init", no VFS/root-mount, no init banner, no prompt.
This is a cap, not a failure: no panic, no halt, state
still moving. The 220M checkpoint
(ckpt_cont170_run/ckpt_220000000.done) is banked as the
resume point for any continuation; whether to extend the
cap (e.g. 220M->250M) needs Jayant's word. Nothing pushed;
core, firmware, kernel, rootfs untouched by this job.
Full-config grind remains open at 220M; skip-jent work
(Steps 22/24/26) already boot-proven separately.

## STEP 28 -- full-config grind 220M->250M from ckpt_cont170_run/: 250M CAP REACHED, jent STILL GRINDING -- PARTIAL, no new UART lines -- 8 Nov 2026

Pre-flight (all verified before running, not assumed):
- Step 27 read in full. Resume point
  ckpt_cont170_run/ckpt_220000000.done (banked 09:15:08Z),
  header 220000000 / 50 / 150100000. No sim running at launch
  (ps clean). VM uptime 46 min -- rebooted ~14:45 IST just
  after Step 27 finished.
- NO disk rewrite: the banked 220M .disk FILE md5 is
  9da95d3bf4dea5887b9514e0f82ed845, identical to
  ckpt_catecho210/'s, and its payload md5 is
  c073ba7f766976b265d6b0057edb8d6f (1,048,576 bytes) == the
  current patched rootfs image. Verified pre-flight; nothing
  was rewritten.
- Full-config DTB (NOT skipjent):
  soc2_hex/big32_kboot_10mhz_rootfs.dtb.txt; testbench
  sim/tb_kboot_ckpt.vvp built 30 Oct 14:42 UTC from the
  drain-fixed sources (src/big32_soc2.v 14:26 UTC; fix line
  src/big32_soc2.v:850). Header untouched: rx2idx=50,
  rx2next=150100000 -- the attempt-17 feed
  rootfs/rx_cmds.txt is fully consumed, so no re-feed; judge
  prompt/banner/serial/virtio/root-mount only (any command
  output after a prompt would be stale-FIFO artefact, NOT
  clean evidence). Shell fixes explicitly NOT judged.
- Post-run verification (this check): 230M, 240M and 250M
  .disk payload md5s all = c073ba7f... (1,048,576 payload
  bytes each).

Run: tools/run_cont220_250.sh (adapted from
run_cont170_220.sh; same ensure_vvp, segment logic,
full-config DTB), log
kernel/boot_attempt17_cont220_250.log, progress
kernel/cont220_250_progress.log, watcher
tools/step28_watch.sh (600s polls, relaunches the runner
with setsid nohup if it dies while unfinished). Three
explicit-cap 10M segments, never uncapped loop mode. Stops
early on HALTED, kernel panic, or prompt + command output.
Watermark kernel/cont220_250_watermark.txt = 220000000
(hourly watcher).

Segment 1, 220M->230M (10:02:35Z->10:38:55Z, 36m20s, clean).
Segment 2, 230M->240M (11:20:12Z->11:56:51Z, 36m39s, clean).
Segment 3, 240M->250M (11:56:51Z->12:33:22Z, 36m31s, clean).
Each segment footer CYCLES: <target>, HALTED: 0; "latest
UART lines:" empty after every segment -- no new UART
output at any checkpoint.

Incident -- VM reboot ~11:15Z (16:45 IST): segment 2 had
been grinding ~37 min (started 10:38:55Z) when the runner,
vvp and watcher all died (uptime 1 min at 11:16:31Z; new
runtime cell). No work lost: the 230M checkpoint was
already banked 10:38:55Z, logs intact. Recovery: runner
relaunched 11:16:40Z with setsid nohup, resumed from the
intact 230M checkpoint; watcher relaunched 11:17:12Z.
Watcher relaunch first failed with "nohup: failed to run
command './tools/step28_watch.sh': No such file or
directory" -- the `&` had backgrounded the `cd` list, so
the second launch ran from `~`; fixed by relaunching with
the cd in the same backgrounded unit. Retry-loop quirk
(runner, not kernel): after the restart the runner walked
target 230M as a no-op 3x (~70s each, 11:16:40Z->11:20:12Z)
before grinding 230M->240M; the three extra CYCLES:
230000000 footers in the log are these no-progress passes
with identical REGS, not real segments. Total wall
10:02:35Z->12:33:22Z = 2h30m47s.

250M checkpoint banked (ckpt_cont170_run/ckpt_250000000.done,
12:33:22Z "cont220_250 complete: 250M cap reached"); runner
exit 0; watcher exited cleanly 12:37:12Z ("250M done
present -- finished", final summary in
/tmp/step28_watch.out).

Whole-log grep: ZERO "Kernel panic", ZERO "HALTED: 1",
ZERO "big32# ", ZERO "[ " kernel-timestamp lines; 1x
CYCLES: 250000000 footer, HALTED: 0. Headers at 230M/240M/
250M all still rx2idx=50, rx2next=150100000 (feed fully
consumed, nothing new). REGS change substantially between
every real segment footer (e.g. x5=2450045128 at 230M,
3761524640 at 240M, 2370977806 at 250M) -- the CPU is still
executing, not wedged on one instruction. (The first five
REGS words are identical across all footers, as in
Step 27.)

Verdict: PARTIAL -- the 250M cap was reached with jent
still grinding. None of the Step 27 finish criteria
appeared: no "[342] console [ttyS0] enabled", no "[357]
virtio-blk", no "Freeing unused kernel image", no
"Run /init", no VFS/root-mount, no init banner, no prompt.
This is a cap, not a failure: no panic, no halt, state
still moving. The 250M checkpoint
(ckpt_cont170_run/ckpt_250000000.done) is banked as the
resume point for any continuation; whether to extend the
cap further (e.g. 250M->280M) needs Jayant's word -- do NOT
extend without it. Nothing pushed; core, firmware, kernel,
rootfs untouched by this job. Pristine check:
ckpt_cont160/ and ckpt_catecho210/ md5-identical to
pre-flight (note: the /tmp baseline file was wiped by the
11:15Z reboot -- /tmp does not survive restarts -- so
verification was by direct comparison against the
pre-flight md5s captured in-session; baselines belong in
the workspace, not /tmp). Full-config grind remains open
at 250M; skip-jent work (Steps 22/24/26) already
boot-proven separately.
