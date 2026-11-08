# Virtio-mmio VERSION_1 negotiation test (M-mode, bare, on soc2).
# a0 = fail count. Mirrors the Linux kernel's vm_get_features /
# vm_finalize_features sequence for a version-2 virtio-mmio device:
#   DeviceFeaturesSel=1 -> DeviceFeatures must have bit 0 set
#     (VIRTIO_F_VERSION_1 = bit 32 of the 64-bit feature word)
#   DeviceFeaturesSel=0 -> DeviceFeatures low word (expect 0)
#   DriverFeaturesSel=1 -> DriverFeatures=1 (accept VERSION_1)
#   DriverFeaturesSel=0 -> DriverFeatures=0
#   Status = ACK|DRIVER|FEATURES_OK (0xB), read back: FEATURES_OK
#     bit must stick (the device must not refuse the features)
# then the usual queue setup and a READ of sector 5 through the
# v1 split-queue path (descriptor table / avail ring / used ring
# layout is shared by legacy and v1; the queue addresses use the
# Low/High registers, which is the v1 path -- legacy QueuePFN
# is never touched).
# Queue: desc 0x80020000, avail 0x80021000, used 0x80022000,
# QueueNum 8. Header buffer 0x80023000, data buffer
# 0x80024000, status byte 0x80025000.
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
    # Reset, then ACK | DRIVER.
    sw x0, 0x70(t0)
    li t1, 1
    sw t1, 0x70(t0)
    li t1, 3
    sw t1, 0x70(t0)
    # ---- v1 feature negotiation (kernel order: sel=1 first) ----
    li t1, 1
    sw t1, 0x14(t0)    # DeviceFeaturesSel = 1
    lw t1, 0x10(t0)    # high word: bit 0 = VIRTIO_F_VERSION_1
    li t2, 1
    bne t1, t2, fail
    sw x0, 0x14(t0)    # DeviceFeaturesSel = 0
    lw t1, 0x10(t0)    # low word: no legacy features offered
    bne t1, x0, fail
    # Accept VERSION_1 (high word) and nothing else (low word).
    li t1, 1
    sw t1, 0x24(t0)    # DriverFeaturesSel = 1
    li t1, 1
    sw t1, 0x20(t0)    # DriverFeatures = 1
    sw x0, 0x24(t0)    # DriverFeaturesSel = 0
    sw x0, 0x20(t0)    # DriverFeatures = 0
    li t1, 0xB
    sw t1, 0x70(t0)    # ACK|DRIVER|FEATURES_OK
    lw t1, 0x70(t0)
    andi t1, t1, 0x8   # FEATURES_OK must stick
    beq t1, x0, fail
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
    # ---- READ sector 5 into 0x80024000 ----
    jal ra, build_read5
    jal ra, notify_wait
    # Status byte must be 0, used idx 1, len 512, data word
    # 0x05050505 (sector 5 pattern byte = 5).
    li t0, 0x80025000
    lbu t1, 0(t0)
    bne t1, x0, fail
    li t0, 0x80022000
    lhu t1, 2(t0)      # used idx
    li t2, 1
    bne t1, t2, fail
    lw t1, 8(t0)       # used entry len (entry at +4: id, len)
    li t2, 512
    bne t1, t2, fail
    li t0, 0x80024000
    lw t1, 0(t0)
    li t2, 0x05050505
    bne t1, t2, fail
    # Ack the interrupt, check InterruptStatus clears.
    li t0, 0x10001000
    li t1, 1
    sw t1, 0x64(t0)    # InterruptACK
    lw t1, 0x60(t0)
    bne t1, x0, fail
    j done
fail:
    addi s0, s0, 1
done:
    mv a0, s0
    ecall

# Build a READ chain for sector 5. Clobbers t0-t2, a0-a1.
build_read5:
    li t0, 0x80023000
    sw x0, 0(t0)       # type = 0 (read)
    sw x0, 4(t0)       # reserved
    li t1, 5
    sw t1, 8(t0)       # sector lo
    sw x0, 12(t0)      # sector hi
    li t0, 0x80020000
    li t1, 0x80023000
    sw t1, 0(t0)       # desc0 addr
    sw x0, 4(t0)
    li t1, 16
    sw t1, 8(t0)       # desc0 len
    li t1, 0x10001      # flags NEXT | next=1
    sw t1, 12(t0)
    li t1, 0x80024000
    sw t1, 16(t0)      # desc1 addr
    sw x0, 20(t0)
    li t1, 512
    sw t1, 24(t0)      # desc1 len
    li t1, 0x20002      # flags WRITE | next=2
    sw t1, 28(t0)
    li t1, 0x80025000
    sw t1, 32(t0)      # desc2 addr
    sw x0, 36(t0)
    li t1, 1
    sw t1, 40(t0)      # desc2 len
    li t1, 0x2         # flags WRITE, no NEXT
    sw t1, 44(t0)
    li t0, 0x80021000
    sw x0, 0(t0)       # avail flags
    li t1, 1
    sh t1, 2(t0)       # avail idx = 1
    sh x0, 4(t0)       # avail ring[0] = 0
    ret

# Notify queue 0, then poll InterruptStatus bit 0 (timeout).
notify_wait:
    li t0, 0x10001000
    sw x0, 0x50(t0)    # QueueNotify = 0
    li t1, 100000
poll_v:
    lw t2, 0x60(t0)    # InterruptStatus
    andi t2, t2, 1
    bne t2, x0, notified
    addi t1, t1, -1
    bne t1, x0, poll_v
    # Timeout: count as failure in the caller? Signal via s0.
    addi s0, s0, 1
notified:
    ret
