# big32 — a 32-bit RISC-V CPU, built from zero

A 32-bit RISC-V CPU built from zero: a pipelined RV32IMAC core
(with its single-cycle sibling), a Python model that runs the
same programs, a two-pass assembler, a tiny OS kernel — and,
since Phase 5, a real Linux boot. Linux 6.6.52 rv32 boots on
this CPU in Icarus Verilog simulation, mounts a root filesystem
from a virtio block device, runs `/init` as PID 1, and drops
into a working shell. This README is the honest state as of
8 Nov 2026. The full evidence, step by step, is in
[`LINUX_BOOT.md`](LINUX_BOOT.md).

## Status — 8 Nov 2026

| Phase | What | State |
|---|---|---|
| 1 | 5-stage pipelined core, same semantics as the v7 single-cycle core | Done |
| 2–3 | M/S/U privilege, interrupts, Sv32 MMU, unified-memory SOC | Done |
| 4 | SBI-style M firmware, S-mode kernel, U-mode user program | Done |
| 5 | SOC2: SBI firmware, device tree, PLIC, 16550 UART, 64-bit CLINT, virtio-blk, TLB, A/D bits | Done |
| 5 | Linux 6.6.52 boots to a working shell (skip-jent config) | **Proven** — Step 26 |
| 5 | Same boot, full unmodified kernel config | **Open** — grind at 250M, Step 28 |

**The shell is proven, not just booted.** Step 26 (6 Nov 2026)
resumed the boot from a 210M-cycle checkpoint and drove the
shell with a clean feed at 225M cycles. In order:

```
bare cat        -> cat: missing file
bare echo       -> (a bare newline, nothing else)
echo hello      -> hello
cat /hello.txt  -> Hello from the big32 root filesystem.
```

Bare `ls` lists the root (Step 24), and `uname` and `pwd`
work too. The whole log has zero "cannot open directory",
zero "Kernel panic", zero "Oops". That boot used the
skip-jent configuration (see below) — the shell, the root
filesystem, and every command in it are real; the
configuration is the only qualifier.

**The full-config boot is the one open question.** The
unmodified kernel gets stuck early in `jent_mod_init` —
jitterentropy initialisation, 1,124 rounds of SHA3 hashing
to collect randomness. On real hardware that is instant;
in this simulation each CPU cycle costs real wall time
(~36 minutes per 10M cycles), so the kernel sits inside
that one function for hours. It is not crashed and not
wedged — the CPU state keeps changing between
checkpoints, and the log has zero panics — but nothing
after it can happen (no console, no disk, no root mount,
no prompt) until it finishes. Steps 27–28 ground it
170M → 250M cycles in 10M segments; the 250M checkpoint
is banked (8 Nov 2026, 18:03 IST) as the resume point.
On 8 Nov Jayant authorized extending the grind past 250M
with no cap, until jent finishes (Step 29, from the banked
250M checkpoint) — so the grind continues; the only thing
standing between it and the prompt is cycles.
What full-config proof would mean: the stock kernel
boots with nothing blacklisted. What the skip-jent proof
already banked means: everything downstream of jent
works — the only thing unproven is jent itself finishing.

Simulation only, throughout: Icarus Verilog 12.0. Not
silicon, not production-ready, no CI, no RISCOF
compliance, no formal verification. No badges here
because there is nothing to badge.

## What it is

The instruction set below is the v7 single-cycle core's.
The pipelined core in `src/big32_core_pipe.v` keeps its
exact semantics — see "Pipelined core (Phase 1)".

- 32 registers x0..x31 (x0 hardwired to 0), 32-bit program counter.
- Single-cycle: fetch, decode, execute, memory, writeback in one clock.
- RV32I base integer instructions, all formats:
  - R: add, sub, and, or, xor, sll, srl, sra, slt, sltu
  - I: addi, andi, ori, xori, slti, sltiu, slli, srli, srai
  - Loads: lb, lh, lw, lbu, lhu — Stores: sb, sh, sw (little-endian)
  - Branches: beq, bne, blt, bge, bltu, bgeu
  - jal, jalr, lui, auipc, ecall, ebreak
