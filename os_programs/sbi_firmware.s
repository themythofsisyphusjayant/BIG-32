# SBI firmware (M-mode, Phase 5 + Attempt 12 emulation).
# Entry at RAM base (via ROM jump).
# Sets up delegation (S-ecall NOT delegated, so it lands here),
# then drops to the S-mode test at 0x80001000 with a0=hartid,
# a1=DTB address (0x80020000, loaded by the testbench).
# Attempt 12: misaligned load/store traps are NOT delegated
# (medeleg 0xB9AF: bits 4 and 6 cleared from the Phase-4
# 0xB9FF), so they land in M-mode where mtval is readable,
# and the handler below emulates them (misalign_entry):
# decode the faulting instruction from mepc, translate each
# byte/halfword piece through the trapped context's Sv32
# page tables (walk_va), do the access at the physical
# address, advance mepc by 4, and mret. Misaligned AMO/LR/SC
# are NOT emulated (the spec requires them to trap): they are
# redirected to S-mode with sepc/scause/stval/sstatus set as
# a hardware trap entry would set them, and mret lands in
# S-mode at stvec. See LINUX_BOOT.md "Attempt 12".
# SBI extensions implemented:
#   Base 0x10: get_spec_version (2.0), get_impl_id ("BIG3"),
#     get_impl_version (1), probe_extension, vendor/arch/imp ids (0)
#   Legacy 0x01: console_putchar (a0 = byte)
#   TIME 0x54494D45: set_timer (a0=lo, a1=hi -> mtimecmp)
#   sPI 0x735049: send_ipi (Phase 5: real single-hart IPI via
#   the soc2 IPI register at 0x10002000; a real
#     IPI line is added with the core irq_soft step)
#   RFNC 0x52464E43: fence_i / sfence_vma (single hart: the
#     sfence executes here, so a TLB flush happens in M)
#   SRST 0x53525354: system_reset -> shutdown (clear mtvec, ecall)
# Unknown extension/FID -> SBI_ERR_INVALID_PARAM (-2).
# Handler stack: firmware stack top 0x8000E000 via mscratch swap.
entry:
    li t0, 0x8000E000
    csrw mscratch, t0
    la t1, handler
    csrw mtvec, t1
    # Attempt 12: 0xB9AF = 0xB9FF with bits 4 (load address
    # misaligned) and 6 (store/AMO address misaligned)
    # cleared, so those traps land in M-mode for emulation.
    # Bit 0 (instruction address misaligned) stays delegated:
    # a misaligned fetch is a control-flow error, not a data
    # access, and S-mode is the right place to fault it.
    li t1, 0xB9AF
    csrw medeleg, t1
    li t1, 0x888
    csrw mideleg, t1
    # Drop to S: MPP=S (mstatus bits 12:11 = 01), mepc=test.
    li t1, 0x80001000
    csrw mepc, t1
    li t1, 0x800
    csrw mstatus, t1
    li a0, 0
    li a1, 0x80020000
    mret

handler:
    csrrw sp, mscratch, sp
    addi sp, sp, -128
    sw ra, 0(sp)
    sw a0, 4(sp)
    sw a1, 8(sp)
    sw a2, 12(sp)
    sw a3, 16(sp)
    sw a4, 20(sp)
    sw a5, 24(sp)
    sw a6, 28(sp)
    sw a7, 32(sp)
    sw t0, 36(sp)
    sw t1, 40(sp)
    sw t2, 44(sp)
    sw t3, 48(sp)
    sw t4, 52(sp)
    sw t5, 56(sp)
    sw t6, 60(sp)
    csrr t0, mcause
    blt t0, x0, int_path
    li t1, 9
    beq t0, t1, ecall_dispatch
    li t1, 4
    beq t0, t1, misalign_entry
    li t1, 6
    beq t0, t1, misalign_entry
    j other_trap
ecall_dispatch:
    # S-ecall: dispatch on a7.
    li t1, 0x10
    beq a7, t1, base_ext
    li t1, 1
    beq a7, t1, legacy_putchar
    li t1, 0x54494D45
    beq a7, t1, time_ext
    li t1, 0x735049
    beq a7, t1, spi_ext
    li t1, 0x52464E43
    beq a7, t1, rfnc_ext
    li t1, 0x53525354
    beq a7, t1, srst_ext
    li a0, -2
    li a1, 0
    j ret_path

