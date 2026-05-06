/* verilator lint_off MULTITOP */
// risky_mem_arbiter.sv — Memory Arbiter
//
// Three requestors, one shared BRAM/DDR3 read port:
//   Priority: PTW > MEM > IF
//
// Requestors present (valid, addr, write, wdata, width).
// Arbiter issues one request per cycle to the downstream memory.
// When response arrives, it is routed back to the correct requestor.
//
// For the BRAM-only target: downstream = risky_bram_mem_adapter.
// For the DDR3 target:      downstream = risky_mig_adapter.

module risky_mem_arbiter (
    input  wire        clk_i,
    input  wire        rst_ni,

    // --- IF fetch port ---
    input  wire        if_req_valid_i,
    input  wire [63:0] if_req_addr_i,
    output reg         if_rsp_valid_o,
    output reg  [31:0] if_rsp_data_o,

    // --- MEM (data) port ---
    input  wire        mem_req_valid_i,
    input  wire [63:0] mem_req_addr_i,
    input  wire        mem_req_write_i,
    input  wire [63:0] mem_req_wdata_i,
    input  wire [2:0]  mem_req_width_i,
    output reg         mem_rsp_valid_o,
    output reg  [63:0] mem_rsp_data_o,

    // --- PTW port (highest priority) ---
    input  wire        ptw_req_valid_i,
    input  wire [63:0] ptw_req_addr_i,
    output reg         ptw_rsp_valid_o,
    output reg  [63:0] ptw_rsp_data_o,

    // --- Downstream memory port ---
    output reg         mem_req_o,
    output reg  [63:0] mem_addr_o,
    output reg         mem_write_o,
    output reg  [63:0] mem_wdata_o,
    output reg  [2:0]  mem_width_o,
    input  wire        mem_rsp_valid_i,
    input  wire [63:0] mem_rsp_data_i
);

    // Track which requestor is outstanding
    typedef enum logic [1:0] {
        IDLE_  = 2'd0,
        IN_PTW = 2'd1,
        IN_MEM = 2'd2,
        IN_IF  = 2'd3
    } arb_owner_t;

    arb_owner_t owner_q = IDLE_;
    reg [63:0] if_half_addr_q = 64'd0;  // track which 32-bit half was requested

    always @(posedge clk_i) begin
        if (!rst_ni) begin
            owner_q        <= IDLE_;
            mem_req_o      <= 1'b0;
            mem_write_o    <= 1'b0;
            if_rsp_valid_o <= 1'b0;
            mem_rsp_valid_o<= 1'b0;
            ptw_rsp_valid_o<= 1'b0;
        end else begin
            // Default: clear response pulses
            if_rsp_valid_o  <= 1'b0;
            mem_rsp_valid_o <= 1'b0;
            ptw_rsp_valid_o <= 1'b0;
            mem_req_o       <= 1'b0;

            if (owner_q == IDLE_) begin
                // Arbitrate: PTW > MEM > IF
                if (ptw_req_valid_i) begin
                    owner_q    <= IN_PTW;
                    mem_req_o  <= 1'b1;
                    mem_addr_o <= ptw_req_addr_i;
                    mem_write_o<= 1'b0;
                    mem_wdata_o<= 64'd0;
                    mem_width_o<= 3'd3;  // 64-bit PTE
                end else if (mem_req_valid_i) begin
                    owner_q     <= IN_MEM;
                    mem_req_o   <= 1'b1;
                    mem_addr_o  <= mem_req_addr_i;
                    mem_write_o <= mem_req_write_i;
                    mem_wdata_o <= mem_req_wdata_i;
                    mem_width_o <= mem_req_width_i;
                end else if (if_req_valid_i) begin
                    owner_q         <= IN_IF;
                    mem_req_o       <= 1'b1;
                    mem_addr_o      <= {if_req_addr_i[63:3], 3'd0};  // align to 8B
                    mem_write_o     <= 1'b0;
                    mem_wdata_o     <= 64'd0;
                    mem_width_o     <= 3'd3;
                    if_half_addr_q  <= if_req_addr_i;
                end
            end else begin
                // Waiting for downstream response
                if (mem_rsp_valid_i) begin
                    case (owner_q)
                        IN_PTW: begin
                            ptw_rsp_valid_o <= 1'b1;
                            ptw_rsp_data_o  <= mem_rsp_data_i;
                        end
                        IN_MEM: begin
                            mem_rsp_valid_o <= 1'b1;
                            mem_rsp_data_o  <= mem_rsp_data_i;
                        end
                        IN_IF: begin
                            if_rsp_valid_o <= 1'b1;
                            if_rsp_data_o  <= if_half_addr_q[2]
                                              ? mem_rsp_data_i[63:32]
                                              : mem_rsp_data_i[31:0];
                        end
                        default: ;
                    endcase
                    owner_q <= IDLE_;
                end
            end
        end
    end
endmodule
