module risky_fpga_peripherals #(
    parameter int CORE_CLK_HZ = 25_000_000,
    parameter int UART_BAUD = 115200,
    parameter int UART_FIFO_DEPTH = 64
) (
    input  wire        clk_i,
    input  wire        rst_ni,
    input  wire        rx_i,
    input  wire [63:0] mem_addr_i,
    input  wire        mem_read_i,
    input  wire        mem_write_i,
    input  wire        store_valid_i,
    input  wire [63:0] store_addr_i,
    input  wire [63:0] store_data_i,
    input  wire [63:0] mtime_i,
    input  wire [63:0] mtimecmp_i,
    input  wire [63:0] stimecmp_i,
    output wire [63:0] mem_rdata_o,
    output wire [63:0] ext_mip_o,
    output wire        tx_o,
    output wire [7:0]  led_o,
    output wire        fan_pwm_o
);
    localparam logic [63:0] LED_MMIO       = 64'h0000_0000_1000_0008;
    localparam logic [63:0] UART_BASE      = 64'h0000_0000_1000_0000;
    localparam logic [63:0] UART_LSR_MMIO  = 64'h0000_0000_1000_0005;
    localparam logic [63:0] CLINT_MTIMECMP = 64'h0000_0000_0200_4000;
    localparam logic [63:0] CLINT_MTIME    = 64'h0000_0000_0200_BFF8;
    localparam logic [63:0] CLINT_STIMECMP = 64'h0000_0000_0200_4008;
    localparam int UART_CLKS_PER_BIT = CORE_CLK_HZ / UART_BAUD;
    localparam int UART_PTR_W = $clog2(UART_FIFO_DEPTH);
    localparam int UART_COUNT_W = $clog2(UART_FIFO_DEPTH + 1);

    reg [7:0] led_q = 8'h00;
    reg [7:0] fan_ctr_q = 8'd0;

    reg [7:0] uart_ier_q = 8'h00;
    reg [7:0] uart_lcr_q = 8'h03;
    reg [7:0] uart_mcr_q = 8'h00;
    reg [7:0] uart_scr_q = 8'h00;
    reg [7:0] uart_fcr_q = 8'h00;
    reg [7:0] uart_dll_q = 8'h03;
    reg [7:0] uart_dlm_q = 8'h00;

    reg [7:0] tx_fifo [0:UART_FIFO_DEPTH-1];
    reg [UART_PTR_W-1:0] tx_wr_ptr_q = '0;
    reg [UART_PTR_W-1:0] tx_rd_ptr_q = '0;
    reg [UART_COUNT_W-1:0] tx_count_q = '0;
    reg [7:0] tx_data_q = 8'h00;
    reg       tx_start_q = 1'b0;
    reg       tx_push_q = 1'b0;
    reg [UART_PTR_W-1:0] tx_push_addr_q = '0;
    reg [7:0] tx_push_data_q = 8'h00;

    reg [7:0] rx_fifo [0:UART_FIFO_DEPTH-1];
    reg [UART_PTR_W-1:0] rx_wr_ptr_q = '0;
    reg [UART_PTR_W-1:0] rx_rd_ptr_q = '0;
    reg [UART_COUNT_W-1:0] rx_count_q = '0;
    reg       rx_pop_q = 1'b0;
    reg [UART_PTR_W-1:0] rx_pop_addr_q = '0;
    reg [7:0] rx_data_hold_q = 8'h00;

    reg [63:0] last_store_addr_q = 64'd0;
    reg [63:0] last_store_data_q = 64'd0;
    reg        last_store_valid_q = 1'b0;

    wire uart_tx_busy;
    wire tx_fifo_empty = (tx_count_q == {UART_COUNT_W{1'b0}});
    wire tx_fifo_full = (tx_count_q == UART_FIFO_DEPTH[UART_COUNT_W-1:0]);
    wire rx_fifo_empty = (rx_count_q == {UART_COUNT_W{1'b0}});
    wire rx_fifo_full = (rx_count_q == UART_FIFO_DEPTH[UART_COUNT_W-1:0]);
    wire [7:0] uart_rx_data;
    wire uart_rx_valid;
    wire uart_dlab = uart_lcr_q[7];
    wire uart_thr_empty = tx_fifo_empty && !uart_tx_busy && !tx_push_q;
    wire uart_rx_irq = uart_ier_q[0] && !rx_fifo_empty;
    wire uart_tx_irq = uart_ier_q[1] && uart_thr_empty;
    wire store_event = store_valid_i
        && (!last_store_valid_q
            || store_addr_i != last_store_addr_q
            || store_data_i != last_store_data_q);
    wire [2:0] mem_byte_off = mem_addr_i[2:0];
    wire [3:0] mem_reg_off = mem_addr_i[3:0];
    wire [3:0] store_reg_off = store_addr_i[3:0];
    wire [7:0] uart_lsr = {
        1'b0,
        uart_thr_empty,
        uart_thr_empty,
        1'b0,
        1'b0,
        1'b0,
        1'b0,
        !rx_fifo_empty
    };
    wire [7:0] uart_iir = uart_rx_irq ? 8'h04 : uart_tx_irq ? 8'h02 : 8'h01;

    wire [63:0] plic_rdata;
    wire [63:0] plic_ext_mip;

    function automatic [7:0] mmio_store_byte;
        input [63:0] addr;
        input [63:0] data;
        reg [63:0] shifted;
        begin
            shifted = data >> (addr[2:0] * 8);
            mmio_store_byte = shifted[7:0];
        end
    endfunction

    reg [63:0] mmio_rdata_r;
    always @* begin
        mmio_rdata_r = 64'd0;
        case (mem_addr_i & 64'hffff_ffff_ffff_fff8)
            LED_MMIO: begin
                mmio_rdata_r = {56'd0, led_q} << (mem_byte_off * 8);
            end
            UART_BASE: begin
                case (mem_reg_off)
                    4'h0: mmio_rdata_r = {56'd0, uart_dlab ? uart_dll_q : rx_data_hold_q} << (mem_byte_off * 8);
                    4'h1: mmio_rdata_r = {56'd0, uart_dlab ? uart_dlm_q : uart_ier_q} << (mem_byte_off * 8);
                    4'h2: mmio_rdata_r = {56'd0, uart_iir} << (mem_byte_off * 8);
                    4'h3: mmio_rdata_r = {56'd0, uart_lcr_q} << (mem_byte_off * 8);
                    4'h4: mmio_rdata_r = {56'd0, uart_mcr_q} << (mem_byte_off * 8);
                    4'h5: mmio_rdata_r = {56'd0, uart_lsr} << (mem_byte_off * 8);
                    4'h7: mmio_rdata_r = {56'd0, uart_scr_q} << (mem_byte_off * 8);
                    default: mmio_rdata_r = 64'd0;
                endcase
            end
            CLINT_MTIMECMP: begin
                mmio_rdata_r = mtimecmp_i;
            end
            CLINT_MTIME: begin
                mmio_rdata_r = mtime_i;
            end
            CLINT_STIMECMP: begin
                mmio_rdata_r = stimecmp_i;
            end
            default: begin
                if (mem_addr_i[31:26] == 6'd3) begin
                    mmio_rdata_r = plic_rdata;
                end
            end
        endcase
    end

    always @(posedge clk_i) begin
        if (!rst_ni) begin
            led_q <= 8'h00;
            fan_ctr_q <= 8'd0;
            uart_ier_q <= 8'h00;
            uart_lcr_q <= 8'h03;
            uart_mcr_q <= 8'h00;
            uart_scr_q <= 8'h00;
            uart_fcr_q <= 8'h00;
            uart_dll_q <= 8'h03;
            uart_dlm_q <= 8'h00;
            tx_wr_ptr_q <= '0;
            tx_rd_ptr_q <= '0;
            tx_count_q <= '0;
            tx_data_q <= 8'h00;
            tx_start_q <= 1'b0;
            tx_push_q <= 1'b0;
            tx_push_addr_q <= '0;
            tx_push_data_q <= 8'h00;
            rx_wr_ptr_q <= '0;
            rx_rd_ptr_q <= '0;
            rx_count_q <= '0;
            rx_pop_q <= 1'b0;
            rx_pop_addr_q <= '0;
            rx_data_hold_q <= 8'h00;
            last_store_addr_q <= 64'd0;
            last_store_data_q <= 64'd0;
            last_store_valid_q <= 1'b0;
        end else begin
            fan_ctr_q <= fan_ctr_q + 8'd1;
            tx_start_q <= 1'b0;
            tx_push_q <= 1'b0;
            rx_pop_q <= 1'b0;

            if (store_event && store_addr_i == LED_MMIO) begin
                led_q <= store_data_i[7:0];
            end

            if (store_event && (store_addr_i & 64'hffff_ffff_ffff_fff0) == UART_BASE) begin
                case (store_reg_off)
                    4'h0: begin
                        if (uart_dlab) begin
                            uart_dll_q <= mmio_store_byte(store_addr_i, store_data_i);
                        end else if (!tx_fifo_full) begin
                            tx_push_q <= 1'b1;
                            tx_push_addr_q <= tx_wr_ptr_q;
                            tx_push_data_q <= mmio_store_byte(store_addr_i, store_data_i);
                            tx_wr_ptr_q <= tx_wr_ptr_q + {{(UART_PTR_W-1){1'b0}}, 1'b1};
                            tx_count_q <= tx_count_q + {{(UART_COUNT_W-1){1'b0}}, 1'b1};
                        end
                    end
                    4'h1: begin
                        if (uart_dlab) begin
                            uart_dlm_q <= mmio_store_byte(store_addr_i, store_data_i);
                        end else begin
                            uart_ier_q[3:0] <= mmio_store_byte(store_addr_i, store_data_i)[3:0];
                        end
                    end
                    4'h2: begin
                        uart_fcr_q <= mmio_store_byte(store_addr_i, store_data_i);
                        if (mmio_store_byte(store_addr_i, store_data_i)[1]) begin
                            rx_wr_ptr_q <= '0;
                            rx_rd_ptr_q <= '0;
                            rx_count_q <= '0;
                        end
                        if (mmio_store_byte(store_addr_i, store_data_i)[2]) begin
                            tx_wr_ptr_q <= '0;
                            tx_rd_ptr_q <= '0;
                            tx_count_q <= '0;
                        end
                    end
                    4'h3: uart_lcr_q <= mmio_store_byte(store_addr_i, store_data_i);
                    4'h4: uart_mcr_q <= mmio_store_byte(store_addr_i, store_data_i);
                    4'h7: uart_scr_q <= mmio_store_byte(store_addr_i, store_data_i);
                    default: begin end
                endcase
            end

            if (uart_rx_valid && !rx_fifo_full) begin
                rx_fifo[rx_wr_ptr_q] <= uart_rx_data;
                rx_wr_ptr_q <= rx_wr_ptr_q + {{(UART_PTR_W-1){1'b0}}, 1'b1};
                rx_count_q <= rx_count_q + {{(UART_COUNT_W-1){1'b0}}, 1'b1};
            end

            if (mem_read_i && (mem_addr_i & 64'hffff_ffff_ffff_fff0) == UART_BASE && mem_reg_off == 4'h0 && !uart_dlab && !rx_fifo_empty) begin
                rx_data_hold_q <= rx_fifo[rx_rd_ptr_q];
                rx_pop_q <= 1'b1;
                rx_pop_addr_q <= rx_rd_ptr_q;
                rx_rd_ptr_q <= rx_rd_ptr_q + {{(UART_PTR_W-1){1'b0}}, 1'b1};
                rx_count_q <= rx_count_q - {{(UART_COUNT_W-1){1'b0}}, 1'b1};
            end else if (!rx_fifo_empty) begin
                rx_data_hold_q <= rx_fifo[rx_rd_ptr_q];
            end else begin
                rx_data_hold_q <= 8'h00;
            end

            if (!tx_fifo_empty && !uart_tx_busy && !tx_push_q) begin
                tx_data_q <= tx_fifo[tx_rd_ptr_q];
                tx_rd_ptr_q <= tx_rd_ptr_q + {{(UART_PTR_W-1){1'b0}}, 1'b1};
                tx_count_q <= tx_count_q - {{(UART_COUNT_W-1){1'b0}}, 1'b1};
                tx_start_q <= 1'b1;
            end

            if (tx_push_q) begin
                tx_fifo[tx_push_addr_q] <= tx_push_data_q;
            end

            last_store_addr_q <= store_addr_i;
            last_store_data_q <= store_data_i;
            last_store_valid_q <= store_valid_i;
        end
    end

    risky_uart_tx #(
        .CLKS_PER_BIT(UART_CLKS_PER_BIT)
    ) i_uart_tx (
        .clk_i   (clk_i),
        .rst_ni  (rst_ni),
        .start_i (tx_start_q),
        .data_i  (tx_data_q),
        .tx_o    (tx_o),
        .busy_o  (uart_tx_busy)
    );

    risky_uart_rx #(
        .CLKS_PER_BIT(UART_CLKS_PER_BIT)
    ) i_uart_rx (
        .clk_i       (clk_i),
        .rst_ni      (rst_ni),
        .rx_i        (rx_i),
        .data_valid_o(uart_rx_valid),
        .data_o      (uart_rx_data)
    );

    risky_plic i_plic (
        .clk_i        (clk_i),
        .rst_ni       (rst_ni),
        .mem_addr_i   (mem_addr_i),
        .mem_read_i   (mem_read_i),
        .store_valid_i(store_valid_i && store_addr_i[31:26] == 6'd3),
        .store_addr_i (store_addr_i),
        .store_data_i (store_data_i),
        .uart_irq_i   (uart_rx_irq || uart_tx_irq),
        .virtio_irq_i (1'b0),
        .mem_rdata_o  (plic_rdata),
        .ext_mip_o    (plic_ext_mip)
    );

    assign mem_rdata_o = mmio_rdata_r;
    assign ext_mip_o = plic_ext_mip;
    assign led_o = led_q;
    assign fan_pwm_o = fan_ctr_q != 8'd0;
endmodule
