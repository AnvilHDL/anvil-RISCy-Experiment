// risky_mig_adapter.sv - simple request/response bridge to MIG AXI4
//
// The Genesys 2 DDR3 MIG project is configured with an AXI slave interface,
// matching the CVA6 FPGA platform. This bridge intentionally issues only
// single-beat 64-bit AXI transactions; wider/later burst support belongs above
// this boundary once the core memory contract is latency-clean.

module risky_mig_adapter (
    input  wire        clk_i,
    input  wire        rst_ni,

    // --- Upstream (arbiter) ---
    input  wire        req_valid_i,
    input  wire [63:0] req_addr_i,
    input  wire        req_write_i,
    input  wire [63:0] req_wdata_i,
    input  wire [2:0]  req_width_i,

    // --- Committed store path (writes only, no read response expected) ---
    input  wire        store_valid_i,
    input  wire [63:0] store_addr_i,
    input  wire [63:0] store_data_i,
    input  wire [2:0]  store_width_i,

    // --- Response back to arbiter ---
    output reg         rsp_valid_o,
    output reg  [63:0] rsp_data_o,

    // --- MIG AXI slave port ---
    output wire [4:0]  s_axi_awid_o,
    output reg  [29:0] s_axi_awaddr_o,
    output wire [7:0]  s_axi_awlen_o,
    output wire [2:0]  s_axi_awsize_o,
    output wire [1:0]  s_axi_awburst_o,
    output wire [0:0]  s_axi_awlock_o,
    output wire [3:0]  s_axi_awcache_o,
    output wire [2:0]  s_axi_awprot_o,
    output wire [3:0]  s_axi_awqos_o,
    output reg         s_axi_awvalid_o,
    input  wire        s_axi_awready_i,
    output reg  [63:0] s_axi_wdata_o,
    output reg  [7:0]  s_axi_wstrb_o,
    output wire        s_axi_wlast_o,
    output reg         s_axi_wvalid_o,
    input  wire        s_axi_wready_i,
    output wire        s_axi_bready_o,
    input  wire [4:0]  s_axi_bid_i,
    input  wire [1:0]  s_axi_bresp_i,
    input  wire        s_axi_bvalid_i,
    output wire [4:0]  s_axi_arid_o,
    output reg  [29:0] s_axi_araddr_o,
    output wire [7:0]  s_axi_arlen_o,
    output wire [2:0]  s_axi_arsize_o,
    output wire [1:0]  s_axi_arburst_o,
    output wire [0:0]  s_axi_arlock_o,
    output wire [3:0]  s_axi_arcache_o,
    output wire [2:0]  s_axi_arprot_o,
    output wire [3:0]  s_axi_arqos_o,
    output reg         s_axi_arvalid_o,
    input  wire        s_axi_arready_i,
    output wire        s_axi_rready_o,
    input  wire [4:0]  s_axi_rid_i,
    input  wire [63:0] s_axi_rdata_i,
    input  wire [1:0]  s_axi_rresp_i,
    input  wire        s_axi_rlast_i,
    input  wire        s_axi_rvalid_i
);
    typedef enum logic [2:0] {
        IDLE      = 3'd0,
        WRITE_AW  = 3'd1,
        WRITE_W   = 3'd2,
        WRITE_B   = 3'd3,
        READ_AR   = 3'd4,
        READ_R    = 3'd5
    } axi_state_t;

    axi_state_t state_q = IDLE;

    reg         saved_needs_rsp_q = 1'b0;
    reg [29:0]  saved_addr_q = 30'd0;
    reg [63:0]  saved_wdata_q = 64'd0;
    reg [7:0]   saved_wstrb_q = 8'h00;

    wire _unused_axi_status = |s_axi_bid_i | |s_axi_bresp_i | |s_axi_arid_o |
                              |s_axi_rid_i | |s_axi_rresp_i | s_axi_rlast_i;

    function automatic [29:0] axi_addr64;
        input [63:0] addr;
        begin
            axi_addr64 = {addr[29:3], 3'b000};
        end
    endfunction

    function automatic [7:0] req_wstrb;
        input [2:0] width;
        input [2:0] byte_off;
        reg [7:0] mask;
        begin
            case (width)
                3'd0: mask = 8'b0000_0001;
                3'd1: mask = 8'b0000_0011;
                3'd2: mask = 8'b0000_1111;
                3'd3: mask = 8'b1111_1111;
                default: mask = 8'b1111_1111;
            endcase
            req_wstrb = mask << byte_off;
        end
    endfunction

    function automatic [63:0] req_wdata_shifted;
        input [63:0] data;
        input [2:0] byte_off;
        begin
            req_wdata_shifted = data << (byte_off * 8);
        end
    endfunction

    assign s_axi_awid_o    = 5'd0;
    assign s_axi_awlen_o   = 8'd0;
    assign s_axi_awsize_o  = 3'd3;       // 8 bytes
    assign s_axi_awburst_o = 2'b01;      // INCR
    assign s_axi_awlock_o  = 1'b0;
    assign s_axi_awcache_o = 4'b0011;
    assign s_axi_awprot_o  = 3'b000;
    assign s_axi_awqos_o   = 4'd0;
    assign s_axi_wlast_o   = 1'b1;
    assign s_axi_bready_o  = 1'b1;

    assign s_axi_arid_o    = 5'd0;
    assign s_axi_arlen_o   = 8'd0;
    assign s_axi_arsize_o  = 3'd3;       // 8 bytes
    assign s_axi_arburst_o = 2'b01;      // INCR
    assign s_axi_arlock_o  = 1'b0;
    assign s_axi_arcache_o = 4'b0011;
    assign s_axi_arprot_o  = 3'b000;
    assign s_axi_arqos_o   = 4'd0;
    assign s_axi_rready_o  = 1'b1;

    always @(posedge clk_i) begin
        if (!rst_ni) begin
            state_q         <= IDLE;
            saved_needs_rsp_q <= 1'b0;
            saved_addr_q    <= 30'd0;
            saved_wdata_q   <= 64'd0;
            saved_wstrb_q   <= 8'h00;
            rsp_valid_o     <= 1'b0;
            rsp_data_o      <= 64'd0;
            s_axi_awaddr_o  <= 30'd0;
            s_axi_awvalid_o <= 1'b0;
            s_axi_wdata_o   <= 64'd0;
            s_axi_wstrb_o   <= 8'h00;
            s_axi_wvalid_o  <= 1'b0;
            s_axi_araddr_o  <= 30'd0;
            s_axi_arvalid_o <= 1'b0;
        end else begin
            rsp_valid_o <= 1'b0;

            case (state_q)
                IDLE: begin
                    if (store_valid_i) begin
                        saved_needs_rsp_q <= 1'b0;
                        saved_addr_q      <= axi_addr64(store_addr_i);
                        // core already shifts data into the correct byte lane;
                        // use proper byte enables so adjacent bytes are preserved
                        saved_wdata_q     <= store_data_i;
                        saved_wstrb_q     <= req_wstrb(store_width_i, store_addr_i[2:0]);
                        state_q           <= WRITE_AW;
                    end else if (req_valid_i) begin
                        saved_addr_q <= axi_addr64(req_addr_i);
                        if (req_write_i) begin
                            saved_needs_rsp_q <= 1'b1;
                            saved_wdata_q     <= req_wdata_shifted(req_wdata_i, req_addr_i[2:0]);
                            saved_wstrb_q     <= req_wstrb(req_width_i, req_addr_i[2:0]);
                            state_q           <= WRITE_AW;
                        end else begin
                            state_q <= READ_AR;
                        end
                    end
                end

                WRITE_AW: begin
                    s_axi_awaddr_o  <= saved_addr_q;
                    s_axi_awvalid_o <= 1'b1;
                    if (s_axi_awvalid_o && s_axi_awready_i) begin
                        s_axi_awvalid_o <= 1'b0;
                        state_q <= WRITE_W;
                    end
                end

                WRITE_W: begin
                    s_axi_wdata_o  <= saved_wdata_q;
                    s_axi_wstrb_o  <= saved_wstrb_q;
                    s_axi_wvalid_o <= 1'b1;
                    if (s_axi_wvalid_o && s_axi_wready_i) begin
                        s_axi_wvalid_o <= 1'b0;
                        state_q <= WRITE_B;
                    end
                end

                WRITE_B: begin
                    if (s_axi_bvalid_i) begin
                        if (saved_needs_rsp_q) begin
                            rsp_valid_o <= 1'b1;
                            rsp_data_o  <= 64'd0;
                        end
                        state_q <= IDLE;
                    end
                end

                READ_AR: begin
                    s_axi_araddr_o  <= saved_addr_q;
                    s_axi_arvalid_o <= 1'b1;
                    if (s_axi_arvalid_o && s_axi_arready_i) begin
                        s_axi_arvalid_o <= 1'b0;
                        state_q <= READ_R;
                    end
                end

                READ_R: begin
                    if (s_axi_rvalid_i) begin
                        rsp_valid_o <= 1'b1;
                        rsp_data_o  <= s_axi_rdata_i;
                        state_q <= IDLE;
                    end
                end

                default: state_q <= IDLE;
            endcase
        end
    end
endmodule