base_ext:
    li t1, 0
    beq a6, t1, base_spec
    li t1, 1
    beq a6, t1, base_implid
    li t1, 2
    beq a6, t1, base_implver
    li t1, 3
    beq a6, t1, base_probe
    li t1, 4
    beq a6, t1, base_zero
    li t1, 5
    beq a6, t1, base_zero
    li t1, 6
    beq a6, t1, base_zero
    li a0, -2
    li a1, 0
    j ret_path
base_spec:
    li a0, 0
    li a1, 0x02000000
    j ret_path
base_implid:
    li a0, 0
    li a1, 0x42494733
    j ret_path
base_implver:
    li a0, 0
    li a1, 1
    j ret_path
base_zero:
    li a0, 0
    li a1, 0
    j ret_path
base_probe:
    mv t2, a0
    li t1, 0x10
    beq t2, t1, probe_yes
    li t1, 0x54494D45
    beq t2, t1, probe_yes
    li t1, 0x735049
    beq t2, t1, probe_yes
    li t1, 0x52464E43
    beq t2, t1, probe_yes
    li t1, 0x53525354
    beq t2, t1, probe_yes
    li a0, 0
    li a1, 0
    j ret_path
probe_yes:
    li a0, 0
    li a1, 1
    j ret_path

legacy_putchar:
    li t0, 0x10000000
    sb a0, 0(t0)
    li a0, 0
    li a1, 0
    j ret_path

time_ext:
    li t1, 0
    bne a6, t1, err_param
    li t0, 0x02004000
    sw a0, 0(t0)
    sw a1, 4(t0)
    li a0, 0
    li a1, 0
    j ret_path

spi_ext:
    li t1, 0
    bne a6, t1, err_param
    # Phase 5: real IPI, not a no-op. Single hart: set the
    # soc2 SBI IPI register (0x10002000) when the mask
    # selects hart 0: hart_mask_base == -1 (all harts), or
    # base == 0 with mask bit 0 set. The S-mode handler
    # clears it by writing 0 to the same register.
    li t0, 0x10002000
    li t1, -1
    beq a1, t1, spi_set
    li t1, 0
    bne a1, t1, spi_done
    andi t2, a0, 1
    beq t2, x0, spi_done
spi_set:
    li t2, 1
    sw t2, 0(t0)
spi_done:
    li a0, 0
    li a1, 0
    j ret_path

rfnc_ext:
    li t1, 0
    beq a6, t1, rfnc_ok
    li t1, 1
    beq a6, t1, rfnc_sfence
    li t1, 2
    beq a6, t1, rfnc_sfence
    li t1, 3
    beq a6, t1, rfnc_ok
    li t1, 4
    beq a6, t1, rfnc_ok
    li t1, 5
    beq a6, t1, rfnc_ok
    li t1, 6
    beq a6, t1, rfnc_ok
    j err_param
rfnc_sfence:
    sfence.vma
rfnc_ok:
    li a0, 0
    li a1, 0
    j ret_path

srst_ext:
    li t1, 0
    bne a6, t1, err_param
    # Shutdown: restore the original stack, clear mtvec, ecall
    # in M with mtvec==0 -> core halts.
    lw ra, 0(sp)
    lw a2, 12(sp)
    lw a3, 16(sp)
    lw a4, 20(sp)
    lw a5, 24(sp)
    lw a6, 28(sp)
    lw a7, 32(sp)
    lw t0, 36(sp)
    lw t1, 40(sp)
    lw t2, 44(sp)
    lw t3, 48(sp)
    lw t4, 52(sp)
    lw t5, 56(sp)
    lw t6, 60(sp)
    addi sp, sp, 128
    csrrw sp, mscratch, sp
    csrw mtvec, x0
    ecall
    # Unreachable if the core halts; loop defensively.
halt_loop:
    j halt_loop

err_param:
    li a0, -2
    li a1, 0
    j ret_path

other_trap:
    li t0, 0x10000000
    li t1, 0x21
    sb t1, 0(t0)        # '!' on an unexpected trap
    j halt_path

int_path:
    # Machine timer interrupt (code 7): stop the timer, mret
    # without advancing mepc (interrupts do not advance it).
    csrr t0, mcause
    li t1, 0x80000007
    bne t0, t1, halt_path
    li t0, 0x02004000
    li t1, -1
    sw t1, 0(t0)
    sw t1, 4(t0)
    j ret_int

