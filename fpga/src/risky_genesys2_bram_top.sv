// Genesys 2 BRAM bring-up top for real board execution of a tiny program.
//
// This target uses a patched FPGA export of pipeline_core that exposes the
// existing fetch/load data and store side-channel registers as ports, then
// attaches small synthesizable BRAM, LED MMIO, and a minimal UART TX debug
// path. It is for bare-metal board bring-up before DDR, UART RX, interrupts,
// storage, and RTL Sv39 PTW.

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
    localparam logic [63:0] LED_MMIO = 64'h0000_0000_1000_0000;
    localparam logic [63:0] UART_MMIO = 64'h0000_0000_1000_0008;
    localparam int RAM_WORDS = 1024;
    localparam logic [63:0] RAM_WORDS_64 = 64'd1024;
    localparam int CORE_CLK_HZ = 25_000_000;
    localparam int UART_BAUD = 115200;
    localparam int UART_CLKS_PER_BIT = CORE_CLK_HZ / UART_BAUD;
    localparam int UART_FIFO_DEPTH = 64;
    localparam logic [6:0] UART_FIFO_DEPTH_7 = 7'd64;

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
        .CLKOUT0  (clk_core_mmcm),
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

    reg [3:0] reset_sync = 4'h0;
    wire core_resetn = cpu_resetn && core_clk_locked;
    always @(posedge clk_core) begin
        if (!core_resetn) begin
            reset_sync <= 4'h0;
        end else begin
            reset_sync <= {reset_sync[2:0], 1'b1};
        end
    end

    wire rst_ni = reset_sync[3];

    wire [63:0] core_pc;
    wire [63:0] core_mem_addr;
    wire        core_store_valid;
    wire [63:0] core_store_addr;
    wire [63:0] core_store_word;
    wire [31:0] core_imem_rdata;
    wire [63:0] core_mem_rdata;
    wire        core_sim_exit_valid;
    wire [63:0] core_sim_exit_code;

    (* ram_style = "block" *) reg [63:0] bram [0:RAM_WORDS-1];
    reg [63:0] fetch_word_q = 64'h0000_0013_0000_0013;
    reg [63:0] mem_word_q = 64'd0;
    reg [7:0] led_q = 8'h00;
    reg [31:0] heartbeat_q = 32'd0;

    reg [7:0] uart_fifo [0:UART_FIFO_DEPTH-1];
    reg [5:0] uart_wr_ptr_q = 6'd0;
    reg [5:0] uart_rd_ptr_q = 6'd0;
    reg [6:0] uart_count_q = 7'd0;
    reg [7:0] uart_tx_data_q = 8'h00;
    reg       uart_tx_start_q = 1'b0;
    reg       uart_fifo_push_q = 1'b0;
    reg [5:0] uart_fifo_push_addr_q = 6'd0;
    reg [7:0] uart_fifo_push_data_q = 8'h00;

    reg [9:0] pc_word_idx_q = 10'd0;
    reg [2:0] pc_byte_idx_q = 3'd0;
    reg       pc_in_ram_q = 1'b0;
    reg [9:0] mem_word_idx_q = 10'd0;
    reg       mem_in_ram_q = 1'b0;
    reg [9:0] store_word_idx_q = 10'd0;
    reg       store_in_ram_q = 1'b0;
    reg [63:0] core_store_addr_q = RAM_BASE;
    reg [63:0] core_store_word_q = 64'd0;
    reg       core_store_valid_q = 1'b0;
    reg [63:0] last_mmio_store_addr_q = 64'd0;
    reg [63:0] last_mmio_store_word_q = 64'd0;
    reg       last_mmio_store_valid_q = 1'b0;
    (* DONT_TOUCH = "true" *) reg [9:0] bram_store_word_idx_q = 10'd0;
    (* DONT_TOUCH = "true" *) reg [63:0] bram_store_word_q = 64'd0;
    (* DONT_TOUCH = "true" *) reg       bram_store_we_q = 1'b0;

    wire uart_fifo_empty = uart_count_q == 7'd0;
    wire uart_fifo_full = uart_count_q == UART_FIFO_DEPTH_7;
    wire uart_tx_busy;

    assign core_imem_rdata = pc_byte_idx_q[2] ? fetch_word_q[63:32] : fetch_word_q[31:0];
    assign core_mem_rdata = mem_word_q;

    integer i;
    initial begin
        for (i = 0; i < RAM_WORDS; i = i + 1) begin
            bram[i] = 64'h0000_0013_0000_0013; // NOP/NOP
        end

        // Bare-metal bring-up payload at 0x80000000:
        //   - writes LEDs with 0x5a
        //   - writes "BOOT\r\nB\r\nL=5A\r\n" to UART MMIO
        //   - loops forever
        bram[0]  = 64'h05a00313_100002b7;
        bram[1]  = 64'h04200313_0062a023;
        bram[2]  = 64'h04f00313_0062a423;
        bram[3]  = 64'h04f00313_0062a423;
        bram[4]  = 64'h05400313_0062a423;
        bram[5]  = 64'h00d00313_0062a423;
        bram[6]  = 64'h00a00313_0062a423;
        bram[7]  = 64'h04200313_0062a423;
        bram[8]  = 64'h00d00313_0062a423;
        bram[9]  = 64'h00a00313_0062a423;
        bram[10] = 64'h04c00313_0062a423;
        bram[11] = 64'h03d00313_0062a423;
        bram[12] = 64'h03500313_0062a423;
        bram[13] = 64'h04100313_0062a423;
        bram[14] = 64'h00d00313_0062a423;
        bram[15] = 64'h00a00313_0062a423;
        bram[16] = 64'h0000006f_0062a423;
    end

    always @(posedge clk_core) begin
        if (!rst_ni) begin
            pc_word_idx_q <= 10'd0;
            pc_byte_idx_q <= 3'd0;
            pc_in_ram_q <= 1'b1;
            mem_word_idx_q <= 10'd0;
            mem_in_ram_q <= 1'b1;
            store_word_idx_q <= 10'd0;
            store_in_ram_q <= 1'b0;
            core_store_addr_q <= RAM_BASE;
            core_store_word_q <= 64'd0;
            core_store_valid_q <= 1'b0;
            bram_store_word_idx_q <= 10'd0;
            bram_store_word_q <= 64'd0;
            bram_store_we_q <= 1'b0;
        end else begin
            logic [63:0] pc_offset;
            logic [63:0] mem_offset;
            logic [63:0] store_offset;

            pc_offset = core_pc - RAM_BASE;
            mem_offset = core_mem_addr - RAM_BASE;
            store_offset = core_store_addr - RAM_BASE;

            pc_word_idx_q <= pc_offset[12:3];
            pc_byte_idx_q <= core_pc[2:0];
            pc_in_ram_q <= (pc_offset >> 3) < RAM_WORDS_64;

            mem_word_idx_q <= mem_offset[12:3];
            mem_in_ram_q <= (mem_offset >> 3) < RAM_WORDS_64;

            store_word_idx_q <= store_offset[12:3];
            store_in_ram_q <= (store_offset >> 3) < RAM_WORDS_64;
            core_store_addr_q <= core_store_addr;
            core_store_word_q <= core_store_word;
            core_store_valid_q <= core_store_valid;
            bram_store_word_idx_q <= store_word_idx_q;
            bram_store_word_q <= core_store_word_q;
            bram_store_we_q <= core_store_valid_q && store_in_ram_q;
        end
    end

    // Keep the RAM in a synchronous read/write template so Vivado infers BRAM
    // instead of dissolving the array into flip-flops.
    always @(posedge clk_core) begin
        fetch_word_q <= pc_in_ram_q ? bram[pc_word_idx_q] : 64'h0000_0013_0000_0013;
        mem_word_q <= mem_in_ram_q ? bram[mem_word_idx_q] : 64'd0;
        if (bram_store_we_q) begin
            bram[bram_store_word_idx_q] <= bram_store_word_q;
        end
        if (uart_fifo_push_q) begin
            uart_fifo[uart_fifo_push_addr_q] <= uart_fifo_push_data_q;
        end
    end

    always @(posedge clk_core or negedge rst_ni) begin
        if (!rst_ni) begin
            led_q <= 8'h00;
            heartbeat_q <= 32'd0;
            uart_wr_ptr_q <= 6'd0;
            uart_rd_ptr_q <= 6'd0;
            uart_count_q <= 7'd0;
            uart_tx_data_q <= 8'h00;
            uart_tx_start_q <= 1'b0;
            uart_fifo_push_q <= 1'b0;
            uart_fifo_push_addr_q <= 6'd0;
            uart_fifo_push_data_q <= 8'h00;
            last_mmio_store_addr_q <= 64'd0;
            last_mmio_store_word_q <= 64'd0;
            last_mmio_store_valid_q <= 1'b0;
        end else begin
            logic store_mmio_event;

            heartbeat_q <= heartbeat_q + 32'd1;
            uart_tx_start_q <= 1'b0;
            uart_fifo_push_q <= 1'b0;

            store_mmio_event = core_store_valid_q
                && (!last_mmio_store_valid_q
                    || core_store_addr_q != last_mmio_store_addr_q
                    || core_store_word_q != last_mmio_store_word_q);

            if (store_mmio_event && core_store_addr_q == LED_MMIO) begin
                led_q <= core_store_word_q[7:0];
            end

            if (!uart_fifo_full && store_mmio_event && core_store_addr_q == UART_MMIO) begin
                uart_fifo_push_q <= 1'b1;
                uart_fifo_push_addr_q <= uart_wr_ptr_q;
                uart_fifo_push_data_q <= core_store_word_q[7:0];
                uart_wr_ptr_q <= uart_wr_ptr_q + 6'd1;
                uart_count_q <= uart_count_q + 7'd1;
            end

            last_mmio_store_addr_q <= core_store_addr_q;
            last_mmio_store_word_q <= core_store_word_q;
            last_mmio_store_valid_q <= core_store_valid_q;

            if (!uart_fifo_empty && !uart_tx_busy && !uart_fifo_push_q) begin
                uart_tx_data_q <= uart_fifo[uart_rd_ptr_q];
                uart_rd_ptr_q <= uart_rd_ptr_q + 6'd1;
                uart_count_q <= uart_count_q - 7'd1;
                uart_tx_start_q <= 1'b1;
            end
        end
    end

    pipeline_core_bram_if i_core (
        .clk_i              (clk_core),
        .rst_ni             (rst_ni),
        .imem_rdata_i       (core_imem_rdata),
        .mem_rdata_i        (core_mem_rdata),
        .pc_o               (core_pc),
        .mem_addr_o         (core_mem_addr),
        .mem_store_valid_o  (core_store_valid),
        .mem_store_addr_o   (core_store_addr),
        .mem_store_word_o   (core_store_word),
        .sim_exit_valid_o   (core_sim_exit_valid),
        .sim_exit_code_o    (core_sim_exit_code)
    );

    risky_uart_tx #(
        .CLKS_PER_BIT(UART_CLKS_PER_BIT)
    ) i_uart_tx (
        .clk_i      (clk_core),
        .rst_ni     (rst_ni),
        .start_i    (uart_tx_start_q),
        .data_i     (uart_tx_data_q),
        .tx_o       (tx),
        .busy_o     (uart_tx_busy)
    );

    assign led[0] = rst_ni;
    assign led[1] = heartbeat_q[22];
    assign led[7:2] = led_q[5:0];

    assign fan_pwm = 1'b1;

    wire unused_rx = rx;