- RV32M (v2): mul, mulh, mulhsu, mulhu, div, divu, rem, remu —
  including the spec edge cases: div by zero returns -1, rem by zero
  returns the dividend, and (-2147483648) / (-1) returns -2147483648.
- RV32A, word only (v3): lr.w, sc.w, amoadd.w, amoswap.w, amoxor.w,
  amoor.w, amoand.w, amomin.w, amomax.w, amominu.w, amomaxu.w, with
  an LR/SC reservation (single core, so each atomic is a
  read-modify-write in one cycle).
- M-mode CSRs (v3): mstatus, mtvec, mscratch, mepc, mcause, mtval,
  mhartid (read-only 0). Instructions: csrrw, csrrs, csrrc,
  csrrwi, csrrsi, csrrci, plus the pseudos csrw, csrs, csrc, csrr,
  and mret. ECALL/EBREAK trap to mtvec (mcause 11/3) when mtvec is
  non-zero, and halt when mtvec is zero — so plain test programs
  ending with ECALL still halt, while a kernel that sets mtvec gets
  control on every ECALL.
- UART MMIO (v3): store a byte to 0x10000000 to transmit it; loads
  from 0x10000004 (RX) return -1 (no input in this core), loads from
  0x10000008 (status) return 0.
- Memory (Harvard, for now): 16KB instruction memory (4096 words,
  programs live at byte addresses 0..16383) and 64KB byte-addressable
  data memory (addresses modulo 64KB).
- Assembler pseudos: nop, mv, li (small immediates as addi, larger
  ones as lui + addi), j, jr, ret, la (auipc + addi, pc-relative),
  and character literals in li, e.g. li a0, 'A'.

## The tiny OS kernel

`programs/kernel.s` is a real supervisor, not a demo print:

- Boots, sets the kernel stack (mscratch = 0x8000) and mtvec to its
  trap handler, and prints `big32 OS` on the UART.
- Runs two apps in turn (sum 1..10, then 6 × 7) via jal.
- Each app ends with ECALL. The trap handler swaps to the kernel
  stack via mscratch, saves a0/a1/t0–t6/ra, prints `E=` plus the
  app's result in decimal, advances mepc past the ECALL, restores
  everything, swaps the stack back, and mrets — so the app returns
  normally to the kernel.
- Prints `done`, clears mtvec, and ECALLs, which halts (mtvec == 0).

Expected UART output:

```
big32 OS
E=55
E=42
done
```

## Forge on big32 — a whole language running on this CPU

Forge (the language in the `RED-MOON-` repo) now compiles to
big32. `forge.py build --target big32` turns a Forge program into
big32 assembly + `.hex` using Forge's existing parser/checker/
inference and a new RISC-V backend (`forge_lang/codegen_rv.py`).
The demo in this repo is the generated program, not the compiler
itself — the compiler lives in the Forge repo; what belongs here
is the program it produced and how to run it.

- `programs/forge_os.s` / `programs/forge_os.hex` — the Forge OS
  demo, generated from `examples/big32/forge_os.fg`: a Forge
  program that boots on big32, prints a banner, runs two apps
  (sum 1..10, then 6 × 7), prints their results, and halts via
  ECALL. It sits alongside, and does not replace, the assembly
  kernel `programs/kernel.s` — the kernel is still the real
  trap-handling supervisor; the Forge demo is a user program
  acting as an OS.
- `tools/run_forge.py` — run any Forge-generated `.hex` in both
  the Python model and Icarus Verilog, and print both UART
  transcripts for comparison:
  `python3 tools/run_forge.py programs/forge_os.hex`

Expected UART output (identical in model and Verilog):

```
forge OS on big32
boot ok
app_sum = 55
app_mul = 42
done
```

Honest limits, same as the Forge side: simulation only, subset
language (int/bool/str/arrays, loops, functions — no float,
structs, threads, file I/O, network, or GC on big32), native
RISC-V arithmetic (wrapping, div by zero → -1), and the demo
runs on the bare core, not under Linux. The full backend
contract is documented in the Forge README's "Forge on big32"
section.

