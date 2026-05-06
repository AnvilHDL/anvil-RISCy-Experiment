// risky_bram_mem_adapter.sv
//
// Maps the core's instruction-fetch and data-memory ports onto synchronous
// block RAM.  The design uses ONE physical BRAM array written in the exact
// pattern that Vivado's RAMB inference engine requires:
//
//   Simple Dual-Port (SDP) BRAM pattern per Xilinx UG901:
//     • One write port  (port A):  always write-enabled, data gated by WE
//     • One read port   (port B):  always reads every cycle (no CE guard)
//     • Both ports share the same clock
//     • No read-first / write-first mux on the read output
//
// Two logical views of the array are provided by TWO separate BRAM instances:
//   bram_if[]  — dedicated to IF reads (port B of instance 0)
//   bram_mem[] — dedicated to MEM reads (port B of instance 1)
// Both instances are written identically whenever a store commits.
//
// This pattern reliably produces RAMB36E1 primitives in Vivado.

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
    (* ram_style = "block" *) reg [63:0] bram     [0:RAM_WORDS-1];
    (* ram_style = "block" *) reg [63:0] bram_mem [0:RAM_WORDS-1];

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

    wire [63:0]          sto_offset    = mem_store_addr_i - RAM_BASE;
    wire [RAM_ADDR_W-1:0] sto_word_idx = sto_offset[RAM_ADDR_W+2:3];
    wire                 sto_in_ram   = (sto_offset >> 3) < RAM_WORDS_64;

    // =========================================================================
    // Read data
    //
    // Keep the read ports synchronous and unconditional so Vivado infers block
    // RAM instead of LUTRAM. The outputs are gated separately below.
    // =========================================================================
    reg [63:0] if_word_q  = 64'd0;
    reg [63:0] mem_word_q = 64'd0;

    always @(posedge clk_i) begin
        if_word_q <= bram[if_word_idx];
        // Write port A — committed store
        if (sto_in_ram && mem_store_valid_i)
            bram[sto_word_idx] <= mem_store_word_i;
    end

    always @(posedge clk_i) begin
        mem_word_q <= bram_mem[mem_word_idx];
        // Write port A — committed store (same data as instance 0)
        if (sto_in_ram && mem_store_valid_i)
            bram_mem[sto_word_idx] <= mem_store_word_i;
    end

    // =========================================================================
    // Output mux
    // =========================================================================
    assign if_rsp_data_o  = (if_req_valid_i && if_in_ram)
        ? (if_req_addr_i[2] ? if_word_q[63:32] : if_word_q[31:0])
        : 32'h0000_0013;
    assign mem_rsp_data_o = (mem_req_valid_i && !mem_req_write_i)
        ? (mem_in_ram ? mem_word_q : mmio_rdata_i)
        : 64'd0;

endmodule
