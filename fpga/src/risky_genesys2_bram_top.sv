// Genesys 2 BRAM bring-up top for real board execution of a tiny program.
//
// This target keeps the board wrapper thin and pushes platform-like behavior
// into small dedicated blocks:
//   - MMCM/clock/reset live here
//   - BRAM remains a local synchronous memory
//   - LED/UART/CLINT readback live in risky_fpga_peripherals
//
// The BRAM payload itself is software-authored and generated into
// risky_genesys2_bram_init.vh during FPGA export.

module risky_genesys2_bram_top (
    input  wire       clk200_p,
    input  wire       clk200_n,
    input  wire       cpu_resetn,
    input  wire       rx,
    output wire       tx,
    output wire [7:0] led,
    output wire       fan_pwm
);
    localparam logic [63:0] RAM_BASE = 64'h0000_0000_8000_0000;
    localparam int RAM_WORDS = 1024;
    localparam int CORE_CLK_HZ = 25_000_000;
    localparam int UART_BAUD = 115200;
    localparam int UART_FIFO_DEPTH = 64;

    wire clk200;
    wire clk_core;
    wire core_clk_locked;

`ifdef VERILATOR
    assign clk200 = clk200_p;
    assign clk_core = clk200_p;
    assign core_clk_locked = 1'b1;
`else
    IBUFDS #(
        .DIFF_TERM("FALSE"),
        .IBUF_LOW_PWR("TRUE"),
        .IOSTANDARD("LVDS")
    ) i_sysclk_ibufds (
        .I (clk200_p),
        .IB(clk200_n),
        .O (clk200)
    );

    wire clkfb_mmcm;
    wire clkfb_bufg;
    wire clk_core_mmcm;
    wire clkout0b_unused;
    wire clkout1_unused;
    wire clkout1b_unused;
    wire clkout2_unused;
    wire clkout2b_unused;
    wire clkout3_unused;
    wire clkout3b_unused;
    wire clkout4_unused;
    wire clkout5_unused;
    wire clkout6_unused;
    wire clkfboutb_unused;

    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKIN1_PERIOD(5.000),
        .CLKFBOUT_MULT_F(5.000),
        .DIVCLK_DIVIDE(1),
        .CLKOUT0_DIVIDE_F(40.000),
        .CLKOUT0_DUTY_CYCLE(0.500)
    ) i_coreclk_mmcm (
        .CLKIN1   (clk200),
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

    BUFG i_coreclk_fb_bufg (
        .I (clkfb_mmcm),
        .O (clkfb_bufg)
    );

    BUFG i_coreclk_bufg (
        .I (clk_core_mmcm),
        .O (clk_core)
    );
`endif

    reg [7:0] reset_sync = 8'h00;
    wire core_resetn = cpu_resetn && core_clk_locked;
    always @(posedge clk_core) begin
        if (!core_resetn) begin
            reset_sync <= 8'h00;
        end else begin
            reset_sync <= {reset_sync[6:0], 1'b1};
        end
    end

    wire rst_ni = reset_sync[7];

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

    reg [31:0] heartbeat_q = 32'd0;

    reg [63:0] core_store_addr_q = RAM_BASE;
    reg [63:0] core_store_word_q = 64'd0;
    reg       core_store_valid_q = 1'b0;

    wire [63:0] mmio_rdata;
    wire [7:0] led_state;
    wire [31:0] adapter_imem_rdata;
    wire [63:0] adapter_mem_rdata;

    // Fold all future-use / observation-only outputs into the heartbeat counter so
    // Vivado preserves their fan-in cones without needing (* keep *) on dead nets.
    // heartbeat_q[22] drives led[1] (observable), so Vivado will never prune it.
    wire [31:0] _obs_fold =
        {core_if_req_valid,  core_mem_req_valid,  core_mem_req_write,
         core_sim_exit_valid, core_sv39_flush,
         core_priv,                                       // [1:0] -> 2 bits
         |core_if_req_addr,  |core_mem_req_addr,
         |core_mem_req_wdata, |core_mem_req_width,
         |core_satp,          |core_sim_exit_code,
         19'd0};

    always @(posedge clk_core) begin
        if (!rst_ni) begin
            core_store_addr_q <= RAM_BASE;
            core_store_word_q <= 64'd0;
            core_store_valid_q <= 1'b0;
        end else begin
            core_store_addr_q <= core_store_addr;
            core_store_word_q <= core_store_word;
            core_store_valid_q <= core_store_valid;
        end
    end

    always @(posedge clk_core) begin
        if (!rst_ni) begin
            heartbeat_q <= 32'd0;
        end else begin
            heartbeat_q <= heartbeat_q + 32'd1 + {31'd0, ^_obs_fold};
        end
    end

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

    risky_bram_mem_adapter #(
        .RAM_BASE (RAM_BASE),
        .RAM_WORDS(RAM_WORDS)
    ) i_bram_mem_adapter (
        .clk_i           (clk_core),
        .if_req_valid_i  (rst_ni),
        .if_req_addr_i   (core_pc),
        .if_rsp_data_o   (adapter_imem_rdata),
        .mem_req_valid_i (core_mem_read || core_mem_write),
        .mem_req_addr_i  (core_mem_addr),
        .mem_req_write_i (core_mem_write),
        .mem_store_valid_i(core_store_valid_q),
        .mem_store_addr_i(core_store_addr_q),
        .mem_store_word_i(core_store_word_q),
        .mmio_rdata_i    (mmio_rdata),
        .mem_rsp_data_o  (adapter_mem_rdata)
    );

    assign core_imem_rdata = adapter_imem_rdata;
    assign core_mem_rdata = adapter_mem_rdata;

    risky_fpga_peripherals #(
        .CORE_CLK_HZ(CORE_CLK_HZ),
        .UART_BAUD(UART_BAUD),
        .UART_FIFO_DEPTH(UART_FIFO_DEPTH)
    ) i_peripherals (
        .clk_i         (clk_core),
        .rst_ni        (rst_ni),
        .rx_i          (rx),
        .mem_addr_i    (core_mem_addr),
        .mmio_read_valid_i(core_mmio_read_valid),
        .mmio_read_addr_i (core_mmio_read_addr),
        .store_valid_i (core_store_valid_q && ((core_store_addr_q[31:28] == 4'h1) ||
                                               (core_store_addr_q[31:24] == 8'h02) ||
                                               (core_store_addr_q[31:26] == 6'd3))),
        .store_addr_i  (core_store_addr_q),
        .store_data_i  (core_store_word_q),
        .mtime_i       (core_mtime),
        .mtimecmp_i    (core_mtimecmp),
        .stimecmp_i    (core_stimecmp),
        .mem_rdata_o   (mmio_rdata),
        .ext_mip_o     (core_ext_mip),
        .tx_o          (tx),
        .led_o         (led_state),
        .fan_pwm_o     (fan_pwm)
    );

    assign sv39_stall = 1'b0;
    assign sv39_if_valid = 1'b0;
    assign sv39_if_pa = 64'd0;
    assign sv39_if_pf = 1'b0;
    assign sv39_mem_valid = 1'b0;
    assign sv39_mem_pa = 64'd0;
    assign sv39_mem_pf = 1'b0;
    assign sv39_mem_pf_store = 1'b0;

    assign led[0] = rst_ni;
    assign led[1] = heartbeat_q[22];
    assign led[7:2] = led_state[5:0];
endmodule