ret_int:
    lw ra, 0(sp)
    lw a0, 4(sp)
    lw a1, 8(sp)
    lw a2, 12(sp)
    lw a3, 16(sp)
    lw a4, 20(sp)
    lw a5, 24(sp)
    lw a6, 28(sp)
    lw a7, 32(sp)
    lw t0, 36(sp)
    lw t1, 40(sp)
    lw t2, 44(sp)
    lw t3, 48(sp)
    lw t4, 52(sp)
    lw t5, 56(sp)
    lw t6, 60(sp)
    addi sp, sp, 128
    csrrw sp, mscratch, sp
    mret

ret_path:
    # Advance mepc FIRST, while t2 still holds handler
    # scratch: restoring t2 from its slot afterwards then
    # preserves an emulated load whose rd is t2. (Attempt 12
    # fix: the old order restored t2 and then clobbered it
    # with mepc+4, so every emulated load into t2 returned
    # the next PC instead of the loaded value. SBI callers
    # never noticed because SBI returns in a0/a1 and t2 is
    # caller-saved scratch to them.)
    csrr t2, mepc
    addi t2, t2, 4
    csrw mepc, t2
    lw ra, 0(sp)
    lw a2, 12(sp)
    lw a3, 16(sp)
    lw a4, 20(sp)
    lw a5, 24(sp)
    lw a6, 28(sp)
    lw a7, 32(sp)
    lw t0, 36(sp)
    lw t1, 40(sp)
    lw t2, 44(sp)
    lw t3, 48(sp)
    lw t4, 52(sp)
    lw t5, 56(sp)
    lw t6, 60(sp)
    addi sp, sp, 128
    csrrw sp, mscratch, sp
    mret

halt_path:
    lw ra, 0(sp)
    lw a2, 12(sp)
    lw a3, 16(sp)
    lw a4, 20(sp)
    lw a5, 24(sp)
    lw a6, 28(sp)
    lw a7, 32(sp)
    lw t0, 36(sp)
    lw t1, 40(sp)
    lw t2, 44(sp)
    lw t3, 48(sp)
    lw t4, 52(sp)
    lw t5, 56(sp)
    lw t6, 60(sp)
    addi sp, sp, 128
    csrrw sp, mscratch, sp
    csrw mtvec, x0
    ecall
    j halt_loop

# ================= Attempt 12: misaligned emulation =================
# Entry: misalign_entry, from handler when mcause is 4 or 6.
# At entry the handler has saved ra, a0-a7, t0-t6 to the stack
# frame (sp points at it, slots 0..60) and swapped sp with
# mscratch (trapped sp is in mscratch). This code uses ONLY
# t0-t6 plus the free frame slots below, so the trapped
# a0-a7/s0-s11/gp/tp values survive untouched until writeback
# (putreg) or redirect (which restores everything).
# Free frame slots (bytes 64..124):
#   64: insn, then loop index i (insn dead after decode)
#   68: funct3, then redirect cause (funct3 dead at redirect)
#   72: rd, then redirect stval (rd dead at redirect)
#   76: rs1num, then current piece VA (rs1num dead after fetch)
#   80: rs2num (dead after fetch)
#   84: imm, then effective address EA (imm dead after EA)
#   88: size (1/2/4)
#   92: is_store (0 load, 1 store)
#   96: fault VA (mtval, kept for redirect stval)
#   100: load result
#   104: current piece PA
#   120: rs1 value
#   124: rs2 value (stores)
# NOT emulated, redirected to S-mode instead: misaligned
# AMO/LR/SC (spec: they must trap), compressed instructions
# (kernel has no C code; low insn bits != 11), unknown
# opcodes/funct3, mcause/opcode mismatch, and any piece
# whose page-table walk faults (redirect cause 13/15).
# The walk does NOT set A/D bits in PTEs: the next hardware
# access to the page sets them, as on a normal TLB miss.
# Partial stores: if a later piece faults, earlier pieces
# are already written; re-execution after the kernel fixes
# the mapping rewrites the same bytes (idempotent on RAM;
# cross-page MMIO stores are not guaranteed).
# No UART output anywhere on this path: the kernel probe's
# timing loops would spam the console and corrupt the log.
misalign_entry:
    csrr t0, mcause
    li t1, 6
    beq t0, t1, mis_is_store
    li t1, 0
    sw t1, 92(sp)
    j mis_have_cause