endmodule

module risky_uart_tx #(
    parameter integer CLKS_PER_BIT = 1736
) (
    input  wire      clk_i,
    input  wire      rst_ni,
    input  wire      start_i,
    input  wire [7:0] data_i,
    output reg       tx_o,
    output wire      busy_o
);
    reg [13:0] baud_ctr_q = 14'd0;
    reg [3:0] bit_idx_q = 4'd0;
    reg [9:0] shift_q = 10'h3ff;
    reg       busy_q = 1'b0;
    localparam logic [13:0] CLKS_PER_BIT_14 = CLKS_PER_BIT[13:0];

    assign busy_o = busy_q;

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            baud_ctr_q <= 14'd0;
            bit_idx_q <= 4'd0;
            shift_q <= 10'h3ff;
            busy_q <= 1'b0;
            tx_o <= 1'b1;
        end else if (!busy_q) begin
            tx_o <= 1'b1;
            baud_ctr_q <= 14'd0;
            bit_idx_q <= 4'd0;
            if (start_i) begin
                shift_q <= {1'b1, data_i, 1'b0};
                tx_o <= 1'b0;
                busy_q <= 1'b1;
            end
        end else if (baud_ctr_q == CLKS_PER_BIT_14 - 14'd1) begin
            baud_ctr_q <= 14'd0;
            shift_q <= {1'b1, shift_q[9:1]};
            bit_idx_q <= bit_idx_q + 4'd1;
            tx_o <= shift_q[1];
            if (bit_idx_q == 4'd9) begin
                busy_q <= 1'b0;
                bit_idx_q <= 4'd0;
                tx_o <= 1'b1;
            end
        end else begin
            baud_ctr_q <= baud_ctr_q + 14'd1;
        end
    end
endmodule