## Files

- `src/big32_core.v` — the CPU core alone (v7, no memories)
- `src/big32.v` — simulation top for the single-cycle core:
  core + instruction/data memories
- `src/big32_core_pipe.v` — the pipelined core (Phase 1),
  same semantics as the v7 core
- `src/big32_pipe.v` — simulation top for the pipelined core
- `src/big32_soc.v` — SOC top for Phases 2–4 (M/S/U, MMU,
  interrupts, unified memory)
- `src/big32_soc2.v` — SOC top for Phase 5 (Linux platform:
  PLIC, 16550 UART, 64-bit CLINT, virtio-blk, TLB)
- `tools/asm.py` — RISC-V assembler (labels, R/I/S/B/U/J/A/CSR
  encodings, la, character literals)
- `tools/model.py` — Python behavioural model, cross-checks the Verilog
- `tools/rand_test.py` — random differential tester (see below)
- `tools/rand_pipe_test.py` — random tester for the pipelined core
- `tools/pipe_check.py`, `tools/soc_check.py`, `tools/os_check.py`,
  `tools/soc2_check.py`, `tools/sbi_check.py`, `tools/check_dtb.py`,
  `tools/boot_check.py`, `tools/coregaps_check.py` — the
  per-phase checkers the `./run_*.sh` runners call
- `tools/build_kboot.py`, `tools/build_kboot_dtb.py`,
  `tools/build_sbi.py`, `tools/build_smode.py`,
  `tools/build_os.py`, `tools/img2hex.py`, `tools/soc_asm.py`
  — kernel/DTB/SBI/image builders
- `tools/run_cont170_220.sh`, `tools/run_cont220_250.sh`,
  `tools/step28_watch.sh`, `tools/run_catecho_cont230.sh`,
  `tools/run_skipjent*.sh`, `tools/ckpt_run.sh` — the
  checkpoint/resume boot runners and watchers used in
  [`LINUX_BOOT.md`](LINUX_BOOT.md) Steps 22–28
- `programs/` — sum, fib, mul_loop, call_demo, mul_demo, mulh_demo,
  div_demo, div_edge, div_zero, rem_zero, amo_demo, sc_fail,
  csr_demo, edge_cases, pipe_hazards, kernel (each .s with its
  assembled .hex), plus `forge_os` (see above) and the
  `rand_*` differential-test programs
- `os_programs/` — SBI firmware (`sbi_firmware.s`), device tree
  (`big32.dts`), bootloader (`bootloader.s`), S-mode kernel
  (`kernel_s.s`), user program (`user.s`), and the Phase 4
  firmware/kernel/user sources
- `soc_programs/` — Phase 2–3 SOC test programs
- `soc2_programs/` — Phase 5 SOC2 test programs (misalign,
  entry/drain, fault, virtio)
- `soc2_hex/` — Phase 5 hex images: SBI firmware
  (`kboot_fw.hex`), device trees (full-config and
  skip-jent variants, 2/10 MHz), and the root-filesystem
  disk image (`rootfs_disk.hex`)
- `rootfs/` — the root filesystem: `init.asm` (the shell,
  3440 bytes), `mkelf.py` (the ELF builder), `rootfs.img`
  (the 1 MiB ext4 image), `hello.txt`, and the RX feed
  files (`rx_cmds.txt`, `rx_catecho.txt`, `rx_lsfix.txt`)
  used to drive the shell in the boot attempts
- `sim/` — testbenches: `tb_big32.v`, `tb_pipe.v`,
  `tb_rand.v`, `tb_soc.v`, `tb_soc2.v`, the checkpoint
  testbenches (`tb_kboot_ckpt*.v`, `tb_kboot_trace*.v`,
  `tb_kboot_fine.v`), and `synth_test.v`
- `LINUX_BOOT.md` — the full Linux boot record, Steps 1–28
- `OS_BOOT.md`, `PIPELINE.md`, `PRIVILEGE_MMU.md` — the
  Phase 4, Phase 1, and Phases 2–3 design docs