mis_is_store:
    li t1, 1
    sw t1, 92(sp)
mis_have_cause:
    csrr t0, mtval
    sw t0, 96(sp)
    # Translate mepc (fetch, mode 2) to fetch the instruction.
    csrr t0, mepc
    li t1, 2
    jal ra, walk_va
    li t1, -1
    beq t2, t1, mis_halt
    lw t2, 0(t2)
    sw t2, 64(sp)
    # Decode: must be a 4-byte load/store, not AMO.
    lw t0, 64(sp)
    andi t1, t0, 3
    li t2, 3
    bne t1, t2, redirect_mis
    andi t1, t0, 0x7F
    li t2, 0x2F
    beq t1, t2, redirect_mis
    li t2, 3
    beq t1, t2, mis_is_load_op
    li t2, 0x23
    beq t1, t2, mis_is_store_op
    j redirect_mis
mis_is_load_op:
    lw t1, 92(sp)
    beq t1, x0, mis_decode
    j redirect_mis
mis_is_store_op:
    lw t1, 92(sp)
    bne t1, x0, mis_decode
    j redirect_mis
mis_decode:
    lw t0, 64(sp)
    srli t1, t0, 12
    andi t1, t1, 7
    sw t1, 68(sp)
    srli t1, t0, 7
    andi t1, t1, 0x1F
    sw t1, 72(sp)
    srli t1, t0, 15
    andi t1, t1, 0x1F
    sw t1, 76(sp)
    srli t1, t0, 20
    andi t1, t1, 0x1F
    sw t1, 80(sp)
    # size from funct3: 0->1, 1->2, 2->4, 4->1, 5->2.
    lw t1, 68(sp)
    li t2, 0
    beq t1, t2, mis_size1
    li t2, 1
    beq t1, t2, mis_size2
    li t2, 2
    beq t1, t2, mis_size4
    li t2, 4
    beq t1, t2, mis_size1
    li t2, 5
    beq t1, t2, mis_size2
    j redirect_mis
mis_size1:
    li t1, 1
    sw t1, 88(sp)
    j mis_imm
mis_size2:
    li t1, 2
    sw t1, 88(sp)
    j mis_imm
mis_size4:
    li t1, 4
    sw t1, 88(sp)
    j mis_imm
mis_imm:
    lw t1, 92(sp)
    bne t1, x0, mis_imm_store
    # Load imm: insn[31:20] sign-extended.
    lw t0, 64(sp)
    srli t0, t0, 20
    srli t1, t0, 11
    andi t1, t1, 1
    beq t1, x0, mis_imm_done
    li t1, -4096
    or t0, t0, t1
    j mis_imm_done
mis_imm_store:
    # Store imm: (insn[31:25] << 5) | insn[11:7], sign-extended.
    lw t0, 64(sp)
    srli t1, t0, 25
    slli t1, t1, 5
    srli t2, t0, 7
    andi t2, t2, 0x1F
    or t0, t1, t2
    srli t1, t0, 11
    andi t1, t1, 1
    beq t1, x0, mis_imm_done
    li t1, -4096
    or t0, t0, t1
mis_imm_done:
    sw t0, 84(sp)
    # rs1/rs2 values (getreg reads trapped regs; see below).
    lw t0, 76(sp)
    jal ra, getreg
    sw t1, 120(sp)
    lw t0, 80(sp)
    jal ra, getreg
    sw t1, 124(sp)
    # EA = rs1val + imm (slot 84 now holds EA).
    lw t0, 120(sp)
    lw t1, 84(sp)
    add t0, t0, t1
    sw t0, 84(sp)
    sw x0, 100(sp)
    sw x0, 64(sp)
mis_loop:
    lw t0, 64(sp)
    lw t1, 88(sp)
    bge t0, t1, mis_done
    lw t2, 84(sp)
    add t2, t2, t0
    sw t2, 76(sp)
    mv t0, t2
    lw t1, 92(sp)
    jal ra, walk_va
    li t3, -1
    beq t2, t3, redirect_pf
    sw t2, 104(sp)
    lw t1, 92(sp)
    bne t1, x0, mis_store_piece
    # Load piece: byte at PA, shifted into result (LE order).
    lw t2, 104(sp)
    lbu t2, 0(t2)
    lw t0, 64(sp)
    slli t0, t0, 3
    sll t2, t2, t0
    lw t3, 100(sp)
    or t3, t3, t2
    sw t3, 100(sp)
    j mis_next
