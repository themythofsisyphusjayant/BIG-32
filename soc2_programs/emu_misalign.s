# Attempt 12 firmware-emulation test (S-mode, via SBI firmware).
# VA 0x40000000 -> PA 0x80030000 (R/W, 4 KiB page 0),
# VA 0x40001000 -> PA 0x80031000 (R/W, 4 KiB page 1, NEW
# vs misalign.s, where page 1 is unmapped).
# New semantics: cross-page unaligned loads/stores are
# EMULATED in M-mode firmware (medeleg 0xB9AF: causes 4/6
# not delegated), so the S handler must NOT fire (count 0)
# and values must be correct. Misaligned AMO/LR/SC are NOT
# emulated: firmware redirects them to S, so the S handler
# MUST fire (count 1, cause 4/6, tval = faulting VA).
# Within-page accesses still take the hardware path
# (count 0). s0 = fail count at SRST.
# Page data (bare stores, before translation):
#   page0 word 0x000 = 0x11223344, word 0x004 = 0x12345678,
#   page0 word 0xFFC = 0x55667788 (bytes 88 77 66 55),
#   page1 word 0x000 = 0xAABBCCDD (bytes DD CC BB AA),
#   page1 word 0x004 = 0x01020304.
start:
    li sp, 0x8000F000
    li s0, 0
    la t0, handler
    csrw stvec, t0
    # --- bare stores: test data + tables ---
    li t0, 0x80030000
    li t1, 0x11223344
    sw t1, 0(t0)
    li t1, 0x12345678
    sw t1, 4(t0)
    li t1, 0x55667788
    li t0, 0x80030FFC
    sw t1, 0(t0)
    li t0, 0x80031000
    li t1, 0xAABBCCDD
    sw t1, 0(t0)
    li t1, 0x01020304
    sw t1, 4(t0)
    li t0, 0x80010000
    li t2, 0x80010800
    li t1, 0x2000000F
    sw t1, 0(t2)
    li t1, 0x20004401
    sw t1, 0x400(t0)
    li t0, 0x80011000
    li t1, 0x2000C00F
    sw t1, 0(t0)
    li t1, 0x2000C40F
    sw t1, 4(t0)
    # --- enable translation ---
    li t0, 0x80080010
    csrw satp, t0
    sfence.vma
    li t1, 0x40000000
    # --- case 1: lw at VA+0xFFE (2+2 straddle), emulated ---
    li t5, 0x8000F108
    sw x0, 0(t5)
    li t4, 0x40000FFE
    lw t2, 0(t4)
    li t4, 0xCCDD5566
    bne t2, t4, bad1
    lw t6, 0(t5)
    bne t6, x0, bad1
    j c2
bad1:
    addi s0, s0, 1
c2:
    # --- case 2: EXACT probe shape: lw at VA+0xFFF (1+3),
    # rd=a0 (live-register writeback path) ---
    li t5, 0x8000F108
    sw x0, 0(t5)
    li t4, 0x40000FFF
    lw a0, 0(t4)
    li t4, 0xBBCCDD55
    bne a0, t4, bad2
    lw t6, 0(t5)
    bne t6, x0, bad2
    j c3
bad2:
    addi s0, s0, 1
c3:
    # --- case 3: lw at VA+0xFFD (3+1 straddle), emulated,
    # rd=s2 (live s-register writeback path) ---
    li t5, 0x8000F108
    sw x0, 0(t5)
    li t4, 0x40000FFD
    lw s2, 0(t4)
    li t4, 0xDD556677
    bne s2, t4, bad3
    lw t6, 0(t5)
    bne t6, x0, bad3
    j c4
bad3:
    addi s0, s0, 1
c4:
    # --- case 4: lh at VA+0xFFF, sign-extended, emulated,
    # rd=t0 (slot writeback path) ---
    li t5, 0x8000F108
    sw x0, 0(t5)
    li t4, 0x40000FFF
    lh t0, 0(t4)
    li t4, 0xFFFFDD55
    bne t0, t4, bad4
    lw t6, 0(t5)
    bne t6, x0, bad4
    j c5
