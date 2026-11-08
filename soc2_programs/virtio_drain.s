# Virtio-mmio drain test (M-mode, bare, on soc2). a0 = fail count.
# Attempt 18 Step 16: one QueueNotify kick must drain ALL pending
# chains, not just the first. Mirrors the 210M kernel park (4
# queued reads, avail > last_avail, no further kick): queue 4
# read chains up front (sectors 5,6,7,8), kick ONCE, require
# used idx == 4 with correct ids, lens, status bytes and data.
# FAILS on the pre-fix model (used idx sticks at 1 after the
# poll timeout); PASSES on the fixed model.
# Virtio base 0x10001000. Queue: desc 0x80020000, avail
# 0x80021000, used 0x80022000, QueueNum 8. Per chain i:
# header 0x80023000+i*0x100, data 0x80024000+i*0x1000,
# status byte 0x80028000+i. Descs 3i (header), 3i+1 (data),
# 3i+2 (status). Sector pattern byte == sector number, so
# sector N reads back as word 0x0N0N0N0N.
start:
    li sp, 0x80010000
    li s0, 0
    li t0, 0x10001000
    # Identify: magic, version, device id, capacity.
    lw t1, 0(t0)
    li t2, 0x74726976
    bne t1, t2, fail
    lw t1, 4(t0)
    li t2, 2
    bne t1, t2, fail
    lw t1, 8(t0)
    li t2, 2
    bne t1, t2, fail
    lw t1, 0x100(t0)
    li t2, 2048
    bne t1, t2, fail
    # Reset, then ACK | DRIVER | FEATURES_OK (legacy, no v1).
    sw x0, 0x70(t0)
    li t1, 1
    sw t1, 0x70(t0)
    li t1, 3
    sw t1, 0x70(t0)
    sw x0, 0x20(t0)    # driver features = 0
    li t1, 0xB
    sw t1, 0x70(t0)
    # Queue addresses and number, then READY, then DRIVER_OK.
    li t1, 0x80020000
    sw t1, 0x80(t0)    # desc lo
    sw x0, 0x84(t0)    # desc hi
    li t1, 0x80021000
    sw t1, 0x90(t0)    # avail lo
    sw x0, 0x94(t0)
    li t1, 0x80022000
    sw t1, 0xA0(t0)    # used lo
    sw x0, 0xA4(t0)
    li t1, 8
    sw t1, 0x38(t0)    # QueueNum
    li t1, 1
    sw t1, 0x44(t0)    # QueueReady
    li t1, 0xF
    sw t1, 0x70(t0)    # DRIVER_OK
    # ---- Build all 4 chains, then kick ONCE ----
    li s1, 0           # i = 0..3
build_loop:
    # header addr = 0x80023000 + i*0x100 (a0)
    slli a0, s1, 8
    li t0, 0x80023000
    add a0, a0, t0
    sw x0, 0(a0)       # type = 0 (read)
    sw x0, 4(a0)       # reserved
    addi t1, s1, 5     # sector = 5 + i
    sw t1, 8(a0)       # sector lo
    sw x0, 12(a0)      # sector hi
    # desc base = 0x80020000 + 3i*16 (a1)
    slli t1, s1, 1
    add t1, t1, s1     # 3i
    slli a1, t1, 4     # 3i*16
    li t0, 0x80020000
    add a1, a1, t0
    # desc 3i: header, len 16, flags NEXT, next = 3i+1
    sw a0, 0(a1)
    sw x0, 4(a1)
    li t1, 16
    sw t1, 8(a1)
    slli t2, s1, 1
    add t2, t2, s1     # 3i
    addi t2, t2, 1     # 3i+1
    slli t2, t2, 16
    addi t2, t2, 1     # flags NEXT
    sw t2, 12(a1)
    # data addr = 0x80024000 + i*0x1000 (a2)
    slli a2, s1, 12
    li t0, 0x80024000
    add a2, a2, t0
    # desc 3i+1: data, len 512, flags WRITE|NEXT, next = 3i+2
    sw a2, 16(a1)
    sw x0, 20(a1)
    li t1, 512
    sw t1, 24(a1)
    slli t2, s1, 1
    add t2, t2, s1
    addi t2, t2, 2     # 3i+2
    slli t2, t2, 16
    addi t2, t2, 3     # flags WRITE|NEXT
    sw t2, 28(a1)
    # status addr = 0x80028000 + i (a3)
    li a3, 0x80028000
    add a3, a3, s1
    # desc 3i+2: status, len 1, flags WRITE, no NEXT
    sw a3, 32(a1)
    sw x0, 36(a1)
    li t1, 1
    sw t1, 40(a1)
    li t1, 2
    sw t1, 44(a1)
    # avail ring[i] = 3i
    li t0, 0x80021000
    slli t1, s1, 1     # byte offset 4 + 2i
    addi t1, t1, 4
    add t1, t1, t0
    slli t2, s1, 1
    add t2, t2, s1     # 3i
    sh t2, 0(t1)
    addi s1, s1, 1
    li t1, 4
    blt s1, t1, build_loop
    # avail flags = 0, avail idx = 4.
    li t0, 0x80021000
    sw x0, 0(t0)
    li t1, 4
    sh t1, 2(t0)
    # ---- SINGLE kick, then poll used idx to 4 ----
    li t0, 0x10001000
    sw x0, 0x50(t0)    # QueueNotify = 0 (the only kick)
    # 20000 poll iterations is ~80x the ~2500 cycles a
    # 4-chain drain needs; it only bounds the wait, and
    # keeps the fail path (unfixed model) from burning
    # minutes in the simulator's slow poll loop.
    li t1, 20000
poll_drain:
    li t0, 0x80022000
    lhu t2, 2(t0)      # used idx
    li t3, 4
    beq t2, t3, drained
    addi t1, t1, -1
    bne t1, x0, poll_drain
    # Timeout: the drain did not happen.
    addi s0, s0, 1
    j done
drained:
    # used idx == 4; check each used entry (id, len), each
    # status byte, and each data word.
    li s1, 0
check_loop:
    # entry i: id at used+4+8i, len at used+8+8i
    li t0, 0x80022000
    slli t1, s1, 3     # 8i
    add t1, t1, t0
    lw t2, 4(t1)       # id
    slli t3, s1, 1
    add t3, t3, s1     # 3i
    bne t2, t3, fail
    lw t2, 8(t1)       # len
    li t3, 512
    bne t2, t3, fail
    # status byte i must be 0
    li t0, 0x80028000
    add t0, t0, s1
    lbu t2, 0(t0)
    bne t2, x0, fail
    # data word i must be 0x0N0N0N0N with N = 5+i
    slli t0, s1, 12
    li t1, 0x80024000
    add t0, t0, t1
    lw t2, 0(t0)
    addi t3, s1, 5     # N
    slli t1, t3, 8
    or t1, t1, t3
    slli t1, t1, 8
    or t1, t1, t3
    slli t1, t1, 8
    or t1, t1, t3     # expected = (N<<24)|(N<<16)|(N<<8)|N
    bne t2, t1, fail
    addi s1, s1, 1
    li t1, 4
    blt s1, t1, check_loop
    j done
fail:
    addi s0, s0, 1
done:
    mv a0, s0
    ecall