mis_store_piece:
    lw t2, 124(sp)
    lw t0, 64(sp)
    slli t0, t0, 3
    srl t2, t2, t0
    andi t2, t2, 0xFF
    lw t3, 104(sp)
    sb t2, 0(t3)
mis_next:
    lw t0, 64(sp)
    addi t0, t0, 1
    sw t0, 64(sp)
    j mis_loop
mis_done:
    lw t1, 92(sp)
    bne t1, x0, mis_ret
    # Sign extension for lb/lh (funct3 0/1); lw/lbu/lhu: none.
    lw t0, 68(sp)
    li t2, 0
    beq t0, t2, mis_sext_b
    li t2, 1
    beq t0, t2, mis_sext_h
    j mis_writeback
mis_sext_b:
    lw t1, 100(sp)
    srli t0, t1, 7
    andi t0, t0, 1
    beq t0, x0, mis_writeback
    li t0, -256
    or t1, t1, t0
    sw t1, 100(sp)
    j mis_writeback
mis_sext_h:
    lw t1, 100(sp)
    srli t0, t1, 15
    andi t0, t0, 1
    beq t0, x0, mis_writeback
    li t0, -65536
    or t1, t1, t0
    sw t1, 100(sp)
    j mis_writeback
mis_writeback:
    lw t0, 72(sp)
    lw t1, 100(sp)
    jal ra, putreg
mis_ret:
    j ret_path
mis_halt:
    j halt_path

# Redirect to S-mode with hardware trap-entry state:
# sepc = mepc (NOT advanced), scause/sstatus as below,
# stval = faulting VA, then mret lands in S at stvec
# (vectored: stvec + 4*cause). All trapped registers are
# restored first, since this is a trap, not a return.
# Entry stubs write cause -> slot 68, stval -> slot 72.
redirect_mis:
    csrr t0, mcause
    csrr t1, mtval
    sw t0, 68(sp)
    sw t1, 72(sp)
    j redirect
redirect_pf:
    lw t0, 92(sp)
    li t2, 15
    beq t0, x0, red_pf_load
    sw t2, 68(sp)
    j red_pf_stval
red_pf_load:
    li t2, 13
    sw t2, 68(sp)
red_pf_stval:
    lw t1, 76(sp)
    sw t1, 72(sp)
    j redirect
redirect:
    csrr t2, sstatus
    li t3, -291
    and t4, t2, t3
    csrr t3, mstatus
    srli t3, t3, 11
    andi t3, t3, 3
    slli t3, t3, 8
    or t4, t4, t3
    andi t3, t2, 2
    slli t3, t3, 4
    or t4, t4, t3
    csrw sstatus, t4
    csrr t3, mepc
    csrw sepc, t3
    lw t3, 68(sp)
    csrw scause, t3
    lw t3, 72(sp)
    csrw stval, t3
    csrr t3, mstatus
    li t4, -6145
    and t3, t3, t4
    li t4, 0x800
    or t3, t3, t4
    csrw mstatus, t3
    csrr t3, stvec
    andi t4, t3, 1
    beq t4, x0, red_direct
    lw t4, 68(sp)
    slli t4, t4, 2
    add t3, t3, t4
red_direct:
    csrw mepc, t3
    lw ra, 0(sp)
    lw a0, 4(sp)
    lw a1, 8(sp)
    lw a2, 12(sp)
    lw a3, 16(sp)
    lw a4, 20(sp)
    lw a5, 24(sp)
    lw a6, 28(sp)
    lw a7, 32(sp)
    lw t0, 36(sp)
    lw t1, 40(sp)
    lw t2, 44(sp)
    lw t3, 48(sp)
    lw t4, 52(sp)
    lw t5, 56(sp)
    lw t6, 60(sp)
    addi sp, sp, 128
    csrrw sp, mscratch, sp
    mret

# getreg: input t0 = register number, output t1 = trapped
# value. Uses t2-t6 only. t0-t6 live values are dead (the
# handler saved them); a0/a1/s0-s11/gp/tp live values are
# still the trapped ones. ra live is DEAD (jal wrote it),
# so ra comes from slot 0. sp comes from mscratch.
getreg:
    li t2, 5
    blt t0, t2, gr_low
    li t2, 8
    blt t0, t2, gr_t0t2
    li t2, 28
    blt t0, t2, gr_mid
    slli t1, t0, 2
    addi t1, t1, -64
    add t1, sp, t1
    lw t1, 0(t1)
    ret
