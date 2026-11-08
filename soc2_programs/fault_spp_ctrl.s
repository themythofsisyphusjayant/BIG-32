# CONTROL for the fault_spp tests: proves an S-mode indirect jump to a
# translated VA works, and that a copied stub (li + ecall only, no la,
# no branches: copy-safe) runs there. The stub sets s5 = 0x5A5A and
# halts via ecall. Expected footer: halted=1, s0=0, s5=23130.
# Runs bare in M-mode from RAM base (soc2 harness); drops to S via
# mret, builds its own tables, enables satp, then jumps.
start:
    li sp, 0x8000F000
    li s0, 0
    li t0, 0x1000
    csrw medeleg, t0
    csrr t0, mstatus
    li t1, 0xFFFFE7FF
    and t0, t0, t1
    li t1, 0x800
    or t0, t0, t1
    csrw mstatus, t0
    la t0, s_entry
    csrw mepc, t0
    mret
s_entry:
    # Copy the 3-word stub (li s5 / ecall) to PA 0x80030000.
    la t0, stub_exec
    li t1, 0x80030000
    li t2, 3
copy_loop:
    lw t3, 0(t0)
    sw t3, 0(t1)
    addi t0, t0, 4
    addi t1, t1, 4
    addi t2, t2, -1
    bne t2, x0, copy_loop
    # Tables: L1 at 0x80010000, L0 at 0x80011000.
    li t0, 0x80010000
    li t2, 0x80010800
    li t1, 0x2000000F
    sw t1, 0(t2)
    li t1, 0x20004401
    li t2, 0x80010C00
    sw t1, 0(t2)
    li t0, 0x80011000
    li t1, 0x2000C00B
    sw t1, 0(t0)
    li t0, 0x80080010
    csrw satp, t0
    sfence.vma
    # Jump to VA 0xC0000000: the copied stub sets s5 and halts.
    li t1, 0xC0000000
    jalr x0, 0(t1)
    # Never reached: the stub halts. If reached, fail loudly.
    addi s0, s0, 1
    li a7, 0x53525354
    li a6, 0
    li a0, 0
    li a1, 0
    ecall
    j s_entry
stub_exec:
    li s5, 0x5A5A
    ecall
