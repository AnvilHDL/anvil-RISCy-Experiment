module risky_uart_tx #(
    parameter integer CLKS_PER_BIT = 1736
) (
    input  wire       clk_i,
    input  wire       rst_ni,
    input  wire       start_i,
    input  wire [7:0] data_i,
    output reg        tx_o,
    output wire       busy_o
);
    localparam int BAUD_CTR_W = (CLKS_PER_BIT > 1) ? $clog2(CLKS_PER_BIT) : 1;

    reg [BAUD_CTR_W-1:0] baud_ctr_q = '0;
    reg [3:0] bit_idx_q = 4'd0;
    reg [9:0] shift_q = 10'h3ff;
    reg       busy_q = 1'b0;

    assign busy_o = busy_q;

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            baud_ctr_q <= '0;
            bit_idx_q <= 4'd0;
            shift_q <= 10'h3ff;
            busy_q <= 1'b0;
            tx_o <= 1'b1;
        end else if (!busy_q) begin
            tx_o <= 1'b1;
            baud_ctr_q <= '0;
            bit_idx_q <= 4'd0;
            if (start_i) begin
                shift_q <= {1'b1, data_i, 1'b0};
                busy_q <= 1'b1;
                tx_o <= 1'b0;
            end
        end else if (baud_ctr_q == BAUD_CTR_W'(CLKS_PER_BIT - 1)) begin
            baud_ctr_q <= '0;
            shift_q <= {1'b1, shift_q[9:1]};
            tx_o <= shift_q[1];
            if (bit_idx_q == 4'd9) begin
                bit_idx_q <= 4'd0;
                busy_q <= 1'b0;
                tx_o <= 1'b1;
            end else begin
                bit_idx_q <= bit_idx_q + 4'd1;
            end
        end else begin
            baud_ctr_q <= baud_ctr_q + {{(BAUD_CTR_W-1){1'b0}}, 1'b1};
        end
    end
endmodule
