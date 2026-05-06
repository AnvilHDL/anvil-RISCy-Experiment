/* verilator lint_off MULTITOP */
// risky_ptw.sv — Synthesizable Sv39 Three-Level Page Table Walker
//
// Sits between the core's virtual address observation ports and the sv39_* inputs.
// Handles both instruction-fetch (IF) and data-memory (MEM) walks.
// One walk at a time; MEM takes priority over IF.
//
// Interface (all synchronous, 25 MHz):
//   clk_i / rst_ni                     — clock / active-low reset
//   satp_i                             — core's satp CSR (mode[63:60], ASID, PPN)
//   priv_i[1:0]                        — current privilege (2=M, 1=S, 0=U)
//   sv39_flush_i                       — TLB flush: invalidate all entries
//
//   if_va_i / if_req_i                 — IF virtual address + request pulse
//   mem_va_i / mem_req_i / mem_write_i — MEM virtual address + request + write flag
//
//   mem_if_req_o / mem_if_addr_o       — physical read to memory arbiter (PTW reads)
//   mem_if_rvalid_i / mem_if_rdata_i   — response from memory arbiter
//
//   sv39_stall_o                       — hold the pipeline while walk is in progress
//   sv39_if_valid_o / sv39_if_pa_o     — resolved IF physical address
//   sv39_if_pf_o                       — IF page fault
//   sv39_mem_valid_o / sv39_mem_pa_o   — resolved MEM physical address
//   sv39_mem_pf_o / sv39_mem_pf_store_o— MEM page fault (load / store)

