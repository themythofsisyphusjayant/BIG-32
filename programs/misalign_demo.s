# misalign_demo: hardware unaligned loads/stores (Phase 6).
# The pipelined core no longer traps regular unaligned
# loads/stores; the tops deliver the right bytes (pipe top:
# bytes at addr..addr+3; soc2 top: merged RAM words).
# Data lives at 0x200/0x300, clear of the pipe_check
# scratch words at 0x100..0x10C. Final a0 is the XOR of
# every loaded value (hand-computed below; the model
# comparison checks every register, not just a0).
# Bytes after the first two stores (little-endian):
#   0x200: 44 33 22 11 | 0x204: 88 77 66 55
        li s0, 0x200
        li t0, 0x11223344
        sw t0, 0(s0)
        li t0, 0x55667788
        sw t0, 4(s0)
        lh t1, 1(s0)        # bytes 33 22 -> 0x2233
        lhu t2, 3(s0)       # bytes 11 88 -> 0x8811
        lw t3, 1(s0)        # bytes 33 22 11 88 -> 0x88112233
        lw t4, 2(s0)        # bytes 22 11 88 77 -> 0x77881122
        lw t5, 3(s0)        # bytes 11 88 77 66 -> 0x66778811
        lb t6, 3(s0)        # 0x11
        lb s1, 4(s0)        # 0x88 -> sign-extended 0xFFFFFF88
        lbu s2, 4(s0)       # 0x88
        lh s3, 3(s0)        # bytes 11 88 -> sign-extended 0xFFFF8811
        lhu s4, 3(s0)       # 0x8811
        # Unaligned store then aligned + unaligned re-load.
        li t0, 0xAABB
        sh t0, 1(s0)        # bytes 0x201=BB 0x202=AA
        lw s5, 0(s0)        # bytes 44 BB AA 11 -> 0x11AABB44
        li t0, 0xCCDDEEFF
        sw t0, 2(s0)        # bytes 0x202=FF 0x203=EE 0x204=DD 0x205=CC
        lw s6, 0(s0)        # bytes 44 BB FF EE -> 0xEEFFBB44
        lw s7, 2(s0)        # bytes FF EE DD CC -> 0xCCDDEEFF
        lb s8, 5(s0)        # 0xCC -> sign-extended 0xFFFFFFCC
        # Kernel-probe shape: word loads at base+1 (page|0x1
        # style) and base+3 (src off by 3 style).
        li s9, 0x300
        li t0, 0xDEADBEEF
        sw t0, 0(s9)        # bytes EF BE AD DE
        li t0, 0x12345678
        sw t0, 4(s9)        # bytes 78 56 34 12
        lw s10, 1(s9)       # bytes BE AD DE 78 -> 0x78DEADBE
        lw s11, 3(s9)       # bytes DE 78 56 34 -> 0x345678DE
        # a0 = XOR of all loaded values.
        xor a0, t1, t2
        xor a0, a0, t3
        xor a0, a0, t4
        xor a0, a0, t5
        xor a0, a0, t6
        xor a0, a0, s1
        xor a0, a0, s2
        xor a0, a0, s3
        xor a0, a0, s4
        xor a0, a0, s5
        xor a0, a0, s6
        xor a0, a0, s7
        xor a0, a0, s8
        xor a0, a0, s10
        xor a0, a0, s11
        ecall