## Interrupts, privilege, MMU (Phases 2 and 3)

On top of the pipelined core: M-mode interrupts (CLINT timer
ticking every cycle, external line, 16-byte UART RX FIFO),
vectored `mtvec`, privilege modes M/S/U with trap delegation
and `sret`, and an Sv32 MMU with a multi-cycle page-table
walker (no TLB) on a unified-memory SOC top
(`src/big32_soc.v`). Full design, CSR/bit lists, walk timing,
memory map, deviations from the privileged specification, and
test results are in
[`PRIVILEGE_MMU.md`](PRIVILEGE_MMU.md). Re-run with
`./run_soc.sh` (11/11 SOC checks, then the Phase 1 pipe suite
as regression). Still simulation only: no RISCOF, no formal
verification, no silicon. Linux now boots on the Phase 5
SOC2 top — see below.

## OS boot (Phase 4)

M-mode firmware delegates traps to an S-mode kernel, which
enables Sv32 translation, counts CLINT timer ticks, drops to
U-mode, serves print/exit syscalls, demand-maps a faulting
page, and shuts down cleanly through the firmware — with the
full UART boot transcript checked byte-for-byte. Full design,
delegation table, memory map, syscall ABI, transcript, xv6
blockers, and the Linux roadmap are in
[`OS_BOOT.md`](OS_BOOT.md). Re-run with `./run_os.sh`
(OS boot check, then `./run_soc.sh` as regression). This phase
also fixed a latent core bug: S interrupt delivery now
requires the source to actually be pending (previously, merely
enabling an S interrupt took a phantom interrupt forever).
xv6-riscv is NOT an intermediate step here: it is RV64/Sv39
and cannot run on this RV32/Sv32 core (see OS_BOOT.md).
RV32 Linux, by contrast, is architecturally possible — and
Phase 5 proves it boots.

## Linux platform (Phase 5)

New SOC top `src/big32_soc2.v` (the Phase 2–4 top is
untouched): SBI firmware (Base, TIME, sPI, RFNC, SRST,
legacy putchar) in `os_programs/sbi_firmware.s`, a device
tree in `os_programs/big32.dts` (rv32ima, Sv32, PLIC,
16550 UART, CLINT, virtio-mmio), a real PLIC
(claim/complete, priorities, enables, lowest-ID tie-break),
a 16550-compatible UART at 0x10010000, a 64-bit CLINT
timer, a virtio-mmio block device (queue 0, block only),
and a bootloader that loads a kernel image from virtio
into RAM and drops to S-mode. Core gaps closed for Linux:
a real 16-entry TLB (sfence.vma flushes), A/D bit updates
on page-table walks (including D-miss re-walk), software
interrupts (SBI IPI register at 0x10002000), TIME/CYCLE/
INSTRET counters (the kernel clocksource reads rdtime),
and misaligned accesses now trap (causes 4/6) instead of
silently continuing into the next physical page. Tests:
`./run_soc2.sh` (soc2 + coregaps + sbi + dtb + boot +
the full Phase 1–4 regression).

**Linux 6.6.52 rv32 boots on big32 in simulation and
reaches userspace.** SBI probed, DTB parsed, earlycon on
the 16550, memory/SLUB/IRQ init, virtio-blk probed, root
mounted (ext4), `Run /init as init process`, PID 1 up,
shell prompt `big32#` — see the full log in
[`LINUX_BOOT.md`](LINUX_BOOT.md), Steps 22–26. The
remaining open item is the full-config boot (Step 28,
250M, jent still grinding) — see "Status" above.

## Pipelined core (Phase 1)

