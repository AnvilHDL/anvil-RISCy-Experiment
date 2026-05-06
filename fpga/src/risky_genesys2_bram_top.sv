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
    localparam logic [63:0] RAM_WORDS_64 = 64'd1024;
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
    wire [63:0] core_mem_addr;
    wire        core_mem_read;
    wire        core_mem_write;
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

    (* ram_style = "block" *) reg [63:0] bram [0:RAM_WORDS-1];
    reg [63:0] fetch_word_q = 64'h0000_0013_0000_0013;
    reg [63:0] mem_word_q = 64'd0;
    reg [63:0] mmio_word_q = 64'd0;
    reg [31:0] heartbeat_q = 32'd0;
    reg        fetch_valid_q = 1'b0;

    reg [2:0] pc_byte_idx_q = 3'd0;
    reg       mem_in_ram_q = 1'b0;
    reg [63:0] core_store_addr_q = RAM_BASE;
    reg [63:0] core_store_word_q = 64'd0;
    reg       core_store_valid_q = 1'b0;
    (* DONT_TOUCH = "true" *) reg [9:0] bram_store_word_idx_q = 10'd0;
    (* DONT_TOUCH = "true" *) reg [63:0] bram_store_word_q = 64'd0;
    (* DONT_TOUCH = "true" *) reg       bram_store_we_q = 1'b0;

    wire [63:0] mmio_rdata;
    wire [7:0] led_state;
    wire [63:0] pc_offset = core_pc - RAM_BASE;
    wire [9:0] pc_word_idx = pc_offset[12:3];
    wire pc_in_ram = (pc_offset >> 3) < RAM_WORDS_64;
    wire [63:0] mem_offset = core_mem_addr - RAM_BASE;
    wire [9:0] mem_word_idx = mem_offset[12:3];
    wire mem_in_ram = (mem_offset >> 3) < RAM_WORDS_64;
    wire [63:0] store_offset = core_store_addr - RAM_BASE;
    wire [9:0] store_word_idx = store_offset[12:3];
    wire store_in_ram = (store_offset >> 3) < RAM_WORDS_64;

    assign core_imem_rdata = fetch_valid_q
        ? (pc_byte_idx_q[2] ? fetch_word_q[63:32] : fetch_word_q[31:0])
        : 32'h0000_0013;
    assign core_mem_rdata = mem_in_ram_q ? mem_word_q : mmio_word_q;

    integer i;
    initial begin
        for (i = 0; i < RAM_WORDS; i = i + 1) begin
            bram[i] = 64'h0000_0013_0000_0013;
        end
`include "risky_genesys2_bram_init.vh"
    end

    always @(posedge clk_core) begin
        if (!rst_ni) begin
            pc_byte_idx_q <= 3'd0;
            mem_in_ram_q <= 1'b1;
            core_store_addr_q <= RAM_BASE;
            core_store_word_q <= 64'd0;
            core_store_valid_q <= 1'b0;
            bram_store_word_idx_q <= 10'd0;
            bram_store_word_q <= 64'd0;
            bram_store_we_q <= 1'b0;
            fetch_valid_q <= 1'b0;
        end else begin
            pc_byte_idx_q <= core_pc[2:0];
            mem_in_ram_q <= mem_in_ram;
            core_store_addr_q <= core_store_addr;
            core_store_word_q <= core_store_word;
            core_store_valid_q <= core_store_valid;
            bram_store_word_idx_q <= store_word_idx;
            bram_store_word_q <= core_store_word;
            bram_store_we_q <= core_store_valid && store_in_ram;
            fetch_valid_q <= 1'b1;
        end
    end

    always @(posedge clk_core) begin
        if (!rst_ni) begin
            fetch_word_q <= bram[0];
            mem_word_q <= 64'd0;
            mmio_word_q <= 64'd0;
        end else begin
            fetch_word_q <= pc_in_ram ? bram[pc_word_idx] : 64'h0000_0013_0000_0013;
            mem_word_q <= mem_in_ram ? bram[mem_word_idx] : 64'd0;
            mmio_word_q <= mmio_rdata;
        end
        if (rst_ni && bram_store_we_q) begin
            bram[bram_store_word_idx_q] <= bram_store_word_q;
        end
    end

    always @(posedge clk_core) begin
        if (!rst_ni) begin
            heartbeat_q <= 32'd0;
        end else begin
            heartbeat_q <= heartbeat_q + 32'd1;
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
        .mem_addr_o         (core_mem_addr),
        .mem_read_o         (core_mem_read),
        .mem_write_o        (core_mem_write),
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

    risky_fpga_peripherals #(
        .CORE_CLK_HZ(CORE_CLK_HZ),
        .UART_BAUD(UART_BAUD),
        .UART_FIFO_DEPTH(UART_FIFO_DEPTH)
    ) i_peripherals (
        .clk_i         (clk_core),
        .rst_ni        (rst_ni),
        .rx_i          (rx),
        .mem_addr_i    (core_mem_addr),
        .mem_read_i    (core_mem_read),
        .mem_write_i   (core_mem_write),
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