gr_t0t2:
    slli t1, t0, 2
    addi t1, t1, 16
    add t1, sp, t1
    lw t1, 0(t1)
    ret
gr_low:
    beq t0, x0, gr_zero
    li t2, 1
    beq t0, t2, gr_ra
    li t2, 2
    beq t0, t2, gr_sp
    li t2, 3
    beq t0, t2, gr_gp
    mv t1, tp
    ret
gr_mid:
    li t2, 8
    beq t0, t2, gr_s0
    li t2, 9
    beq t0, t2, gr_s1
    li t2, 10
    beq t0, t2, gr_a0
    li t2, 11
    beq t0, t2, gr_a1
    li t2, 12
    beq t0, t2, gr_a2
    li t2, 13
    beq t0, t2, gr_a3
    li t2, 14
    beq t0, t2, gr_a4
    li t2, 15
    beq t0, t2, gr_a5
    li t2, 16
    beq t0, t2, gr_a6
    li t2, 17
    beq t0, t2, gr_a7
    li t2, 18
    beq t0, t2, gr_s2
    li t2, 19
    beq t0, t2, gr_s3
    li t2, 20
    beq t0, t2, gr_s4
    li t2, 21
    beq t0, t2, gr_s5
    li t2, 22
    beq t0, t2, gr_s6
    li t2, 23
    beq t0, t2, gr_s7
    li t2, 24
    beq t0, t2, gr_s8
    li t2, 25
    beq t0, t2, gr_s9
    li t2, 26
    beq t0, t2, gr_s10
    mv t1, s11
    ret
gr_zero:
    li t1, 0
    ret
gr_ra:
    lw t1, 0(sp)
    ret
gr_sp:
    csrr t1, mscratch
    ret
gr_gp:
    mv t1, gp
    ret
gr_s0:
    mv t1, s0
    ret
gr_s1:
    mv t1, s1
    ret
gr_a0:
    mv t1, a0
    ret
gr_a1:
    mv t1, a1
    ret
gr_a2:
    mv t1, a2
    ret
gr_a3:
    mv t1, a3
    ret
gr_a4:
    mv t1, a4
    ret
gr_a5:
    mv t1, a5
    ret
gr_a6:
    mv t1, a6
    ret
gr_a7:
    mv t1, a7
    ret
gr_s2:
    mv t1, s2
    ret
gr_s3:
    mv t1, s3
    ret
gr_s4:
    mv t1, s4
    ret
gr_s5:
    mv t1, s5
    ret
gr_s6:
    mv t1, s6
    ret
gr_s7:
    mv t1, s7
    ret
gr_s8:
    mv t1, s8
    ret
gr_s9:
    mv t1, s9
    ret
gr_s10:
    mv t1, s10
    ret

# putreg: input t0 = rd number, t1 = value. Writes the
# value where ret_path will pick it up: the stack slot
# for ra/a2-a7/t0-t6 (ret_path restores those), the live
# register for a0/a1/s0-s11/gp/tp (ret_path leaves those),
# mscratch for sp (ret_path swaps it in), nothing for x0.
putreg:
    beq t0, x0, pr_done
    li t2, 1
    beq t0, t2, pr_ra
    li t2, 2
    beq t0, t2, pr_sp
    li t2, 5
    blt t0, t2, pr_live_low
    li t2, 8
    blt t0, t2, pr_t0t2
    li t2, 12
    blt t0, t2, pr_live_mid1
    li t2, 18
    blt t0, t2, pr_a2a7
    li t2, 28
    blt t0, t2, pr_s2s11
    slli t2, t0, 2
    addi t2, t2, -64
    add t2, sp, t2
    sw t1, 0(t2)
    ret
pr_t0t2:
    slli t2, t0, 2
    addi t2, t2, 16
    add t2, sp, t2
    sw t1, 0(t2)
    ret
pr_a2a7:
    slli t2, t0, 2
    addi t2, t2, -36
    add t2, sp, t2
    sw t1, 0(t2)
    ret
pr_ra:
    sw t1, 0(sp)
    ret
pr_sp:
    csrw mscratch, t1
    ret
pr_live_low:
    li t2, 3
    beq t0, t2, pr_gp
    mv tp, t1
    ret
