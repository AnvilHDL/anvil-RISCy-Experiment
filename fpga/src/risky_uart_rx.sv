module risky_uart_rx #(
    parameter int CLKS_PER_BIT = 217
) (
    input  wire       clk_i,
    input  wire       rst_ni,
    input  wire       rx_i,
    output reg        data_valid_o,
    output reg [7:0]  data_o
);
    localparam int HALF_CLKS = (CLKS_PER_BIT > 1) ? (CLKS_PER_BIT / 2) : 1;
    localparam int CTR_W = (CLKS_PER_BIT > 1) ? $clog2(CLKS_PER_BIT + 1) : 1;

    reg [2:0] rx_sync_q = 3'b111;
    reg       busy_q = 1'b0;
    reg [CTR_W-1:0] clk_count_q = '0;
    reg [3:0] bit_idx_q = 4'd0;
    reg [7:0] shift_q = 8'h00;

    wire rx_s = rx_sync_q[2];

    always @(posedge clk_i) begin
        if (!rst_ni) begin
            rx_sync_q <= 3'b111;
            busy_q <= 1'b0;
            clk_count_q <= '0;
            bit_idx_q <= 4'd0;
            shift_q <= 8'h00;
            data_valid_o <= 1'b0;
            data_o <= 8'h00;
        end else begin
            rx_sync_q <= {rx_sync_q[1:0], rx_i};
            data_valid_o <= 1'b0;

            if (!busy_q) begin
                if (rx_s == 1'b0) begin
                    busy_q <= 1'b1;
                    clk_count_q <= HALF_CLKS[CTR_W-1:0];
                    bit_idx_q <= 4'd0;
                end
            end else if (clk_count_q != 0) begin
                clk_count_q <= clk_count_q - {{(CTR_W-1){1'b0}}, 1'b1};
            end else begin
                clk_count_q <= CLKS_PER_BIT[CTR_W-1:0] - {{(CTR_W-1){1'b0}}, 1'b1};
                if (bit_idx_q < 4'd8) begin
                    shift_q <= {rx_s, shift_q[7:1]};
                    bit_idx_q <= bit_idx_q + 4'd1;
                end else begin
                    busy_q <= 1'b0;
                    if (rx_s == 1'b1) begin
                        data_o <= shift_q;
                        data_valid_o <= 1'b1;
                    end
                end
            end
        end
    end
endmodule