The v7 single-cycle core now has a pipelined sibling that keeps
its exact semantics: a 5-stage IF/ID/EX/MEM/WB core in
`src/big32_core_pipe.v` with full forwarding, load-use and CSR
stalls, branch/jump flushes (JAL in ID, branches/JALR/traps/
mret in EX), AMO in MEM, and an iterative 32-cycle divider
(edge-case divisions still single-cycle). MUL stays
combinational. Full design, stall/flush rules, commit rules,
cycle-count table, and test results are in
[`PIPELINE.md`](PIPELINE.md). Re-run it with `./run_pipe.sh`
(16/16 directed checks with full register/UART/memory
comparison, 50/50 hazard-heavy random tests — plus a second
50/50 batch on fresh seeds). The v7 files are untouched and
v7 still passes its full suite. This pipelined core is the
one the SOC tops run — S/U modes, the MMU, interrupts, and
Linux all sit on it, not on the single-cycle core.

## Production hardening (v4)

This is what "production ready" work actually looks like for a core
like this, following the pattern of the production open cores
(Ibex, PicoRV32, SERV — see below): verification first, then
synthesis-friendliness, then honest numbers.

- **Sparse CSR file.** v3 kept all 4096 CSRs in one array, which
  would synthesise to an enormous block of flip-flops. v4 keeps only
  the implemented CSRs (mstatus, mtvec, mscratch, mepc, mcause,
  mtval) as individual registers; unimplemented CSRs read 0 and
  ignore writes, and the Python model matches exactly.
- **ABI-correct register names.** The assembler used to map t3–t6
  to 25–28 and s2–s11 to 16–25, which is not the RISC-V ABI
  (t3–t6 = 28–31, s2–s11 = 18–27). Internal programs still ran
  because model and Verilog agreed, but ABI-wrong code would not
  interoperate with a real RISC-V toolchain. Fixed in v4.
- **Random differential testing.** `python3 tools/rand_test.py 50 0`
  generates 50 random, terminating programs (ALU, M, shifts,
  loads/stores to a scratch word, forward-only branches), runs each
  through the Python model and the Verilog simulation, and compares
  all 32 registers. This is the small version of the riscv-torture /
  riscv-dv approach used by the production cores, and it caught
  three real bugs that the 14 directed tests missed (below).
- **v5: DMEM no longer cleared on reset.** The v4 fix (clearing
  64KB of data memory on reset) was a simulation convenience that
  would synthesise to 64KB of resettable flip-flops — and it is
  what stalled the Yosys check. Real RAM power-up contents are
  undefined anyway, and software must not rely on them. The core
  now leaves DMEM alone on reset; the testbenches initialise it
  to zero (once in tb_rand, and on every reset in tb_big32), and
  the Python model still starts from a zeroed bytearray per run.
  The old Yosys run was killed and restarted on the v5 core.
- **v6: parametrised memories.** IMEM_DEPTH (default 4096 words)
  and DMEM_DEPTH (default 65536 bytes) are now module parameters,
  both required to be powers of two. Defaults are unchanged, so
  all tested programs behave identically. The point is synthesis:
  Yosys replaces async-read memories with registers, so the full
  64KB DMEM makes even `proc; opt` time out (>120s, no stat).
  Core logic is therefore measured with a small-memory
  instantiation (`sim/synth_test.v`: 256-word IMEM, 1KB DMEM),
  and the full-size memories are reported separately as SRAM
  bits (IMEM 131072 bits, DMEM 524288 bits), not as logic.
- **Edge-case test.** `programs/edge_cases.s` checks 19
  hand-computed cases (SRAI/SRA on -56, signed div/rem, mulh,
  lb/lbu, lh/lhu, slt/sltu, blt, amoadd, CSR readback, jal
  subroutine) and ends with a0 = fail count, so a0 = 0 is a pass
  in both model and Verilog, independent of either implementation.
  It is now the 15th directed program in `./run.sh`.
