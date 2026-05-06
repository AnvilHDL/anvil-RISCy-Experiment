// risky_mig_adapter.sv — MIG 7-series Native UI Adapter
//
// Translates simple request/response handshake into MIG's native UI protocol.
//
// MIG UI key facts for Kintex-7 at 50 MHz ui_clk, 400 MHz DDR3:
//   - Data bus: 128 bits (burst length 8, 16 bytes per transaction)
//   - Address: 29-bit word address (app_addr = byte_addr >> 3, shifted again by MIG)
//   - Commands: 3'b000 = WRITE, 3'b001 = READ
//   - app_rdy: command accepted when high at app_en assertion
//   - app_wdf_rdy: write data FIFO ready
//   - Read data arrives ~15 cycles later via app_rd_data_valid
//
// Byte-enable (mask) note: MIG mask is ACTIVE LOW (1 = mask this byte).
// For a sub-64-bit store we compute the mask from width and byte offset.

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

    // --- Response back to arbiter ---
    output reg         rsp_valid_o,
    output reg  [63:0] rsp_data_o,

    // --- MIG UI ---
    output reg  [28:0] app_addr_o,
    output reg  [2:0]  app_cmd_o,
    output reg         app_en_o,
    output reg  [127:0] app_wdf_data_o,
    output reg         app_wdf_end_o,
    output reg  [15:0] app_wdf_mask_o,
    output reg         app_wdf_wren_o,
    input  wire [127:0] app_rd_data_i,
    input  wire        app_rd_data_valid_i,
    input  wire        app_rdy_i,
    input  wire        app_wdf_rdy_i
);

    // MIG address: app_addr = byte_addr[31:3] (MIG internally shifts by 4 for 128-bit BL8)
    // We send byte_addr >> 3 and MIG takes care of the rest.
    function automatic [28:0] mig_addr;
        input [63:0] byte_addr;
        begin
            mig_addr = byte_addr[31:3];
        end
    endfunction

    // Build 128-bit write data + 16-bit mask from 64-bit data + byte offset + width
    function automatic [127:0] expand_wdata;
        input [63:0] data;
        input [3:0]  byte_off;  // addr[3:0]
        begin
            expand_wdata = {64'd0, data} << (byte_off * 8);
        end
    endfunction

    function automatic [15:0] expand_mask;
        input [2:0] width;      // 0=byte,1=half,2=word,3=dword
        input [3:0] byte_off;
        reg [7:0] byte_en;
        begin
            case (width)
                3'd0: byte_en = 8'b0000_0001 << byte_off[2:0];
                3'd1: byte_en = 8'b0000_0011 << byte_off[2:0];
                3'd2: byte_en = 8'b0000_1111 << byte_off[2:0];
                3'd3: byte_en = 8'b1111_1111;
                default: byte_en = 8'hFF;
            endcase
            // MIG mask is active-low (1=masked)
            expand_mask = ~{8'd0, byte_en};
        end
    endfunction

    // -------------------------------------------------------------------------
    // State machine
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {
        IDLE      = 3'd0,
        CMD_WRITE = 3'd1,
        DAT_WRITE = 3'd2,
        CMD_READ  = 3'd3,
        WAIT_READ = 3'd4,
        DO_STORE  = 3'd5
    } mig_state_t;

    mig_state_t state_q = IDLE;

    reg [63:0]  saved_addr_q  = 64'd0;
    reg [127:0] saved_wdata_q = 128'd0;
    reg [15:0]  saved_mask_q  = 16'hFFFF;
    reg         saved_is_store_q = 1'b0;  // pure write (no read response)

    always @(posedge clk_i) begin
        if (!rst_ni) begin
            state_q        <= IDLE;
            app_en_o       <= 1'b0;
            app_wdf_wren_o <= 1'b0;
            app_wdf_end_o  <= 1'b0;
            rsp_valid_o    <= 1'b0;
            app_cmd_o      <= 3'b001;
            app_addr_o     <= 29'd0;
            app_wdf_data_o <= 128'd0;
            app_wdf_mask_o <= 16'hFFFF;
        end else begin
            app_en_o       <= 1'b0;
            app_wdf_wren_o <= 1'b0;
            app_wdf_end_o  <= 1'b0;
            rsp_valid_o    <= 1'b0;

            case (state_q)
                // ----------------------------------------------------------------
                IDLE: begin
                    // Committed stores take priority (write-only, no stall)
                    if (store_valid_i) begin
                        saved_addr_q      <= store_addr_i;
                        saved_wdata_q     <= expand_wdata(store_data_i, store_addr_i[3:0]);
                        saved_mask_q      <= 16'h0000;  // full 128-bit write (safe)
                        saved_is_store_q  <= 1'b1;
                        state_q           <= DO_STORE;
                    end else if (req_valid_i) begin
                        saved_addr_q  <= req_addr_i;
                        if (req_write_i) begin
                            saved_wdata_q    <= expand_wdata(req_wdata_i, req_addr_i[3:0]);
                            saved_mask_q     <= expand_mask(req_width_i, req_addr_i[3:0]);
                            saved_is_store_q <= 1'b0;
                            state_q          <= CMD_WRITE;
                        end else begin
                            state_q <= CMD_READ;
                        end
                    end
                end

                // ----------------------------------------------------------------
                // Write command
                // ----------------------------------------------------------------
                CMD_WRITE: begin
                    if (app_rdy_i) begin
                        app_en_o   <= 1'b1;
                        app_cmd_o  <= 3'b000;  // WRITE
                        app_addr_o <= mig_addr(saved_addr_q);
                        state_q    <= DAT_WRITE;
                    end else begin
                        // Keep trying
                        app_en_o   <= 1'b1;
                        app_cmd_o  <= 3'b000;
                        app_addr_o <= mig_addr(saved_addr_q);
                    end
                end

                // ----------------------------------------------------------------
                // Write data
                // ----------------------------------------------------------------
                DAT_WRITE: begin
                    if (app_wdf_rdy_i) begin
                        app_wdf_wren_o <= 1'b1;
                        app_wdf_end_o  <= 1'b1;
                        app_wdf_data_o <= saved_wdata_q;
                        app_wdf_mask_o <= saved_mask_q;
                        if (!saved_is_store_q) begin
                            rsp_valid_o <= 1'b1;  // write complete, ack to arbiter
                        end
                        state_q <= IDLE;
                    end
                end

                // ----------------------------------------------------------------
                // Committed store (best-effort, no response needed)
                // ----------------------------------------------------------------
                DO_STORE: begin
                    if (app_rdy_i) begin
                        app_en_o   <= 1'b1;
                        app_cmd_o  <= 3'b000;
                        app_addr_o <= mig_addr(saved_addr_q);
                        state_q    <= DAT_WRITE;
                        saved_is_store_q <= 1'b1;
                    end else begin
                        app_en_o   <= 1'b1;
                        app_cmd_o  <= 3'b000;
                        app_addr_o <= mig_addr(saved_addr_q);
                    end
                end

                // ----------------------------------------------------------------
                // Read command
                // ----------------------------------------------------------------
                CMD_READ: begin
                    if (app_rdy_i) begin
                        app_en_o   <= 1'b1;
                        app_cmd_o  <= 3'b001;  // READ
                        app_addr_o <= mig_addr(saved_addr_q);
                        state_q    <= WAIT_READ;
                    end else begin
                        app_en_o   <= 1'b1;
                        app_cmd_o  <= 3'b001;
                        app_addr_o <= mig_addr(saved_addr_q);
                    end
                end

                // ----------------------------------------------------------------
                // Wait for read data
                // ----------------------------------------------------------------
                WAIT_READ: begin
                    if (app_rd_data_valid_i) begin
                        rsp_valid_o <= 1'b1;
                        // Return the relevant 64-bit slice from the 128-bit burst
                        rsp_data_o  <= saved_addr_q[3]
                                       ? app_rd_data_i[127:64]
                                       : app_rd_data_i[63:0];
                        state_q     <= IDLE;
                    end
                end

                default: state_q <= IDLE;
            endcase
        end
    end
endmodule