module risky_ptw #(
    parameter int TLB_ENTRIES = 8
) (
    input  wire        clk_i,
    input  wire        rst_ni,

    // Core observation inputs
    input  wire [63:0] satp_i,
    input  wire [1:0]  priv_i,
    input  wire        sv39_flush_i,

    // IF request
    input  wire [63:0] if_va_i,
    input  wire        if_req_i,

    // MEM request
    input  wire [63:0] mem_va_i,
    input  wire        mem_req_i,
    input  wire        mem_write_i,

    // Physical memory port (to arbiter, dedicated PTW channel)
    output reg         ptw_mem_req_o,
    output reg  [63:0] ptw_mem_addr_o,
    input  wire        ptw_mem_rvalid_i,
    input  wire [63:0] ptw_mem_rdata_i,

    // Outputs back to core (sv39_* inputs)
    output reg         sv39_stall_o,
    output reg         sv39_if_valid_o,
    output reg  [63:0] sv39_if_pa_o,
    output reg         sv39_if_pf_o,
    output reg         sv39_mem_valid_o,
    output reg  [63:0] sv39_mem_pa_o,
    output reg         sv39_mem_pf_o,
    output reg         sv39_mem_pf_store_o
);

    // -------------------------------------------------------------------------
    // Sv39 constants
    // -------------------------------------------------------------------------
    localparam logic [3:0] SATP_MODE_SV39 = 4'h8;
    localparam int LEVELS = 3;

    // PTE fields
    // [0]    V — valid
    // [1]    R — read
    // [2]    W — write
    // [3]    X — execute
    // [4]    U — user
    // [5]    G — global
    // [6]    A — accessed
    // [7]    D — dirty
    // [9:8]  RSW
    // [53:10] PPN

    // -------------------------------------------------------------------------
    // Simple direct-mapped TLB (VA tag → PA + protection bits)
    // -------------------------------------------------------------------------
    localparam int TLB_IDX_W = $clog2(TLB_ENTRIES);

    reg [26:0] tlb_vpn  [0:TLB_ENTRIES-1];   // VPN[2] (9 bits) of the 4KB page
    reg [43:0] tlb_ppn  [0:TLB_ENTRIES-1];   // PPN of translated page
    reg [3:0]  tlb_prot [0:TLB_ENTRIES-1];   // {D, X, W, R}
    reg        tlb_v    [0:TLB_ENTRIES-1];   // valid
    reg [8:0]  tlb_asid [0:TLB_ENTRIES-1];

    // Use VA[20:12] as index (9-bit VPN[0]) and VA[38:12] as the full tag
    wire [TLB_IDX_W-1:0] if_tlb_idx  = if_va_i[TLB_IDX_W-1+12:12];
    wire [TLB_IDX_W-1:0] mem_tlb_idx = mem_va_i[TLB_IDX_W-1+12:12];
    wire [8:0]  cur_asid = satp_i[8:0];  // use lower 9 bits of ASID[15:0] for TLB tag

    wire if_tlb_hit  = tlb_v[if_tlb_idx]  && tlb_asid[if_tlb_idx] == cur_asid[8:0]
                       && tlb_vpn[if_tlb_idx] == if_va_i[38:12];
    wire mem_tlb_hit = tlb_v[mem_tlb_idx] && tlb_asid[mem_tlb_idx] == cur_asid[8:0]
                       && tlb_vpn[mem_tlb_idx] == mem_va_i[38:12];

    wire [63:0] if_tlb_pa  = {8'd0, tlb_ppn[if_tlb_idx],  if_va_i[11:0]};
    wire [63:0] mem_tlb_pa = {8'd0, tlb_ppn[mem_tlb_idx], mem_va_i[11:0]};

    // -------------------------------------------------------------------------
    // PTW FSM
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {
        IDLE    = 3'd0,
        WALK_L2 = 3'd1,
        WALK_L1 = 3'd2,
        WALK_L0 = 3'd3,
        DONE    = 3'd4,
        FAULT   = 3'd5
    } ptw_state_t;

    ptw_state_t state_q = IDLE;

    reg         walking_if_q  = 1'b0;   // 1=IF walk, 0=MEM walk
    reg [63:0]  walk_va_q     = 64'd0;
    reg         walk_write_q  = 1'b0;
    reg [63:0]  pte_q         = 64'd0;
    reg [1:0]   level_q       = 2'd2;   // 2→1→0

    // Satp fields
    wire sv39_active = (satp_i[63:60] == SATP_MODE_SV39) && (priv_i != 2'b11);
    wire [43:0] satp_ppn = satp_i[43:0];

    // VPN extraction from current walk VA
    wire [8:0] vpn2 = walk_va_q[38:30];
    wire [8:0] vpn1 = walk_va_q[29:21];
    wire [8:0] vpn0 = walk_va_q[20:12];

    // PTE from last memory read
    wire pte_v  = pte_q[0];
    wire pte_r  = pte_q[1];
    wire pte_w  = pte_q[2];
    wire pte_x  = pte_q[3];
    wire pte_u  = pte_q[4];
    wire [43:0] pte_ppn = pte_q[53:10];
    wire pte_is_leaf = pte_v && (pte_r || pte_x);
    wire pte_is_ptr  = pte_v && !pte_r && !pte_x;

    // Access permission check
    wire pte_perm_ok = pte_is_leaf &&
        (!walk_write_q ? (pte_r) : (pte_w)) &&
        (walking_if_q ? pte_x : 1'b1);

    // Physical address from leaf PTE
    wire [63:0] leaf_pa = {8'd0, pte_ppn, walk_va_q[11:0]};

    // PTE address computation
    reg  [63:0] pte_addr_q = 64'd0;

    function automatic [63:0] pte_addr_at;
        input [43:0] ppn;
        input [8:0]  vpn;
        begin
            pte_addr_at = {8'd0, ppn, vpn, 3'd0};  // ppn*4096 + vpn*8
        end
    endfunction

    integer j;

    always @(posedge clk_i) begin
        if (!rst_ni) begin
            state_q           <= IDLE;
            sv39_stall_o      <= 1'b0;
            sv39_if_valid_o   <= 1'b0;
            sv39_if_pa_o      <= 64'd0;
            sv39_if_pf_o      <= 1'b0;
            sv39_mem_valid_o  <= 1'b0;
            sv39_mem_pa_o     <= 64'd0;
            sv39_mem_pf_o     <= 1'b0;
            sv39_mem_pf_store_o <= 1'b0;
            ptw_mem_req_o     <= 1'b0;
            ptw_mem_addr_o    <= 64'd0;
            walking_if_q      <= 1'b0;
            walk_va_q         <= 64'd0;
            walk_write_q      <= 1'b0;
            pte_q             <= 64'd0;
            pte_addr_q        <= 64'd0;
            level_q           <= 2'd2;
            for (j = 0; j < TLB_ENTRIES; j = j + 1) begin
                tlb_v[j] <= 1'b0;
            end
        end else begin
            // Default pulse signals off
            sv39_if_valid_o     <= 1'b0;
            sv39_if_pf_o        <= 1'b0;
            sv39_mem_valid_o    <= 1'b0;
            sv39_mem_pf_o       <= 1'b0;
            sv39_mem_pf_store_o <= 1'b0;
            ptw_mem_req_o       <= 1'b0;

            // TLB flush
            if (sv39_flush_i) begin
                for (j = 0; j < TLB_ENTRIES; j = j + 1)
                    tlb_v[j] <= 1'b0;
            end

            case (state_q)
                // -----------------------------------------------------------------
                IDLE: begin
                    sv39_stall_o <= 1'b0;
                    if (!sv39_active) begin
                        // M-mode or bare: pass through directly
                        if (if_req_i) begin
                            sv39_if_valid_o <= 1'b1;
                            sv39_if_pa_o    <= if_va_i;
                        end
                        if (mem_req_i) begin
                            sv39_mem_valid_o <= 1'b1;
                            sv39_mem_pa_o    <= mem_va_i;
                        end
                    end else begin
                        // --- MEM takes priority over IF ---
                        if (mem_req_i && !mem_tlb_hit) begin
                            // MEM miss — start walk
                            sv39_stall_o <= 1'b1;
                            walking_if_q <= 1'b0;
                            walk_va_q    <= mem_va_i;
                            walk_write_q <= mem_write_i;
                            level_q      <= 2'd2;
                            pte_addr_q   <= pte_addr_at(satp_ppn, mem_va_i[38:30]);
                            ptw_mem_req_o  <= 1'b1;
                            ptw_mem_addr_o <= pte_addr_at(satp_ppn, mem_va_i[38:30]);
                            state_q      <= WALK_L2;
                        end else if (mem_req_i && mem_tlb_hit) begin
                            // MEM TLB hit
                            sv39_mem_valid_o <= 1'b1;
                            sv39_mem_pa_o    <= mem_tlb_pa;
                        end else if (if_req_i && !if_tlb_hit) begin
                            // IF miss — start walk
                            sv39_stall_o <= 1'b1;
                            walking_if_q <= 1'b1;
                            walk_va_q    <= if_va_i;
                            walk_write_q <= 1'b0;
                            level_q      <= 2'd2;
                            pte_addr_q   <= pte_addr_at(satp_ppn, if_va_i[38:30]);
                            ptw_mem_req_o  <= 1'b1;
                            ptw_mem_addr_o <= pte_addr_at(satp_ppn, if_va_i[38:30]);
                            state_q      <= WALK_L2;
                        end else if (if_req_i && if_tlb_hit) begin
                            // IF TLB hit
                            sv39_if_valid_o <= 1'b1;
                            sv39_if_pa_o    <= if_tlb_pa;
                        end
                    end
                end

                // -----------------------------------------------------------------
                // Wait for PTE from memory, then decide: descend or leaf
                // -----------------------------------------------------------------
                WALK_L2, WALK_L1, WALK_L0: begin
                    sv39_stall_o <= 1'b1;
                    if (ptw_mem_rvalid_i) begin
                        pte_q <= ptw_mem_rdata_i;
                        if (!ptw_mem_rdata_i[0]) begin
                            // Invalid PTE → fault
                            state_q <= FAULT;
                        end else if (ptw_mem_rdata_i[1] || ptw_mem_rdata_i[3]) begin
                            // Leaf PTE
                            if (pte_perm_ok) begin
                                state_q <= DONE;
                            end else begin
                                state_q <= FAULT;
                            end
                        end else begin
                            // Pointer PTE — descend one level
                            if (level_q == 2'd0) begin
                                state_q <= FAULT;  // no more levels
                            end else begin
                                level_q <= level_q - 2'd1;
                                case (level_q - 2'd1)
                                    2'd1: begin
                                        ptw_mem_addr_o <= pte_addr_at(
                                            ptw_mem_rdata_i[53:10], walk_va_q[29:21]);
                                        ptw_mem_req_o <= 1'b1;
                                        state_q <= WALK_L1;
                                    end
                                    2'd0: begin
                                        ptw_mem_addr_o <= pte_addr_at(
                                            ptw_mem_rdata_i[53:10], walk_va_q[20:12]);
                                        ptw_mem_req_o <= 1'b1;
                                        state_q <= WALK_L0;
                                    end
                                    default: state_q <= FAULT;
                                endcase
                            end
                        end
                    end
                end

                // -----------------------------------------------------------------
                DONE: begin
                    // Fill TLB
                    begin
                        automatic logic [TLB_IDX_W-1:0] tidx =
                            walking_if_q ? if_tlb_idx[TLB_IDX_W-1:0]
                                         : mem_tlb_idx[TLB_IDX_W-1:0];
                        tlb_v   [tidx] <= 1'b1;
                        tlb_asid[tidx] <= cur_asid[8:0];
                        tlb_vpn [tidx] <= walk_va_q[38:12];
                        tlb_ppn [tidx] <= pte_ppn;
                        tlb_prot[tidx] <= {pte_q[7], pte_q[3], pte_q[2], pte_q[1]};
                    end
                    // Signal resolved address
                    if (walking_if_q) begin
                        sv39_if_valid_o <= 1'b1;
                        sv39_if_pa_o    <= leaf_pa;
                    end else begin
                        sv39_mem_valid_o <= 1'b1;
                        sv39_mem_pa_o    <= leaf_pa;
                    end
                    sv39_stall_o <= 1'b0;
                    state_q <= IDLE;
                end

                // -----------------------------------------------------------------
                FAULT: begin
                    if (walking_if_q) begin
                        sv39_if_pf_o <= 1'b1;
                    end else begin
                        sv39_mem_pf_o       <= 1'b1;
                        sv39_mem_pf_store_o <= walk_write_q;
                    end
                    sv39_stall_o <= 1'b0;
                    state_q <= IDLE;
                end

                default: state_q <= IDLE;
            endcase
        end
    end
endmodule
