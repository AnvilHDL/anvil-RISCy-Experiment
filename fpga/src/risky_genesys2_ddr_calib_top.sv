// DDR3 calibration and AXI smoke-test top for Digilent Genesys 2.
//
// This target isolates the CVA6-style MIG configuration from the RISCy core so
// board DDR3 bring-up can proceed even while the full core path is being timed.

module risky_genesys2_ddr_calib_top (
    input  wire       clk200_p,
    input  wire       clk200_n,
    input  wire       cpu_resetn,
    input  wire       rx,
    output wire       tx,
    output wire [7:0] led,
    output wire       fan_pwm,

    inout  wire [31:0] ddr3_dq,
    inout  wire [3:0]  ddr3_dqs_n,
    inout  wire [3:0]  ddr3_dqs_p,
    output wire [14:0] ddr3_addr,
    output wire [2:0]  ddr3_ba,
    output wire        ddr3_ras_n,
    output wire        ddr3_cas_n,
    output wire        ddr3_we_n,
    output wire        ddr3_reset_n,
    output wire [0:0]  ddr3_ck_p,
    output wire [0:0]  ddr3_ck_n,
    output wire [0:0]  ddr3_cke,
    output wire [0:0]  ddr3_cs_n,
    output wire [3:0]  ddr3_dm,
    output wire [0:0]  ddr3_odt
);
    assign tx = 1'b1;
    assign fan_pwm = 1'b1;
    wire _unused_rx = rx;

    wire ui_clk;
    wire ui_clk_sync_rst;
    wire mmcm_locked;
    wire init_calib_complete;

    reg  [4:0]  s_axi_awid;
    reg  [29:0] s_axi_awaddr;
    wire [7:0]  s_axi_awlen = 8'd0;
    wire [2:0]  s_axi_awsize = 3'd3;
    wire [1:0]  s_axi_awburst = 2'b01;
    wire [0:0]  s_axi_awlock = 1'b0;
    wire [3:0]  s_axi_awcache = 4'b0011;
    wire [2:0]  s_axi_awprot = 3'b000;
    wire [3:0]  s_axi_awqos = 4'd0;
    reg         s_axi_awvalid;
    wire        s_axi_awready;
    reg  [63:0] s_axi_wdata;
    reg  [7:0]  s_axi_wstrb;
    wire        s_axi_wlast = 1'b1;
    reg         s_axi_wvalid;
    wire        s_axi_wready;
    wire        s_axi_bready = 1'b1;
    wire [4:0]  s_axi_bid;
    wire [1:0]  s_axi_bresp;
    wire        s_axi_bvalid;
    reg  [4:0]  s_axi_arid;
    reg  [29:0] s_axi_araddr;
    wire [7:0]  s_axi_arlen = 8'd0;
    wire [2:0]  s_axi_arsize = 3'd3;
    wire [1:0]  s_axi_arburst = 2'b01;
    wire [0:0]  s_axi_arlock = 1'b0;
    wire [3:0]  s_axi_arcache = 4'b0011;
    wire [2:0]  s_axi_arprot = 3'b000;
    wire [3:0]  s_axi_arqos = 4'd0;
    reg         s_axi_arvalid;
    wire        s_axi_arready;
    wire        s_axi_rready = 1'b1;
    wire [4:0]  s_axi_rid;
    wire [63:0] s_axi_rdata;
    wire [1:0]  s_axi_rresp;
    wire        s_axi_rlast;
    wire        s_axi_rvalid;
    wire        app_sr_active;
    wire        app_ref_ack;
    wire        app_zq_ack;
    wire [11:0] device_temp;

    wire _unused_axi = |s_axi_bid | |s_axi_rid | s_axi_rlast |
                       app_sr_active | app_ref_ack | app_zq_ack | |device_temp;

    mig_7series_0 i_mig (
        .ddr3_dq        (ddr3_dq),
        .ddr3_dqs_n     (ddr3_dqs_n),
        .ddr3_dqs_p     (ddr3_dqs_p),
        .ddr3_addr      (ddr3_addr),
        .ddr3_ba        (ddr3_ba),
        .ddr3_ras_n     (ddr3_ras_n),
        .ddr3_cas_n     (ddr3_cas_n),
        .ddr3_we_n      (ddr3_we_n),
        .ddr3_reset_n   (ddr3_reset_n),
        .ddr3_ck_p      (ddr3_ck_p),
        .ddr3_ck_n      (ddr3_ck_n),
        .ddr3_cke       (ddr3_cke),
        .ddr3_cs_n      (ddr3_cs_n),
        .ddr3_dm        (ddr3_dm),
        .ddr3_odt       (ddr3_odt),
        .sys_clk_p      (clk200_p),
        .sys_clk_n      (clk200_n),
        .aresetn        (cpu_resetn),
        .s_axi_awid     (s_axi_awid),
        .s_axi_awaddr   (s_axi_awaddr),
        .s_axi_awlen    (s_axi_awlen),
        .s_axi_awsize   (s_axi_awsize),
        .s_axi_awburst  (s_axi_awburst),
        .s_axi_awlock   (s_axi_awlock),
        .s_axi_awcache  (s_axi_awcache),
        .s_axi_awprot   (s_axi_awprot),
        .s_axi_awqos    (s_axi_awqos),
        .s_axi_awvalid  (s_axi_awvalid),
        .s_axi_awready  (s_axi_awready),
        .s_axi_wdata    (s_axi_wdata),
        .s_axi_wstrb    (s_axi_wstrb),
        .s_axi_wlast    (s_axi_wlast),
        .s_axi_wvalid   (s_axi_wvalid),
        .s_axi_wready   (s_axi_wready),
        .s_axi_bready   (s_axi_bready),
        .s_axi_bid      (s_axi_bid),
        .s_axi_bresp    (s_axi_bresp),
        .s_axi_bvalid   (s_axi_bvalid),
        .s_axi_arid     (s_axi_arid),
        .s_axi_araddr   (s_axi_araddr),
        .s_axi_arlen    (s_axi_arlen),
        .s_axi_arsize   (s_axi_arsize),
        .s_axi_arburst  (s_axi_arburst),
        .s_axi_arlock   (s_axi_arlock),
        .s_axi_arcache  (s_axi_arcache),
        .s_axi_arprot   (s_axi_arprot),
        .s_axi_arqos    (s_axi_arqos),
        .s_axi_arvalid  (s_axi_arvalid),
        .s_axi_arready  (s_axi_arready),
        .s_axi_rready   (s_axi_rready),
        .s_axi_rid      (s_axi_rid),
        .s_axi_rdata    (s_axi_rdata),
        .s_axi_rresp    (s_axi_rresp),
        .s_axi_rlast    (s_axi_rlast),
        .s_axi_rvalid   (s_axi_rvalid),
        .app_sr_req     (1'b0),
        .app_ref_req    (1'b0),
        .app_zq_req     (1'b0),
        .app_sr_active  (app_sr_active),
        .app_ref_ack    (app_ref_ack),
        .app_zq_ack     (app_zq_ack),
        .ui_clk         (ui_clk),
        .ui_clk_sync_rst(ui_clk_sync_rst),
        .init_calib_complete(init_calib_complete),
        .mmcm_locked    (mmcm_locked),
        .device_temp    (device_temp),
        .sys_rst        (cpu_resetn)
    );

    typedef enum logic [2:0] {
        WAIT_CALIB = 3'd0,
        SEND_AW    = 3'd1,
        SEND_W     = 3'd2,
        WAIT_B     = 3'd3,
        SEND_AR    = 3'd4,
        WAIT_R     = 3'd5,
        PASS       = 3'd6,
        FAIL       = 3'd7
    } state_t;

    localparam logic [63:0] TEST_WORD = 64'h0123_4567_89ab_cdef;

    reg [7:0]  reset_sync_q = 8'h00;
    reg [31:0] heartbeat_q = 32'd0;
    reg        write_ok_q = 1'b0;
    reg        read_ok_q = 1'b0;
    reg        fail_q = 1'b0;
    state_t    state_q = WAIT_CALIB;

    wire run_reset_n = cpu_resetn && !ui_clk_sync_rst && init_calib_complete;

    always @(posedge ui_clk or negedge run_reset_n) begin
        if (!run_reset_n) reset_sync_q <= 8'h00;
        else              reset_sync_q <= {reset_sync_q[6:0], 1'b1};
    end

    always @(posedge ui_clk) begin
        if (!reset_sync_q[7]) begin
            heartbeat_q   <= 32'd0;
            write_ok_q    <= 1'b0;
            read_ok_q     <= 1'b0;
            fail_q        <= 1'b0;
            state_q       <= WAIT_CALIB;
            s_axi_awid    <= 5'd0;
            s_axi_awaddr  <= 30'd0;
            s_axi_awvalid <= 1'b0;
            s_axi_wdata   <= TEST_WORD;
            s_axi_wstrb   <= 8'hff;
            s_axi_wvalid  <= 1'b0;
            s_axi_arid    <= 5'd0;
            s_axi_araddr  <= 30'd0;
            s_axi_arvalid <= 1'b0;
        end else begin
            heartbeat_q <= heartbeat_q + 32'd1;
            case (state_q)
                WAIT_CALIB: begin
                    state_q <= SEND_AW;
                end

                SEND_AW: begin
                    s_axi_awaddr  <= 30'd0;
                    s_axi_awvalid <= 1'b1;
                    if (s_axi_awready) begin
                        s_axi_awvalid <= 1'b0;
                        state_q <= SEND_W;
                    end
                end

                SEND_W: begin
                    s_axi_wdata  <= TEST_WORD;
                    s_axi_wstrb  <= 8'hff;
                    s_axi_wvalid <= 1'b1;
                    if (s_axi_wready) begin
                        s_axi_wvalid <= 1'b0;
                        state_q <= WAIT_B;
                    end
                end

                WAIT_B: begin
                    if (s_axi_bvalid) begin
                        write_ok_q <= s_axi_bresp == 2'b00;
                        state_q <= (s_axi_bresp == 2'b00) ? SEND_AR : FAIL;
                    end
                end

                SEND_AR: begin
                    s_axi_araddr  <= 30'd0;
                    s_axi_arvalid <= 1'b1;
                    if (s_axi_arready) begin
                        s_axi_arvalid <= 1'b0;
                        state_q <= WAIT_R;
                    end
                end

                WAIT_R: begin
                    if (s_axi_rvalid) begin
                        read_ok_q <= (s_axi_rresp == 2'b00) && (s_axi_rdata == TEST_WORD);
                        state_q <= ((s_axi_rresp == 2'b00) && (s_axi_rdata == TEST_WORD)) ? PASS : FAIL;
                    end
                end

                PASS: begin
                    state_q <= PASS;
                end

                FAIL: begin
                    fail_q <= 1'b1;
                    state_q <= FAIL;
                end

                default: state_q <= FAIL;
            endcase
        end
    end

    assign led[0] = cpu_resetn;
    assign led[1] = heartbeat_q[22];
    assign led[2] = mmcm_locked;
    assign led[3] = init_calib_complete;
    assign led[4] = s_axi_awvalid | s_axi_wvalid | s_axi_arvalid;
    assign led[5] = write_ok_q;
    assign led[6] = read_ok_q;
    assign led[7] = fail_q;
endmodule
