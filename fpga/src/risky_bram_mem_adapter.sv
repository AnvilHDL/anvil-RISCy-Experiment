// risky_bram_mem_adapter.sv
//
// Maps the core's instruction-fetch and data-memory ports onto a tiny local
// memory for BRAM bringup. The Anvil core expects combinatorial read data, so
// this target intentionally uses distributed RAM rather than RAMB36 primitives.
//
// Two logical views of the memory are provided:
//   bram[]     — instruction fetch view
//   bram_mem[] — data-memory view
// Request-stage stores update both views so a store followed by a load can
// observe the new value without waiting for the later committed-store pulse.

module risky_bram_mem_adapter #(
    parameter logic [63:0] RAM_BASE  = 64'h0000_0000_8000_0000,
    parameter int          RAM_WORDS = 1024
) (
    input  wire        clk_i,
    input  wire        if_req_valid_i,
    input  wire [63:0] if_req_addr_i,
    output wire [31:0] if_rsp_data_o,
    input  wire        mem_req_valid_i,
    input  wire [63:0] mem_req_addr_i,
    input  wire        mem_req_write_i,
    input  wire [63:0] mem_req_wdata_i,
    input  wire [2:0]  mem_req_width_i,
    input  wire        mem_store_valid_i,
    input  wire [63:0] mem_store_addr_i,
    input  wire [63:0] mem_store_word_i,
    input  wire [63:0] mmio_rdata_i,
    output wire [63:0] mem_rsp_data_o
);
    localparam int      RAM_ADDR_W  = $clog2(RAM_WORDS);
    localparam logic [63:0] RAM_WORDS_64 = 64'(RAM_WORDS);

    // -------------------------------------------------------------------------
    // Two BRAM arrays — identical contents, separate read ports
    //   bram_if[]  : port B used for instruction-fetch reads
    //   bram_mem[] : port B used for data-memory reads
    // -------------------------------------------------------------------------
    (* ram_style = "distributed" *) reg [63:0] bram     [0:RAM_WORDS-1];
    (* ram_style = "distributed" *) reg [63:0] bram_mem [0:RAM_WORDS-1];

    // ---- Initialise both arrays from the generated init header ----
    integer _i;
    initial begin
        for (_i = 0; _i < RAM_WORDS; _i = _i + 1) begin
            bram    [_i] = 64'h0000_0013_0000_0013;
            bram_mem[_i] = 64'h0000_0013_0000_0013;
        end
`ifndef __VERILATOR__
`include "risky_genesys2_bram_init.vh"          // writes bram[N] = ...
`define bram bram_mem
`include "risky_genesys2_bram_init.vh"          // writes bram_mem[N] = ...
`undef bram
`endif
    end

    // ---- Address decode (combinatorial) ----
    wire [63:0]          if_offset    = if_req_addr_i  - RAM_BASE;
    wire [RAM_ADDR_W-1:0] if_word_idx = if_offset[RAM_ADDR_W+2:3];
    wire                 if_in_ram   = (if_offset >> 3) < RAM_WORDS_64;

    wire [63:0]          mem_offset    = mem_req_addr_i - RAM_BASE;
    wire [RAM_ADDR_W-1:0] mem_word_idx = mem_offset[RAM_ADDR_W+2:3];
    wire                 mem_in_ram   = (mem_offset >> 3) < RAM_WORDS_64;

    wire                 req_store_in_ram = mem_req_valid_i && mem_req_write_i && mem_in_ram;
    wire                 _unused_committed_store =
        mem_store_valid_i || |mem_store_addr_i || |mem_store_word_i;

    function automatic [63:0] store_mask;
        input [2:0] width;
        input [2:0] byte_off;
        reg [63:0] byte_en;
        begin
            case (width)
                3'd0: byte_en = 64'h0000_0000_0000_00ff;
                3'd1: byte_en = 64'h0000_0000_0000_ffff;
                3'd2: byte_en = 64'h0000_0000_ffff_ffff;
                3'd3: byte_en = 64'hffff_ffff_ffff_ffff;
                default: byte_en = 64'hffff_ffff_ffff_ffff;
            endcase
            store_mask = byte_en << (byte_off * 8);
        end
    endfunction

    function automatic [63:0] merge_store;
        input [63:0] old_word;
        input [63:0] store_data;
        input [2:0]  width;
        input [2:0]  byte_off;
        reg [63:0] mask;
        reg [63:0] shifted_data;
        begin
            mask = store_mask(width, byte_off);
            shifted_data = store_data << (byte_off * 8);
            merge_store = (old_word & ~mask) | (shifted_data & mask);
        end
    endfunction

    // =========================================================================
    // Read data (Asynchronous for Anvil 0-cycle requirement)
    //
    // The Anvil pipeline requires 0-cycle combinatorial memory reads because 
    // it was built under the assumption that the C++ testbench pre-populates
    // memory registers before the tick. To satisfy this on FPGA without 
    // stalling, we must implement the BRAM read as an asynchronous LUTRAM.
    // =========================================================================
    wire [63:0] if_word   = bram[if_word_idx];
    wire [63:0] mem_word  = bram_mem[mem_word_idx];

    always @(posedge clk_i) begin
        if (req_store_in_ram) begin
            bram[mem_word_idx] <= merge_store(
                bram[mem_word_idx],
                mem_req_wdata_i,
                mem_req_width_i,
                mem_req_addr_i[2:0]
            );
            bram_mem[mem_word_idx] <= merge_store(
                bram_mem[mem_word_idx],
                mem_req_wdata_i,
                mem_req_width_i,
                mem_req_addr_i[2:0]
            );
        end
    end

    // =========================================================================
    // Output mux — combinatorial to match Anvil's 0-cycle memory assumption
    //
    // We CANNOT use `_valid_i` signals to gate these combinatorial outputs 
    // because Anvil exports them as pipeline registers (delayed by 1 cycle).
    // The C++ testbench reads memory unconditionally; we must do the same.
    // =========================================================================
    assign if_rsp_data_o = if_in_ram
        ? (if_req_addr_i[2] ? if_word[63:32] : if_word[31:0])
        : 32'h0000_0013; // nop

    assign mem_rsp_data_o = mem_in_ram
        ? mem_word
        : mmio_rdata_i;

endmodule
