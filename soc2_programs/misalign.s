# Phase 6 misaligned-access test (S-mode, via SBI firmware),
# updated for Attempt 12 firmware emulation.
# VA 0x40000000 -> PA 0x80030000 (R/W, 4 KiB page 0),
# VA 0x40001000 -> PA 0x80031000 (R/W, 4 KiB page 1).
# Semantics: within-page unaligned loads/stores are handled
# in hardware and must NOT trap; cross-page loads/stores are
# EMULATED in M-mode firmware (case 9) and must NOT reach
# the S handler; AMO/LR/SC misalignment still traps, but
# via firmware REDIRECT to S (cases 6-8: the S handler
# still sees cause 4/6, tval = faulting VA, count 1).
# The S handler records cause/tval/count at identity-mapped
# scratch 0x8000F100/104/108. s0 = fail count at SRST.
# Note: medeleg in the firmware is now 0xB9AF (Attempt 12:
# causes 4 and 6 NOT delegated), so cross-page and AMO
# traps land in M-mode first; only the redirect reaches S.
start:
    li sp, 0x8000F000
    li s0, 0
    la t0, handler
    csrw stvec, t0
    # --- bare stores: test data + tables ---
    li t0, 0x80030000
    li t1, 0x11223344
    sw t1, 0(t0)
    li t0, 0x80010000
    li t2, 0x80010800
    li t1, 0x2000000F
    sw t1, 0(t2)        # L1[0x200] identity superpage
    li t1, 0x20004401
    sw t1, 0x400(t0)    # L1[0x100] -> L0 table
    li t0, 0x80031000
    li t1, 0xAABBCCDD
    sw t1, 0(t0)        # page 1 word 0 (for case 9)
    li t0, 0x80011000
    li t1, 0x2000C00F
    sw t1, 0(t0)        # L0[0] -> 0x80030000
    li t1, 0x2000C40F
    sw t1, 4(t0)        # L0[1] -> 0x80031000
    # --- enable translation ---
    li t0, 0x80080010
    csrw satp, t0
    sfence.vma
    li t1, 0x40000000
    # --- case 1: lh from VA+1 must SUCCEED, no trap ---
    # bytes at VA: 44 33 22 11 -> lh at +1 = 0x2233.
    li t5, 0x8000F108
    sw x0, 0(t5)
    lh t2, 1(t1)
    li t4, 0x2233
    bne t2, t4, bad1
    lw t6, 0(t5)
    bne t6, x0, bad1
    j c2
bad1:
    addi s0, s0, 1
c2:
    # --- case 2: lw from VA+2 must SUCCEED, no trap ---
    # bytes at VA+2: 22 11 00 00 -> 0x00001122.
    lw t2, 2(t1)
    li t4, 0x00001122
    bne t2, t4, bad2
    lw t6, 0(t5)
    bne t6, x0, bad2
    j c3
bad2:
    addi s0, s0, 1
c3:
    # --- case 3: lhu from VA+3 must SUCCEED, no trap ---
    # bytes at VA+3: 11 00 -> 0x0011.
    lhu t2, 3(t1)
    li t4, 0x0011
    bne t2, t4, bad3
    lw t6, 0(t5)
    bne t6, x0, bad3
    j c4
bad3:
    addi s0, s0, 1
c4:
    # --- case 4: sh to VA+1 must SUCCEED, no trap ---
    li t2, 0x1234
    sh t2, 1(t1)
    lw t2, 0(t1)
    li t4, 0x11123444
    bne t2, t4, bad4
    lw t6, 0(t5)
    bne t6, x0, bad4
    j c5
bad4:
    addi s0, s0, 1
c5:
    # --- case 5: sw to VA+2 must SUCCEED, no trap ---
    li t2, 0x1234
    sw t2, 2(t1)
    lw t2, 0(t1)
    li t4, 0x12343444
    bne t2, t4, bad5
    lw t6, 0(t5)
    bne t6, x0, bad5
    j c6
bad5:
    addi s0, s0, 1
c6:
    # --- case 6: amoadd.w at VA+2 -> cause 6, tval VA+2 ---
    li t5, 0x8000F108
    sw x0, 0(t5)
    li t4, 0x40000002
    li t3, 5
    amoadd.w t2, t3, (t4)
    li t5, 0x8000F100
    lw t6, 8(t5)
    li t4, 1
    bne t6, t4, bad6
    lw t6, 0(t5)
    li t4, 6
    bne t6, t4, bad6
    lw t6, 4(t5)
    li t4, 0x40000002
    bne t6, t4, bad6
    j c7
bad6:
    addi s0, s0, 1
c7:
    # --- case 7: lr.w at VA+2 -> cause 4, tval VA+2 ---
    li t5, 0x8000F108
    sw x0, 0(t5)
    li t4, 0x40000002
    lr.w t2, (t4)
    li t5, 0x8000F100
    lw t6, 8(t5)
    li t4, 1
    bne t6, t4, bad7
    lw t6, 0(t5)
    li t4, 4
    bne t6, t4, bad7
    lw t6, 4(t5)
    li t4, 0x40000002
    bne t6, t4, bad7
    j c8
bad7:
    addi s0, s0, 1
c8:
    # --- case 8: sc.w at VA+2 -> cause 6, tval VA+2 ---
    li t5, 0x8000F108
    sw x0, 0(t5)
    li t4, 0x40000002
    li t3, 7
    sc.w t2, t3, (t4)
    li t5, 0x8000F100
    lw t6, 8(t5)
    li t4, 1
    bne t6, t4, bad8
    lw t6, 0(t5)
    li t4, 6
    bne t6, t4, bad8
    lw t6, 4(t5)
    li t4, 0x40000002
    bne t6, t4, bad8
    j c9
bad8:
    addi s0, s0, 1
c9:
    # --- case 9: lw crossing the page boundary ---
    # VA 0x40000FFE + 4 crosses into MAPPED VA 0x40001000:
    # Attempt 12 firmware EMULATES it (count 0, value
    # 0xCCDD0000: page-0 bytes at 0xFFE/0xFFF are zero,
    # page-1 bytes are DD CC). Old Phase-6 expectation
    # (trap cause 4) is superseded by emulation.
    li t5, 0x8000F108
    sw x0, 0(t5)
    li t4, 0x40000FFE
    lw t2, 0(t4)
    li t4, 0xCCDD0000
    bne t2, t4, bad9
    lw t6, 0(t5)
    bne t6, x0, bad9
    j ctrl
bad9:
    addi s0, s0, 1
ctrl:
    # --- controls: aligned lw/sw must NOT trap ---
    # word at VA is now 0x12343444 (case 5).
    li t5, 0x8000F108
    sw x0, 0(t5)
    lw t2, 0(t1)
    li t3, 0x12343444
    bne t2, t3, badc
    lw t6, 0(t5)
    bne t6, x0, badc
    li t2, 0x55667788
    sw t2, 0(t1)
    lw t6, 0(t5)
    bne t6, x0, badc
    lw t2, 0(t1)
    li t3, 0x55667788
    beq t2, t3, done
badc:
    addi s0, s0, 1
done:
    li a7, 0x53525354
    li a6, 0
    li a0, 0
    li a1, 0
    ecall
    j done
handler:
    csrr t0, scause
    li t5, 0x8000F100
    sw t0, 0(t5)
    csrr t0, stval
    sw t0, 4(t5)
    lw t0, 8(t5)
    addi t0, t0, 1
    sw t0, 8(t5)
    csrr t0, sepc
    addi t0, t0, 4
    csrw sepc, t0
    sret
