module risky_plic (
    input  wire        clk_i,
    input  wire        rst_ni,
    input  wire [63:0] mem_addr_i,
    input  wire        claim_read_i,
    input  wire [63:0] claim_addr_i,
    input  wire        store_valid_i,
    input  wire [63:0] store_addr_i,
    input  wire [63:0] store_data_i,
    input  wire        uart_irq_i,
    input  wire        virtio_irq_i,
    output reg  [63:0] mem_rdata_o,
    output wire [63:0] ext_mip_o
);
    localparam logic [63:0] PLIC_BASE        = 64'h0000_0000_0c00_0000;
    localparam logic [63:0] PLIC_PENDING     = 64'h0000_0000_0c00_1000;
    localparam logic [63:0] PLIC_ENABLE_S0   = 64'h0000_0000_0c00_2080;
    localparam logic [63:0] PLIC_SPRIORITY0  = 64'h0000_0000_0c20_1000;
    localparam logic [63:0] PLIC_SCLAIM0     = 64'h0000_0000_0c20_1004;
    localparam int VIRTIO_IRQ_ID = 1;
    localparam int UART_IRQ_ID = 10;

    reg [2:0] priority_virtio_q = 3'd1;
    reg [2:0] priority_uart_q = 3'd1;
    reg [31:0] enable_s_q = 32'd0;
    reg [2:0] threshold_q = 3'd0;
    reg pending_virtio_q = 1'b0;
    reg pending_uart_q = 1'b0;

    wire [2:0] best_irq_prio =
        (pending_uart_q && enable_s_q[UART_IRQ_ID] && priority_uart_q > threshold_q) ? priority_uart_q :
        (pending_virtio_q && enable_s_q[VIRTIO_IRQ_ID] && priority_virtio_q > threshold_q) ? priority_virtio_q :
        3'd0;
    wire [31:0] best_irq_id =
        (pending_uart_q && enable_s_q[UART_IRQ_ID] && priority_uart_q == best_irq_prio && best_irq_prio != 3'd0) ? UART_IRQ_ID :
        (pending_virtio_q && enable_s_q[VIRTIO_IRQ_ID] && priority_virtio_q == best_irq_prio && best_irq_prio != 3'd0) ? VIRTIO_IRQ_ID :
        32'd0;

    wire [2:0] mem_byte_off = mem_addr_i[2:0];
    wire [63:0] claim_rdata = {32'd0, best_irq_id} << (mem_byte_off * 8);
    wire [31:0] pending_word_32 = ({31'd0, pending_uart_q} << UART_IRQ_ID) |
                                  ({31'd0, pending_virtio_q} << VIRTIO_IRQ_ID);
    wire [63:0] pending_bits = {32'd0, pending_word_32} << (mem_byte_off * 8);
    wire [63:0] enable_rdata = {32'd0, enable_s_q} << (mem_byte_off * 8);
    wire [63:0] threshold_rdata = {61'd0, threshold_q} << (mem_byte_off * 8);

    function automatic [31:0] store_word32;
        input [63:0] addr;
        input [63:0] data;
        reg [63:0] shifted;
        begin
            shifted = data >> (addr[2:0] * 8);
            store_word32 = shifted[31:0];
        end
    endfunction

    wire [31:0] store_word = store_word32(store_addr_i, store_data_i);

    always @* begin
        mem_rdata_o = 64'd0;
        if ((mem_addr_i & 64'hffff_ffff_ffff_fffc) == PLIC_SCLAIM0) begin
            mem_rdata_o = claim_rdata;
        end else if ((mem_addr_i & 64'hffff_ffff_ffff_fffc) == PLIC_SPRIORITY0) begin
            mem_rdata_o = threshold_rdata;
        end else if ((mem_addr_i & 64'hffff_ffff_ffff_fffc) == PLIC_ENABLE_S0) begin
            mem_rdata_o = enable_rdata;
        end else if ((mem_addr_i & 64'hffff_ffff_ffff_fffc) == PLIC_PENDING) begin
            mem_rdata_o = pending_bits;
        end else if ((mem_addr_i & 64'hffff_ffff_ffff_fffc) == (PLIC_BASE + 64'd4 * UART_IRQ_ID)) begin
            mem_rdata_o = {61'd0, priority_uart_q} << (mem_byte_off * 8);
        end else if ((mem_addr_i & 64'hffff_ffff_ffff_fffc) == (PLIC_BASE + 64'd4 * VIRTIO_IRQ_ID)) begin
            mem_rdata_o = {61'd0, priority_virtio_q} << (mem_byte_off * 8);
        end
    end

    always @(posedge clk_i) begin
        if (!rst_ni) begin
            priority_virtio_q <= 3'd1;
            priority_uart_q <= 3'd1;
            enable_s_q <= 32'd0;
            threshold_q <= 3'd0;
            pending_virtio_q <= 1'b0;
            pending_uart_q <= 1'b0;
        end else begin
            if (uart_irq_i) begin
                pending_uart_q <= 1'b1;
            end
            if (virtio_irq_i) begin
                pending_virtio_q <= 1'b1;
            end

            if (store_valid_i) begin
                if ((store_addr_i & 64'hffff_ffff_ffff_fffc) == PLIC_ENABLE_S0) begin
                    enable_s_q <= store_word;
                end else if ((store_addr_i & 64'hffff_ffff_ffff_fffc) == PLIC_SPRIORITY0) begin
                    threshold_q <= store_word[2:0];
                end else if ((store_addr_i & 64'hffff_ffff_ffff_fffc) == (PLIC_BASE + 64'd4 * UART_IRQ_ID)) begin
                    priority_uart_q <= store_word[2:0];
                end else if ((store_addr_i & 64'hffff_ffff_ffff_fffc) == (PLIC_BASE + 64'd4 * VIRTIO_IRQ_ID)) begin
                    priority_virtio_q <= store_word[2:0];
                end else if ((store_addr_i & 64'hffff_ffff_ffff_fffc) == PLIC_SCLAIM0) begin
                    if (store_word == UART_IRQ_ID[31:0]) begin
                        pending_uart_q <= 1'b0;
                    end
                    if (store_word == VIRTIO_IRQ_ID[31:0]) begin
                        pending_virtio_q <= 1'b0;
                    end
                end
            end

            if (claim_read_i && (claim_addr_i & 64'hffff_ffff_ffff_fffc) == PLIC_SCLAIM0 && best_irq_id != 32'd0) begin
                if (best_irq_id == UART_IRQ_ID[31:0]) begin
                    pending_uart_q <= 1'b0;
                end
                if (best_irq_id == VIRTIO_IRQ_ID[31:0]) begin
                    pending_virtio_q <= 1'b0;
                end
            end
        end
    end

    assign ext_mip_o = (best_irq_id != 32'd0) ? 64'h0000_0000_0000_0200 : 64'd0;
endmodule
