// risky_genesys2_ddr_top.sv — Genesys 2 DDR3-backed top for xv6 boot
//
// Memory map:
//   0x80000000 – 0x9FFFFFFF   DDR3 SDRAM (512 MB via MIG)
//   0x02000000                CLINT (mtime/mtimecmp)
//   0x0C000000                PLIC
//   0x10000000                UART NS16550
//
// Boot flow: U-Boot or OpenSBI loaded into DDR3 at 0x80000000 by the FPGA
// initialisation (handled via init_data.mem or SPI flash). xv6 starts in
// S-mode after OpenSBI hands over.
//
// PTW runs as a standalone FSM; the arbiter gives it the highest priority.
// BRAM is retired; DDR3 is the single memory substrate.

module risky_genesys2_ddr_top (
    input  wire       clk200_p,
    input  wire       clk200_n,
    input  wire       cpu_resetn,
    input  wire       rx,
    output wire       tx,
    output wire [7:0] led,
    output wire       fan_pwm,

    // DDR3 pins (Genesys 2, matching the CVA6 MIG project)
    inout  wire [31:0] ddr3_dq,
    inout  wire [3:0]  ddr3_dqs_n,
    inout  wire [3:0]  ddr3_dqs_p,
    output wire [14:0] ddr3_addr,
    output wire [2:0]  ddr3_ba,
    output wire        ddr3_ras_n,
    output wire        ddr3_cas_n,
    output wire        ddr3_we_n,
    output wire        ddr3_reset_n,
    output wire [0:0]  ddr3_ck_p,
    output wire [0:0]  ddr3_ck_n,
    output wire [0:0]  ddr3_cke,
    output wire [0:0]  ddr3_cs_n,
    output wire [3:0]  ddr3_dm,
    output wire [0:0]  ddr3_odt
);
    // =========================================================================
    // Clocks and reset
    // =========================================================================
    localparam int CORE_CLK_HZ  = 50_000_000;   // MIG UI clock ÷ 4 = 50 MHz
    localparam int UART_BAUD    = 115200;
    localparam int UART_FIFO_DEPTH = 64;

    // MIG delivers ui_clk and ui_clk_sync_rst; the CPU runs in the MIG UI domain.
    wire clk_core;          // = mig ui_clk (50 MHz)
    wire mig_ui_clk_sync_rst;
    wire mig_mmcm_locked;
    wire mig_init_calib_complete;

    // =========================================================================
    // MIG instance. Like CVA6's Genesys 2 target, our MIG is AXI-facing.
    // =========================================================================
    wire [4:0]  mig_s_axi_awid;
    wire [29:0] mig_s_axi_awaddr;
    wire [7:0]  mig_s_axi_awlen;
    wire [2:0]  mig_s_axi_awsize;
    wire [1:0]  mig_s_axi_awburst;
    wire [0:0]  mig_s_axi_awlock;
    wire [3:0]  mig_s_axi_awcache;
    wire [2:0]  mig_s_axi_awprot;
    wire [3:0]  mig_s_axi_awqos;
    wire        mig_s_axi_awvalid;
    wire        mig_s_axi_awready;
    wire [63:0] mig_s_axi_wdata;
    wire [7:0]  mig_s_axi_wstrb;
    wire        mig_s_axi_wlast;
    wire        mig_s_axi_wvalid;
    wire        mig_s_axi_wready;
    wire        mig_s_axi_bready;
    wire [4:0]  mig_s_axi_bid;
    wire [1:0]  mig_s_axi_bresp;
    wire        mig_s_axi_bvalid;
    wire [4:0]  mig_s_axi_arid;
    wire [29:0] mig_s_axi_araddr;
    wire [7:0]  mig_s_axi_arlen;
    wire [2:0]  mig_s_axi_arsize;
    wire [1:0]  mig_s_axi_arburst;
    wire [0:0]  mig_s_axi_arlock;
    wire [3:0]  mig_s_axi_arcache;
    wire [2:0]  mig_s_axi_arprot;
    wire [3:0]  mig_s_axi_arqos;
    wire        mig_s_axi_arvalid;
    wire        mig_s_axi_arready;
    wire        mig_s_axi_rready;
    wire [4:0]  mig_s_axi_rid;
    wire [63:0] mig_s_axi_rdata;
    wire [1:0]  mig_s_axi_rresp;
    wire        mig_s_axi_rlast;
    wire        mig_s_axi_rvalid;
    wire         mig_app_sr_req = 1'b0;
    wire         mig_app_ref_req = 1'b0;
    wire         mig_app_zq_req = 1'b0;

    mig_7series_0 i_mig (
        // DDR3 pins
        .ddr3_dq        (ddr3_dq),
        .ddr3_dqs_n     (ddr3_dqs_n),
        .ddr3_dqs_p     (ddr3_dqs_p),
        .ddr3_addr      (ddr3_addr),
        .ddr3_ba        (ddr3_ba),
        .ddr3_ras_n     (ddr3_ras_n),
        .ddr3_cas_n     (ddr3_cas_n),
        .ddr3_we_n      (ddr3_we_n),
        .ddr3_reset_n   (ddr3_reset_n),
        .ddr3_ck_p      (ddr3_ck_p),
        .ddr3_ck_n      (ddr3_ck_n),
        .ddr3_cke       (ddr3_cke),
        .ddr3_cs_n      (ddr3_cs_n),
        .ddr3_dm        (ddr3_dm),
        .ddr3_odt       (ddr3_odt),
        // Clocks
        .sys_clk_p      (clk200_p),
        .sys_clk_n      (clk200_n),
        // AXI
        .aresetn        (cpu_resetn),
        .s_axi_awid     (mig_s_axi_awid),
        .s_axi_awaddr   (mig_s_axi_awaddr),
        .s_axi_awlen    (mig_s_axi_awlen),
        .s_axi_awsize   (mig_s_axi_awsize),
        .s_axi_awburst  (mig_s_axi_awburst),
        .s_axi_awlock   (mig_s_axi_awlock),
        .s_axi_awcache  (mig_s_axi_awcache),
        .s_axi_awprot   (mig_s_axi_awprot),
        .s_axi_awqos    (mig_s_axi_awqos),
        .s_axi_awvalid  (mig_s_axi_awvalid),
        .s_axi_awready  (mig_s_axi_awready),
        .s_axi_wdata    (mig_s_axi_wdata),
        .s_axi_wstrb    (mig_s_axi_wstrb),
        .s_axi_wlast    (mig_s_axi_wlast),
        .s_axi_wvalid   (mig_s_axi_wvalid),
        .s_axi_wready   (mig_s_axi_wready),
        .s_axi_bready   (mig_s_axi_bready),
        .s_axi_bid      (mig_s_axi_bid),
        .s_axi_bresp    (mig_s_axi_bresp),
        .s_axi_bvalid   (mig_s_axi_bvalid),
        .s_axi_arid     (mig_s_axi_arid),
        .s_axi_araddr   (mig_s_axi_araddr),
        .s_axi_arlen    (mig_s_axi_arlen),
        .s_axi_arsize   (mig_s_axi_arsize),
        .s_axi_arburst  (mig_s_axi_arburst),
        .s_axi_arlock   (mig_s_axi_arlock),
        .s_axi_arcache  (mig_s_axi_arcache),
        .s_axi_arprot   (mig_s_axi_arprot),
        .s_axi_arqos    (mig_s_axi_arqos),
        .s_axi_arvalid  (mig_s_axi_arvalid),
        .s_axi_arready  (mig_s_axi_arready),
        .s_axi_rready   (mig_s_axi_rready),
        .s_axi_rid      (mig_s_axi_rid),
        .s_axi_rdata    (mig_s_axi_rdata),
        .s_axi_rresp    (mig_s_axi_rresp),
        .s_axi_rlast    (mig_s_axi_rlast),
        .s_axi_rvalid   (mig_s_axi_rvalid),
        .app_sr_req     (mig_app_sr_req),
        .app_ref_req    (mig_app_ref_req),
        .app_zq_req     (mig_app_zq_req),
        .app_sr_active  (),
        .app_ref_ack    (),
        .app_zq_ack     (),
        .ui_clk         (clk_core),
        .ui_clk_sync_rst(mig_ui_clk_sync_rst),
        .init_calib_complete(mig_init_calib_complete),
        .mmcm_locked    (mig_mmcm_locked),
        .device_temp    (),
        .sys_rst        (cpu_resetn)
    );

    // =========================================================================
    // Reset
    // =========================================================================
    reg [7:0] reset_sync_q = 8'h00;
    wire sys_rst_n_raw = cpu_resetn && !mig_ui_clk_sync_rst && mig_init_calib_complete;
    always @(posedge clk_core or negedge sys_rst_n_raw) begin
        if (!sys_rst_n_raw) reset_sync_q <= 8'h00;
        else                reset_sync_q <= {reset_sync_q[6:0], 1'b1};
    end
    wire rst_ni = reset_sync_q[7];

    // =========================================================================
    // Core wires
    // =========================================================================
    wire [63:0] core_pc;
    wire        core_if_req_valid;
    wire [63:0] core_if_req_addr;
    wire [63:0] core_mem_addr;
    wire        core_mem_req_valid;
    wire [63:0] core_mem_req_addr;
    wire        core_mem_req_write;
    wire [63:0] core_mem_req_wdata;
    wire [2:0]  core_mem_req_width;
    wire        core_mem_read;
    wire        core_mem_write;
    wire        core_mmio_read_valid;
    wire [63:0] core_mmio_read_addr;
    wire        core_store_valid;
    wire [63:0] core_store_addr;
    wire [63:0] core_store_word;
    wire [31:0] core_imem_rdata;
    wire [63:0] core_mem_rdata;
    wire        core_sim_exit_valid;
    wire [63:0] core_sim_exit_code;
    wire [63:0] core_mtime;
    wire [63:0] core_mtimecmp;
    wire [63:0] core_stimecmp;
    wire [1:0]  core_priv;
    wire [63:0] core_satp;
    wire        core_sv39_flush;
    wire [63:0] core_ext_mip;

    wire        sv39_stall;
    wire        sv39_if_valid;
    wire [63:0] sv39_if_pa;
    wire        sv39_if_pf;
    wire        sv39_mem_valid;
    wire [63:0] sv39_mem_pa;
    wire        sv39_mem_pf;
    wire        sv39_mem_pf_store;

    // =========================================================================
    // Heartbeat + observation sink
    // =========================================================================
    reg [31:0] heartbeat_q = 32'd0;
    reg [63:0] core_store_addr_q = 64'h0000_0000_8000_0000;
    reg [63:0] core_store_word_q = 64'd0;
    reg        core_store_valid_q = 1'b0;

    wire [31:0] _obs_fold = {
        core_if_req_valid, core_mem_req_valid, core_mem_req_write,
        core_sim_exit_valid, core_sv39_flush,
        core_priv,
        |core_if_req_addr,  |core_mem_req_addr,
        |core_mem_req_wdata, |core_mem_req_width,
        |core_satp, |core_sim_exit_code,
        19'd0
    };

    always @(posedge clk_core) begin
        if (!rst_ni) begin
            heartbeat_q       <= 32'd0;
            core_store_addr_q <= 64'h0000_0000_8000_0000;
            core_store_word_q <= 64'd0;
            core_store_valid_q<= 1'b0;
        end else begin
            heartbeat_q       <= heartbeat_q + 32'd1 + {31'd0, ^_obs_fold};
            core_store_addr_q <= core_store_addr;
            core_store_word_q <= core_store_word;
            core_store_valid_q<= core_store_valid;
        end
    end

    // =========================================================================
    // Core
    // =========================================================================
    pipeline_core_bram_if i_core (
        .clk_i              (clk_core),
        .rst_ni             (rst_ni),
        .ext_mip_i          (core_ext_mip),
        .imem_rdata_i       (core_imem_rdata),
        .mem_rdata_i        (core_mem_rdata),
        .sv39_stall_i       (sv39_stall),
        .sv39_if_valid_i    (sv39_if_valid),
        .sv39_if_pa_i       (sv39_if_pa),
        .sv39_if_pf_i       (sv39_if_pf),
        .sv39_mem_valid_i   (sv39_mem_valid),
        .sv39_mem_pa_i      (sv39_mem_pa),
        .sv39_mem_pf_i      (sv39_mem_pf),
        .sv39_mem_pf_store_i(sv39_mem_pf_store),
        .pc_o               (core_pc),
        .if_req_valid_o     (core_if_req_valid),
        .if_req_addr_o      (core_if_req_addr),
        .mem_addr_o         (core_mem_addr),
        .mem_req_valid_o    (core_mem_req_valid),
        .mem_req_addr_o     (core_mem_req_addr),
        .mem_req_write_o    (core_mem_req_write),
        .mem_req_wdata_o    (core_mem_req_wdata),
        .mem_req_width_o    (core_mem_req_width),
        .mem_read_o         (core_mem_read),
        .mem_write_o        (core_mem_write),
        .mem_mmio_read_valid_o(core_mmio_read_valid),
        .mem_mmio_read_addr_o (core_mmio_read_addr),
        .mem_store_valid_o  (core_store_valid),
        .mem_store_addr_o   (core_store_addr),
        .mem_store_word_o   (core_store_word),
        .sim_exit_valid_o   (core_sim_exit_valid),
        .sim_exit_code_o    (core_sim_exit_code),
        .priv_o             (core_priv),
        .satp_o             (core_satp),
        .sv39_flush_o       (core_sv39_flush),
        .mtime_o            (core_mtime),
        .mtimecmp_o         (core_mtimecmp),
        .stimecmp_o         (core_stimecmp)
    );

    // =========================================================================
    // PTW
    // =========================================================================
    wire        ptw_mem_req;
    wire [63:0] ptw_mem_addr;
    wire        ptw_mem_rvalid;
    wire [63:0] ptw_mem_rdata;

    risky_ptw #(.TLB_ENTRIES(8)) i_ptw (
        .clk_i              (clk_core),
        .rst_ni             (rst_ni),
        .satp_i             (core_satp),
        .priv_i             (core_priv),
        .sv39_flush_i       (core_sv39_flush),
        // IF
        .if_va_i            (core_pc),
        .if_req_i           (rst_ni),
        // MEM
        .mem_va_i           (core_mem_addr),
        .mem_req_i          (core_mem_read || core_mem_write),
        .mem_write_i        (core_mem_write),
        // PTW memory port
        .ptw_mem_req_o      (ptw_mem_req),
        .ptw_mem_addr_o     (ptw_mem_addr),
        .ptw_mem_rvalid_i   (ptw_mem_rvalid),
        .ptw_mem_rdata_i    (ptw_mem_rdata),
        // Core sv39 outputs
        .sv39_stall_o       (sv39_stall),
        .sv39_if_valid_o    (sv39_if_valid),
        .sv39_if_pa_o       (sv39_if_pa),
        .sv39_if_pf_o       (sv39_if_pf),
        .sv39_mem_valid_o   (sv39_mem_valid),
        .sv39_mem_pa_o      (sv39_mem_pa),
        .sv39_mem_pf_o      (sv39_mem_pf),
        .sv39_mem_pf_store_o(sv39_mem_pf_store)
    );

    // =========================================================================
    // Arbiter
    // =========================================================================
    wire        arb_mem_req;
    wire [63:0] arb_mem_addr;
    wire        arb_mem_write;
    wire [63:0] arb_mem_wdata;
    wire [2:0]  arb_mem_width;
    wire        arb_mem_rsp_valid;
    wire [63:0] arb_mem_rsp_data;

    wire [31:0] arb_if_rsp_data;
    wire        arb_if_rsp_valid;
    wire        arb_mem_data_rsp_valid;
    wire [63:0] arb_mem_data_rsp_data;

    risky_mem_arbiter i_arbiter (
        .clk_i          (clk_core),
        .rst_ni         (rst_ni),
        // IF (use physical address from PTW for DDR reads when sv39 active)
        .if_req_valid_i (sv39_if_valid),
        .if_req_addr_i  (sv39_if_pa),
        .if_rsp_valid_o (arb_if_rsp_valid),
        .if_rsp_data_o  (arb_if_rsp_data),
        // MEM
        .mem_req_valid_i(sv39_mem_valid && !core_mem_write),
        .mem_req_addr_i (sv39_mem_pa),
        .mem_req_write_i(1'b0),
        .mem_req_wdata_i(64'd0),
        .mem_req_width_i(core_mem_req_width),
        .mem_rsp_valid_o(arb_mem_data_rsp_valid),
        .mem_rsp_data_o (arb_mem_data_rsp_data),
        // PTW
        .ptw_req_valid_i(ptw_mem_req),
        .ptw_req_addr_i (ptw_mem_addr),
        .ptw_rsp_valid_o(ptw_mem_rvalid),
        .ptw_rsp_data_o (ptw_mem_rdata),
        // Downstream
        .mem_req_o      (arb_mem_req),
        .mem_addr_o     (arb_mem_addr),
        .mem_write_o    (arb_mem_write),
        .mem_wdata_o    (arb_mem_wdata),
        .mem_width_o    (arb_mem_width),
        .mem_rsp_valid_i(arb_mem_rsp_valid),
        .mem_rsp_data_i (arb_mem_rsp_data)
    );

    assign core_imem_rdata = arb_if_rsp_valid  ? arb_if_rsp_data  : 32'h0000_0013;
    assign core_mem_rdata  = arb_mem_data_rsp_valid ? arb_mem_data_rsp_data : 64'd0;

    // =========================================================================
    // MIG Adapter
    // =========================================================================
    wire [63:0] mmio_rdata;
    wire [7:0]  led_state;
    wire [3:0]  uart_debug;

    // MMIO: check if address is in MMIO range (not DDR3)
    wire arb_is_mmio = arb_mem_req && (arb_mem_addr[31:28] != 4'h8) &&
                                      (arb_mem_addr[31:28] != 4'h9);
    wire arb_is_ddr  = arb_mem_req && !arb_is_mmio;

    // Store path: write to DDR3 or MMIO
    wire store_to_mmio = core_store_valid_q &&
                         ((core_store_addr_q[31:28] == 4'h1)  ||
                          (core_store_addr_q[31:24] == 8'h02) ||
                          (core_store_addr_q[31:26] == 6'd3));

    risky_mig_adapter i_mig_adapter (
        .clk_i              (clk_core),
        .rst_ni             (rst_ni),
        // Arbiter downstream
        .req_valid_i        (arb_is_ddr),
        .req_addr_i         (arb_mem_addr),
        .req_write_i        (arb_mem_write),
        .req_wdata_i        (arb_mem_wdata),
        .req_width_i        (arb_mem_width),
        // Write (store) path — bypass arbiter for committed stores
        .store_valid_i      (core_store_valid_q && !store_to_mmio),
        .store_addr_i       (core_store_addr_q),
        .store_data_i       (core_store_word_q),
        // Response
        .rsp_valid_o        (arb_mem_rsp_valid),
        .rsp_data_o         (arb_mem_rsp_data),
        // MIG AXI
        .s_axi_awid_o       (mig_s_axi_awid),
        .s_axi_awaddr_o     (mig_s_axi_awaddr),
        .s_axi_awlen_o      (mig_s_axi_awlen),
        .s_axi_awsize_o     (mig_s_axi_awsize),
        .s_axi_awburst_o    (mig_s_axi_awburst),
        .s_axi_awlock_o     (mig_s_axi_awlock),
        .s_axi_awcache_o    (mig_s_axi_awcache),
        .s_axi_awprot_o     (mig_s_axi_awprot),
        .s_axi_awqos_o      (mig_s_axi_awqos),
        .s_axi_awvalid_o    (mig_s_axi_awvalid),
        .s_axi_awready_i    (mig_s_axi_awready),
        .s_axi_wdata_o      (mig_s_axi_wdata),
        .s_axi_wstrb_o      (mig_s_axi_wstrb),
        .s_axi_wlast_o      (mig_s_axi_wlast),
        .s_axi_wvalid_o     (mig_s_axi_wvalid),
        .s_axi_wready_i     (mig_s_axi_wready),
        .s_axi_bready_o     (mig_s_axi_bready),
        .s_axi_bid_i        (mig_s_axi_bid),
        .s_axi_bresp_i      (mig_s_axi_bresp),
        .s_axi_bvalid_i     (mig_s_axi_bvalid),
        .s_axi_arid_o       (mig_s_axi_arid),
        .s_axi_araddr_o     (mig_s_axi_araddr),
        .s_axi_arlen_o      (mig_s_axi_arlen),
        .s_axi_arsize_o     (mig_s_axi_arsize),
        .s_axi_arburst_o    (mig_s_axi_arburst),
        .s_axi_arlock_o     (mig_s_axi_arlock),
        .s_axi_arcache_o    (mig_s_axi_arcache),
        .s_axi_arprot_o     (mig_s_axi_arprot),
        .s_axi_arqos_o      (mig_s_axi_arqos),
        .s_axi_arvalid_o    (mig_s_axi_arvalid),
        .s_axi_arready_i    (mig_s_axi_arready),
        .s_axi_rready_o     (mig_s_axi_rready),
        .s_axi_rid_i        (mig_s_axi_rid),
        .s_axi_rdata_i      (mig_s_axi_rdata),
        .s_axi_rresp_i      (mig_s_axi_rresp),
        .s_axi_rlast_i      (mig_s_axi_rlast),
        .s_axi_rvalid_i     (mig_s_axi_rvalid)
    );

    // =========================================================================
    // MMIO combinatorial read (UART/CLINT/PLIC) — same as BRAM target
    // =========================================================================
    risky_fpga_peripherals #(
        .CORE_CLK_HZ    (CORE_CLK_HZ),
        .UART_BAUD      (UART_BAUD),
        .UART_FIFO_DEPTH(UART_FIFO_DEPTH)
    ) i_peripherals (
        .clk_i              (clk_core),
        .rst_ni             (rst_ni),
        .rx_i               (rx),
        .mem_addr_i         (core_mem_addr),
        .mmio_read_valid_i  (core_mmio_read_valid),
        .mmio_read_addr_i   (core_mmio_read_addr),
        .store_valid_i      (store_to_mmio),
        .store_addr_i       (core_store_addr_q),
        .store_data_i       (core_store_word_q),
        .mtime_i            (core_mtime),
        .mtimecmp_i         (core_mtimecmp),
        .stimecmp_i         (core_stimecmp),
        .mem_rdata_o        (mmio_rdata),
        .ext_mip_o          (core_ext_mip),
        .tx_o               (tx),
        .led_o              (led_state),
        .uart_debug_o        (uart_debug),
        .fan_pwm_o          (fan_pwm)
    );

    assign led[0] = rst_ni;
    assign led[1] = heartbeat_q[22];
    assign led[2] = mig_init_calib_complete;
    assign led[3] = mig_mmcm_locked;
    assign led[4] = mig_s_axi_arvalid | mig_s_axi_awvalid;
    assign led[5] = mig_s_axi_arready | mig_s_axi_awready;
    assign led[6] = mig_s_axi_rvalid | mig_s_axi_bvalid;
    assign led[7] = led_state[1] | uart_debug[3];
endmodule
