// tb_kboot_ckpt_trace -- tb_kboot_ckpt plus PC sampling from a
// resumed checkpoint (diagnostic trace; no core/SOC changes).
//   +TRACEFILE=...   sample output (default kernel/pc_trace_100m.txt)
//   +TRACESNAPFILE=.. snapshot output (default kernel/pc_trace_100m_snap.txt)
//   +TRACEPERIOD=... sample every N cycles (default 100)
//   +SNAPPERIOD=...  snapshot every N cycles (default 500000)
// tb_kboot_ckpt -- checkpoint/resume variant of tb_kboot_dbg.
// Same launch path (same plusargs, same loads, same UART output),
// plus testbench-level checkpoint/restore so a VM restart no longer
// resets a long kernel boot to cycle zero.
//
// New plusargs:
//   +CKPTDIR=...   directory holding checkpoints (created by the
//                   wrapper script; the testbench does NOT mkdir).
//   +CKPTAT=...    cycle at which to take the first checkpoint
//                   (default -1 = never). Taken AFTER the negedge
//                   UART sample of that cycle, with the clock held
//                   at 0, so no TX byte is lost or duplicated.
//   +CKPTEVERY=... interval in cycles between checkpoints after
//                   the first (default 0 = only +CKPTAT).
//   +CKPTONVSTATE=n checkpoint the first cycle where the virtio
//                   FSM state dut.v_state == n (V_COPY = 5): used
//                   to prove a mid-transfer restore, since a
//                   cycle number alone cannot reliably land
//                   inside a 512-cycle copy window.
//   +CKPTONTX      checkpoint the first cycle in which a UART
//                   TX pulse is emitted (16550 or legacy): used
//                   to prove the checkpoint-boundary TX byte is
//                   printed exactly once, never lost/duplicated.
//   +RESUME=...    cycle number of the checkpoint to resume from:
//                   reads CKPTDIR/ckpt_<N>.hdr/.ram/.disk/.vram/
//                   .pix, overlays them on the freshly loaded
//                   firmware/DTB/kernel/disk, and continues the
//                   run from cycle N. The UART log must be
//                   APPENDED (>>) across the resume, never
//                   overwritten, or the transcript is cut.
// Checkpoint contents (all under CKPTDIR, per cycle N):
//   ckpt_<N>.hdr   tb state (cycles, rx2idx, rx2next) + every
//                   scalar and small-array reg in dut.core and
//                   dut (generated from the source reg lists;
//                   task-local temps excluded: they are
//                   recomputed every cycle, never state).
//   ckpt_<N>.ram   dut.memw via $writememh (64 MiB, ~165 MB hex).
//   ckpt_<N>.disk  dut.disk via $writemh (1 MiB).
//   ckpt_<N>.vram  dut.vramw, ckpt_<N>.pix dut.pixw (small).
// What is NOT in a checkpoint (see LINUX_BOOT.md for the full
// list): the testbench clock phase (resume restarts clk at 0,
// which is cycle-exact: cycles are counted on posedges only),
// unconnected top-level pins (net/ptr inputs read as x in both
// runs, guarded by the SOC's x-checks), and anything outside
// the simulated machine (the shell's log file itself).
// The core and SOC sources are NOT modified; all checkpoint
// code lives in this testbench.
`timescale 1ns/1ps

module tb_kboot_ckpt_trace #(parameter TB_MEM_BYTES = 1048576);
    reg clk = 0;
    reg run_clk = 0;
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

    always @(negedge clk) begin
        if (uart_tx_valid)
            $write("%c", uart_tx);
    end

    // Interrupt/trap counters (pre-edge values, each take counted once).
    always @(posedge clk) begin
        if (trace_on) begin
            if (dut.core.int_take_tim) cnt_int_tim = cnt_int_tim + 1;
            if (dut.core.int_take_ext) cnt_int_ext = cnt_int_ext + 1;
            if (dut.core.int_take_sof) cnt_int_sof = cnt_int_sof + 1;
            if (dut.core.ex_trap) cnt_trap = cnt_trap + 1;
        end
    end

    always #5 begin
        if (run_clk) clk = ~clk;
    end

    integer cycles;
    integer i;
    integer ci2;
    integer maxcycles;
    integer rx2start, rx2period, extat, extlen, dtboff;
    integer nrx2, rx2idx, rx2next;
    integer ckptat, ckptevery, resumecyc, nextckpt;
    integer trace_fd, snap_fd, traceperiod, snapperiod, sample_cnt;
    integer cnt_int_tim, cnt_int_ext, cnt_int_sof, cnt_trap;
    reg trace_on;
    reg [8*256-1:0] tracefile, snapfile;
    integer ckptonvstate, ckptontx, trig_fired;
    reg [8*256-1:0] hexfile;
    reg [8*256-1:0] diskfile;
    reg [8*256-1:0] dtbfile;
    reg [8*256-1:0] rx2file;
    reg [8*256-1:0] ckptdir;
    reg [8*1024-1:0] ckptpath;
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
    reg [31:0] tmp32;
    reg tmp1;

    function [31:0] ramword;
        input [31:0] off;
        begin
            ramword = dut.memw[off[31:2]];
        end
    endfunction

    task do_checkpoint;
        input integer cyc;
        begin
            $sformat(ckptpath, "%0s/ckpt_%0d.hdr", ckptdir, cyc);
            fd = $fopen(ckptpath, "w");
            if (!fd) begin
                $display("CKPT-ERROR: cannot open %0s", ckptpath);
            end else begin
                $fwrite(fd, "%0d\n", cycles);
                $fwrite(fd, "%0d\n", rx2idx);
                $fwrite(fd, "%0d\n", rx2next);
        $fwrite(fd, "%h\n", dut.core.halted);
        $fwrite(fd, "%h\n", dut.core.uart_tx);
        $fwrite(fd, "%h\n", dut.core.uart_tx_valid);
        $fwrite(fd, "%h\n", dut.core.pc);
        $fwrite(fd, "%h\n", dut.core.csr_mstatus);
        $fwrite(fd, "%h\n", dut.core.csr_mtvec);
        $fwrite(fd, "%h\n", dut.core.csr_mscratch);
        $fwrite(fd, "%h\n", dut.core.csr_mepc);
        $fwrite(fd, "%h\n", dut.core.csr_mcause);
        $fwrite(fd, "%h\n", dut.core.csr_mtval);
        $fwrite(fd, "%h\n", dut.core.csr_mie);
        $fwrite(fd, "%h\n", dut.core.priv);
        $fwrite(fd, "%h\n", dut.core.csr_sstatus);
        $fwrite(fd, "%h\n", dut.core.csr_sie);
        $fwrite(fd, "%h\n", dut.core.csr_stvec);
        $fwrite(fd, "%h\n", dut.core.csr_sscratch);
        $fwrite(fd, "%h\n", dut.core.csr_sepc);
        $fwrite(fd, "%h\n", dut.core.csr_scause);
        $fwrite(fd, "%h\n", dut.core.csr_stval);
        $fwrite(fd, "%h\n", dut.core.csr_satp);
        $fwrite(fd, "%h\n", dut.core.csr_medeleg);
        $fwrite(fd, "%h\n", dut.core.csr_mideleg);
        $fwrite(fd, "%h\n", dut.core.ptw_state);
        $fwrite(fd, "%h\n", dut.core.ptw_is_fetch);
        $fwrite(fd, "%h\n", dut.core.ptw_is_store);
        $fwrite(fd, "%h\n", dut.core.ptw_va);
        $fwrite(fd, "%h\n", dut.core.ptw_root_base);
        $fwrite(fd, "%h\n", dut.core.ptw_pte1);
        $fwrite(fd, "%h\n", dut.core.ptw_data_pa);
        $fwrite(fd, "%h\n", dut.core.ptw_data_done);
        $fwrite(fd, "%h\n", dut.core.ptw_data_fault);
        $fwrite(fd, "%h\n", dut.core.ptw_data_super);
        $fwrite(fd, "%h\n", dut.core.ptw_data_fault_cause);
        $fwrite(fd, "%h\n", dut.core.fetch_pa);
        $fwrite(fd, "%h\n", dut.core.fetch_pa_pc);
        $fwrite(fd, "%h\n", dut.core.fetch_pa_valid);
        $fwrite(fd, "%h\n", dut.core.fetch_fault_pending);
        $fwrite(fd, "%h\n", dut.core.fetch_fault_pc);
        $fwrite(fd, "%h\n", dut.core.core_cycles);
        $fwrite(fd, "%h\n", dut.core.tlb_rr);
        $fwrite(fd, "%h\n", dut.core.ptw_write_addr);
        $fwrite(fd, "%h\n", dut.core.ptw_write_data);
        $fwrite(fd, "%h\n", dut.core.ptw_accept_pte);
        $fwrite(fd, "%h\n", dut.core.ptw_accept_pa);
        $fwrite(fd, "%h\n", dut.core.ptw_accept_va);
        $fwrite(fd, "%h\n", dut.core.ptw_accept_super);
        $fwrite(fd, "%h\n", dut.core.ptw_accept_is_fetch);
        $fwrite(fd, "%h\n", dut.core.ptw_accept_is_store);
        $fwrite(fd, "%h\n", dut.core.reservation_valid);
        $fwrite(fd, "%h\n", dut.core.reservation_addr);
        $fwrite(fd, "%h\n", dut.core.if_id_instr);
        $fwrite(fd, "%h\n", dut.core.if_id_pc);
        $fwrite(fd, "%h\n", dut.core.if_id_fetch_fault);
        $fwrite(fd, "%h\n", dut.core.if_id_valid);
        $fwrite(fd, "%h\n", dut.core.id_ex_fetch_fault);
        $fwrite(fd, "%h\n", dut.core.id_ex_pc);
        $fwrite(fd, "%h\n", dut.core.id_ex_opcode);
        $fwrite(fd, "%h\n", dut.core.id_ex_rd);
        $fwrite(fd, "%h\n", dut.core.id_ex_rs1);
        $fwrite(fd, "%h\n", dut.core.id_ex_rs2);
        $fwrite(fd, "%h\n", dut.core.id_ex_funct3);
        $fwrite(fd, "%h\n", dut.core.id_ex_funct7);
        $fwrite(fd, "%h\n", dut.core.id_ex_imm_i);
        $fwrite(fd, "%h\n", dut.core.id_ex_imm_s);
        $fwrite(fd, "%h\n", dut.core.id_ex_imm_b);
        $fwrite(fd, "%h\n", dut.core.id_ex_imm_u);
        $fwrite(fd, "%h\n", dut.core.id_ex_imm_j);
        $fwrite(fd, "%h\n", dut.core.id_ex_csr_addr);
        $fwrite(fd, "%h\n", dut.core.id_ex_amo_f5);
        $fwrite(fd, "%h\n", dut.core.ex_mem_pc);
        $fwrite(fd, "%h\n", dut.core.ex_mem_rd);
        $fwrite(fd, "%h\n", dut.core.ex_mem_funct3);
        $fwrite(fd, "%h\n", dut.core.ex_mem_result);
        $fwrite(fd, "%h\n", dut.core.ex_mem_rs2);
        $fwrite(fd, "%h\n", dut.core.ex_mem_addr);
        $fwrite(fd, "%h\n", dut.core.ex_mem_reg_write);
        $fwrite(fd, "%h\n", dut.core.ex_mem_is_load);
        $fwrite(fd, "%h\n", dut.core.ex_mem_is_store);
        $fwrite(fd, "%h\n", dut.core.ex_mem_is_amo);
        $fwrite(fd, "%h\n", dut.core.ex_mem_is_sc);
        $fwrite(fd, "%h\n", dut.core.ex_mem_is_lr);
        $fwrite(fd, "%h\n", dut.core.ex_mem_amo_funct5);
        $fwrite(fd, "%h\n", dut.core.ex_mem_csr_write);
        $fwrite(fd, "%h\n", dut.core.ex_mem_csr_addr);
        $fwrite(fd, "%h\n", dut.core.ex_mem_csr_new);
        $fwrite(fd, "%h\n", dut.core.ex_mem_size);
        $fwrite(fd, "%h\n", dut.core.mem_wb_rd);
        $fwrite(fd, "%h\n", dut.core.mem_wb_data);
        $fwrite(fd, "%h\n", dut.core.mem_wb_reg_write);
        $fwrite(fd, "%h\n", dut.core.mem_wb_csr_write);
        $fwrite(fd, "%h\n", dut.core.mem_wb_csr_addr);
        $fwrite(fd, "%h\n", dut.core.mem_wb_csr_new);
        $fwrite(fd, "%h\n", dut.core.div_busy);
        $fwrite(fd, "%h\n", dut.core.div_cnt);
        $fwrite(fd, "%h\n", dut.core.div_rem);
        $fwrite(fd, "%h\n", dut.core.div_quot);
        $fwrite(fd, "%h\n", dut.core.div_divisor);
        $fwrite(fd, "%h\n", dut.core.div_dividend);
        $fwrite(fd, "%h\n", dut.core.div_signed_r);
        $fwrite(fd, "%h\n", dut.core.div_is_rem_r);
        $fwrite(fd, "%h\n", dut.core.div_neg_q_r);
        $fwrite(fd, "%h\n", dut.core.div_neg_r_r);
        $fwrite(fd, "%h\n", dut.core.tlb_fetch_hit);
        $fwrite(fd, "%h\n", dut.core.tlb_fetch_perm_ok);
        $fwrite(fd, "%h\n", dut.core.tlb_fetch_pa);
        $fwrite(fd, "%h\n", dut.core.ptw_addr);
        $fwrite(fd, "%h\n", dut.core.load_data);
        $fwrite(fd, "%h\n", dut.core.amo_new);
        $fwrite(fd, "%h\n", dut.core.mem_result);
        $fwrite(fd, "%h\n", dut.core.d_we_comb);
        $fwrite(fd, "%h\n", dut.core.d_wdata_comb);
        $fwrite(fd, "%h\n", dut.core.d_wmask_comb);
        $fwrite(fd, "%h\n", dut.core.ex_rs1_fwd);
        $fwrite(fd, "%h\n", dut.core.ex_rs2_fwd);
        $fwrite(fd, "%h\n", dut.core.ex_csr_old);
        $fwrite(fd, "%h\n", dut.core.ex_trap_cause);
        $fwrite(fd, "%h\n", dut.core.ex_trap_tval);
        $fwrite(fd, "%h\n", dut.core.ex_trap_to_s);
        $fwrite(fd, "%h\n", dut.core.ex_csr_new);
        $fwrite(fd, "%h\n", dut.core.ex_csr_write);
        $fwrite(fd, "%h\n", dut.core.div_abs_a);
        $fwrite(fd, "%h\n", dut.core.div_abs_b);
        $fwrite(fd, "%h\n", dut.core.div_neg_q);
        $fwrite(fd, "%h\n", dut.core.div_neg_r);
        $fwrite(fd, "%h\n", dut.core.div_iter_rem);
        $fwrite(fd, "%h\n", dut.core.div_iter_quot);
        $fwrite(fd, "%h\n", dut.core.div_start_rem);
        $fwrite(fd, "%h\n", dut.core.div_start_quot);
        $fwrite(fd, "%h\n", dut.core.div_start_sub);
        $fwrite(fd, "%h\n", dut.core.div_bit_idx);
        $fwrite(fd, "%h\n", dut.core.div_shifted_start);
        $fwrite(fd, "%h\n", dut.core.div_shifted_busy);
        $fwrite(fd, "%h\n", dut.core.div_sub);
        $fwrite(fd, "%h\n", dut.core.div_ready);
        $fwrite(fd, "%h\n", dut.core.div_result);
        $fwrite(fd, "%h\n", dut.core.ex_alu_out);
        $fwrite(fd, "%h\n", dut.core.ex_branch_taken);
        $fwrite(fd, "%h\n", dut.core.tlb_data_hit);
        $fwrite(fd, "%h\n", dut.core.tlb_data_perm_ok);
        $fwrite(fd, "%h\n", dut.core.tlb_data_rw_ok);
        $fwrite(fd, "%h\n", dut.core.tlb_data_priv_ok);
        $fwrite(fd, "%h\n", dut.core.tlb_data_dbit);
        $fwrite(fd, "%h\n", dut.core.tlb_data_super);
        $fwrite(fd, "%h\n", dut.core.tlb_data_pa);
        $fwrite(fd, "%h\n", dut.core.ex_result);
        $fwrite(fd, "%h\n", dut.core.ex_reg_write);
        $fwrite(fd, "%h\n", dut.core.ex_target);
        $fwrite(fd, "%h\n", dut.core.ptw_perm_fault_now);
        for (ci2 = 0; ci2 <= 31; ci2 = ci2 + 1)
            $fwrite(fd, "%h\n", dut.core.regs[ci2]);
        for (ci2 = 0; ci2 <= 15; ci2 = ci2 + 1)
            $fwrite(fd, "%h\n", dut.core.tlb_valid[ci2]);
        for (ci2 = 0; ci2 <= 15; ci2 = ci2 + 1)
            $fwrite(fd, "%h\n", dut.core.tlb_vpn[ci2]);
        for (ci2 = 0; ci2 <= 15; ci2 = ci2 + 1)
            $fwrite(fd, "%h\n", dut.core.tlb_ppn[ci2]);
        for (ci2 = 0; ci2 <= 15; ci2 = ci2 + 1)
            $fwrite(fd, "%h\n", dut.core.tlb_r[ci2]);
        for (ci2 = 0; ci2 <= 15; ci2 = ci2 + 1)
            $fwrite(fd, "%h\n", dut.core.tlb_w[ci2]);
        for (ci2 = 0; ci2 <= 15; ci2 = ci2 + 1)
            $fwrite(fd, "%h\n", dut.core.tlb_x[ci2]);
        for (ci2 = 0; ci2 <= 15; ci2 = ci2 + 1)
            $fwrite(fd, "%h\n", dut.core.tlb_u[ci2]);
        for (ci2 = 0; ci2 <= 15; ci2 = ci2 + 1)
            $fwrite(fd, "%h\n", dut.core.tlb_super[ci2]);
        for (ci2 = 0; ci2 <= 15; ci2 = ci2 + 1)
            $fwrite(fd, "%h\n", dut.core.tlb_d[ci2]);
        $fwrite(fd, "%h\n", dut.mtime_r);
        $fwrite(fd, "%h\n", dut.mtimecmp_r);
        $fwrite(fd, "%h\n", dut.sbi_ipi_pending);
        $fwrite(fd, "%h\n", dut.u16550_ier);
        $fwrite(fd, "%h\n", dut.u16550_lcr);
        $fwrite(fd, "%h\n", dut.u16550_mcr);
        $fwrite(fd, "%h\n", dut.u16550_scr);
        $fwrite(fd, "%h\n", dut.u16550_dll);
        $fwrite(fd, "%h\n", dut.u16550_dlm);
        $fwrite(fd, "%h\n", dut.u16550_head);
        $fwrite(fd, "%h\n", dut.u16550_tail);
        $fwrite(fd, "%h\n", dut.u16550_count);
        $fwrite(fd, "%h\n", dut.u16550_tx);
        $fwrite(fd, "%h\n", dut.u16550_tx_valid);
        $fwrite(fd, "%h\n", dut.rx_head);
        $fwrite(fd, "%h\n", dut.rx_tail);
        $fwrite(fd, "%h\n", dut.rx_count);
        $fwrite(fd, "%h\n", dut.net_tx_head);
        $fwrite(fd, "%h\n", dut.net_tx_tail);
        $fwrite(fd, "%h\n", dut.net_rx_head);
        $fwrite(fd, "%h\n", dut.net_rx_tail);
        $fwrite(fd, "%h\n", dut.net_tx_count);
        $fwrite(fd, "%h\n", dut.net_rx_count);
        $fwrite(fd, "%h\n", dut.net_tx_r);
        $fwrite(fd, "%h\n", dut.net_tx_valid_r);
        $fwrite(fd, "%h\n", dut.plic_enable_m);
        $fwrite(fd, "%h\n", dut.plic_enable_s);
        $fwrite(fd, "%h\n", dut.plic_thresh_m);
        $fwrite(fd, "%h\n", dut.plic_thresh_s);
        $fwrite(fd, "%h\n", dut.plic_claim_m);
        $fwrite(fd, "%h\n", dut.plic_claim_s);
        $fwrite(fd, "%h\n", dut.plic_best_prio_m);
        $fwrite(fd, "%h\n", dut.plic_best_prio_s);
        $fwrite(fd, "%h\n", dut.v_status);
        $fwrite(fd, "%h\n", dut.v_feat_sel);
        $fwrite(fd, "%h\n", dut.v_drv_feat);
        $fwrite(fd, "%h\n", dut.v_drv_feat_sel);
        $fwrite(fd, "%h\n", dut.v_queue_sel);
        $fwrite(fd, "%h\n", dut.v_queue_num);
        $fwrite(fd, "%h\n", dut.v_queue_ready);
        $fwrite(fd, "%h\n", dut.v_desc_lo);
        $fwrite(fd, "%h\n", dut.v_desc_hi);
        $fwrite(fd, "%h\n", dut.v_drv_lo);
        $fwrite(fd, "%h\n", dut.v_drv_hi);
        $fwrite(fd, "%h\n", dut.v_dev_lo);
        $fwrite(fd, "%h\n", dut.v_dev_hi);
        $fwrite(fd, "%h\n", dut.v_int_status);
        $fwrite(fd, "%h\n", dut.v_notify_q);
        $fwrite(fd, "%h\n", dut.v_state);
        $fwrite(fd, "%h\n", dut.v_avail_idx);
        $fwrite(fd, "%h\n", dut.v_used_idx);
        $fwrite(fd, "%h\n", dut.v_cur_desc);
        $fwrite(fd, "%h\n", dut.v_desc_addr);
        $fwrite(fd, "%h\n", dut.v_req_type);
        $fwrite(fd, "%h\n", dut.v_req_sector_lo);
        $fwrite(fd, "%h\n", dut.v_req_sector_hi);
        $fwrite(fd, "%h\n", dut.v_data_addr);
        $fwrite(fd, "%h\n", dut.v_data_len);
        $fwrite(fd, "%h\n", dut.v_data_off);
        $fwrite(fd, "%h\n", dut.v_status_addr);
        $fwrite(fd, "%h\n", dut.v_rd_addr);
        $fwrite(fd, "%h\n", dut.v_rd_data);
        $fwrite(fd, "%h\n", dut.v_rd_armed);
        $fwrite(fd, "%h\n", dut.v_d0);
        $fwrite(fd, "%h\n", dut.v_d2);
        $fwrite(fd, "%h\n", dut.v_d3);
        $fwrite(fd, "%h\n", dut.v_hdr0);
        $fwrite(fd, "%h\n", dut.v_hdr2);
        $fwrite(fd, "%h\n", dut.v_disk_off);
        $fwrite(fd, "%h\n", dut.v_chain_len);
        $fwrite(fd, "%h\n", dut.v_used_len);
        $fwrite(fd, "%h\n", dut.v_req_write);
        $fwrite(fd, "%h\n", dut.v_req_error);
        $fwrite(fd, "%h\n", dut.v_tmp_byte);
        $fwrite(fd, "%h\n", dut.v_last_avail);
        $fwrite(fd, "%h\n", dut.v_copy_src);
        $fwrite(fd, "%h\n", dut.v_copy_dst);
        $fwrite(fd, "%h\n", dut.dev_rdata);
        for (ci2 = 0; ci2 <= 15; ci2 = ci2 + 1)
            $fwrite(fd, "%h\n", dut.u16550_fifo[ci2]);
        for (ci2 = 0; ci2 <= 15; ci2 = ci2 + 1)
            $fwrite(fd, "%h\n", dut.rx_fifo[ci2]);
        for (ci2 = 0; ci2 <= 63; ci2 = ci2 + 1)
            $fwrite(fd, "%h\n", dut.net_tx_fifo[ci2]);
        for (ci2 = 0; ci2 <= 63; ci2 = ci2 + 1)
            $fwrite(fd, "%h\n", dut.net_rx_fifo[ci2]);
        for (ci2 = 1; ci2 <= 3; ci2 = ci2 + 1)
            $fwrite(fd, "%h\n", dut.plic_prio[ci2]);
        for (ci2 = 1; ci2 <= 3; ci2 = ci2 + 1)
            $fwrite(fd, "%h\n", dut.plic_claimed[ci2]);
                $fclose(fd);
            end
            $sformat(ckptpath, "%0s/ckpt_%0d.ram", ckptdir, cyc);
            $writememh(ckptpath, dut.memw);
            $sformat(ckptpath, "%0s/ckpt_%0d.disk", ckptdir, cyc);
            $writememh(ckptpath, dut.disk);
            $sformat(ckptpath, "%0s/ckpt_%0d.vram", ckptdir, cyc);
            $writememh(ckptpath, dut.vramw);
            $sformat(ckptpath, "%0s/ckpt_%0d.pix", ckptdir, cyc);
            $writememh(ckptpath, dut.pixw);
            // Completion marker, written LAST: a checkpoint is
            // only trusted if its .done file exists. A kill
            // landing mid-dump (as in the first kill test, which
            // caught a 0-byte .ram) leaves a torn set with no
            // .done, and the wrapper must fall back to the
            // previous complete checkpoint, never resume a torn
            // one. Same-cycle re-runs must clear the old set
            // first (the wrapper does this), so a stale .done
            // can never validate a new partial dump.
            $sformat(ckptpath, "%0s/ckpt_%0d.done", ckptdir, cyc);
            fd = $fopen(ckptpath, "w");
            if (fd) begin
                $fwrite(fd, "complete %0d\n", cyc);
                $fclose(fd);
            end
            $display("CKPT: cycle %0d written to %0s", cyc, ckptdir);
        end
    endtask

    task do_resume;
        input integer cyc;
        begin
            $sformat(ckptpath, "%0s/ckpt_%0d.hdr", ckptdir, cyc);
            fd = $fopen(ckptpath, "r");
            if (!fd) begin
                $display("RESUME-ERROR: cannot open %0s", ckptpath);
                $finish;
            end
            code = $fscanf(fd, "%d", cycles);
            code = $fscanf(fd, "%d", rx2idx);
            code = $fscanf(fd, "%d", rx2next);
        code = $fscanf(fd, "%h", dut.core.halted);
        code = $fscanf(fd, "%h", dut.core.uart_tx);
        code = $fscanf(fd, "%h", dut.core.uart_tx_valid);
        code = $fscanf(fd, "%h", dut.core.pc);
        code = $fscanf(fd, "%h", dut.core.csr_mstatus);
        code = $fscanf(fd, "%h", dut.core.csr_mtvec);
        code = $fscanf(fd, "%h", dut.core.csr_mscratch);
        code = $fscanf(fd, "%h", dut.core.csr_mepc);
        code = $fscanf(fd, "%h", dut.core.csr_mcause);
        code = $fscanf(fd, "%h", dut.core.csr_mtval);
        code = $fscanf(fd, "%h", dut.core.csr_mie);
        code = $fscanf(fd, "%h", dut.core.priv);
        code = $fscanf(fd, "%h", dut.core.csr_sstatus);
        code = $fscanf(fd, "%h", dut.core.csr_sie);
        code = $fscanf(fd, "%h", dut.core.csr_stvec);
        code = $fscanf(fd, "%h", dut.core.csr_sscratch);
        code = $fscanf(fd, "%h", dut.core.csr_sepc);
        code = $fscanf(fd, "%h", dut.core.csr_scause);
        code = $fscanf(fd, "%h", dut.core.csr_stval);
        code = $fscanf(fd, "%h", dut.core.csr_satp);
        code = $fscanf(fd, "%h", dut.core.csr_medeleg);
        code = $fscanf(fd, "%h", dut.core.csr_mideleg);
        code = $fscanf(fd, "%h", dut.core.ptw_state);
        code = $fscanf(fd, "%h", dut.core.ptw_is_fetch);
        code = $fscanf(fd, "%h", dut.core.ptw_is_store);
        code = $fscanf(fd, "%h", dut.core.ptw_va);
        code = $fscanf(fd, "%h", dut.core.ptw_root_base);
        code = $fscanf(fd, "%h", dut.core.ptw_pte1);
        code = $fscanf(fd, "%h", dut.core.ptw_data_pa);
        code = $fscanf(fd, "%h", dut.core.ptw_data_done);
        code = $fscanf(fd, "%h", dut.core.ptw_data_fault);
        code = $fscanf(fd, "%h", dut.core.ptw_data_super);
        code = $fscanf(fd, "%h", dut.core.ptw_data_fault_cause);
        code = $fscanf(fd, "%h", dut.core.fetch_pa);
        code = $fscanf(fd, "%h", dut.core.fetch_pa_pc);
        code = $fscanf(fd, "%h", dut.core.fetch_pa_valid);
        code = $fscanf(fd, "%h", dut.core.fetch_fault_pending);
        code = $fscanf(fd, "%h", dut.core.fetch_fault_pc);
        code = $fscanf(fd, "%h", dut.core.core_cycles);
        code = $fscanf(fd, "%h", dut.core.tlb_rr);
        code = $fscanf(fd, "%h", dut.core.ptw_write_addr);
        code = $fscanf(fd, "%h", dut.core.ptw_write_data);
        code = $fscanf(fd, "%h", dut.core.ptw_accept_pte);
        code = $fscanf(fd, "%h", dut.core.ptw_accept_pa);
        code = $fscanf(fd, "%h", dut.core.ptw_accept_va);
        code = $fscanf(fd, "%h", dut.core.ptw_accept_super);
        code = $fscanf(fd, "%h", dut.core.ptw_accept_is_fetch);
        code = $fscanf(fd, "%h", dut.core.ptw_accept_is_store);
        code = $fscanf(fd, "%h", dut.core.reservation_valid);
        code = $fscanf(fd, "%h", dut.core.reservation_addr);
        code = $fscanf(fd, "%h", dut.core.if_id_instr);
        code = $fscanf(fd, "%h", dut.core.if_id_pc);
        code = $fscanf(fd, "%h", dut.core.if_id_fetch_fault);
        code = $fscanf(fd, "%h", dut.core.if_id_valid);
        code = $fscanf(fd, "%h", dut.core.id_ex_fetch_fault);
        code = $fscanf(fd, "%h", dut.core.id_ex_pc);
        code = $fscanf(fd, "%h", dut.core.id_ex_opcode);
        code = $fscanf(fd, "%h", dut.core.id_ex_rd);
        code = $fscanf(fd, "%h", dut.core.id_ex_rs1);
        code = $fscanf(fd, "%h", dut.core.id_ex_rs2);
        code = $fscanf(fd, "%h", dut.core.id_ex_funct3);
        code = $fscanf(fd, "%h", dut.core.id_ex_funct7);
        code = $fscanf(fd, "%h", dut.core.id_ex_imm_i);
        code = $fscanf(fd, "%h", dut.core.id_ex_imm_s);
        code = $fscanf(fd, "%h", dut.core.id_ex_imm_b);
        code = $fscanf(fd, "%h", dut.core.id_ex_imm_u);
        code = $fscanf(fd, "%h", dut.core.id_ex_imm_j);
        code = $fscanf(fd, "%h", dut.core.id_ex_csr_addr);
        code = $fscanf(fd, "%h", dut.core.id_ex_amo_f5);
        code = $fscanf(fd, "%h", dut.core.ex_mem_pc);
        code = $fscanf(fd, "%h", dut.core.ex_mem_rd);
        code = $fscanf(fd, "%h", dut.core.ex_mem_funct3);
        code = $fscanf(fd, "%h", dut.core.ex_mem_result);
        code = $fscanf(fd, "%h", dut.core.ex_mem_rs2);
        code = $fscanf(fd, "%h", dut.core.ex_mem_addr);
        code = $fscanf(fd, "%h", dut.core.ex_mem_reg_write);
        code = $fscanf(fd, "%h", dut.core.ex_mem_is_load);
        code = $fscanf(fd, "%h", dut.core.ex_mem_is_store);
        code = $fscanf(fd, "%h", dut.core.ex_mem_is_amo);
        code = $fscanf(fd, "%h", dut.core.ex_mem_is_sc);
        code = $fscanf(fd, "%h", dut.core.ex_mem_is_lr);
        code = $fscanf(fd, "%h", dut.core.ex_mem_amo_funct5);
        code = $fscanf(fd, "%h", dut.core.ex_mem_csr_write);
        code = $fscanf(fd, "%h", dut.core.ex_mem_csr_addr);
        code = $fscanf(fd, "%h", dut.core.ex_mem_csr_new);
        code = $fscanf(fd, "%h", dut.core.ex_mem_size);
        code = $fscanf(fd, "%h", dut.core.mem_wb_rd);
        code = $fscanf(fd, "%h", dut.core.mem_wb_data);
        code = $fscanf(fd, "%h", dut.core.mem_wb_reg_write);
        code = $fscanf(fd, "%h", dut.core.mem_wb_csr_write);
        code = $fscanf(fd, "%h", dut.core.mem_wb_csr_addr);
        code = $fscanf(fd, "%h", dut.core.mem_wb_csr_new);
        code = $fscanf(fd, "%h", dut.core.div_busy);
        code = $fscanf(fd, "%h", dut.core.div_cnt);
        code = $fscanf(fd, "%h", dut.core.div_rem);
        code = $fscanf(fd, "%h", dut.core.div_quot);
        code = $fscanf(fd, "%h", dut.core.div_divisor);
        code = $fscanf(fd, "%h", dut.core.div_dividend);
        code = $fscanf(fd, "%h", dut.core.div_signed_r);
        code = $fscanf(fd, "%h", dut.core.div_is_rem_r);
        code = $fscanf(fd, "%h", dut.core.div_neg_q_r);
        code = $fscanf(fd, "%h", dut.core.div_neg_r_r);
        code = $fscanf(fd, "%h", dut.core.tlb_fetch_hit);
        code = $fscanf(fd, "%h", dut.core.tlb_fetch_perm_ok);
        code = $fscanf(fd, "%h", dut.core.tlb_fetch_pa);
        code = $fscanf(fd, "%h", dut.core.ptw_addr);
        code = $fscanf(fd, "%h", dut.core.load_data);
        code = $fscanf(fd, "%h", dut.core.amo_new);
        code = $fscanf(fd, "%h", dut.core.mem_result);
        code = $fscanf(fd, "%h", dut.core.d_we_comb);
        code = $fscanf(fd, "%h", dut.core.d_wdata_comb);
        code = $fscanf(fd, "%h", dut.core.d_wmask_comb);
        code = $fscanf(fd, "%h", dut.core.ex_rs1_fwd);
        code = $fscanf(fd, "%h", dut.core.ex_rs2_fwd);
        code = $fscanf(fd, "%h", dut.core.ex_csr_old);
        code = $fscanf(fd, "%h", dut.core.ex_trap_cause);
        code = $fscanf(fd, "%h", dut.core.ex_trap_tval);
        code = $fscanf(fd, "%h", dut.core.ex_trap_to_s);
        code = $fscanf(fd, "%h", dut.core.ex_csr_new);
        code = $fscanf(fd, "%h", dut.core.ex_csr_write);
        code = $fscanf(fd, "%h", dut.core.div_abs_a);
        code = $fscanf(fd, "%h", dut.core.div_abs_b);
        code = $fscanf(fd, "%h", dut.core.div_neg_q);
        code = $fscanf(fd, "%h", dut.core.div_neg_r);
        code = $fscanf(fd, "%h", dut.core.div_iter_rem);
        code = $fscanf(fd, "%h", dut.core.div_iter_quot);
        code = $fscanf(fd, "%h", dut.core.div_start_rem);
        code = $fscanf(fd, "%h", dut.core.div_start_quot);
        code = $fscanf(fd, "%h", dut.core.div_start_sub);
        code = $fscanf(fd, "%h", dut.core.div_bit_idx);
        code = $fscanf(fd, "%h", dut.core.div_shifted_start);
        code = $fscanf(fd, "%h", dut.core.div_shifted_busy);
        code = $fscanf(fd, "%h", dut.core.div_sub);
        code = $fscanf(fd, "%h", dut.core.div_ready);
        code = $fscanf(fd, "%h", dut.core.div_result);
        code = $fscanf(fd, "%h", dut.core.ex_alu_out);
        code = $fscanf(fd, "%h", dut.core.ex_branch_taken);
        code = $fscanf(fd, "%h", dut.core.tlb_data_hit);
        code = $fscanf(fd, "%h", dut.core.tlb_data_perm_ok);
        code = $fscanf(fd, "%h", dut.core.tlb_data_rw_ok);
        code = $fscanf(fd, "%h", dut.core.tlb_data_priv_ok);
        code = $fscanf(fd, "%h", dut.core.tlb_data_dbit);
        code = $fscanf(fd, "%h", dut.core.tlb_data_super);
        code = $fscanf(fd, "%h", dut.core.tlb_data_pa);
        code = $fscanf(fd, "%h", dut.core.ex_result);
        code = $fscanf(fd, "%h", dut.core.ex_reg_write);
        code = $fscanf(fd, "%h", dut.core.ex_target);
        code = $fscanf(fd, "%h", dut.core.ptw_perm_fault_now);
        for (ci2 = 0; ci2 <= 31; ci2 = ci2 + 1)
            code = $fscanf(fd, "%h", dut.core.regs[ci2]);
        for (ci2 = 0; ci2 <= 15; ci2 = ci2 + 1)
            code = $fscanf(fd, "%h", dut.core.tlb_valid[ci2]);
        for (ci2 = 0; ci2 <= 15; ci2 = ci2 + 1)
            code = $fscanf(fd, "%h", dut.core.tlb_vpn[ci2]);
        for (ci2 = 0; ci2 <= 15; ci2 = ci2 + 1)
            code = $fscanf(fd, "%h", dut.core.tlb_ppn[ci2]);
        for (ci2 = 0; ci2 <= 15; ci2 = ci2 + 1)
            code = $fscanf(fd, "%h", dut.core.tlb_r[ci2]);
        for (ci2 = 0; ci2 <= 15; ci2 = ci2 + 1)
            code = $fscanf(fd, "%h", dut.core.tlb_w[ci2]);
        for (ci2 = 0; ci2 <= 15; ci2 = ci2 + 1)
            code = $fscanf(fd, "%h", dut.core.tlb_x[ci2]);
        for (ci2 = 0; ci2 <= 15; ci2 = ci2 + 1)
            code = $fscanf(fd, "%h", dut.core.tlb_u[ci2]);
        for (ci2 = 0; ci2 <= 15; ci2 = ci2 + 1)
            code = $fscanf(fd, "%h", dut.core.tlb_super[ci2]);
        for (ci2 = 0; ci2 <= 15; ci2 = ci2 + 1)
            code = $fscanf(fd, "%h", dut.core.tlb_d[ci2]);
        code = $fscanf(fd, "%h", dut.mtime_r);
        code = $fscanf(fd, "%h", dut.mtimecmp_r);
        code = $fscanf(fd, "%h", dut.sbi_ipi_pending);
        code = $fscanf(fd, "%h", dut.u16550_ier);
        code = $fscanf(fd, "%h", dut.u16550_lcr);
        code = $fscanf(fd, "%h", dut.u16550_mcr);
        code = $fscanf(fd, "%h", dut.u16550_scr);
        code = $fscanf(fd, "%h", dut.u16550_dll);
        code = $fscanf(fd, "%h", dut.u16550_dlm);
        code = $fscanf(fd, "%h", dut.u16550_head);
        code = $fscanf(fd, "%h", dut.u16550_tail);
        code = $fscanf(fd, "%h", dut.u16550_count);
        code = $fscanf(fd, "%h", dut.u16550_tx);
        code = $fscanf(fd, "%h", dut.u16550_tx_valid);
        code = $fscanf(fd, "%h", dut.rx_head);
        code = $fscanf(fd, "%h", dut.rx_tail);
        code = $fscanf(fd, "%h", dut.rx_count);
        code = $fscanf(fd, "%h", dut.net_tx_head);
        code = $fscanf(fd, "%h", dut.net_tx_tail);
        code = $fscanf(fd, "%h", dut.net_rx_head);
        code = $fscanf(fd, "%h", dut.net_rx_tail);
        code = $fscanf(fd, "%h", dut.net_tx_count);
        code = $fscanf(fd, "%h", dut.net_rx_count);
        code = $fscanf(fd, "%h", dut.net_tx_r);
        code = $fscanf(fd, "%h", dut.net_tx_valid_r);
        code = $fscanf(fd, "%h", dut.plic_enable_m);
        code = $fscanf(fd, "%h", dut.plic_enable_s);
        code = $fscanf(fd, "%h", dut.plic_thresh_m);
        code = $fscanf(fd, "%h", dut.plic_thresh_s);
        code = $fscanf(fd, "%h", dut.plic_claim_m);
        code = $fscanf(fd, "%h", dut.plic_claim_s);
        code = $fscanf(fd, "%h", dut.plic_best_prio_m);
        code = $fscanf(fd, "%h", dut.plic_best_prio_s);
        code = $fscanf(fd, "%h", dut.v_status);
        code = $fscanf(fd, "%h", dut.v_feat_sel);
        code = $fscanf(fd, "%h", dut.v_drv_feat);
        code = $fscanf(fd, "%h", dut.v_drv_feat_sel);
        code = $fscanf(fd, "%h", dut.v_queue_sel);
        code = $fscanf(fd, "%h", dut.v_queue_num);
        code = $fscanf(fd, "%h", dut.v_queue_ready);
        code = $fscanf(fd, "%h", dut.v_desc_lo);
        code = $fscanf(fd, "%h", dut.v_desc_hi);
        code = $fscanf(fd, "%h", dut.v_drv_lo);
        code = $fscanf(fd, "%h", dut.v_drv_hi);
        code = $fscanf(fd, "%h", dut.v_dev_lo);
        code = $fscanf(fd, "%h", dut.v_dev_hi);
        code = $fscanf(fd, "%h", dut.v_int_status);
        code = $fscanf(fd, "%h", dut.v_notify_q);
        code = $fscanf(fd, "%h", dut.v_state);
        code = $fscanf(fd, "%h", dut.v_avail_idx);
        code = $fscanf(fd, "%h", dut.v_used_idx);
        code = $fscanf(fd, "%h", dut.v_cur_desc);
        code = $fscanf(fd, "%h", dut.v_desc_addr);
        code = $fscanf(fd, "%h", dut.v_req_type);
        code = $fscanf(fd, "%h", dut.v_req_sector_lo);
        code = $fscanf(fd, "%h", dut.v_req_sector_hi);
        code = $fscanf(fd, "%h", dut.v_data_addr);
        code = $fscanf(fd, "%h", dut.v_data_len);
        code = $fscanf(fd, "%h", dut.v_data_off);
        code = $fscanf(fd, "%h", dut.v_status_addr);
        code = $fscanf(fd, "%h", dut.v_rd_addr);
        code = $fscanf(fd, "%h", dut.v_rd_data);
        code = $fscanf(fd, "%h", dut.v_rd_armed);
        code = $fscanf(fd, "%h", dut.v_d0);
        code = $fscanf(fd, "%h", dut.v_d2);
        code = $fscanf(fd, "%h", dut.v_d3);
        code = $fscanf(fd, "%h", dut.v_hdr0);
        code = $fscanf(fd, "%h", dut.v_hdr2);
        code = $fscanf(fd, "%h", dut.v_disk_off);
        code = $fscanf(fd, "%h", dut.v_chain_len);
        code = $fscanf(fd, "%h", dut.v_used_len);
        code = $fscanf(fd, "%h", dut.v_req_write);
        code = $fscanf(fd, "%h", dut.v_req_error);
        code = $fscanf(fd, "%h", dut.v_tmp_byte);
        code = $fscanf(fd, "%h", dut.v_last_avail);
        code = $fscanf(fd, "%h", dut.v_copy_src);
        code = $fscanf(fd, "%h", dut.v_copy_dst);
        code = $fscanf(fd, "%h", dut.dev_rdata);
        for (ci2 = 0; ci2 <= 15; ci2 = ci2 + 1)
            code = $fscanf(fd, "%h", dut.u16550_fifo[ci2]);
        for (ci2 = 0; ci2 <= 15; ci2 = ci2 + 1)
            code = $fscanf(fd, "%h", dut.rx_fifo[ci2]);
        for (ci2 = 0; ci2 <= 63; ci2 = ci2 + 1)
            code = $fscanf(fd, "%h", dut.net_tx_fifo[ci2]);
        for (ci2 = 0; ci2 <= 63; ci2 = ci2 + 1)
            code = $fscanf(fd, "%h", dut.net_rx_fifo[ci2]);
        // NOTE: Icarus rejects $fscanf straight into the [1:3]
        // PLIC arrays ("vpiConstant not assignable"), so these
        // two go through temp regs. The [0:N] arrays above
        // accept $fscanf directly and are left as-is.
        for (ci2 = 1; ci2 <= 3; ci2 = ci2 + 1) begin
            code = $fscanf(fd, "%h", tmp32);
            dut.plic_prio[ci2] = tmp32[2:0];
        end
        for (ci2 = 1; ci2 <= 3; ci2 = ci2 + 1) begin
            code = $fscanf(fd, "%h", tmp1);
            dut.plic_claimed[ci2] = tmp1;
        end
            $fclose(fd);
            $sformat(ckptpath, "%0s/ckpt_%0d.ram", ckptdir, cyc);
            $readmemh(ckptpath, dut.memw);
            $sformat(ckptpath, "%0s/ckpt_%0d.disk", ckptdir, cyc);
            $readmemh(ckptpath, dut.disk);
            $sformat(ckptpath, "%0s/ckpt_%0d.vram", ckptdir, cyc);
            $readmemh(ckptpath, dut.vramw);
            $sformat(ckptpath, "%0s/ckpt_%0d.pix", ckptdir, cyc);
            $readmemh(ckptpath, dut.pixw);
            $display("RESUMED: cycle %0d from %0s", cycles, ckptdir);
        end
    endtask

    initial begin
        rst_n = 0;
        run_clk = 0;
        trace_on = 0;
        sample_cnt = 0;
        cnt_int_tim = 0; cnt_int_ext = 0; cnt_int_sof = 0; cnt_trap = 0;
        traceperiod = 100; snapperiod = 500000;
        if (!$value$plusargs("TRACEPERIOD=%d", traceperiod)) begin end
        if (!$value$plusargs("SNAPPERIOD=%d", snapperiod)) begin end
        if (!$value$plusargs("TRACEFILE=%s", tracefile))
            tracefile = "kernel/pc_trace_100m.txt";
        if (!$value$plusargs("TRACESNAPFILE=%s", snapfile))
            snapfile = "kernel/pc_trace_100m_snap.txt";
        trace_fd = $fopen(tracefile, "w");
        snap_fd = $fopen(snapfile, "w");
        if (!$value$plusargs("CKPTDIR=%s", ckptdir))
            ckptdir = "";
        ckptat = -1;
        ckptevery = 0;
        resumecyc = -1;
        ckptonvstate = -1;
        ckptontx = 0;
        trig_fired = 0;
        if (!$value$plusargs("CKPTAT=%d", ckptat)) begin end
        if (!$value$plusargs("CKPTEVERY=%d", ckptevery)) begin end
        if (!$value$plusargs("RESUME=%d", resumecyc)) begin end
        if (!$value$plusargs("CKPTONVSTATE=%d", ckptonvstate)) begin end
        if ($test$plusargs("CKPTONTX")) ckptontx = 1;
        if (!$test$plusargs("NOCLEAR")) begin
            for (i = 0; i < dut.MEM_WORDS; i = i + 1)
                dut.memw[i] = 32'b0;
        end
        if (!$value$plusargs("HEX=%s", hexfile))
            hexfile = "soc2_hex/soc2_current.hex";
        $readmemh(hexfile, img);
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
                dut.memw[(dtboff + i) >> 2] =
                    (dut.memw[(dtboff + i) >> 2] &
                     ~(32'hFF << (((dtboff + i) & 3) * 8))) |
                    (dtbbytes[i] << (((dtboff + i) & 3) * 8));
        end
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
        if (resumecyc >= 0) begin
            // Reset-settle: let the reset branches run a few
            // cycles, then hold the clock at 0 (after a
            // negedge, so no TX sample is pending) and overlay
            // the checkpoint on top of the fresh loads above.
            run_clk = 1;
            repeat (4) @(posedge clk);
            @(negedge clk);
            run_clk = 0;
            do_resume(resumecyc);
            rst_n = 1;
            nextckpt = (ckptat >= 0) ? ckptat : -1;
            if ((nextckpt >= 0) && (nextckpt <= cycles))
                nextckpt = cycles + ((ckptevery > 0) ? ckptevery : -1);
            run_clk = 1;
            trace_on = 1;
        end else begin
            run_clk = 1;
            #23;
            rst_n = 1;
            trace_on = 1;
            cycles = 0;
            rx2next = rx2start;
            nextckpt = ckptat;
        end
        while (!halted && cycles < maxcycles) begin
            @(posedge clk);
            cycles = cycles + 1;
            if (cycles % traceperiod == 0) begin
                $fwrite(trace_fd, "%0d %08x %0d\n", cycles, dut.core.pc, dut.core.priv);
                sample_cnt = sample_cnt + 1;
                // Flush regularly so a VM restart mid-run keeps the
                // samples taken so far (Icarus otherwise buffers ~8KB).
                if (sample_cnt % 1000 == 0) $fflush(trace_fd);
            end
            if ((snapperiod > 0) && (cycles % snapperiod == 0)) begin
                $fwrite(snap_fd, "%0d pc=%08x priv=%0d mtime=%0d mtimecmp=%0d irq_timer=%0d sie=%08x mie=%08x sstatus=%08x mstatus=%08x mcause=%08x scause=%08x satp=%08x\n",
                    cycles, dut.core.pc, dut.core.priv, dut.mtime_r, dut.mtimecmp_r, dut.irq_timer_w,
                    dut.core.csr_sie, dut.core.csr_mie, dut.core.csr_sstatus, dut.core.csr_mstatus,
                    dut.core.csr_mcause, dut.core.csr_scause, dut.core.csr_satp);
                $fflush(snap_fd);
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
            if (!halted && (((nextckpt >= 0) && (cycles >= nextckpt)) ||
                ((ckptonvstate >= 0) && !trig_fired &&
                 (dut.v_state == ckptonvstate)) ||
                ((ckptontx == 1) && !trig_fired && uart_tx_valid))) begin
                // Wait for the negedge sample of this cycle,
                // then freeze the clock at 0 and dump.
                // (For the TX trigger: the pulse was set at
                // this posedge, so the negedge below is the
                // sample that prints it -- the checkpoint is
                // taken after the print, never before.)
                trig_fired = 1;
                @(negedge clk);
                run_clk = 0;
                do_checkpoint(cycles);
                if (ckptevery > 0)
                    nextckpt = cycles + ckptevery;
                else
                    nextckpt = -1;
                run_clk = 1;
            end
        end
        rx2_valid = 0;
        ext_irq = 0;
        repeat (4) @(posedge clk);
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
