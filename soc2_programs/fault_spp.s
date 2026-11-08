# TEST A: S-mode fetch from a page with X=0 must trap to the S handler
# with cause 12, stval = sepc = the faulting VA, and sstatus.SPP = 1
# (the faulting code ran in S-mode). This validates the SPP linchpin:
# a genuine S-mode fetch fault shows SPP=1, so the panic Oops
# status 0x20 (SPP=0) can only come from a U-mode fetch.
# Expected footer: halted=1, s0=0, s1=0x100, s2=12,
# s3=0xC0001000, s4=0xC0001000.
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
    la t0, handler
    csrw stvec, t0
    # Tables: L1 at 0x80010000, L0 at 0x80011000.
    li t0, 0x80010000
    li t2, 0x80010800
    li t1, 0x2000000F
    sw t1, 0(t2)
    li t1, 0x20004401
    li t2, 0x80010C00
    sw t1, 0(t2)
    li t0, 0x80011000
    li t1, 0x2000C403
    sw t1, 4(t0)
    li t0, 0x80080010
    csrw satp, t0
    sfence.vma
    # Jump to VA 0xC0001000 (V,R, X=0): must fault to handler.
    li t1, 0xC0001000
    jalr x0, 0(t1)
    # Never reached (fault). If reached, fail.
    addi s0, s0, 1
    j halt
handler:
    csrr t0, sstatus
    mv s1, t0
    csrr t0, scause
    mv s2, t0
    csrr t0, stval
    mv s3, t0
    csrr t0, sepc
    mv s4, t0
    li s0, 0
    li t0, 12
    bne s2, t0, fail
    li t0, 0xC0001000
    bne s3, t0, fail
    bne s4, t0, fail
    srli t0, s1, 8
    andi t0, t0, 1
    beq t0, x0, fail
    j halt
fail:
    addi s0, s0, 1
halt:
    li a7, 0x53525354
    li a6, 0
    li a0, 0
    li a1, 0
    ecall
    j halt