- **v7: core split from memories (Ibex-style).** `src/big32_core.v`
  is the same single-cycle logic as v6, but with no imem/dmem
  arrays. Instead it exposes: `instr_i` / `if_addr_o` (fetch),
  `d_addr_o` (load: rs1+imm_i, store: rs1+imm_s, AMO: rs1),
  `d_rdata_i` (32-bit word read at `d_addr_o`, little-endian
  bytes at addr..addr+3), `d_wdata_o` + `d_wmask_o` + `d_we_o`
  (write). The mask is RELATIVE: bit i writes byte i of
  `d_wdata_o` to `d_addr_o+i` (SB=0001, SH=0011, SW/AMO=1111),
  so unaligned loads/stores behave exactly as in v6 — bytes
  land at addr..addr+3, each wrapped modulo the memory depth.
  A real SRAM/AXI wrapper must translate that relative mask
  into absolute lanes for unaligned addresses, or restrict
  itself to aligned accesses (where relative = absolute).
  Stores to UART MMIO addresses never assert `d_we_o`; AMO
  writes assert it even at MMIO addresses, exactly as v6's
  `store_word` did (AMO bypassed the MMIO check). No other
  semantic change: the directed suite passes with identical
  cycle counts, and the random suite still passes 50/50.
  `src/big32.v` is now just the simulation top (core + the
  same byte arrays, same port list), so testbenches keep
  working — only the register-file/PC paths changed
  (`dut.core.regs`, `dut.core.pc`). Memories at defaults are
  reported separately as SRAM bits, not logic: IMEM 4096x32 =
  131072 bits, DMEM 65536x8 = 524288 bits. Yosys result for
  the core alone: see the synthesis note below.
- **Bugs the random tester caught and fixed (v4):**
  1. **SRAI was a logical shift in Icarus.** Writing SRAI as a
     ternary made the whole expression unsigned in Icarus, so
     `srai -56, 17` gave 32767 instead of -1. Fixed with if/else,
     and documented in the source.
  2. **Signed DIV/REM were unsigned in Icarus, for the same
     ternary reason.** `-1 / -41` gave 1 instead of 0, and
     `-1644167168 / -29` gave 0 instead of 56695419. Fixed with
     if/else.
  3. The directed suite passed all along; only the random tester
     found these, because no directed test used SRAI with a
     negative value or signed division with both operands
     negative. That is exactly why production cores do random
     testing, not just directed tests.

## What the production cores do that big32 does not (yet)

Checked 26 Oct 2026 against what people are actually building now:
Ibex is a production-quality 32-bit core (RV32IMC/EMC, 2-stage,
formally verified, used in Google's OpenTitan root of trust, with
nightly regression runs and published area/performance numbers
around 15–30k gates and up to 3.13 CoreMark/MHz); PicoRV32 is the
tiny FPGA core (~750–2000 LUTs, RV32I/IM/C/E); VexRiscv is the
configurable SpinalHDL core; SERV proves itself with RISCOF
compliance tests against the SAIL reference model plus riscv-formal;
TinyTapeout's community is building RISC-V peripherals and
microcontrollers, and FPGA builders are pairing custom cores with
FreeRTOS on boards like the Arty S7-25. The pattern is consistent:
directed tests + constrained-random tests + compliance against a
reference model + formal checks + synthesis numbers, all in CI.
big32 now has the first two; it does not yet have RISCOF
compliance, formal (RVFI) checks, CI, or synthesis numbers — those
are the next production steps, not claims made here.

## Synthesis (v7) — core logic only, memories excluded

Run Yosys on the core alone (log file, so the real exit code is
captured — never pipe Yosys to `tail`, which hides failures):

```sh
yosys -Q -T -l /tmp/yosys_v7.log -p 'read_verilog src/big32_core.v; hierarchy -top big32_core; proc; opt; fsm; opt; memory; opt; techmap; opt; stat'
```

