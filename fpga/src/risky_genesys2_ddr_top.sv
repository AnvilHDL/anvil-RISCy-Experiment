// risky_genesys2_ddr_top.sv — Genesys 2 DDR3-backed top for xv6 boot
//
// Memory map:
//   0x80000000 – 0x9FFFFFFF   DDR3 SDRAM (512 MB via MIG)
//   0x02000000                CLINT (mtime/mtimecmp)
//   0x0C000000                PLIC
//   0x10000000                UART NS16550
//
// Clock architecture:
//   ui_clk    ≈ 200 MHz from MIG (DDR3-1600 controller clock; MIG owns IBUFDS on sys_clk_p/n)
//   clk_core  = 25 MHz  from MMCME2_BASE driven by ui_clk (200 MHz ÷ 8; VCO=1000 MHz)
//   axi_clock_converter_0 bridges core AXI (25 MHz) to MIG AXI (ui_clk)
//
// Memory stall contract:
//   risky_mem_arbiter.stall_o is ORed with sv39_stall to hold the pipeline
//   for the full DDR round-trip latency.

module risky_genesys2_ddr_top (
    input  wire       clk200_p,
    input  wire       clk200_n,
    input  wire       cpu_resetn,
    input  wire       rx,
    output wire       tx,
    output wire [7:0] led,
    output wire       fan_pwm,

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
    // Parameters
    // =========================================================================
    localparam int CORE_CLK_HZ     = 25_000_000;
    localparam int UART_BAUD       = 115200;
    localparam int UART_FIFO_DEPTH = 64;

    // =========================================================================
    // MIG owns the IBUFDS on sys_clk_p/n (clk200_p/n).  Its ui_clk output
    // (≈200 MHz) feeds our MMCM to produce the 25 MHz core clock.
    // =========================================================================
    wire ui_clk;               // driven by MIG below; declared early for MMCM
    wire clk_core;
    wire core_clk_locked;

    wire clkfb_mmcm, clkfb_bufg, clk_core_mmcm;
    wire clkout0b_unused, clkout1_unused, clkout1b_unused;
    wire clkout2_unused,  clkout2b_unused;
    wire clkout3_unused,  clkout3b_unused;
    wire clkout4_unused,  clkout5_unused, clkout6_unused;
    wire clkfboutb_unused;

    MMCME2_BASE #(
        .BANDWIDTH         ("OPTIMIZED"),
        .CLKIN1_PERIOD     (5.000),    // ui_clk ≈ 200 MHz → 5 ns
        .CLKFBOUT_MULT_F   (5.000),    // VCO = 1000 MHz
        .DIVCLK_DIVIDE     (1),
        .CLKOUT0_DIVIDE_F  (40.000),   // 25 MHz
        .CLKOUT0_DUTY_CYCLE(0.500),
        .STARTUP_WAIT      ("FALSE")
    ) i_coreclk_mmcm (
        .CLKIN1   (ui_clk),
        .CLKFBIN  (clkfb_bufg),
        .RST      (!cpu_resetn),
        .PWRDWN   (1'b0),
        .CLKFBOUT (clkfb_mmcm),
        .CLKFBOUTB(clkfboutb_unused),
        .CLKOUT0  (clk_core_mmcm),
        .CLKOUT0B (clkout0b_unused),
        .CLKOUT1  (clkout1_unused),
        .CLKOUT1B (clkout1b_unused),
        .CLKOUT2  (clkout2_unused),
        .CLKOUT2B (clkout2b_unused),
        .CLKOUT3  (clkout3_unused),
        .CLKOUT3B (clkout3b_unused),
        .CLKOUT4  (clkout4_unused),
        .CLKOUT5  (clkout5_unused),
        .CLKOUT6  (clkout6_unused),
        .LOCKED   (core_clk_locked)
    );

    BUFG i_coreclk_fb_bufg (.I(clkfb_mmcm),    .O(clkfb_bufg));
    BUFG i_coreclk_bufg    (.I(clk_core_mmcm), .O(clk_core));

    // =========================================================================
    // MIG instance — AXI slave runs in ui_clk domain (≈200 MHz)
    // All core-side logic runs in clk_core domain (25 MHz); an
    // axi_clock_converter_0 bridges the two domains below.
    // =========================================================================

    wire mig_ui_clk_sync_rst;
    wire mig_mmcm_locked;
    wire mig_init_calib_complete;

    // MIG-domain AXI wires (master outputs of axi_clock_converter_0 → MIG)
    wire [4:0]  m_axi_awid;
    wire [29:0] m_axi_awaddr;
    wire [7:0]  m_axi_awlen;
    wire [2:0]  m_axi_awsize;
    wire [1:0]  m_axi_awburst;
    wire [0:0]  m_axi_awlock;
    wire [3:0]  m_axi_awcache;
    wire [2:0]  m_axi_awprot;
    wire [3:0]  m_axi_awqos;
    wire        m_axi_awvalid;
    wire        m_axi_awready;
    wire [63:0] m_axi_wdata;
    wire [7:0]  m_axi_wstrb;
    wire        m_axi_wlast;
    wire        m_axi_wvalid;
    wire        m_axi_wready;
    wire        m_axi_bready;
    wire [4:0]  m_axi_bid;
    wire [1:0]  m_axi_bresp;
    wire        m_axi_bvalid;
    wire [4:0]  m_axi_arid;
    wire [29:0] m_axi_araddr;
    wire [7:0]  m_axi_arlen;
    wire [2:0]  m_axi_arsize;
    wire [1:0]  m_axi_arburst;
    wire [0:0]  m_axi_arlock;
    wire [3:0]  m_axi_arcache;
    wire [2:0]  m_axi_arprot;
    wire [3:0]  m_axi_arqos;
    wire        m_axi_arvalid;
    wire        m_axi_arready;
    wire        m_axi_rready;
    wire [4:0]  m_axi_rid;
    wire [63:0] m_axi_rdata;
    wire [1:0]  m_axi_rresp;
    wire        m_axi_rlast;
    wire        m_axi_rvalid;

    wire _unused_mig_status = |m_axi_bid | |m_axi_rid | m_axi_rlast;

    mig_7series_0 i_mig (
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
        .sys_clk_p      (clk200_p),
        .sys_clk_n      (clk200_n),
        .aresetn        (cpu_resetn),
        .s_axi_awid     (m_axi_awid),
        .s_axi_awaddr   (m_axi_awaddr),
        .s_axi_awlen    (m_axi_awlen),
        .s_axi_awsize   (m_axi_awsize),
        .s_axi_awburst  (m_axi_awburst),
        .s_axi_awlock   (m_axi_awlock),
        .s_axi_awcache  (m_axi_awcache),
        .s_axi_awprot   (m_axi_awprot),
        .s_axi_awqos    (m_axi_awqos),
        .s_axi_awvalid  (m_axi_awvalid),
        .s_axi_awready  (m_axi_awready),
        .s_axi_wdata    (m_axi_wdata),
        .s_axi_wstrb    (m_axi_wstrb),
        .s_axi_wlast    (m_axi_wlast),
        .s_axi_wvalid   (m_axi_wvalid),
        .s_axi_wready   (m_axi_wready),
        .s_axi_bready   (m_axi_bready),
        .s_axi_bid      (m_axi_bid),
        .s_axi_bresp    (m_axi_bresp),
        .s_axi_bvalid   (m_axi_bvalid),
        .s_axi_arid     (m_axi_arid),
        .s_axi_araddr   (m_axi_araddr),
        .s_axi_arlen    (m_axi_arlen),
        .s_axi_arsize   (m_axi_arsize),
        .s_axi_arburst  (m_axi_arburst),
        .s_axi_arlock   (m_axi_arlock),
        .s_axi_arcache  (m_axi_arcache),
        .s_axi_arprot   (m_axi_arprot),
        .s_axi_arqos    (m_axi_arqos),
        .s_axi_arvalid  (m_axi_arvalid),
        .s_axi_arready  (m_axi_arready),
        .s_axi_rready   (m_axi_rready),
        .s_axi_rid      (m_axi_rid),
        .s_axi_rdata    (m_axi_rdata),
        .s_axi_rresp    (m_axi_rresp),
        .s_axi_rlast    (m_axi_rlast),
        .s_axi_rvalid   (m_axi_rvalid),
        .app_sr_req     (1'b0),
        .app_ref_req    (1'b0),
        .app_zq_req     (1'b0),
        .app_sr_active  (),
        .app_ref_ack    (),
        .app_zq_ack     (),
        .ui_clk         (ui_clk),
        .ui_clk_sync_rst(mig_ui_clk_sync_rst),
        .init_calib_complete(mig_init_calib_complete),
        .mmcm_locked    (mig_mmcm_locked),
        .device_temp    (),
        .sys_rst        (cpu_resetn)
    );

    // =========================================================================
    // Reset — wait for MMCM lock, MIG calibration, and MIG reset to clear
    // =========================================================================
    reg [7:0] reset_sync_q = 8'h00;
    wire sys_rst_n_raw = cpu_resetn && core_clk_locked
                         && !mig_ui_clk_sync_rst && mig_init_calib_complete;
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
    reg [31:0] heartbeat_q     = 32'd0;
    reg [63:0] core_store_addr_q  = 64'h0000_0000_8000_0000;
    reg [63:0] core_store_word_q  = 64'd0;
    reg [2:0]  core_store_width_q = 3'd3;
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
            core_store_width_q<= 3'd3;
            core_store_valid_q<= 1'b0;
        end else begin
            heartbeat_q        <= heartbeat_q + 32'd1 + {31'd0, ^_obs_fold};
            core_store_addr_q  <= core_store_addr;
            core_store_word_q  <= core_store_word;
            core_store_width_q <= core_mem_req_width;
            core_store_valid_q <= core_store_valid;
        end
    end

    // =========================================================================
    // Core
    // =========================================================================
    wire arb_stall;

    pipeline_core_bram_if i_core (
        .clk_i              (clk_core),
        .rst_ni             (rst_ni),
        .ext_mip_i          (core_ext_mip),
        .imem_rdata_i       (core_imem_rdata),
        .mem_rdata_i        (core_mem_rdata),
        // PTW stall OR arbiter stall (DDR multi-cycle latency)
        .sv39_stall_i       (sv39_stall || arb_stall),
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
        .if_va_i            (core_pc),
        .if_req_i           (rst_ni),
        .mem_va_i           (core_mem_addr),
        .mem_req_i          (core_mem_read || core_mem_write),
        .mem_write_i        (core_mem_write),
        .ptw_mem_req_o      (ptw_mem_req),
        .ptw_mem_addr_o     (ptw_mem_addr),
        .ptw_mem_rvalid_i   (ptw_mem_rvalid),
        .ptw_mem_rdata_i    (ptw_mem_rdata),
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
        .if_req_valid_i (sv39_if_valid),
        .if_req_addr_i  (sv39_if_pa),
        .if_rsp_valid_o (arb_if_rsp_valid),
        .if_rsp_data_o  (arb_if_rsp_data),
        .mem_req_valid_i(sv39_mem_valid && !core_mem_write),
        .mem_req_addr_i (sv39_mem_pa),
        .mem_req_write_i(1'b0),
        .mem_req_wdata_i(64'd0),
        .mem_req_width_i(core_mem_req_width),
        .mem_rsp_valid_o(arb_mem_data_rsp_valid),
        .mem_rsp_data_o (arb_mem_data_rsp_data),
        .ptw_req_valid_i(ptw_mem_req),
        .ptw_req_addr_i (ptw_mem_addr),
        .ptw_rsp_valid_o(ptw_mem_rvalid),
        .ptw_rsp_data_o (ptw_mem_rdata),
        .mem_req_o      (arb_mem_req),
        .mem_addr_o     (arb_mem_addr),
        .mem_write_o    (arb_mem_write),
        .mem_wdata_o    (arb_mem_wdata),
        .mem_width_o    (arb_mem_width),
        .mem_rsp_valid_i(arb_mem_rsp_valid),
        .mem_rsp_data_i (arb_mem_rsp_data),
        .stall_o        (arb_stall)
    );

    assign core_imem_rdata = arb_if_rsp_valid       ? arb_if_rsp_data       : 32'h0000_0013;
    assign core_mem_rdata  = arb_mem_data_rsp_valid  ? arb_mem_data_rsp_data : 64'd0;

    // =========================================================================
    // MMIO decode
    // =========================================================================
    wire arb_is_mmio = arb_mem_req && (arb_mem_addr[31:28] != 4'h8) &&
                                      (arb_mem_addr[31:28] != 4'h9);
    wire arb_is_ddr  = arb_mem_req && !arb_is_mmio;

    wire store_to_mmio = core_store_valid_q &&
                         ((core_store_addr_q[31:28] == 4'h1)  ||
                          (core_store_addr_q[31:24] == 8'h02) ||
                          (core_store_addr_q[31:26] == 6'd3));

    // =========================================================================
    // Core-domain AXI wires (25 MHz) — from mig_adapter to CDC slave port
    // =========================================================================
    wire [4:0]  c_axi_awid;
    wire [29:0] c_axi_awaddr;
    wire [7:0]  c_axi_awlen;
    wire [2:0]  c_axi_awsize;
    wire [1:0]  c_axi_awburst;
    wire [0:0]  c_axi_awlock;
    wire [3:0]  c_axi_awcache;
    wire [2:0]  c_axi_awprot;
    wire [3:0]  c_axi_awqos;
    wire        c_axi_awvalid;
    wire        c_axi_awready;
    wire [63:0] c_axi_wdata;
    wire [7:0]  c_axi_wstrb;
    wire        c_axi_wlast;
    wire        c_axi_wvalid;
    wire        c_axi_wready;
    wire        c_axi_bready;
    wire [4:0]  c_axi_bid;
    wire [1:0]  c_axi_bresp;
    wire        c_axi_bvalid;
    wire [4:0]  c_axi_arid;
    wire [29:0] c_axi_araddr;
    wire [7:0]  c_axi_arlen;
    wire [2:0]  c_axi_arsize;
    wire [1:0]  c_axi_arburst;
    wire [0:0]  c_axi_arlock;
    wire [3:0]  c_axi_arcache;
    wire [2:0]  c_axi_arprot;
    wire [3:0]  c_axi_arqos;
    wire        c_axi_arvalid;
    wire        c_axi_arready;
    wire        c_axi_rready;
    wire [4:0]  c_axi_rid;
    wire [63:0] c_axi_rdata;
    wire [1:0]  c_axi_rresp;
    wire        c_axi_rlast;
    wire        c_axi_rvalid;

    // =========================================================================
    // MIG adapter (runs at core clock, 25 MHz)
    // =========================================================================
    risky_mig_adapter i_mig_adapter (
        .clk_i              (clk_core),
        .rst_ni             (rst_ni),
        .req_valid_i        (arb_is_ddr),
        .req_addr_i         (arb_mem_addr),
        .req_write_i        (arb_mem_write),
        .req_wdata_i        (arb_mem_wdata),
        .req_width_i        (arb_mem_width),
        .store_valid_i      (core_store_valid_q && !store_to_mmio),
        .store_addr_i       (core_store_addr_q),
        .store_data_i       (core_store_word_q),
        .store_width_i      (core_store_width_q),
        .rsp_valid_o        (arb_mem_rsp_valid),
        .rsp_data_o         (arb_mem_rsp_data),
        .s_axi_awid_o       (c_axi_awid),
        .s_axi_awaddr_o     (c_axi_awaddr),
        .s_axi_awlen_o      (c_axi_awlen),
        .s_axi_awsize_o     (c_axi_awsize),
        .s_axi_awburst_o    (c_axi_awburst),
        .s_axi_awlock_o     (c_axi_awlock),
        .s_axi_awcache_o    (c_axi_awcache),
        .s_axi_awprot_o     (c_axi_awprot),
        .s_axi_awqos_o      (c_axi_awqos),
        .s_axi_awvalid_o    (c_axi_awvalid),
        .s_axi_awready_i    (c_axi_awready),
        .s_axi_wdata_o      (c_axi_wdata),
        .s_axi_wstrb_o      (c_axi_wstrb),
        .s_axi_wlast_o      (c_axi_wlast),
        .s_axi_wvalid_o     (c_axi_wvalid),
        .s_axi_wready_i     (c_axi_wready),
        .s_axi_bready_o     (c_axi_bready),
        .s_axi_bid_i        (c_axi_bid),
        .s_axi_bresp_i      (c_axi_bresp),
        .s_axi_bvalid_i     (c_axi_bvalid),
        .s_axi_arid_o       (c_axi_arid),
        .s_axi_araddr_o     (c_axi_araddr),
        .s_axi_arlen_o      (c_axi_arlen),
        .s_axi_arsize_o     (c_axi_arsize),
        .s_axi_arburst_o    (c_axi_arburst),
        .s_axi_arlock_o     (c_axi_arlock),
        .s_axi_arcache_o    (c_axi_arcache),
        .s_axi_arprot_o     (c_axi_arprot),
        .s_axi_arqos_o      (c_axi_arqos),
        .s_axi_arvalid_o    (c_axi_arvalid),
        .s_axi_arready_i    (c_axi_arready),
        .s_axi_rready_o     (c_axi_rready),
        .s_axi_rid_i        (c_axi_rid),
        .s_axi_rdata_i      (c_axi_rdata),
        .s_axi_rresp_i      (c_axi_rresp),
        .s_axi_rlast_i      (c_axi_rlast),
        .s_axi_rvalid_i     (c_axi_rvalid)
    );

    // =========================================================================
    // AXI clock converter — bridges 25 MHz core domain to ≈200 MHz MIG domain
    // Xilinx IP: axi_clock_converter v2.1, ACLK_ASYNC=1 (async clocks)
    // =========================================================================
    axi_clock_converter_0 i_axi_cdc (
        // Slave port — core domain (25 MHz)
        .s_axi_aclk     (clk_core),
        .s_axi_aresetn  (rst_ni),
        .s_axi_awid     (c_axi_awid),
        .s_axi_awaddr   (c_axi_awaddr),
        .s_axi_awlen    (c_axi_awlen),
        .s_axi_awsize   (c_axi_awsize),
        .s_axi_awburst  (c_axi_awburst),
        .s_axi_awlock   (c_axi_awlock),
        .s_axi_awcache  (c_axi_awcache),
        .s_axi_awprot   (c_axi_awprot),
        .s_axi_awqos    (c_axi_awqos),
        .s_axi_awvalid  (c_axi_awvalid),
        .s_axi_awready  (c_axi_awready),
        .s_axi_wdata    (c_axi_wdata),
        .s_axi_wstrb    (c_axi_wstrb),
        .s_axi_wlast    (c_axi_wlast),
        .s_axi_wvalid   (c_axi_wvalid),
        .s_axi_wready   (c_axi_wready),
        .s_axi_bready   (c_axi_bready),
        .s_axi_bid      (c_axi_bid),
        .s_axi_bresp    (c_axi_bresp),
        .s_axi_bvalid   (c_axi_bvalid),
        .s_axi_arid     (c_axi_arid),
        .s_axi_araddr   (c_axi_araddr),
        .s_axi_arlen    (c_axi_arlen),
        .s_axi_arsize   (c_axi_arsize),
        .s_axi_arburst  (c_axi_arburst),
        .s_axi_arlock   (c_axi_arlock),
        .s_axi_arcache  (c_axi_arcache),
        .s_axi_arprot   (c_axi_arprot),
        .s_axi_arqos    (c_axi_arqos),
        .s_axi_arvalid  (c_axi_arvalid),
        .s_axi_arready  (c_axi_arready),
        .s_axi_rready   (c_axi_rready),
        .s_axi_rid      (c_axi_rid),
        .s_axi_rdata    (c_axi_rdata),
        .s_axi_rresp    (c_axi_rresp),
        .s_axi_rlast    (c_axi_rlast),
        .s_axi_rvalid   (c_axi_rvalid),
        // Master port — MIG domain (ui_clk ≈200 MHz)
        .m_axi_aclk     (ui_clk),
        .m_axi_aresetn  (!mig_ui_clk_sync_rst),
        .m_axi_awid     (m_axi_awid),
        .m_axi_awaddr   (m_axi_awaddr),
        .m_axi_awlen    (m_axi_awlen),
        .m_axi_awsize   (m_axi_awsize),
        .m_axi_awburst  (m_axi_awburst),
        .m_axi_awlock   (m_axi_awlock),
        .m_axi_awcache  (m_axi_awcache),
        .m_axi_awprot   (m_axi_awprot),
        .m_axi_awqos    (m_axi_awqos),
        .m_axi_awvalid  (m_axi_awvalid),
        .m_axi_awready  (m_axi_awready),
        .m_axi_wdata    (m_axi_wdata),
        .m_axi_wstrb    (m_axi_wstrb),
        .m_axi_wlast    (m_axi_wlast),
        .m_axi_wvalid   (m_axi_wvalid),
        .m_axi_wready   (m_axi_wready),
        .m_axi_bready   (m_axi_bready),
        .m_axi_bid      (m_axi_bid),
        .m_axi_bresp    (m_axi_bresp),
        .m_axi_bvalid   (m_axi_bvalid),
        .m_axi_arid     (m_axi_arid),
        .m_axi_araddr   (m_axi_araddr),
        .m_axi_arlen    (m_axi_arlen),
        .m_axi_arsize   (m_axi_arsize),
        .m_axi_arburst  (m_axi_arburst),
        .m_axi_arlock   (m_axi_arlock),
        .m_axi_arcache  (m_axi_arcache),
        .m_axi_arprot   (m_axi_arprot),
        .m_axi_arqos    (m_axi_arqos),
        .m_axi_arvalid  (m_axi_arvalid),
        .m_axi_arready  (m_axi_arready),
        .m_axi_rready   (m_axi_rready),
        .m_axi_rid      (m_axi_rid),
        .m_axi_rdata    (m_axi_rdata),
        .m_axi_rresp    (m_axi_rresp),
        .m_axi_rlast    (m_axi_rlast),
        .m_axi_rvalid   (m_axi_rvalid)
    );

    // =========================================================================
    // MMIO (UART / CLINT / PLIC) — same as BRAM target
    // =========================================================================
    wire [63:0] mmio_rdata;
    wire [7:0]  led_state;
    wire [3:0]  uart_debug;

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
        .uart_debug_o       (uart_debug),
        .fan_pwm_o          (fan_pwm)
    );

    // =========================================================================
    // LEDs
    //   LD0 = reset active       LD1 = heartbeat
    //   LD2 = DDR3 calib done    LD3 = MIG MMCM locked
    //   LD4 = core issuing AXI   LD5 = CDC relayed to MIG
    //   LD6 = MIG responding     LD7 = UART / app
    // =========================================================================
    assign led[0] = rst_ni;
    assign led[1] = heartbeat_q[22];
    assign led[2] = mig_init_calib_complete;
    assign led[3] = mig_mmcm_locked;
    assign led[4] = c_axi_arvalid | c_axi_awvalid;
    assign led[5] = m_axi_arvalid | m_axi_awvalid;
    assign led[6] = m_axi_rvalid  | m_axi_bvalid;
    assign led[7] = led_state[1] | uart_debug[3];
endmodule
