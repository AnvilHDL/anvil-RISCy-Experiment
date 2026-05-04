// Minimal Genesys 2 synthesis wrapper for the current RISCy core.
//
// This wrapper is intentionally a synthesis smoke target. The current core
// still relies on simulation-backed memory/device services for xv6; the FPGA
// wrapper proves the generated RTL can be packaged for Vivado without claiming
// full board-ready software execution.

module risky_genesys2_top (
    input  wire       clk200_p,
    input  wire       clk200_n,
    input  wire       cpu_resetn,
    input  wire       rx,
    output wire       tx,
    output wire [7:0] led,
    output wire       fan_pwm
);
    wire clk200;

`ifdef VERILATOR
    assign clk200 = clk200_p;
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
`endif

    reg [3:0] reset_sync = 4'h0;
    always @(posedge clk200 or negedge cpu_resetn) begin
        if (!cpu_resetn) begin
            reset_sync <= 4'h0;
        end else begin
            reset_sync <= {reset_sync[2:0], 1'b1};
        end
    end

    wire rst_ni = reset_sync[3];

    pipeline_core i_core (
        .clk_i  (clk200),
        .rst_ni (rst_ni)
    );

    reg [31:0] heartbeat_q = 32'd0;
    always @(posedge clk200 or negedge rst_ni) begin
        if (!rst_ni) begin
            heartbeat_q <= 32'd0;
        end else begin
            heartbeat_q <= heartbeat_q + 32'd1;
        end
    end

    assign led[0] = rst_ni;
    assign led[1] = heartbeat_q[25];
    assign led[2] = rx;
    assign led[7:3] = 5'd0;

    assign tx = 1'b1;
    assign fan_pwm = 1'b1;
endmodule
