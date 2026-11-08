// big32_soc2 — Phase 5 platform top for the pipelined core.
// ---------------------------------------------------------------------------
// This is a NEW top; src/big32_soc.v (Phases 2-4) is untouched, so
// ./run_os.sh regressions keep running on the old platform.
//
// Memory map (physical addresses):
//   ROM   0x00000000..0x00000FFF : two instructions, jump to RAM
//         (lui t0, 0x80000; jalr x0, 0(t0)) — the core resets pc
//         to 0, and RAM lives at 0x80000000, so the ROM is the
//         only thing that can bridge the gap (jal cannot reach
//         that far). ROM is read-only; data writes there are
//         ignored, data reads return the ROM word.
//   RAM   0x80000000..0x80000000+MEM_BYTES-1 (parameter, default
//         16 MiB; index = addr - 0x80000000). Instruction fetch
//         and data access share it (unified, as in soc.v).
//   PLIC  0x0C000000 (see below; standard PLIC register layout)
//   UART (legacy, core-driven) 0x10000000 TX / 0x10000004 RX /
//         0x10000008 status — kept for SBI console and old
//         programs. The core itself pulses uart_tx on a store
//         to 0x10000000 and overrides loads from +4/+8, so the
//         16550 below CANNOT live at 0x10000000 (its RBR would
//         collide with the core's RX override). Hence:
//   UART (16550) 0x10010000 : RBR/THR +0, IER +1, IIR/FCR +2,
//         LCR +3, MCR +4, LSR +5, MSR +6, SCR +7, DLL/DLM when
//         LCR.DLAB=1. FIFO is always on (documented deviation:
//         FCR bit 0 is stored but the FIFO does not switch
//         off). TX pulses the top-level uart_tx on THR writes.
//   Virtio-mmio block 0x10001000 (device ID 2, version 2,
//         queue 0 only, single-sector and multi-descriptor
//         chains; see the virtio FSM below).
//   CLINT 0x02004000 mtimecmp (64-bit, low at +0, high at +4),
//         0x0200BFF8 mtime (64-bit, low at +0, high at +4).
//         mtime increments 1/cycle; timer interrupt pends
//         while mtime >= mtimecmp (64-bit compare).
//
// PLIC (simplified but spec-shaped): sources 1=UART16550,
// 2=virtio block, 3=external line. Priority registers, pending
// bits, per-context enables (context 0 = M, 1 = S), thresholds,
// claim/complete. Pending is LEVEL: a source stays pending
// while its device asserts it, so a handler must drain/ack
// the device before completing, or the interrupt retakes —
// that is correct PLIC behaviour for level sources, not a bug.
// The core sees one irq_ext line: it is asserted when EITHER
// context has a claimable interrupt; the core's own M/S
// delegation logic (mideleg/sie/mie) then decides which mode
// takes it, exactly as with the old external line.
//
// Virtio-mmio: only queue 0, only block device. The driver
// (S-mode test programs, and later a kernel) does the usual
// sequence: reset (Status=0), ACKNOWLEDGE, DRIVER, read
// features, FEATURES_OK, set queue addresses, QUEUE_READY,
// DRIVER_OK, then QueueNotify. Feature negotiation is v1:
// DeviceFeatures (0x010) is selected by DeviceFeaturesSel
// (0x014); sel=1 bit 0 advertises VIRTIO_F_VERSION_1, which
// the Linux virtio-mmio driver requires of a version-2
// device. The queue path needs no v1-specific change: the
// split-queue layout (16-byte descriptors, avail ring,
// used ring) and the Desc/Driver/Device Low/High address
// registers are shared by legacy and v1, the guest is
// little-endian as v1 requires, and legacy QueuePFN is
// never used by a v1 driver. On notify the FSM walks the
// descriptor chain from guest RAM, copies data between RAM
// and the internal disk array (DISK_BYTES, default 1 MiB =
// 2048 sectors of 512 bytes), writes the used ring, sets
// InterruptStatus bit 0, and asserts PLIC source 2 until the
// driver acks. The disk is initialised with a checkable
// pattern (sector s, word w = (s<<16)|w) unless the testbench
// overwrites it hierarchically (dut.disk[...]).
// Guest physical addresses in descriptors are translated by
// subtracting RAM_BASE; addresses outside RAM abort the
// request (used entry written with len 0, status byte 1).
// ---------------------------------------------------------------------------
`default_nettype none

module big32_soc2 #(
    parameter MEM_BYTES = 1048576,
    parameter DISK_BYTES = 1048576
) (
    input  wire        clk,
    input  wire        rst_n,
    output wire        halted,
    output wire [7:0]  uart_tx,
    output wire        uart_tx_valid,
    input  wire        ext_irq,
    input  wire [7:0]  rx_data,
    input  wire        rx_valid,
    input  wire [7:0]  rx2_data,
    input  wire        rx2_valid,
    output wire [7:0]  net_tx,
    output wire        net_tx_valid,
    input  wire [7:0]  net_rx_data,
    input  wire        net_rx_valid,
    input  wire [31:0] ptr_x,
    input  wire [31:0] ptr_y,
    input  wire        ptr_btn
);
    localparam [31:0] RAM_BASE = 32'h80000000;
    localparam [31:0] PLIC_BASE = 32'h0C000000;
    localparam [31:0] UART16550_BASE = 32'h10010000;
    localparam [31:0] VIRTIO_BASE = 32'h10001000;

    // RAM is a WORD array, not a byte array, and the virtio
    // FSM reads it through a single synchronous port (below).
    // Rationale (measured 26 Oct 2026): with a byte array and
    // ~44 combinational byte-read ports, iverilog elaboration
    // took 3m43s at just 64 KiB and grew with size, because
    // each async port builds a full address mux. Word reads
    // (4 async ports total: fetch x2, data x2) plus one sync
    // virtio port keep elaboration practical. MEM_BYTES must
    // stay a power of two, multiple of 4.
    localparam [31:0] MEM_WORDS = MEM_BYTES / 4;
    reg [31:0] memw [0:MEM_WORDS-1];
    reg [7:0] disk [0:DISK_BYTES-1];

    // ---- ROM: lui t0, 0x80000 ; jalr x0, 0(t0) ---------------------
    function [31:0] rom_word;
        input [31:0] a;
        begin
            case (a)
                32'd0: rom_word = 32'h800002B7; // lui t0, 0x80000
                32'd4: rom_word = 32'h00028067; // jalr x0, 0(t0)
                default: rom_word = 32'h00000013; // nop
            endcase
        end
    endfunction

    // ---- 64-bit CLINT ----------------------------------------------
    reg [63:0] mtime_r, mtimecmp_r;
    // Phase 5 SBI IPI register (0x10002000): set by the
    // firmware's sPI call, cleared by the S handler.
    reg sbi_ipi_pending;
    wire irq_timer_w = (mtime_r >= mtimecmp_r);

    // ---- 16550 UART -------------------------------------------------
    reg [7:0] u16550_ier, u16550_lcr, u16550_mcr, u16550_scr;
    reg [7:0] u16550_dll, u16550_dlm;
    reg [7:0] u16550_fifo [0:15];
    reg [3:0] u16550_head, u16550_tail;
    reg [4:0] u16550_count;
    reg [7:0] u16550_tx;
    reg       u16550_tx_valid;
    wire u16550_dr = (u16550_count != 5'd0);
    wire u16550_thre = 1'b1; // TX is always empty in simulation
    wire u16550_irq = (u16550_dr && u16550_ier[0]) ||
                      (u16550_thre && u16550_ier[1]);
    // IIR: bit0=0 pending; ID bits[3:1]: 010 RDA, 001 THRE;
    // bits[7:6]=11 FIFO enabled (always).
    wire [7:0] u16550_iir = u16550_irq ?
        ((u16550_dr && u16550_ier[0]) ? 8'hC4 : 8'hC2) : 8'hC1;
    wire [7:0] u16550_lsr = {1'b0, 1'b1, 1'b1, 3'b0, 1'b0, u16550_dr};
    // LSR bits: 7=0, 6=TEMT=1, 5=THRE=1, 4-2=0, 1=0, 0=DR.

    // ---- Legacy UART RX (0x10000004) ---------------------------------
    // The pipelined core already implements the legacy RX contract
    // (load from 0x10000004 returns the byte when ready, -1 when
    // empty; uart_rx_pop fires on a real load while ready), but
    // the SOC tied uart_rx_ready to 0, so no byte could ever
    // arrive. This FIFO connects the top-level rx_data/rx_valid
    // pins to the core, in the same push/pop discipline as the
    // 16550 FIFO below. Full at 16 bytes, further bytes drop.
    reg [7:0] rx_fifo [0:15];
    reg [3:0] rx_head, rx_tail;
    reg [4:0] rx_count;
    wire rx_ready_w = (rx_count != 5'd0);
    wire [7:0] rx_byte_w = rx_fifo[rx_head];

    // ---- Network packet device (0x10003000) ------------------------
    // A serial link device: SLIP over a serial line (RFC 1055).
    // The kernel's SLIP + checksum + echo stack talks to it, and
    // bytes cross the device boundary to a peer instead of a
    // shared-memory loopback. Registers (word-aligned):
    //   +0x00 TX_DATA (WO): write a byte -> transmit queue.
    //   +0x04 RX_DATA (RO): read -> pop a byte, or -1 if empty.
    //   +0x08 STATUS  (RO): bit0 = RX ready, bit1 = TX not full.
    // FIFOs are 64 bytes; a full TX FIFO drops the written
    // byte, a full RX FIFO drops the incoming byte. TX drains
    // one byte per cycle to the net_tx pins. RX pop uses the
    // same mem_load_w discipline as the 16550 RBR.
    localparam [31:0] NET_BASE = 32'h10003000;
    // ---- Text-mode framebuffer (0x10004000) ------------------------
    // VGA-text-style VRAM: 80x25 cells, 2 bytes per cell (char
    // + attribute), stored as 1000 words (2 cells per word:
    // low half = even cell, high half = odd cell). Word
    // stores only (the language's poke32 is a word store);
    // reads return the aligned word, 0 for unaligned. VRAM
    // is NOT reset-cleared: like real hardware it powers up
    // undefined, and the kernel must clear it. No new pins:
    // the display side reads this array (the testbench
    // reads it hierarchically; a real display would scan it).
    localparam [31:0] FB_BASE = 32'h10004000;
    reg [31:0] vramw [0:999];
    // ---- Pixel framebuffer (0x10020000) --------------------------
    // Mode-13h-style, grown to 640x480 for the macOS look:
    // 8 bits per pixel, 307200 bytes stored as 76800 words.
    // Byte 0 of a word is the leftmost of its 4 pixels. Word
    // stores only, aligned-word reads, NOT reset-cleared
    // (same rule as the text VRAM). A real display would
    // scan this through a palette; the bytes here are
    // palette indices, and the palette itself is a later
    // step, not this one.
    localparam [31:0] PIX_BASE = 32'h10020000;
    reg [31:0] pixw [0:76799];
    // ---- Pointer device (0x10006000) ---------------------------
    // Absolute pointer, TB-driven for now (like a
    // touchscreen reporting position): X +0x00, Y +0x04,
    // buttons +0x08 (bit0 = primary). Read-only; the
    // kernel polls. Unconnected top-level pins (other
    // testbenches) read as 0 via the x-guards below.
    localparam [31:0] PTR_BASE = 32'h10006000;
    wire [31:0] ptr_x_w = ((^ptr_x) === 1'bx) ? 32'd0 : ptr_x;
    wire [31:0] ptr_y_w = ((^ptr_y) === 1'bx) ? 32'd0 : ptr_y;
    wire ptr_btn_w = ((^ptr_btn) === 1'bx) ? 1'b0 : ptr_btn;    reg [7:0] net_tx_fifo [0:63];
    reg [7:0] net_rx_fifo [0:63];
    reg [5:0] net_tx_head, net_tx_tail;
    reg [5:0] net_rx_head, net_rx_tail;
    reg [6:0] net_tx_count, net_rx_count;
    reg [7:0] net_tx_r;
    reg net_tx_valid_r;
    assign net_tx = net_tx_r;
    assign net_tx_valid = net_tx_valid_r;
    wire net_rx_ready_w = (net_rx_count != 7'd0);
    wire net_tx_notfull_w = (net_tx_count != 7'd64);

    // ---- PLIC --------------------------------------------------------
    reg [2:0] plic_prio [1:3];
    reg [31:0] plic_enable_m, plic_enable_s;
    reg [2:0] plic_thresh_m, plic_thresh_s;
    reg plic_claimed [1:3];
    wire plic_pend1 = u16550_irq;
    wire plic_pend2 = virtio_irq_w;
    wire plic_pend3 = ext_irq;
    // Claim resolution (combinational, per context).
    reg [31:0] plic_claim_m, plic_claim_s;
    reg [2:0] plic_best_prio_m, plic_best_prio_s;
    integer pi;
    always @* begin
        plic_claim_m = 32'd0; plic_best_prio_m = 3'd0;
        for (pi = 1; pi <= 3; pi = pi + 1) begin
            if (plic_enable_m[pi] && !plic_claimed[pi]) begin
                if ((pi == 1) && plic_pend1 &&
                    (plic_prio[1] > plic_thresh_m) &&
                    (plic_prio[1] > plic_best_prio_m)) begin
                    plic_claim_m = 32'd1; plic_best_prio_m = plic_prio[1];
                end
                if ((pi == 2) && plic_pend2 &&
                    (plic_prio[2] > plic_thresh_m) &&
                    (plic_prio[2] > plic_best_prio_m)) begin
                    plic_claim_m = 32'd2; plic_best_prio_m = plic_prio[2];
                end
                if ((pi == 3) && plic_pend3 &&
                    (plic_prio[3] > plic_thresh_m) &&
                    (plic_prio[3] > plic_best_prio_m)) begin
                    plic_claim_m = 32'd3; plic_best_prio_m = plic_prio[3];
                end
            end
        end
        plic_claim_s = 32'd0; plic_best_prio_s = 3'd0;
        for (pi = 1; pi <= 3; pi = pi + 1) begin
            if (plic_enable_s[pi] && !plic_claimed[pi]) begin
                if ((pi == 1) && plic_pend1 &&
                    (plic_prio[1] > plic_thresh_s) &&
                    (plic_prio[1] > plic_best_prio_s)) begin
                    plic_claim_s = 32'd1; plic_best_prio_s = plic_prio[1];
                end
                if ((pi == 2) && plic_pend2 &&
                    (plic_prio[2] > plic_thresh_s) &&
                    (plic_prio[2] > plic_best_prio_s)) begin
                    plic_claim_s = 32'd2; plic_best_prio_s = plic_prio[2];
                end
                if ((pi == 3) && plic_pend3 &&
                    (plic_prio[3] > plic_thresh_s) &&
                    (plic_prio[3] > plic_best_prio_s)) begin
                    plic_claim_s = 32'd3; plic_best_prio_s = plic_prio[3];
                end
            end
        end
    end
    wire plic_irq_w = (plic_claim_m != 32'd0) ||
                      (plic_claim_s != 32'd0);

    // ---- Virtio-mmio registers --------------------------------------
    reg [31:0] v_status, v_feat_sel, v_drv_feat, v_drv_feat_sel;
    reg [31:0] v_queue_sel, v_queue_num, v_queue_ready;
    reg [31:0] v_desc_lo, v_desc_hi, v_drv_lo, v_drv_hi;
    reg [31:0] v_dev_lo, v_dev_hi, v_int_status;
    reg [31:0] v_notify_q;
    // Virtio FSM state.
    reg [3:0] v_state;
    reg [31:0] v_avail_idx, v_used_idx, v_cur_desc, v_desc_addr;
    reg [31:0] v_req_type, v_req_sector_lo, v_req_sector_hi;
    reg [31:0] v_data_addr, v_data_len, v_data_off, v_status_addr;
    // Synchronous virtio RAM read port: v_rd_addr is a RAM
    // BYTE offset; v_rd_data is the word at that offset,
    // valid one cycle after the address settles (see the
    // v_rd_armed wait in each V_RD_* state). v_d0/v_d2/v_d3
    // are the latched current-descriptor words (addr, len,
    // flags/next); v_hdr0/v_hdr2 latch the block-header
    // words (type, sector lo). All virtio guest-RAM reads
    // are word-aligned (descriptors, rings, headers).
    reg [31:0] v_rd_addr, v_rd_data;
    reg v_rd_armed;
    reg [31:0] v_d0, v_d2, v_d3, v_hdr0, v_hdr2;
    reg [31:0] v_disk_off, v_chain_len, v_used_len;
    reg v_req_write, v_req_error;
    reg [7:0] v_tmp_byte;
    wire virtio_irq_w = (v_int_status != 32'd0);
    localparam [3:0] V_IDLE = 4'd0,
        V_DESC = 4'd3, V_HDR = 4'd4, V_COPY = 4'd5, V_STATUS = 4'd6,
        V_USED = 4'd7,
        // Synchronous-read states (see below): each waits one
        // cycle for v_rd_data to become valid (v_rd_armed),
        // then consumes it. V_AVAIL/V_AVAIL2 are gone: the
        // avail/ring reads are V_RD_AVAIL/V_RD_RING now.
        V_RD_AVAIL = 4'd8, V_RD_RING = 4'd9, V_RD_D0 = 4'd10,
        V_RD_D2 = 4'd11, V_RD_D3 = 4'd12, V_RD_H0 = 4'd13,
        V_RD_H2 = 4'd14, V_RD_H3 = 4'd15;

    // ---- Core ---------------------------------------------------------
    wire [31:0] instr_w, if_addr_w, d_addr_w, d_rdata_w;
    wire [31:0] d_wdata_w;
    wire [3:0] d_wmask_w;
    wire d_we_w, rx_pop_w, mem_load_w;
    wire [7:0] core_tx;
    wire core_tx_valid;
    big32_core_pipe core (
        .clk(clk), .rst_n(rst_n), .halted(halted),
        .uart_tx(core_tx), .uart_tx_valid(core_tx_valid),
        .instr_i(instr_w), .if_addr_o(if_addr_w),
        .d_addr_o(d_addr_w), .d_rdata_i(d_rdata_w),
        .d_wdata_o(d_wdata_w), .d_wmask_o(d_wmask_w),
        .d_we_o(d_we_w),
        .irq_timer(irq_timer_w), .irq_ext(plic_irq_w),
        .irq_soft(sbi_ipi_pending),
        .uart_rx_ready(rx_ready_w), .uart_rx_data(rx_byte_w),
        .uart_rx_pop(rx_pop_w), .mem_load_o(mem_load_w)
    );
    assign uart_tx = u16550_tx_valid ? u16550_tx : core_tx;
    assign uart_tx_valid = u16550_tx_valid | core_tx_valid;

    // ---- Address helpers ---------------------------------------------
    wire in_ram = (d_addr_w >= RAM_BASE) &&
                  (d_addr_w < (RAM_BASE + MEM_BYTES));
    wire [31:0] ram_idx = d_addr_w - RAM_BASE;
    wire in_ram_if = (if_addr_w >= RAM_BASE) &&
                     (if_addr_w < (RAM_BASE + MEM_BYTES));
    wire [31:0] ram_idx_if = if_addr_w - RAM_BASE;
    wire in_rom_if = (if_addr_w < 32'h00001000);
    wire in_rom_d = (d_addr_w < 32'h00001000);
    wire in_plic = (d_addr_w >= PLIC_BASE) &&
                   (d_addr_w < (PLIC_BASE + 32'h04000000));
    wire in_uart16550 = (d_addr_w >= UART16550_BASE) &&
                        (d_addr_w < (UART16550_BASE + 32'h100));
    wire in_virtio = (d_addr_w >= VIRTIO_BASE) &&
                     (d_addr_w < (VIRTIO_BASE + 32'h1000));
    wire in_net = (d_addr_w >= NET_BASE) &&
                  (d_addr_w < (NET_BASE + 32'h10));
    wire in_fb = (d_addr_w >= FB_BASE) &&
                 (d_addr_w < (FB_BASE + 32'h1000));
    wire [31:0] fb_idx = (d_addr_w - FB_BASE) >> 2;
    wire in_pix = (d_addr_w >= PIX_BASE) &&
                  (d_addr_w < (PIX_BASE + 32'h4B000));
    wire [31:0] pix_idx = (d_addr_w - PIX_BASE) >> 2;
    wire in_ptr = (d_addr_w >= PTR_BASE) &&
                  (d_addr_w < (PTR_BASE + 32'h10));
    wire in_clint = ((d_addr_w >= 32'h02004000) &&
                     (d_addr_w < 32'h02004010)) ||
                    ((d_addr_w >= 32'h0200BFF8) &&
                     (d_addr_w < 32'h0200C008));

    // CPU store -> word RMW helpers. The core's write mask
    // is RELATIVE: bit i writes byte i to addr+i, so an
    // unaligned store spans two words. Shift the data and the
    // mask into word alignment: byte j of the store lands at
    // byte (addr[1:0]+j) of the {word1, word0} pair.
    wire [63:0] st_data64 = ({32'b0, d_wdata_w} <<
                             {d_addr_w[1:0], 3'b0});
    wire [7:0] st_mask8 = ({4'b0, d_wmask_w} << d_addr_w[1:0]);
    wire [31:0] st_mask0 = {{8{st_mask8[3]}}, {8{st_mask8[2]}},
                            {8{st_mask8[1]}}, {8{st_mask8[0]}}};
    wire [31:0] st_mask1 = {{8{st_mask8[7]}}, {8{st_mask8[6]}},
                            {8{st_mask8[5]}}, {8{st_mask8[4]}}};
    wire [31:0] st_widx = ram_idx[31:2];
    wire [31:0] st_widx1 = (ram_idx[31:2] + 32'd1) &
                           (MEM_WORDS - 1);

    // ---- Instruction fetch --------------------------------------------
    // Two word reads + merge: the core's interface delivers
    // the 4 bytes at addr..addr+3, so a halfword-aligned
    // fetch spans two words. Word index = byte offset >> 2.
    wire [31:0] if_w0 = memw[ram_idx_if[31:2]];
    wire [31:0] if_w1 = memw[(ram_idx_if[31:2] + 32'd1) &
                             (MEM_WORDS - 1)];
    wire [31:0] if_word_ram = (if_addr_w[1:0] == 2'd0) ? if_w0 :
        (if_addr_w[1:0] == 2'd1) ? {if_w1[7:0], if_w0[31:8]} :
        (if_addr_w[1:0] == 2'd2) ? {if_w1[15:0], if_w0[31:16]} :
        {if_w1[23:0], if_w0[31:24]};
    wire [31:0] if_word = in_rom_if ? rom_word(if_addr_w) :
        in_ram_if ? if_word_ram : 32'h00000013;
    assign instr_w = if_word;

    // Data word reads + merge, as for fetch above.
    wire [31:0] data_w0 = memw[ram_idx[31:2]];
    wire [31:0] data_w1 = memw[(ram_idx[31:2] + 32'd1) &
                               (MEM_WORDS - 1)];
    wire [31:0] data_word_ram = (d_addr_w[1:0] == 2'd0) ? data_w0 :
        (d_addr_w[1:0] == 2'd1) ? {data_w1[7:0], data_w0[31:8]} :
        (d_addr_w[1:0] == 2'd2) ? {data_w1[15:0], data_w0[31:16]} :
        {data_w1[23:0], data_w0[31:24]};

    // ---- Data read mux --------------------------------------------------
    reg [31:0] dev_rdata;
    always @* begin
        if (in_ram) begin
            dev_rdata = data_word_ram;
        end else if (in_rom_d) begin
            dev_rdata = rom_word(d_addr_w);
        end else if (d_addr_w == 32'h02004000) begin
            dev_rdata = mtimecmp_r[31:0];
        end else if (d_addr_w == 32'h02004004) begin
            dev_rdata = mtimecmp_r[63:32];
        end else if (d_addr_w == 32'h0200BFF8) begin
            dev_rdata = mtime_r[31:0];
        end else if (d_addr_w == 32'h0200BFFC) begin
            dev_rdata = mtime_r[63:32];
        end else if (d_addr_w == 32'h10002000) begin
            dev_rdata = {31'b0, sbi_ipi_pending};
        end else if (in_uart16550) begin
            case (d_addr_w[3:0])
                4'h0: dev_rdata = u16550_lcr[7] ? {24'b0, u16550_dll} :
                       (u16550_dr ? {24'b0, u16550_fifo[u16550_head]} : 32'b0);
                4'h1: dev_rdata = u16550_lcr[7] ? {24'b0, u16550_dlm} :
                       {24'b0, u16550_ier};
                4'h2: dev_rdata = {24'b0, u16550_iir};
                4'h3: dev_rdata = {24'b0, u16550_lcr};
                4'h4: dev_rdata = {24'b0, u16550_mcr};
                4'h5: dev_rdata = {24'b0, u16550_lsr};
                4'h6: dev_rdata = 8'h00; // MSR: no modem lines
                4'h7: dev_rdata = {24'b0, u16550_scr};
                default: dev_rdata = 32'b0;
            endcase
        end else if (in_plic) begin
            dev_rdata = plic_rdata(d_addr_w);
        end else if (in_virtio) begin
            dev_rdata = virtio_rdata(d_addr_w);
        end else if (in_net) begin
            case (d_addr_w[3:0])
                4'h0: dev_rdata = 32'b0; // TX_DATA is write-only
                4'h4: dev_rdata = net_rx_ready_w ?
                       {24'b0, net_rx_fifo[net_rx_head]} : 32'hFFFFFFFF;
                4'h8: dev_rdata = {30'b0, net_tx_notfull_w, net_rx_ready_w};
                default: dev_rdata = 32'b0;
            endcase
        end else if (in_fb) begin
            dev_rdata = (d_addr_w[1:0] == 2'd0) ? vramw[fb_idx] : 32'b0;
        end else if (in_pix) begin
            dev_rdata = (d_addr_w[1:0] == 2'd0) ? pixw[pix_idx] : 32'b0;
        end else if (in_ptr) begin
            case (d_addr_w[3:0])
                4'h0: dev_rdata = ptr_x_w;
                4'h4: dev_rdata = ptr_y_w;
                4'h8: dev_rdata = {31'b0, ptr_btn_w};
                default: dev_rdata = 32'b0;
            endcase
        end else begin
            dev_rdata = 32'b0;
        end
    end
    assign d_rdata_w = dev_rdata;

    // ---- PLIC / virtio read functions (combinational) ---------------
    function [31:0] plic_rdata;
        input [31:0] a;
        reg [31:0] off;
        begin
            off = a - PLIC_BASE;
            if (off < 32'h00000100) begin
                // Priority registers, one word per source.
                if (off == 32'h4) plic_rdata = {29'b0, plic_prio[1]};
                else if (off == 32'h8) plic_rdata = {29'b0, plic_prio[2]};
                else if (off == 32'hC) plic_rdata = {29'b0, plic_prio[3]};
                else plic_rdata = 32'b0;
            end else if (off == 32'h001000) begin
                plic_rdata = {28'b0, plic_pend3, plic_pend2,
                              plic_pend1, 1'b0};
            end else if (off >= 32'h002000 && off < 32'h002080) begin
                plic_rdata = plic_enable_m;
            end else if (off >= 32'h002080 && off < 32'h002100) begin
                plic_rdata = plic_enable_s;
            end else if (off == 32'h200000) begin
                plic_rdata = {29'b0, plic_thresh_m};
            end else if (off == 32'h200004) begin
                plic_rdata = plic_claim_m;
            end else if (off == 32'h201000) begin
                plic_rdata = {29'b0, plic_thresh_s};
            end else if (off == 32'h201004) begin
                plic_rdata = plic_claim_s;
            end else begin
                plic_rdata = 32'b0;
            end
        end
    endfunction

    function [31:0] virtio_rdata;
        input [31:0] a;
        reg [31:0] off;
        begin
            off = a - VIRTIO_BASE;
            case (off)
                32'h000: virtio_rdata = 32'h74726976; // "virt"
                32'h004: virtio_rdata = 32'd2;        // version
                32'h008: virtio_rdata = 32'd2;        // block
                32'h00C: virtio_rdata = 32'h42494733; // "BIG3"
                // Device features, selected by v_feat_sel (write
                // to 0x014): sel=0 -> low word (no legacy block
                // features offered); sel=1 -> high word bit 0 =
                // VIRTIO_F_VERSION_1 (bit 32 of the 64-bit
                // feature word). The Linux virtio-mmio driver
                // (vm_get_features: sel=1 first, then sel=0)
                // refuses a version-2 device without this bit
                // (probe -EINVAL, no /dev/vda), so it must be
                // advertised. No other feature bit is offered:
                // the driver then uses only the default block
                // behaviour, which the FSM already implements.
                32'h010: virtio_rdata =
                    (v_feat_sel == 32'd1) ? 32'h00000001 : 32'd0;
                32'h020: virtio_rdata = v_drv_feat;
                32'h030: virtio_rdata = v_queue_sel;
                32'h034: virtio_rdata = 32'd64;       // QueueNumMax
                32'h038: virtio_rdata = v_queue_num;
                32'h044: virtio_rdata = v_queue_ready;
                32'h060: virtio_rdata = v_int_status;
                32'h070: virtio_rdata = v_status;
                32'h080: virtio_rdata = v_desc_lo;
                32'h084: virtio_rdata = v_desc_hi;
                32'h090: virtio_rdata = v_drv_lo;
                32'h094: virtio_rdata = v_drv_hi;
                32'h0A0: virtio_rdata = v_dev_lo;
                32'h0A4: virtio_rdata = v_dev_hi;
                32'h0FC: virtio_rdata = 32'd0;
                32'h100: virtio_rdata = DISK_BYTES / 512;
                32'h104: virtio_rdata = 32'd0; // capacity high
                default: virtio_rdata = 32'b0;
            endcase
        end
    endfunction

    // ---- Virtio FSM RAM addressing (no combinational reads) -------
    // Guest PA -> RAM byte offset (only valid when in range;
    // the FSM checks range before using these). The actual
    // reads go through the synchronous v_rd_* port: the FSM
    // sets v_rd_addr, waits one cycle (v_rd_armed), then
    // consumes v_rd_data. This keeps guest RAM a real memory
    // in iverilog instead of ~44 async-read muxes.
    wire [31:0] v_drv_idx = v_drv_lo - RAM_BASE;
    wire [31:0] v_desc_idx = v_desc_lo - RAM_BASE;
    wire [31:0] v_dev_idx = v_dev_lo - RAM_BASE;
    // Ring word containing the NEXT entry for the device to
    // process: the device tracks its own last-seen avail index
    // (v_last_avail), because a driver places new entries at
    // the device's last index, not at the current avail counter.
    // Ring position = v_last_avail % QueueNum; word at
    // drv_base + 4 + (pos/2)*4, halfword by pos parity.
    reg [31:0] v_last_avail;
    wire [31:0] v_ring_pos = v_last_avail %
        (v_queue_num == 32'd0 ? 32'd64 : v_queue_num);
    wire [31:0] v_ring_addr = v_drv_idx + 32'd4 +
        (v_ring_pos / 32'd2) * 32'd4;
    // Byte-copy helpers for V_COPY/V_STATUS (word RMW).
    wire [31:0] v_copy_widx = ((v_data_addr - RAM_BASE +
                                v_data_off) >> 2) & (MEM_WORDS - 1);
    wire [1:0] v_copy_lane = v_data_addr[1:0] + v_data_off[1:0];
    wire [31:0] v_stat_widx = ((v_status_addr - RAM_BASE) >> 2) &
                              (MEM_WORDS - 1);
    wire [1:0] v_stat_lane = v_status_addr[1:0];

    // ---- Clocked state --------------------------------------------------
    integer ci;
    reg [31:0] v_copy_src, v_copy_dst;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mtime_r <= 64'b0;
            mtimecmp_r <= 64'hFFFFFFFFFFFFFFFF;
            sbi_ipi_pending <= 1'b0;
            u16550_ier <= 8'b0; u16550_lcr <= 8'b0;
            u16550_mcr <= 8'b0; u16550_scr <= 8'b0;
            u16550_dll <= 8'b0; u16550_dlm <= 8'b0;
            u16550_head <= 4'b0; u16550_tail <= 4'b0;
            u16550_count <= 5'b0;
            rx_head <= 4'b0; rx_tail <= 4'b0; rx_count <= 5'b0;
            net_tx_head <= 6'b0; net_tx_tail <= 6'b0;
            net_tx_count <= 7'b0;
            net_rx_head <= 6'b0; net_rx_tail <= 6'b0;
            net_rx_count <= 7'b0;
            net_tx_valid_r <= 1'b0;
            u16550_tx <= 8'b0; u16550_tx_valid <= 1'b0;
            plic_prio[1] <= 3'd0; plic_prio[2] <= 3'd0;
            plic_prio[3] <= 3'd0;
            plic_enable_m <= 32'b0; plic_enable_s <= 32'b0;
            plic_thresh_m <= 3'd0; plic_thresh_s <= 3'd0;
            plic_claimed[1] <= 1'b0; plic_claimed[2] <= 1'b0;
            plic_claimed[3] <= 1'b0;
            v_status <= 32'b0; v_feat_sel <= 32'b0;
            v_drv_feat <= 32'b0; v_drv_feat_sel <= 32'b0;
            v_queue_sel <= 32'b0; v_queue_num <= 32'b0;
            v_queue_ready <= 32'b0;
            v_desc_lo <= 32'b0; v_desc_hi <= 32'b0;
            v_drv_lo <= 32'b0; v_drv_hi <= 32'b0;
            v_dev_lo <= 32'b0; v_dev_hi <= 32'b0;
            v_int_status <= 32'b0; v_notify_q <= 32'b0;
            v_state <= V_IDLE;
            v_avail_idx <= 32'b0; v_used_idx <= 32'b0;
            v_cur_desc <= 32'b0; v_desc_addr <= 32'b0;
            v_req_type <= 32'b0; v_req_sector_lo <= 32'b0;
            v_req_sector_hi <= 32'b0;
            v_data_addr <= 32'b0; v_data_len <= 32'b0;
            v_data_off <= 32'b0; v_status_addr <= 32'b0;
            v_disk_off <= 32'b0; v_chain_len <= 32'b0;
            v_used_len <= 32'b0; v_req_write <= 1'b0;
            v_req_error <= 1'b0; v_tmp_byte <= 8'b0;
            v_last_avail <= 32'b0;
            v_copy_src <= 32'b0; v_copy_dst <= 32'b0;
            v_rd_addr <= 32'b0; v_rd_data <= 32'b0;
            v_rd_armed <= 1'b0;
            v_d0 <= 32'b0; v_d2 <= 32'b0; v_d3 <= 32'b0;
            v_hdr0 <= 32'b0; v_hdr2 <= 32'b0;
        end else begin
            // Synchronous virtio RAM read: v_rd_data tracks
            // v_rd_addr with one cycle of latency. This is a
            // clocked-block read, so memw stays a memory.
            v_rd_data <= memw[(v_rd_addr >> 2) & (MEM_WORDS - 1)];
            mtime_r <= mtime_r + 64'd1;
            u16550_tx_valid <= 1'b0;
            // ---- 16550 RX FIFO push/pop, single section ------------
            // Push = testbench byte; pop = a real MEM load from
            // RBR (mem_load_w guards against ALU instructions
            // whose rs1 merely equals the RBR address).
            begin : u16550_fifo_io
                reg push, pop;
                push = rx2_valid && (u16550_count != 5'd16);
                pop = mem_load_w && in_uart16550 &&
                      (d_addr_w[3:0] == 4'h0) && !u16550_lcr[7] &&
                      u16550_dr;
                case ({push, pop})
                    2'b10: begin
                        u16550_fifo[u16550_tail] <= rx2_data;
                        u16550_tail <= u16550_tail + 4'd1;
                        u16550_count <= u16550_count + 5'd1;
                    end
                    2'b01: begin
                        u16550_head <= u16550_head + 4'd1;
                        u16550_count <= u16550_count - 5'd1;
                    end
                    2'b11: begin
                        u16550_fifo[u16550_tail] <= rx2_data;
                        u16550_tail <= u16550_tail + 4'd1;
                        u16550_head <= u16550_head + 4'd1;
                    end
                    default: begin end
                endcase
            end
            // ---- Legacy UART RX FIFO I/O ----------------------------
            begin : rx_fifo_io
                reg push, pop;
                push = rx_valid && (rx_count != 5'd16);
                pop = rx_pop_w && rx_ready_w;
                case ({push, pop})
                    2'b10: begin
                        rx_fifo[rx_tail] <= rx_data;
                        rx_tail <= rx_tail + 4'd1;
                        rx_count <= rx_count + 5'd1;
                    end
                    2'b01: begin
                        rx_head <= rx_head + 4'd1;
                        rx_count <= rx_count - 5'd1;
                    end
                    2'b11: begin
                        rx_fifo[rx_tail] <= rx_data;
                        rx_tail <= rx_tail + 4'd1;
                        rx_head <= rx_head + 4'd1;
                    end
                    default: begin end
                endcase
            end
            // ---- Network device FIFOs -------------------------------
            begin : net_fifo_io
                reg push, pop;
                push = (net_rx_valid === 1'b1) && (net_rx_count != 7'd64);
                pop = mem_load_w && (d_addr_w == (NET_BASE + 32'h4)) &&
                      net_rx_ready_w;
                case ({push, pop})
                    2'b10: begin
                        net_rx_fifo[net_rx_tail] <= net_rx_data;
                        net_rx_tail <= net_rx_tail + 6'd1;
                        net_rx_count <= net_rx_count + 7'd1;
                    end
                    2'b01: begin
                        net_rx_head <= net_rx_head + 6'd1;
                        net_rx_count <= net_rx_count - 7'd1;
                    end
                    2'b11: begin
                        net_rx_fifo[net_rx_tail] <= net_rx_data;
                        net_rx_tail <= net_rx_tail + 6'd1;
                        net_rx_head <= net_rx_head + 6'd1;
                    end
                    default: begin end
                endcase
            end
            begin : net_tx_io
                reg push, drain;
                push = d_we_w && (d_addr_w == NET_BASE) &&
                       net_tx_notfull_w;
                drain = (net_tx_count != 7'd0);
                case ({push, drain})
                    2'b10: begin
                        net_tx_fifo[net_tx_tail] <= d_wdata_w[7:0];
                        net_tx_tail <= net_tx_tail + 6'd1;
                        net_tx_count <= net_tx_count + 7'd1;
                        net_tx_valid_r <= 1'b0;
                    end
                    2'b01: begin
                        net_tx_r <= net_tx_fifo[net_tx_head];
                        net_tx_valid_r <= 1'b1;
                        net_tx_head <= net_tx_head + 6'd1;
                        net_tx_count <= net_tx_count - 7'd1;
                    end
                    2'b11: begin
                        net_tx_fifo[net_tx_tail] <= d_wdata_w[7:0];
                        net_tx_tail <= net_tx_tail + 6'd1;
                        net_tx_r <= net_tx_fifo[net_tx_head];
                        net_tx_valid_r <= 1'b1;
                        net_tx_head <= net_tx_head + 6'd1;
                    end
                    default: begin
                        net_tx_valid_r <= 1'b0;
                    end
                endcase
            end
            // ---- Core data writes -----------------------------------
            if (d_we_w) begin
                if (in_ram) begin
                    // Word read-modify-write (see st_* wires
                    // above). The word1 write is an identity
                    // write for aligned stores; harmless.
                    memw[st_widx] <= (memw[st_widx] & ~st_mask0) |
                                     (st_data64[31:0] & st_mask0);
                    memw[st_widx1] <= (memw[st_widx1] & ~st_mask1) |
                                      (st_data64[63:32] & st_mask1);
                end else if (in_fb) begin
                    // VRAM word stores only; byte/halfword
                    // stores are ignored (the language only
                    // emits word stores via poke32 anyway).
                    if (d_wmask_w == 4'b1111 && d_addr_w[1:0] == 2'd0)
                        vramw[fb_idx] <= d_wdata_w;
                end else if (in_pix) begin
                    // Same word-store-only rule for pixels.
                    if (d_wmask_w == 4'b1111 && d_addr_w[1:0] == 2'd0)
                        pixw[pix_idx] <= d_wdata_w;
                end else if (d_addr_w == 32'h02004000) begin
                    if (d_wmask_w[0]) mtimecmp_r[7:0] <= d_wdata_w[7:0];
                    if (d_wmask_w[1]) mtimecmp_r[15:8] <= d_wdata_w[15:8];
                    if (d_wmask_w[2]) mtimecmp_r[23:16] <= d_wdata_w[23:16];
                    if (d_wmask_w[3]) mtimecmp_r[31:24] <= d_wdata_w[31:24];
                end else if (d_addr_w == 32'h02004004) begin
                    if (d_wmask_w[0]) mtimecmp_r[39:32] <= d_wdata_w[7:0];
                    if (d_wmask_w[1]) mtimecmp_r[47:40] <= d_wdata_w[15:8];
                    if (d_wmask_w[2]) mtimecmp_r[55:48] <= d_wdata_w[23:16];
                    if (d_wmask_w[3]) mtimecmp_r[63:56] <= d_wdata_w[31:24];
                end else if (d_addr_w == 32'h0200BFF8) begin
                    if (d_wmask_w[0]) mtime_r[7:0] <= d_wdata_w[7:0];
                    if (d_wmask_w[1]) mtime_r[15:8] <= d_wdata_w[15:8];
                    if (d_wmask_w[2]) mtime_r[23:16] <= d_wdata_w[23:16];
                    if (d_wmask_w[3]) mtime_r[31:24] <= d_wdata_w[31:24];
                end else if (d_addr_w == 32'h0200BFFC) begin
                    if (d_wmask_w[0]) mtime_r[39:32] <= d_wdata_w[7:0];
                    if (d_wmask_w[1]) mtime_r[47:40] <= d_wdata_w[15:8];
                    if (d_wmask_w[2]) mtime_r[55:48] <= d_wdata_w[23:16];
                    if (d_wmask_w[3]) mtime_r[63:56] <= d_wdata_w[31:24];
                end else if (d_addr_w == 32'h10002000) begin
                    // Phase 5 SBI IPI register: any nonzero
                    // write sets the software interrupt, a
                    // zero write clears it.
                    if (d_wmask_w[0])
                        sbi_ipi_pending <= (d_wdata_w[7:0] != 8'b0);
                end else if (in_uart16550) begin
                    case (d_addr_w[3:0])
                        4'h0: begin
                            if (u16550_lcr[7]) begin
                                if (d_wmask_w[0]) u16550_dll <= d_wdata_w[7:0];
                            end else begin
                                u16550_tx <= d_wdata_w[7:0];
                                u16550_tx_valid <= 1'b1;
                            end
                        end
                        4'h1: begin
                            if (u16550_lcr[7]) begin
                                if (d_wmask_w[0]) u16550_dlm <= d_wdata_w[7:0];
                            end else if (d_wmask_w[0]) begin
                                u16550_ier <= d_wdata_w[7:0];
                            end
                        end
                        4'h3: if (d_wmask_w[0]) u16550_lcr <= d_wdata_w[7:0];
                        4'h4: if (d_wmask_w[0]) u16550_mcr <= d_wdata_w[7:0];
                        4'h7: if (d_wmask_w[0]) u16550_scr <= d_wdata_w[7:0];
                        default: begin end
                    endcase
                end else if (in_plic) begin
                    plic_write(d_addr_w, d_wdata_w, d_wmask_w);
                end else if (in_virtio) begin
                    virtio_write(d_addr_w, d_wdata_w, d_wmask_w);
                end
            end else begin
                // ---- Reads with side effects ------------------------
                // PLIC claim marking (a real MEM load of either
                // claim reg; mem_load_w guards against ALU
                // instructions whose rs1 merely equals it).
                if (mem_load_w && in_plic &&
                    ((d_addr_w == (PLIC_BASE + 32'h200004)) ||
                     (d_addr_w == (PLIC_BASE + 32'h201004)))) begin
                    if (d_addr_w == (PLIC_BASE + 32'h200004)) begin
                        if (plic_claim_m != 32'd0)
                            plic_claimed[plic_claim_m[1:0]] <= 1'b1;
                    end else begin
                        if (plic_claim_s != 32'd0)
                            plic_claimed[plic_claim_s[1:0]] <= 1'b1;
                    end
                end
            end
            // ---- Virtio FSM ------------------------------------------
            case (v_state)
                V_IDLE: begin
                    // Attempt 18 Step 16: drain, don't idle.
                    // Before this fix the only trigger was a
                    // fresh kick, and V_USED returned here, so
                    // one kick processed exactly one chain --
                    // the 210M kernel park (4 queued reads,
                    // avail 9 > last_avail 5, no kick pending)
                    // had no completer. Now V_IDLE also
                    // re-enters V_RD_AVAIL while last_avail
                    // trails the last-read avail idx, so one
                    // kick drains every chain queued at kick
                    // time, and a resumed model whose avail
                    // idx was already read (the 210M case)
                    // drains without any new kick. This cannot
                    // busy-poll: V_RD_AVAIL returns to V_IDLE
                    // exactly when last_avail == avail idx,
                    // which also falsifies this condition.
                    if (v_queue_ready &&
                        (v_status[2] == 1'b1) &&
                        (v_notify_q ||
                         (v_last_avail != v_avail_idx))) begin
                        v_notify_q <= 1'b0;
                        v_rd_addr <= v_drv_idx;
                        v_state <= V_RD_AVAIL;
                    end
                end
                V_DESC: begin
                    // Descriptor fields (latched by V_RD_D*):
                    // v_d0 = buffer addr, v_d2 = len.
                    v_data_addr <= v_d0;
                    v_data_len <= v_d2;
                    if ((v_d0 < RAM_BASE) ||
                        (v_d0 >= (RAM_BASE + MEM_BYTES))) begin
                        // Buffer outside RAM: abort this chain
                        // (used entry, len 0, no status write).
                        v_req_error <= 1'b1;
                        v_state <= V_USED;
                    end else begin
                        v_state <= V_HDR;
                    end
                end
                V_HDR: begin
                    // First descriptor in the chain: read the
                    // block header words (type, sector) via
                    // the sync port. Later descriptors dispatch
                    // on the latched v_d3 flags.
                    if (v_chain_len == 32'd0) begin
                        v_rd_addr <= v_data_addr - RAM_BASE;
                        v_state <= V_RD_H0;
                    end else if (v_data_len == 32'd1 &&
                                 (v_d3[15:0] & 16'd2) &&
                                 !(v_d3[15:0] & 16'd1)) begin
                        // Status descriptor: last, WRITE, 1 byte.
                        v_status_addr <= v_data_addr;
                        v_state <= V_STATUS;
                    end else begin
                        // Data descriptor: copy v_data_len bytes.
                        v_data_off <= 32'b0;
                        v_state <= V_COPY;
                    end
                end
                V_COPY: begin
                    if (v_data_off >= v_data_len) begin
                        v_used_len <= v_used_len + v_data_len;
                        if (v_d3[15:0] & 16'd1) begin
                            v_cur_desc <= {16'b0, v_d3[31:16]};
                            v_rd_addr <= v_desc_idx +
                                {16'b0, v_d3[31:16]} * 32'd16;
                            v_state <= V_RD_D0;
                        end else begin
                            v_state <= V_USED;
                        end
                    end else begin
                        // One byte per cycle, via word RMW.
                        if (v_req_write) begin
                            // Device reads guest RAM -> disk.
                            disk[(v_disk_off + v_data_off) %
                                 DISK_BYTES] <=
                                (memw[v_copy_widx] >>
                                 (v_copy_lane * 8)) & 32'hFF;
                        end else begin
                            // Device writes disk -> guest RAM.
                            memw[v_copy_widx] <=
                                (memw[v_copy_widx] &
                                 ~(32'hFF << (v_copy_lane * 8))) |
                                (disk[(v_disk_off + v_data_off) %
                                      DISK_BYTES] <<
                                 (v_copy_lane * 8));
                        end
                        v_data_off <= v_data_off + 32'd1;
                    end
                end
                V_STATUS: begin
                    memw[v_stat_widx] <=
                        (memw[v_stat_widx] &
                         ~(32'hFF << (v_stat_lane * 8))) |
                        ((v_req_error ? 32'd1 : 32'd0) <<
                         (v_stat_lane * 8));
                    v_state <= V_USED;
                end
                V_USED: begin
                    // Used ring: word0 = {idx+1, flags}
                    // (flags preserved from the pre-edge word),
                    // then the entry id and len words. k =
                    // used_idx % QueueNum; entry k starts at
                    // dev word 1 + 2k.
                    memw[(v_dev_idx >> 2) & (MEM_WORDS - 1)] <=
                        {(v_used_idx[15:0] + 16'd1),
                         memw[(v_dev_idx >> 2) & (MEM_WORDS - 1)][15:0]};
                    memw[((v_dev_idx >> 2) + 32'd1 +
                          (v_used_idx % (v_queue_num == 32'd0 ?
                                         32'd64 : v_queue_num)) * 32'd2) &
                         (MEM_WORDS - 1)] <= v_desc_addr;
                    memw[((v_dev_idx >> 2) + 32'd2 +
                          (v_used_idx % (v_queue_num == 32'd0 ?
                                         32'd64 : v_queue_num)) * 32'd2) &
                         (MEM_WORDS - 1)] <= v_used_len;
                    v_int_status <= 32'd1;
                    v_used_idx <= v_used_idx + 32'd1;
                    v_last_avail <= v_last_avail + 32'd1;
                    v_state <= V_IDLE;
                end
                V_RD_AVAIL: begin
                    if (!v_rd_armed) begin
                        v_rd_armed <= 1'b1;
                    end else begin
                        // Avail idx is bits [31:16] of the
                        // avail word. If the device has
                        // already processed up to it, there
                        // is nothing new: go back idle.
                        v_rd_armed <= 1'b0;
                        v_avail_idx <= v_rd_data[31:16];
                        v_used_len <= 32'b0;
                        v_req_error <= 1'b0;
                        v_chain_len <= 32'b0;
                        if (v_last_avail == v_rd_data[31:16])
                            v_state <= V_IDLE;
                        else begin
                            v_rd_addr <= v_ring_addr;
                            v_state <= V_RD_RING;
                        end
                    end
                end
                V_RD_RING: begin
                    if (!v_rd_armed) begin
                        v_rd_armed <= 1'b1;
                    end else begin
                        // Head descriptor id from the avail
                        // ring halfword, saved in v_desc_addr
                        // for the used entry.
                        v_rd_armed <= 1'b0;
                        if ((v_ring_pos % 2) == 0) begin
                            v_cur_desc <= {16'b0, v_rd_data[15:0]};
                            v_desc_addr <= {16'b0, v_rd_data[15:0]};
                            v_rd_addr <= v_desc_idx +
                                {16'b0, v_rd_data[15:0]} * 32'd16;
                        end else begin
                            v_cur_desc <= {16'b0, v_rd_data[31:16]};
                            v_desc_addr <= {16'b0, v_rd_data[31:16]};
                            v_rd_addr <= v_desc_idx +
                                {16'b0, v_rd_data[31:16]} * 32'd16;
                        end
                        v_state <= V_RD_D0;
                    end
                end
                V_RD_D0: begin
                    if (!v_rd_armed) begin
                        v_rd_armed <= 1'b1;
                    end else begin
                        // Descriptor word 0 = buffer addr.
                        // Word 1 (addr hi) is skipped: only
                        // 32-bit guest addresses are used.
                        v_rd_armed <= 1'b0;
                        v_d0 <= v_rd_data;
                        v_rd_addr <= v_desc_idx +
                            v_cur_desc * 32'd16 + 32'd8;
                        v_state <= V_RD_D2;
                    end
                end
                V_RD_D2: begin
                    if (!v_rd_armed) begin
                        v_rd_armed <= 1'b1;
                    end else begin
                        // Descriptor word 2 = length.
                        v_rd_armed <= 1'b0;
                        v_d2 <= v_rd_data;
                        v_rd_addr <= v_desc_idx +
                            v_cur_desc * 32'd16 + 32'd12;
                        v_state <= V_RD_D3;
                    end
                end
                V_RD_D3: begin
                    if (!v_rd_armed) begin
                        v_rd_armed <= 1'b1;
                    end else begin
                        // Descriptor word 3 = flags (low
                        // half) / next (high half).
                        v_rd_armed <= 1'b0;
                        v_d3 <= v_rd_data;
                        v_state <= V_DESC;
                    end
                end
                V_RD_H0: begin
                    if (!v_rd_armed) begin
                        v_rd_armed <= 1'b1;
                    end else begin
                        // Header word 0 = request type.
                        v_rd_armed <= 1'b0;
                        v_hdr0 <= v_rd_data;
                        v_rd_addr <= v_data_addr - RAM_BASE + 32'd8;
                        v_state <= V_RD_H2;
                    end
                end
                V_RD_H2: begin
                    if (!v_rd_armed) begin
                        v_rd_armed <= 1'b1;
                    end else begin
                        // Header word 2 = sector (low).
                        v_rd_armed <= 1'b0;
                        v_hdr2 <= v_rd_data;
                        v_rd_addr <= v_data_addr - RAM_BASE + 32'd12;
                        v_state <= V_RD_H3;
                    end
                end
                V_RD_H3: begin
                    if (!v_rd_armed) begin
                        v_rd_armed <= 1'b1;
                    end else begin
                        // Header word 3 = sector (high);
                        // parse the header now.
                        v_rd_armed <= 1'b0;
                        v_req_type <= v_hdr0;
                        v_req_sector_lo <= v_hdr2;
                        v_req_sector_hi <= v_rd_data;
                        v_req_write <= (v_hdr0 == 32'd1);
                        v_disk_off <= v_hdr2 * 32'd512;
                        v_chain_len <= 32'd1;
                        // Move to next descriptor (flags NEXT?).
                        if (v_d3[15:0] & 16'd1) begin
                            v_cur_desc <= {16'b0, v_d3[31:16]};
                            v_rd_addr <= v_desc_idx +
                                {16'b0, v_d3[31:16]} * 32'd16;
                            v_state <= V_RD_D0;
                        end else begin
                            v_state <= V_USED;
                        end
                    end
                end
                default: v_state <= V_IDLE;
            endcase
        end
    end

    // ---- PLIC / virtio write tasks (called from clocked block) -------
    task plic_write;
        input [31:0] a;
        input [31:0] d;
        input [3:0] m;
        reg [31:0] off;
        begin
            off = a - PLIC_BASE;
            if (off == 32'h4) begin
                if (m[0]) plic_prio[1] <= d[2:0];
            end else if (off == 32'h8) begin
                if (m[0]) plic_prio[2] <= d[2:0];
            end else if (off == 32'hC) begin
                if (m[0]) plic_prio[3] <= d[2:0];
            end else if (off >= 32'h002000 && off < 32'h002080) begin
                if (m[0]) plic_enable_m[7:0] <= d[7:0];
                if (m[1]) plic_enable_m[15:8] <= d[15:8];
                if (m[2]) plic_enable_m[23:16] <= d[23:16];
                if (m[3]) plic_enable_m[31:24] <= d[31:24];
            end else if (off >= 32'h002080 && off < 32'h002100) begin
                if (m[0]) plic_enable_s[7:0] <= d[7:0];
                if (m[1]) plic_enable_s[15:8] <= d[15:8];
                if (m[2]) plic_enable_s[23:16] <= d[23:16];
                if (m[3]) plic_enable_s[31:24] <= d[31:24];
            end else if (off == 32'h200000) begin
                if (m[0]) plic_thresh_m <= d[2:0];
            end else if (off == 32'h200004) begin
                // Complete: clear claimed for the written id.
                if (d[1:0] != 2'd0)
                    plic_claimed[d[1:0]] <= 1'b0;
            end else if (off == 32'h201000) begin
                if (m[0]) plic_thresh_s <= d[2:0];
            end else if (off == 32'h201004) begin
                if (d[1:0] != 2'd0)
                    plic_claimed[d[1:0]] <= 1'b0;
            end
        end
    endtask

    task virtio_write;
        input [31:0] a;
        input [31:0] d;
        input [3:0] m;
        reg [31:0] off;
        begin
            off = a - VIRTIO_BASE;
            case (off)
                32'h014: v_feat_sel <= d;
                32'h020: v_drv_feat <= d;
                32'h024: v_drv_feat_sel <= d;
                32'h030: v_queue_sel <= d;
                32'h038: v_queue_num <= d;
                32'h044: v_queue_ready <= d;
                32'h050: v_notify_q <= 1'b1;
                32'h064: v_int_status <= v_int_status & ~d;
                32'h070: begin
                    v_status <= d;
                    if (d == 32'd0) begin
                        v_queue_ready <= 32'b0;
                        v_int_status <= 32'b0;
                        v_notify_q <= 1'b0;
                        v_state <= V_IDLE;
                        v_used_idx <= 32'b0;
                        v_last_avail <= 32'b0;
                    end
                end
                32'h080: v_desc_lo <= d;
                32'h084: v_desc_hi <= d;
                32'h090: v_drv_lo <= d;
                32'h094: v_drv_hi <= d;
                32'h0A0: v_dev_lo <= d;
                32'h0A4: v_dev_hi <= d;
                default: begin end
            endcase
        end
    endtask

    // ---- Disk pattern initialisation ----------------------------------
    integer di;
    initial begin
        for (di = 0; di < DISK_BYTES; di = di + 1)
            disk[di] = (di / 512) % 256;
        // Sector 0, word 0/1: distinctive magic for tests.
        disk[0] = 8'hEF; disk[1] = 8'hBE; disk[2] = 8'hAD;
        disk[3] = 8'hDE; disk[4] = 8'h78; disk[5] = 8'h56;
        disk[6] = 8'h34; disk[7] = 8'h12;
    end
endmodule
