# TEST B (control): U-mode fetch from an S page (U=0, X=1) must trap
# to the S handler with cause 12, stval = sepc = the faulting VA, and
# sstatus = 0x20 (SPP=0, SPIE=1 because SPIE was set before sret and
# sret copies SPIE to SIE).
# This is the exact signature of the PID 1 panic Oops
# (status 0x20, badaddr = epc, cause 0xc), proving a genuine U-mode
# fetch fault reproduces it byte-for-byte in the status field.
# Expected footer: halted=1, s0=0, s1=0x20, s2=12,
# s3=0xC0000000, s4=0xC0000000.
# Runs bare in M-mode from RAM base (soc2 harness); drops to S via
# mret, builds its own tables, enables satp, drops to U via sret.
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
    li t1, 0x2000C00B
    sw t1, 0(t0)
    li t0, 0x80080010
    csrw satp, t0
    sfence.vma
    # Drop to U: SPIE=1 (sret copies SPIE to SIE, so the trap that
    # follows sees SIE=1 and the handler gets SPIE=1), SPP=0.
    csrr t0, sstatus
    ori t0, t0, 0x22
    li t1, 0xFFFFFEFF
    and t0, t0, t1
    csrw sstatus, t0
    li t0, 0xC0000000
    csrw sepc, t0
    sret
    # Never reached (sret jumps to sepc).
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
    li t0, 0xC0000000
    bne s3, t0, fail
    bne s4, t0, fail
    srli t0, s1, 8
    andi t0, t0, 1
    bne t0, x0, fail
    li t0, 0x20
    bne s1, t0, fail
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
