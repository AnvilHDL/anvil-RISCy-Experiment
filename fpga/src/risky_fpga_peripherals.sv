module risky_fpga_peripherals #(
    parameter int CORE_CLK_HZ = 25_000_000,
    parameter int UART_BAUD = 115200,
    parameter int UART_FIFO_DEPTH = 64
) (
    input  wire        clk_i,
    input  wire        rst_ni,
    input  wire        rx_i,
    input  wire [63:0] mem_addr_i,
    input  wire        store_valid_i,
    input  wire [63:0] store_addr_i,
    input  wire [63:0] store_data_i,
    input  wire [63:0] mtime_i,
    input  wire [63:0] mtimecmp_i,
    input  wire [63:0] stimecmp_i,
    output wire [63:0] mem_rdata_o,
    output wire        tx_o,
    output wire [7:0]  led_o,
    output wire        fan_pwm_o
);
    localparam logic [63:0] LED_MMIO          = 64'h0000_0000_3000_0000;
    localparam logic [63:0] UART_THR_MMIO     = 64'h0000_0000_1000_0000;
    localparam logic [63:0] UART_LSR_MMIO     = 64'h0000_0000_1000_0005;
    localparam logic [63:0] UART_SCRATCH_MMIO = 64'h0000_0000_1000_0007;
    localparam logic [63:0] CLINT_MTIMECMP    = 64'h0000_0000_0200_4000;
    localparam logic [63:0] CLINT_MTIME       = 64'h0000_0000_0200_BFF8;
    localparam int UART_CLKS_PER_BIT = CORE_CLK_HZ / UART_BAUD;
    localparam int UART_PTR_W = $clog2(UART_FIFO_DEPTH);
    localparam int UART_COUNT_W = $clog2(UART_FIFO_DEPTH + 1);

    reg [7:0] led_q = 8'h00;
    reg [7:0] uart_scratch_q = 8'h00;
    reg [7:0] rx_sync_q = 8'hff;
    reg [7:0] fan_ctr_q = 8'd0;

    reg [7:0] uart_fifo [0:UART_FIFO_DEPTH-1];
    reg [UART_PTR_W-1:0] uart_wr_ptr_q = '0;
    reg [UART_PTR_W-1:0] uart_rd_ptr_q = '0;
    reg [UART_COUNT_W-1:0] uart_count_q = '0;
    reg [7:0] uart_tx_data_q = 8'h00;
    reg       uart_tx_start_q = 1'b0;
    reg       uart_fifo_push_q = 1'b0;
    reg [UART_PTR_W-1:0] uart_fifo_push_addr_q = '0;
    reg [7:0] uart_fifo_push_data_q = 8'h00;

    reg [63:0] last_store_addr_q = 64'd0;
    reg [63:0] last_store_data_q = 64'd0;
    reg        last_store_valid_q = 1'b0;

    wire uart_tx_busy;
    wire uart_fifo_empty = (uart_count_q == {UART_COUNT_W{1'b0}});
    wire uart_fifo_full = (uart_count_q == UART_FIFO_DEPTH[UART_COUNT_W-1:0]);
    wire uart_ready = !uart_fifo_full;

    reg [63:0] mmio_rdata_r;
    wire [2:0] mem_byte_off = mem_addr_i[2:0];
    wire [7:0] uart_lsr = {rx_sync_q[7], 1'b0, 1'b1, 1'b1, 4'b0000};
    wire store_event = store_valid_i
        && (!last_store_valid_q
            || store_addr_i != last_store_addr_q
            || store_data_i != last_store_data_q);

    always @* begin
        mmio_rdata_r = 64'd0;
        case (mem_addr_i & 64'hffff_ffff_ffff_fff8)
            LED_MMIO: begin
                mmio_rdata_r = {56'd0, led_q} << (mem_byte_off * 8);
            end
            UART_THR_MMIO: begin
                if ((mem_addr_i & 64'h7) == 64'd5) begin
                    mmio_rdata_r = {56'd0, uart_lsr} << (mem_byte_off * 8);
                end else if ((mem_addr_i & 64'h7) == 64'd7) begin
                    mmio_rdata_r = {56'd0, uart_scratch_q} << (mem_byte_off * 8);
                end
            end
            CLINT_MTIMECMP: begin
                mmio_rdata_r = mtimecmp_i;
            end
            CLINT_MTIME: begin
                mmio_rdata_r = mtime_i;
            end
            default: begin
                if (mem_addr_i == 64'h0000_0000_0200_4008) begin
                    mmio_rdata_r = stimecmp_i;
                end
            end
        endcase
    end

    always @(posedge clk_i) begin
        if (!rst_ni) begin
            led_q <= 8'h00;
            uart_scratch_q <= 8'h00;
            rx_sync_q <= 8'hff;
            fan_ctr_q <= 8'd0;
            uart_wr_ptr_q <= '0;
            uart_rd_ptr_q <= '0;
            uart_count_q <= '0;
            uart_tx_data_q <= 8'h00;
            uart_tx_start_q <= 1'b0;
            uart_fifo_push_q <= 1'b0;
            uart_fifo_push_addr_q <= '0;
            uart_fifo_push_data_q <= 8'h00;
            last_store_addr_q <= 64'd0;
            last_store_data_q <= 64'd0;
            last_store_valid_q <= 1'b0;
        end else begin
            rx_sync_q <= {rx_sync_q[6:0], rx_i};
            fan_ctr_q <= fan_ctr_q + 8'd1;
            uart_tx_start_q <= 1'b0;
            uart_fifo_push_q <= 1'b0;

            if (store_event && store_addr_i == LED_MMIO) begin
                led_q <= store_data_i[7:0];
            end

            if (store_event && store_addr_i == UART_SCRATCH_MMIO) begin
                uart_scratch_q <= store_data_i[7:0];
            end

            if (store_event && store_addr_i == UART_THR_MMIO && !uart_fifo_full) begin
                uart_fifo_push_q <= 1'b1;
                uart_fifo_push_addr_q <= uart_wr_ptr_q;
                uart_fifo_push_data_q <= store_data_i[7:0];
                uart_wr_ptr_q <= uart_wr_ptr_q + {{(UART_PTR_W-1){1'b0}}, 1'b1};
                uart_count_q <= uart_count_q + {{(UART_COUNT_W-1){1'b0}}, 1'b1};
            end

            last_store_addr_q <= store_addr_i;
            last_store_data_q <= store_data_i;
            last_store_valid_q <= store_valid_i;

            if (!uart_fifo_empty && !uart_tx_busy && !uart_fifo_push_q) begin
                uart_tx_data_q <= uart_fifo[uart_rd_ptr_q];
                uart_rd_ptr_q <= uart_rd_ptr_q + {{(UART_PTR_W-1){1'b0}}, 1'b1};
                uart_count_q <= uart_count_q - {{(UART_COUNT_W-1){1'b0}}, 1'b1};
                uart_tx_start_q <= 1'b1;
            end

            if (uart_fifo_push_q) begin
                uart_fifo[uart_fifo_push_addr_q] <= uart_fifo_push_data_q;
            end
        end
    end

    risky_uart_tx #(
        .CLKS_PER_BIT(UART_CLKS_PER_BIT)
    ) i_uart_tx (
        .clk_i   (clk_i),
        .rst_ni  (rst_ni),
        .start_i (uart_tx_start_q),
        .data_i  (uart_tx_data_q),
        .tx_o    (tx_o),
        .busy_o  (uart_tx_busy)
    );

    assign mem_rdata_o = mmio_rdata_r;
    assign led_o = led_q;
    assign fan_pwm_o = fan_ctr_q != 8'd0;
endmodule