bad4:
    addi s0, s0, 1
c5:
    # --- case 5: lhu at VA+0xFFF, zero-extended, emulated,
    # rd=a1 (live-register writeback path) ---
    li t5, 0x8000F108
    sw x0, 0(t5)
    li t4, 0x40000FFF
    lhu a1, 0(t4)
    li t4, 0x0000DD55
    bne a1, t4, bad5
    lw t6, 0(t5)
    bne t6, x0, bad5
    j c6
bad5:
    addi s0, s0, 1
c6:
    # --- case 6: lb at both sides of the boundary (size 1:
    # never traps, hardware control, count must stay 0) ---
    li t5, 0x8000F108
    sw x0, 0(t5)
    li t4, 0x40000FFF
    lb t2, 0(t4)
    li t4, 0x55
    bne t2, t4, bad6
    li t4, 0x40001000
    lb t2, 0(t4)
    li t4, 0xFFFFFFDD
    bne t2, t4, bad6
    lw t6, 0(t5)
    bne t6, x0, bad6
    j c7
bad6:
    addi s0, s0, 1
c7:
    # --- case 7: lbu at VA+0x1000 (size 1: hardware control) ---
    li t5, 0x8000F108
    sw x0, 0(t5)
    li t4, 0x40001000
    lbu t2, 0(t4)
    li t4, 0xDD
    bne t2, t4, bad7
    lw t6, 0(t5)
    bne t6, x0, bad7
    j c8
bad7:
    addi s0, s0, 1
c8:
    # --- case 8: sh at VA+0xFFF (1+1 split store), emulated ---
    li t5, 0x8000F108
    sw x0, 0(t5)
    li t2, 0xBEEF
    li t4, 0x40000FFF
    sh t2, 0(t4)
    li t4, 0x40000FFC
    lw t2, 0(t4)
    li t4, 0xEF667788
    bne t2, t4, bad8
    li t4, 0x40001000
    lw t2, 0(t4)
    li t4, 0xAABBCCBE
    bne t2, t4, bad8
    lw t6, 0(t5)
    bne t6, x0, bad8
    j c9
bad8:
    addi s0, s0, 1
c9:
    # --- case 9: sw at VA+0xFFE (2+2 split store), emulated ---
    li t5, 0x8000F108
    sw x0, 0(t5)
    li t2, 0x01020304
    li t4, 0x40000FFE
    sw t2, 0(t4)
    li t4, 0x40000FFC
    lw t2, 0(t4)
    li t4, 0x03047788
    bne t2, t4, bad9
    li t4, 0x40001000
    lw t2, 0(t4)
    li t4, 0xAABB0102
    bne t2, t4, bad9
    lw t6, 0(t5)
    bne t6, x0, bad9
    j c10
bad9:
    addi s0, s0, 1
c10:
    # --- case 10: sw at VA+0xFFF (1+3 split store) ---
    li t5, 0x8000F108
    sw x0, 0(t5)
    li t2, 0xA0B0C0D0
    li t4, 0x40000FFF
    sw t2, 0(t4)
    li t4, 0x40000FFC
    lw t2, 0(t4)
    li t4, 0xD0047788
    bne t2, t4, bad10
    li t4, 0x40001000
    lw t2, 0(t4)
    li t4, 0xAAA0B0C0
    bne t2, t4, bad10
    lw t6, 0(t5)
    bne t6, x0, bad10
    j c11
bad10:
    addi s0, s0, 1
c11:
    # --- case 11: amoadd.w at VA+2 -> REDIRECT, not emulate ---
    li t5, 0x8000F108
    sw x0, 0(t5)
    li t4, 0x40000002
    li t3, 5
    amoadd.w t2, t3, (t4)
    li t5, 0x8000F100
    lw t6, 8(t5)
    li t4, 1
    bne t6, t4, bad11
    lw t6, 0(t5)
    li t4, 6
    bne t6, t4, bad11
    lw t6, 4(t5)
    li t4, 0x40000002
    bne t6, t4, bad11
    # amoadd must NOT have executed: word 0 still original.
    lw t2, 0(t1)
    li t4, 0x11223344
    bne t2, t4, bad11
    j c12