RESULT (Yosys 0.33, 26 Oct 2026, run took 225 seconds, exit code
0; the log itself is not in this repo, the numbers below are the
run's recorded result):

```
=== big32_core ===

   Number of wires:               9551
   Number of wire bits:          75081
   Number of public wires:         106
   Number of public wire bits:    2520
   Number of memories:               0
   Number of memory bits:            0
   Number of processes:              0
   Number of cells:              42731
     $_AND_                      17334
     $_DFFE_PN0N_                    1
     $_DFFE_PN0P_                 1289
     $_DFF_PN0_                      1
     $_MUX_                       4373
     $_NOT_                       1328
     $_OR_                       10560
     $_XOR_                       7845
```

Read this honestly, not as a gate count:
- **Memories: 0, memory bits: 0** — the split worked. Yosys no
  longer turns memory into registers, which was the whole point
  of v7. The only Yosys warning is "Replacing memory \regs with
  list of registers", which is expected: the register file is
  meant to be flip-flops.
- **Flip-flops: 1289 + 1 + 1 = 1291**, which is exactly the
  architectural state: PC 32 + registers 32x32 = 1024 + six
  CSRs 6x32 = 192 + reservation_valid 1 + reservation_addr 32
  + halted 1 + uart_tx 8 + uart_tx_valid 1 = 1291. That match
  is a good cross-check that Yosys saw the intended core.
- **Combinational cells: 41440** (AND + MUX + NOT + OR + XOR).
  That is large, and the reason is the single-cycle design: a
  32-bit divider/modulo unit and 64-bit multipliers, all
  combinational, in one cycle. It is NOT a kGE figure (no
  technology library was mapped, and no ABC gate optimisation
  to standard cells was run), so do not quote it as one — and
  do not compare it directly with Ibex's 15–30kGE, which is a
  pipelined core with multi-cycle multiplier options. The
  production lesson is the opposite: if area matters, the next
  step is a multi-cycle divider/multiplier (or a pipeline),
  not a bigger single-cycle ALU.
- **Why it took 225 seconds:** techmapping the combinational
  divider/multiplier, not memory explosion — the v6 failure
  mode is gone. A faster synthesis number would come from
  `synth` with a real library, or from splitting the M unit
  out, but that is future work, not a claim made here.
- Memories, as before, are separate SRAM bits, not logic:
  IMEM 4096x32 = 131072 bits, DMEM 65536x8 = 524288 bits.

## Run it

```sh
./run.sh        # assembles, runs the Python model, compiles + simulates the Verilog
python3 tools/rand_test.py 50 0   # random differential tests, model vs Verilog
```

Verified 26 Oct 2026 in both the Python model and Icarus Verilog
simulation on all 15 programs — sum = 55, fib = 55, mul_loop = 42,
call_demo = 112 with sp restored, all six M cases, amo_demo = 42,
sc_fail = 101, csr_demo = 4660, and the kernel's UART output above,
halting with sp restored to 65532. One real bug was caught by the
Verilog run and fixed: uninitialised DMEM read as x in simulation
and poisoned AMO results (amo_demo failed with a0 = x); DMEM is now
cleared to zero on reset, matching the model, and the suite is green.
v4 adds 50/50 random differential tests passing (see above). v5
keeps all 15 directed programs passing (edge_cases a0 = 0) and
re-runs the random suite on the new core.

Per phase:

```sh
./run_pipe.sh   # Phase 1: pipelined core, directed + random
./run_soc.sh    # Phases 2–3: SOC checks + Phase 1 regression
./run_os.sh     # Phase 4: OS boot transcript + full regression
./run_soc2.sh   # Phase 5: SOC2 platform + full Phase 1–4 regression
```

## Reproducing the Linux boot — and what is NOT in this repo

Everything needed to reproduce the boot is in this repo
except the two things that cannot live here:

- **The kernel Image is not in the repo.** The boot used a
  Linux 6.6.52 rv32 Image, built trimmed (no C/FPU/SMP)
  per the config in [`LINUX_BOOT.md`](LINUX_BOOT.md).
  Build it, point the testbench at it with `+KIMGBIN`,
  and the firmware, device tree, disk image, and shell in
  this repo do the rest.
- **No checkpoints, no compiled testbenches, no run logs.**
  The `ckpt_*` checkpoint sets (~15G), the 2.1G kernel
  build tree, the `.vvp` binaries, and the `kernel/*.log`
  run logs are not in the repo. The boot is reproduced
  from source, not replayed from a checkpoint: compile
  `sim/tb_kboot_ckpt.v` against `src/big32_core_pipe.v`
  and `src/big32_soc2.v` with the `+HEX`, `+DISKHEX`,
  `+DTBFILE`, and `+KIMGBIN` plusargs documented in
  [`LINUX_BOOT.md`](LINUX_BOOT.md) — or run the
  checkpoint runners in `tools/` (`run_cont220_250.sh`
  and friends) against your own checkpoint sets.
  One 87MB file was deliberately left out of the push:
  `soc2_hex/kernel.hex` is an orphan nothing references.

What IS in the repo, and enough to rebuild the boot:
SBI firmware, device trees (full-config and skip-jent),
`kboot_fw.hex`, `rootfs_disk.hex`, `rootfs.img` with the
shell, and the full step-by-step record in
[`LINUX_BOOT.md`](LINUX_BOOT.md). The boot is slow in
Icarus (~36 minutes per 10M cycles at the grind's pace)
— that is the simulator, not the CPU; a faster simulator
or an FPGA is on the roadmap below.

## Honest roadmap

Done, in order: M extension (v2), A extension (v3),
M-mode CSRs/traps + UART + tiny kernel (v3), 5-stage
pipeline (Phase 1), interrupts, S/U modes, Sv32 MMU,
unified memory (Phases 2–3), M-firmware + S-kernel +
U user program (Phase 4), SBI firmware + device tree +
PLIC + 16550 UART + 64-bit timer + virtio block +
bootloader + TLB/A-D/misaligned gaps (Phase 5), RV32
Linux kernel built and booted in simulation (Phase 5),
root filesystem with an init, and the shell proven
(Steps 22–26).

Still missing, in order:

1. **The full-config boot.** The stock kernel, nothing
   blacklisted, finishing `jent_mod_init` and reaching
   the prompt. Ground to 250M so far (Step 28); extension
   past 250M authorized with no cap (Step 29). The only
   thing standing between it and the prompt is cycles.
2. **A bootloader sector loop for multi-megabyte images.**
   The bootloader loads only 2 sectors (1024 bytes);
   the kernel Image is currently loaded through the
   testbench (`+KIMGBIN`) as a documented shortcut.
3. **A faster simulator or an FPGA.** Icarus at ~36
   minutes per 10M cycles cannot boot Linux end-to-end
   in a session; every long boot is checkpointed in
   10M-cycle segments.
4. **A network device.** Virtio-net, or any NIC — the
   platform has block and serial only.
5. **FPU / PMP.** No floating-point unit, no physical
   memory protection.
6. **RISCOF compliance, formal (RVFI) checks, CI.**
   The production-core pattern from "What the
   production cores do" — still not claimed, still
   the next production steps.
7. **Synthesis numbers for the pipelined core.** The
   v7 numbers above are the single-cycle core only.

xv6-riscv is NOT an intermediate step here: it is
RV64/Sv39 and cannot run on this RV32/Sv32 core
(see OS_BOOT.md). RV32 Linux, by contrast, is
architecturally possible — and it boots.

## Next steps (in order)

1. ~~M extension~~ — done in v2. ~~A extension~~ — done in v3.
   ~~M-mode CSRs/traps + UART + tiny kernel~~ — done in v3.
   ~~5-stage pipeline~~ — done in Phase 1. ~~Interrupts,
   S/U modes, Sv32 MMU, unified memory~~ — done in Phases 2–3.
   ~~M-firmware + S-kernel + U user program~~ — done in Phase 4.
   ~~SBI firmware + device tree + PLIC + 16550 UART +
   64-bit timer + virtio block + bootloader + TLB/A-D/
   misaligned gaps~~ — done in Phase 5.
2. ~~Build an RV32 Linux kernel and boot it in
   simulation~~ — done in Phase 5 (boots and prints;
   see LINUX_BOOT.md for the log and the exact state).
3. ~~Root filesystem with an init, shell proven~~ —
   done, Steps 22–26 (bare `ls`, `cat`, `echo`,
   `uname`, `pwd` all verified at the prompt).
4. Next: the full-config boot (grind past 250M authorized
   with no cap — Step 29), a bootloader sector loop for
   multi-megabyte images, and faster simulation/FPGA — then
   the remaining gaps above.
