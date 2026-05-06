module risky_bram_mem_adapter #(
    parameter logic [63:0] RAM_BASE = 64'h0000_0000_8000_0000,
    parameter int RAM_WORDS = 1024
) (
    input  wire        clk_i,
    input  wire        rst_ni,
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
    localparam logic [63:0] RAM_WORDS_64 = 64'(RAM_WORDS);
    localparam int RAM_ADDR_W = $clog2(RAM_WORDS);

    (* ram_style = "block" *) reg [63:0] bram [0:RAM_WORDS-1];
    (* ram_style = "block" *) reg [63:0] bram_mem [0:RAM_WORDS-1];
    reg [63:0] if_word_q = 64'h0000_0013_0000_0013;
    reg [63:0] mem_word_q = 64'd0;
    reg [63:0] mmio_word_q = 64'd0;
    reg        if_valid_q = 1'b0;
    reg        if_halfsel_q = 1'b0;
    reg        mem_in_ram_q = 1'b0;
    (* DONT_TOUCH = "true" *) reg [RAM_ADDR_W-1:0] bram_store_word_idx_q = '0;
    (* DONT_TOUCH = "true" *) reg [63:0] bram_store_word_q = 64'd0;
    (* DONT_TOUCH = "true" *) reg bram_store_we_q = 1'b0;

    wire [63:0] if_offset = if_req_addr_i - RAM_BASE;
    wire [RAM_ADDR_W-1:0] if_word_idx = if_offset[RAM_ADDR_W+2:3];
    wire if_in_ram = (if_offset >> 3) < RAM_WORDS_64;

    wire [63:0] mem_offset = mem_req_addr_i - RAM_BASE;
    wire [RAM_ADDR_W-1:0] mem_word_idx = mem_offset[RAM_ADDR_W+2:3];
    wire mem_in_ram = (mem_offset >> 3) < RAM_WORDS_64;

    wire [63:0] store_offset = mem_store_addr_i - RAM_BASE;
    wire [RAM_ADDR_W-1:0] store_word_idx = store_offset[RAM_ADDR_W+2:3];
    wire store_in_ram = (store_offset >> 3) < RAM_WORDS_64;

    integer i;
    initial begin
        for (i = 0; i < RAM_WORDS; i = i + 1) begin
            bram[i] = 64'h0000_0013_0000_0013;
            bram_mem[i] = 64'h0000_0013_0000_0013;
        end
`include "risky_genesys2_bram_init.vh"
        for (i = 0; i < RAM_WORDS; i = i + 1) begin
            bram_mem[i] = bram[i];
        end
    end

    always @(posedge clk_i) begin
        if (!rst_ni) begin
            if_valid_q <= 1'b0;
            if_halfsel_q <= 1'b0;
            mem_in_ram_q <= 1'b1;
            bram_store_word_idx_q <= '0;
            bram_store_word_q <= 64'd0;
            bram_store_we_q <= 1'b0;
        end else begin
            if_valid_q <= if_req_valid_i;
            if_halfsel_q <= if_req_addr_i[2];
            mem_in_ram_q <= mem_req_valid_i && !mem_req_write_i && mem_in_ram;
            bram_store_word_idx_q <= store_word_idx;
            bram_store_word_q <= mem_store_word_i;
            bram_store_we_q <= mem_store_valid_i && store_in_ram;
        end
    end

    always @(posedge clk_i) begin
        if (!rst_ni) begin
            if_word_q <= bram[0];
            mem_word_q <= 64'd0;
            mmio_word_q <= 64'd0;
        end else begin
            if_word_q <= (if_req_valid_i && if_in_ram) ? bram[if_word_idx] : 64'h0000_0013_0000_0013;
            if (mem_req_valid_i && !mem_req_write_i) begin
                if (mem_in_ram) begin
                    mem_word_q <= bram_mem[mem_word_idx];
                end else begin
                    mmio_word_q <= mmio_rdata_i;
                end
            end
        end
        if (rst_ni && bram_store_we_q) begin
            bram[bram_store_word_idx_q] <= bram_store_word_q;
            bram_mem[bram_store_word_idx_q] <= bram_store_word_q;
        end
    end

    assign if_rsp_data_o = if_valid_q
        ? (if_halfsel_q ? if_word_q[63:32] : if_word_q[31:0])
        : 32'h0000_0013;
    assign mem_rsp_data_o = mem_in_ram_q ? mem_word_q : mmio_word_q;
endmodule