pr_live_mid1:
    li t2, 8
    beq t0, t2, pr_s0
    li t2, 9
    beq t0, t2, pr_s1
    li t2, 10
    beq t0, t2, pr_a0
    mv a1, t1
    ret
pr_s2s11:
    li t2, 18
    beq t0, t2, pr_s2
    li t2, 19
    beq t0, t2, pr_s3
    li t2, 20
    beq t0, t2, pr_s4
    li t2, 21
    beq t0, t2, pr_s5
    li t2, 22
    beq t0, t2, pr_s6
    li t2, 23
    beq t0, t2, pr_s7
    li t2, 24
    beq t0, t2, pr_s8
    li t2, 25
    beq t0, t2, pr_s9
    li t2, 26
    beq t0, t2, pr_s10
    mv s11, t1
    ret
pr_done:
    ret
pr_gp:
    mv gp, t1
    ret
pr_s0:
    mv s0, t1
    ret
pr_s1:
    mv s1, t1
    ret
pr_a0:
    mv a0, t1
    ret
pr_a1:
    mv a1, t1
    ret
pr_s2:
    mv s2, t1
    ret
pr_s3:
    mv s3, t1
    ret
pr_s4:
    mv s4, t1
    ret
pr_s5:
    mv s5, t1
    ret
pr_s6:
    mv s6, t1
    ret
pr_s7:
    mv s7, t1
    ret
pr_s8:
    mv s8, t1
    ret
pr_s9:
    mv s9, t1
    ret
pr_s10:
    mv s10, t1
    ret

# walk_va: input t0 = VA, t1 = mode (0 load, 1 store,
# 2 fetch). Output t2 = PA, or -1 on fault. Clobbers
# t0, t3-t6; preserves t1. M-mode trapped context and
# bare satp (MODE 0) are physical: PA = VA. Otherwise
# a two-level Sv32 walk: L1 superpage leaf, or L1 pointer
# to an L0 leaf. Permission checks mirror the core:
# V required; leaf needs R (load/store), W (store);
# fetch checks no R/W (the core already validated the
# fetch); U page needs SUM for S-mode, faults for U-mode
# on an S page. A/D bits are NOT set (see header note).
walk_va:
    mv t3, t0
    csrr t0, mstatus
    srli t0, t0, 11
    andi t0, t0, 3
    li t2, 3
    beq t0, t2, walk_bare
    mv t6, t0
    csrr t0, satp
    blt t0, x0, walk_on
walk_bare:
    mv t2, t3
    ret
walk_on:
    slli t0, t0, 10
    srli t0, t0, 10
    slli t0, t0, 12
    srli t4, t3, 22
    andi t4, t4, 0x3FF
    slli t4, t4, 2
    add t4, t0, t4
    lw t4, 0(t4)
    andi t5, t4, 1
    beq t5, x0, walk_fault
    andi t5, t4, 0xE
    bne t5, x0, walk_leaf1
    srli t4, t4, 10
    slli t4, t4, 12
    srli t5, t3, 12
    andi t5, t5, 0x3FF
    slli t5, t5, 2
    add t5, t4, t5
    lw t4, 0(t5)
    andi t5, t4, 1
    beq t5, x0, walk_fault
    andi t5, t4, 0xE
    beq t5, x0, walk_fault
    srli t5, t4, 10
    slli t5, t5, 12
    slli t0, t3, 20
    srli t0, t0, 20
    or t2, t5, t0
    j walk_perm
walk_leaf1:
    srli t5, t4, 20
    andi t5, t5, 0x3FF
    slli t5, t5, 22
    slli t0, t3, 10
    srli t0, t0, 10
    or t2, t5, t0
    j walk_perm
walk_perm:
    li t0, 2
    beq t1, t0, walk_usum
    andi t0, t4, 2
    beq t0, x0, walk_fault
    li t0, 1
    bne t1, t0, walk_usum
    andi t0, t4, 4
    beq t0, x0, walk_fault
    j walk_usum
walk_usum:
    andi t0, t4, 0x10
    beq t0, x0, walk_spage
    beq t6, x0, walk_ok
    csrr t0, sstatus
    srli t0, t0, 18
    andi t0, t0, 1
    beq t0, x0, walk_fault
    j walk_ok
walk_spage:
    beq t6, x0, walk_fault
    j walk_ok
walk_ok:
    ret
walk_fault:
    li t2, -1
    ret
