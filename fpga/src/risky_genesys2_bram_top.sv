// Genesys 2 BRAM bring-up top for real board execution of a tiny program.
//
// This target uses a patched FPGA export of pipeline_core that exposes the
// existing fetch/load data and store side-channel registers as ports, then
// attaches small synthesizable BRAM and LED MMIO. It is for bare-metal board
// bring-up before DDR, UART, interrupts, storage, and RTL Sv39 PTW.

module risky_genesys2_bram_top (
    input  wire       clk200_p,
    input  wire       clk200_n,
    input  wire       cpu_resetn,
    input  wire       rx,
    output wire       tx,
    output wire [7:0] led,
    output wire       fan_pwm
);
    localparam logic [63:0] RAM_BASE = 64'h0000_0000_8000_0000;
    localparam logic [63:0] LED_MMIO = 64'h0000_0000_1000_0000;
    localparam int RAM_WORDS = 1024;
    localparam logic [63:0] RAM_WORDS_64 = 64'd1024;

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

    wire [63:0] core_pc;
    wire [63:0] core_mem_addr;
    wire        core_store_valid;
    wire [63:0] core_store_addr;
    wire [63:0] core_store_word;
    wire [31:0] core_imem_rdata;
    wire [63:0] core_mem_rdata;

    reg [63:0] bram [0:RAM_WORDS-1];
    reg [7:0] led_q = 8'h00;
    reg [31:0] heartbeat_q = 32'd0;

    wire [63:0] pc_offset = core_pc - RAM_BASE;
    wire [63:0] mem_offset = core_mem_addr - RAM_BASE;
    wire [63:0] store_offset = core_store_addr - RAM_BASE;

    wire pc_in_ram = core_pc >= RAM_BASE && (pc_offset >> 3) < RAM_WORDS_64;
    wire mem_in_ram = core_mem_addr >= RAM_BASE && (mem_offset >> 3) < RAM_WORDS_64;
    wire store_in_ram = core_store_addr >= RAM_BASE && (store_offset >> 3) < RAM_WORDS_64;

    wire [9:0] pc_word_idx = pc_offset[12:3];
    wire [2:0] pc_byte_idx = core_pc[2:0];
    wire [9:0] mem_word_idx = mem_offset[12:3];
    wire [9:0] store_word_idx = store_offset[12:3];

    wire [63:0] fetch_word = pc_in_ram ? bram[pc_word_idx] : 64'h0000_0013_0000_0013;
    assign core_imem_rdata = pc_byte_idx[2] ? fetch_word[63:32] : fetch_word[31:0];
    assign core_mem_rdata = mem_in_ram ? bram[mem_word_idx] : 64'd0;

    integer i;
    initial begin
        for (i = 0; i < RAM_WORDS; i = i + 1) begin
            bram[i] = 64'h0000_0013_0000_0013; // NOP/NOP
        end

        // Bare-metal program at 0x80000000:
        //   lui   t0, 0x10000      # LED MMIO base 0x10000000
        //   addi  t1, x0, 0x5a
        //   sw    t1, 0(t0)        # LEDs show 0x5a
        //   jal   x0, 0            # hold
        bram[0] = 64'h05a0_0313_1000_02b7;
        bram[1] = 64'h0000_006f_0062_a023;
    end

    always @(posedge clk200 or negedge rst_ni) begin
        if (!rst_ni) begin
            led_q <= 8'h00;
            heartbeat_q <= 32'd0;
        end else begin
            heartbeat_q <= heartbeat_q + 32'd1;
            if (core_store_valid && store_in_ram) begin
                bram[store_word_idx] <= core_store_word;
            end
            if (core_store_valid && core_store_addr == LED_MMIO) begin
                led_q <= core_store_word[7:0];
            end
        end
    end

    pipeline_core_bram_if i_core (
        .clk_i              (clk200),
        .rst_ni             (rst_ni),
        .imem_rdata_i       (core_imem_rdata),
        .mem_rdata_i        (core_mem_rdata),
        .pc_o               (core_pc),
        .mem_addr_o         (core_mem_addr),
        .mem_store_valid_o  (core_store_valid),
        .mem_store_addr_o   (core_store_addr),
        .mem_store_word_o   (core_store_word)
    );

    assign led[0] = rst_ni;
    assign led[1] = heartbeat_q[25];
    assign led[7:2] = led_q[5:0];

    assign tx = 1'b1;
    assign fan_pwm = 1'b1;

    wire unused_rx = rx;
endmodule
