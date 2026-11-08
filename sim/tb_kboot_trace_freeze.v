// Testbench for the big32 Phase 5 platform top (src/big32_soc2.v).
// Loads a word image into RAM at 0x80000000 (the ROM at 0 jumps
// there), optionally loads a disk image into dut.disk and a DTB
// blob into RAM at +DTBOFF, runs until halt, prints registers,
// cycle count, selected RAM words, and the raw UART transcript
// (legacy + 16550 pulses, sampled on the falling edge).
// Plusargs (run from the big32 directory):
//   +HEX=...      program hex (default soc2_hex/soc2_current.hex)
//   +DISKHEX=...  disk image words (default: none, pattern only)
//   +DTBFILE=...  DTB bytes, one hex byte per line
//   +DTBOFF=...   DTB RAM offset in bytes (default 0x20000)
//   +RX2FILE=...  16550 RX bytes, one hex byte per line
//   +RX2START=... default 600
//   +RX2PERIOD=... default 600
//   +EXTAT=...    cycle at which ext_irq asserts (default: never)
//   +EXTLEN=...   ext_irq pulse length in cycles (default 20)
//   +MAXCYCLES=.. default 2000000
// Compile:
//   iverilog -o sim/tb_soc2.vvp src/big32_core_pipe.v src/big32_soc2.v sim/tb_soc2.v
//   vvp sim/tb_soc2.vvp +HEX=soc2_hex/plic.hex
`timescale 1ns/1ps

module tb_kboot_trace_freeze #(parameter TB_MEM_BYTES = 1048576);
    // TB_MEM_BYTES: RAM size for this run. Override on
    // the iverilog command line for the kernel attempt:
    //   -Ptb_soc2.TB_MEM_BYTES=67108864   (64 MiB)
    // (-P only overrides TOP-module parameters in Icarus,
    // so the size lives here and is passed down to dut;
    // -Ptb_soc2.dut.MEM_BYTES does NOT work.)
    reg clk = 0;
    reg rst_n = 0;
    wire halted;
    wire [7:0] uart_tx;
    wire uart_tx_valid;
    reg ext_irq = 0;
    reg [7:0] rx_data = 0;
    reg rx_valid = 0;
    reg [7:0] rx2_data = 0;
    reg rx2_valid = 0;

    big32_soc2 #(.MEM_BYTES(TB_MEM_BYTES)) dut (
        .clk(clk), .rst_n(rst_n), .halted(halted),
        .uart_tx(uart_tx), .uart_tx_valid(uart_tx_valid),
        .ext_irq(ext_irq), .rx_data(rx_data), .rx_valid(rx_valid),
        .rx2_data(rx2_data), .rx2_valid(rx2_valid)
    );

    // pc-trace additions: detect the sched_clock printk in the UART
    // stream (the string appears once, at the end of time_init's
    // clocksource/sched_clock prints). From that cycle on, the main
    // loop samples dut.core.pc periodically into the trace file.
    reg sched_seen = 0;
    integer sched_cycle = 0;
    reg [87:0] uart_shift = 0;
    always @(negedge clk) begin
        if (uart_tx_valid) begin
            $write("%c", uart_tx);
            uart_shift = {uart_shift[79:0], uart_tx};
            if (!sched_seen && uart_shift == "sched_clock") begin
                sched_seen = 1;
                sched_cycle = cycles;
            end
        end
    end
    // Interrupt/trap counters, counted on the clock edge (pre-edge
    // values, so each take/trap cycle is counted exactly once).
    integer cnt_int_tim = 0;
    integer cnt_int_ext = 0;
    integer cnt_int_sof = 0;
    integer cnt_trap = 0;
    always @(posedge clk) begin
        if (rst_n && sched_seen) begin
            if (dut.core.int_take_tim) cnt_int_tim = cnt_int_tim + 1;
            if (dut.core.int_take_ext) cnt_int_ext = cnt_int_ext + 1;
            if (dut.core.int_take_sof) cnt_int_sof = cnt_int_sof + 1;
            if (dut.core.ex_trap) cnt_trap = cnt_trap + 1;
        end
    end

    always #5 clk = ~clk;

    integer cycles;
    integer i;
    integer maxcycles;
    integer rx2start, rx2period, extat, extlen, dtboff;
    integer nrx2, rx2idx, rx2next;
    reg [8*256-1:0] hexfile;
    reg [8*256-1:0] diskfile;
    reg [8*256-1:0] dtbfile;
    reg [8*256-1:0] rx2file;
    reg [7:0] rx2bytes [0:255];
    reg [7:0] dtbbytes [0:65535];
    reg [31:0] img [0:262143];
    reg [31:0] dimg [0:262143];
    reg [31:0] kimgoff;
    reg [8*256-1:0] kimgbinfile;
    reg [31:0] kbinw_arr [0:1048575];
    integer kbinfd, kbincnt, kbinj, kbinn;
    integer fd, code, ndtb;
    reg [7:0] bval;

    // Word RAM (soc2 memw): offsets used here are all
    // word-aligned, so the word at off>>2 is the answer.
    function [31:0] ramword;
        input [31:0] off;
        begin
            ramword = dut.memw[off[31:2]];
        end
    endfunction

    integer trace_fd;
    integer snap_fd;
    integer sample_cnt = 0;
    initial begin
        trace_fd = $fopen("kernel/pc_trace_freeze.txt", "w");
        snap_fd = $fopen("kernel/pc_trace_freeze_snap.txt", "w");
        rst_n = 0;
        // +NOCLEAR skips the RAM clear (for big-RAM kernel runs:
        // clearing 16M words via hierarchical writes takes
        // ~15 min in Icarus). The firmware, DTB, and kernel
        // regions are written explicitly by the loads below,
        // and the kernel zeroes its own BSS before use, so
        // skipping is safe for the boot attempt. Default
        // (no +NOCLEAR) still clears, as all Phase 5 tests do.
        if (!$test$plusargs("NOCLEAR")) begin
            for (i = 0; i < dut.MEM_WORDS; i = i + 1)
                dut.memw[i] = 32'b0;
        end
        if (!$value$plusargs("HEX=%s", hexfile))
            hexfile = "soc2_hex/soc2_current.hex";
        $readmemh(hexfile, img);
        // Bound by the img array (262144 words), NOT by
        // MEM_WORDS: the old break (i = 262144) only exited
        // the loop when MEM_WORDS was 262144 (the 1 MiB
        // default). At 64 MiB it skipped to 262144 and then
        // ran all 16.7M iterations, each hierarchical write
        // re-evaluating the core/SOC combinational logic
        // that reads memw -- that was the 15+ min "hang"
        // in every 64 MiB run. The firmware image never
        // exceeds img[] anyway.
        for (i = 0; i < 262144; i = i + 1) begin
            if (img[i] === 32'hxxxxxxxx)
                i = 262144;
            else begin
                dut.memw[i] = img[i];
            end
        end
        if ($value$plusargs("DISKHEX=%s", diskfile)) begin
            $readmemh(diskfile, dimg);
            for (i = 0; i < 262144; i = i + 1) begin
                if (dimg[i] === 32'hxxxxxxxx)
                    i = 262144;
                else begin
                    dut.disk[i*4] = dimg[i][7:0];
                    dut.disk[i*4+1] = dimg[i][15:8];
                    dut.disk[i*4+2] = dimg[i][23:16];
                    dut.disk[i*4+3] = dimg[i][31:24];
                end
            end
        end
        dtboff = 131072;
        if (!$value$plusargs("DTBOFF=%d", dtboff)) begin end
        if ($value$plusargs("DTBFILE=%s", dtbfile)) begin
            fd = $fopen(dtbfile, "r");
            ndtb = 0;
            if (fd) begin
                while (!$feof(fd) && ndtb < 65536) begin
                    code = $fscanf(fd, "%h", bval);
                    if (code == 1) begin
                        dtbbytes[ndtb] = bval;
                        ndtb = ndtb + 1;
                    end
                end
                $fclose(fd);
            end
            for (i = 0; i < ndtb; i = i + 1)
                // Byte RMW into the word array (blocking
                // assignments here, so sequential updates
                // to the same word compose correctly).
                dut.memw[(dtboff + i) >> 2] =
                    (dut.memw[(dtboff + i) >> 2] &
                     ~(32'hFF << (((dtboff + i) & 3) * 8))) |
                    (dtbbytes[i] << (((dtboff + i) & 3) * 8));
        end
        // Optional kernel image (+KIMG=file, +KIMGOFF=bytes,
        // default 65536 = 0x10000): word image loaded into RAM
        // at KIMGOFF. Used by the Linux boot attempt only; all
        // Phase 5 tests run without it.
        // Binary kernel load (+KIMGBIN=file, +KIMGOFF=bytes):
        // $readmemh on a 77 MB text hex takes 35-65 min in
        // Icarus (its hex parser is ~300 us/line). $fread of
        // the binary Image into a word array, plus a
        // byte-swap loop, takes ~1 min: $fread packs bytes
        // big-endian into words ({b0,b1,b2,b3}), while the
        // RISC-V Image is little-endian, so each word is
        // swapped on the way into RAM. Requires a file size
        // that is a multiple of 4 (the kernel Image is).
        if ($value$plusargs("KIMGBIN=%s", kimgbinfile)) begin
            kimgoff = 65536;
            if (!$value$plusargs("KIMGOFF=%d", kimgoff)) begin end
            kbinfd = $fopen(kimgbinfile, "rb");
            kbinn = 0;
            if (kbinfd) begin
                kbincnt = $fread(kbinw_arr, kbinfd, 0, 1048576);
                while (kbincnt > 0) begin
                    for (kbinj = 0; kbinj < kbincnt / 4; kbinj = kbinj + 1)
                        dut.memw[(kimgoff >> 2) + kbinn + kbinj] =
                            {kbinw_arr[kbinj][7:0], kbinw_arr[kbinj][15:8],
                             kbinw_arr[kbinj][23:16], kbinw_arr[kbinj][31:24]};
                    kbinn = kbinn + kbincnt / 4;
                    kbincnt = $fread(kbinw_arr, kbinfd, 0, 1048576);
                end
                $fclose(kbinfd);
            end
        end
        maxcycles = 2000000;
        rx2start = 600;
        rx2period = 600;
        extat = -1;
        extlen = 20;
        nrx2 = 0;
        rx2idx = 0;
        if (!$value$plusargs("MAXCYCLES=%d", maxcycles)) begin end
        if (!$value$plusargs("RX2START=%d", rx2start)) begin end
        if (!$value$plusargs("RX2PERIOD=%d", rx2period)) begin end
        if (!$value$plusargs("EXTAT=%d", extat)) begin end
        if (!$value$plusargs("EXTLEN=%d", extlen)) begin end
        if ($value$plusargs("RX2FILE=%s", rx2file)) begin
            fd = $fopen(rx2file, "r");
            if (fd) begin
                while (!$feof(fd) && nrx2 < 256) begin
                    code = $fscanf(fd, "%h", bval);
                    if (code == 1) begin
                        rx2bytes[nrx2] = bval;
                        nrx2 = nrx2 + 1;
                    end
                end
                $fclose(fd);
            end
        end
        #23;
        rst_n = 1;
        cycles = 0;
        rx2next = rx2start;
        while (!halted && cycles < maxcycles) begin
            @(posedge clk);
            cycles = cycles + 1;
            if (sched_seen && (cycles % 100 == 0)) begin
                $fwrite(trace_fd, "%0d %08x %0d\n", cycles, dut.core.pc, dut.core.priv);
                sample_cnt = sample_cnt + 1;
            end
            if (sched_seen && (cycles % 500000 == 0)) begin
                $fwrite(snap_fd, "%0d pc=%08x priv=%0d mtime=%0d mtimecmp=%0d irq_timer=%0d sie=%08x mie=%08x sstatus=%08x mstatus=%08x\n",
                    cycles, dut.core.pc, dut.core.priv, dut.mtime_r, dut.mtimecmp_r, dut.irq_timer_w,
                    dut.core.csr_sie, dut.core.csr_mie, dut.core.csr_sstatus, dut.core.csr_mstatus);
            end
            rx2_valid = 0;
            if ((rx2idx < nrx2) && (cycles >= rx2next)) begin
                rx2_data = rx2bytes[rx2idx];
                rx2_valid = 1;
                rx2idx = rx2idx + 1;
                rx2next = rx2next + rx2period;
            end
            if (extat >= 0)
                ext_irq = (cycles >= extat) && (cycles < extat + extlen);
            else
                ext_irq = 0;
        end
        rx2_valid = 0;
        ext_irq = 0;
        repeat (4) @(posedge clk);
        $display("SCHED_CYCLE: %0d", sched_cycle);
        $display("TRACE_SAMPLES: %0d", sample_cnt);
        $display("CNT_INT_TIM: %0d CNT_INT_EXT: %0d CNT_INT_SOF: %0d CNT_TRAP: %0d",
                 cnt_int_tim, cnt_int_ext, cnt_int_sof, cnt_trap);
        $display("MTIME: %0d MTIMECMP: %0d", dut.mtime_r, dut.mtimecmp_r);
        $fclose(trace_fd);
        $fclose(snap_fd);
        $display("CYCLES: %0d", cycles);
        $display("HALTED: %0d", halted);
        $write("REGS:");
        for (i = 0; i < 32; i = i + 1)
            $write(" %0d", dut.core.regs[i]);
        $display("");
        $display("RAM: %0d %0d %0d %0d %0d %0d",
                 ramword(32'h0000F000), ramword(32'h0000F004),
                 ramword(32'h0000F008), ramword(32'h0000F00C),
                 ramword(32'h00010000), ramword(32'h00010004));
        $finish;
    end
endmodule