bad11:
    addi s0, s0, 1
c12:
    # --- case 12: lr.w at VA+2 -> REDIRECT, cause 4 ---
    li t5, 0x8000F108
    sw x0, 0(t5)
    li t4, 0x40000002
    lr.w t2, (t4)
    li t5, 0x8000F100
    lw t6, 8(t5)
    li t4, 1
    bne t6, t4, bad12
    lw t6, 0(t5)
    li t4, 4
    bne t6, t4, bad12
    lw t6, 4(t5)
    li t4, 0x40000002
    bne t6, t4, bad12
    j c13
bad12:
    addi s0, s0, 1
c13:
    # --- case 13: sc.w at VA+2 -> REDIRECT, cause 6 ---
    li t5, 0x8000F108
    sw x0, 0(t5)
    li t4, 0x40000002
    li t3, 7
    sc.w t2, t3, (t4)
    li t5, 0x8000F100
    lw t6, 8(t5)
    li t4, 1
    bne t6, t4, bad13
    lw t6, 0(t5)
    li t4, 6
    bne t6, t4, bad13
    lw t6, 4(t5)
    li t4, 0x40000002
    bne t6, t4, bad13
    j c14
bad13:
    addi s0, s0, 1
c14:
    # --- case 14: cross-page amoadd.w -> REDIRECT, not emulate ---
    li t5, 0x8000F108
    sw x0, 0(t5)
    li t4, 0x40000FFE
    li t3, 5
    amoadd.w t2, t3, (t4)
    li t5, 0x8000F100
    lw t6, 8(t5)
    li t4, 1
    bne t6, t4, bad14
    lw t6, 0(t5)
    li t4, 6
    bne t6, t4, bad14
    lw t6, 4(t5)
    li t4, 0x40000FFE
    bne t6, t4, bad14
    # Boundary words must be untouched (case 10 values).
    li t4, 0x40000FFC
    lw t2, 0(t4)
    li t4, 0xD0047788
    bne t2, t4, bad14
    li t4, 0x40001000
    lw t2, 0(t4)
    li t4, 0xAAA0B0C0
    bne t2, t4, bad14
    j c15
bad14:
    addi s0, s0, 1
c15:
    # --- case 15: within-page fast path, S count stays 0 ---
    li t5, 0x8000F108
    sw x0, 0(t5)
    lh t2, 1(t1)
    li t4, 0x2233
    bne t2, t4, bad15
    lw t2, 2(t1)
    li t4, 0x56781122
    bne t2, t4, bad15
    li t2, 0xABCD
    sh t2, 1(t1)
    lw t2, 0(t1)
    li t4, 0x11ABCD44
    bne t2, t4, bad15
    li t2, 0x01020304
    sw t2, 2(t1)
    lw t2, 0(t1)
    li t4, 0x0304CD44
    bne t2, t4, bad15
    lw t2, 4(t1)
    li t4, 0x12340102
    bne t2, t4, bad15
    lw t6, 0(t5)
    bne t6, x0, bad15
    j ctrl
bad15:
    addi s0, s0, 1
ctrl:
    # --- controls: aligned lw/sw must NOT trap ---
    li t5, 0x8000F108
    sw x0, 0(t5)
    li t2, 0x55667788
    sw t2, 0(t1)
    lw t2, 0(t1)
    li t4, 0x55667788
    bne t2, t4, badc
    lw t6, 0(t5)
    bne t6, x0, badc
    j c16
badc:
    addi s0, s0, 1
    j c16
c16:
    # --- case 16: cross-page load into sp (putreg via
    # mscratch). Last case: sp becomes the result value,
    # which nothing after this uses except the SRST ecall
    # (the firmware handler swaps sp, so it still halts). ---
    li t5, 0x8000F108
    sw x0, 0(t5)
    li t4, 0x40000FFE
    lw sp, 0(t4)
    mv t2, sp
    li t4, 0xB0C0D004
    bne t2, t4, bad16
    lw t6, 0(t5)
    bne t6, x0, bad16
    j done
bad16:
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
