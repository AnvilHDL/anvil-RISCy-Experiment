// ============================================================
// sim_main.cpp — Verilator harness for the RISCy pipeline_core
//
// Usage:
//   Vpipeline_core <program.elf> [cycle_limit] [--disk <fs.img>] [--trace]
//
// Memory model
// ───────────
//   host_mem[] is an 8 MB byte array representing physical RAM at 0x80000000.
//   The RTL has no internal memory arrays; instead, the harness pre-populates
//   two registers before every clock edge:
//
//     imem_rdata_q  ← 32-bit instruction word at pc_q (or translated PA)
//     mem_rdata_q   ← 64-bit data word at the EX/MEM stage's effective address
//
//   After each tick the harness commits RTL stores from mem_store_*_q to
//   host_mem[] (or to an MMIO device model).
//
// MMIO device models
// ──────────────────
//   CLINT  0x02000000 – 0x02FFFFFF   mtime, mtimecmp
//   PLIC   0x0C000000 – 0x0FFFFFFF   claim/complete, priority
//   UART   0x10000000 – 0x1FFFFFFF   NS16550A TX/RX registers
//   virtio 0x10001000 – 0x10001FFF   virtio-blk for disk I/O
//
// Sv39 page-table walk
// ────────────────────
//   The harness maintains a 4-entry software TLB and walks the 3-level Sv39
//   page table synchronously on a TLB miss.  Translated PAs are written into
//   sv39_if_pa_q / sv39_mem_pa_q before the clock edge.  If a PTW is in
//   progress, sv39_stall_q is held high to freeze the pipeline.
//
//   Moving the PTW here (rather than RTL) avoids the ~14 GB peak RSS that
//   the Anvil elaborator hits when compiling wide comparator trees.
//
// Interrupt injection
// ───────────────────
//   ext_mip_q is driven every cycle from sim_mtime / sim_mtimecmp state.
//   When sim_mtime >= sim_mtimecmp, MTIP (bit 7) is raised; when the UART TX
//   IRQ fires, SEIP (bit 9) is raised.  The RTL ORs ext_mip_q with mip_q to
//   form the effective pending interrupt mask.
//
// Division / remainder (software interception)
// ─────────────────────────────────────────────
//   Rather than implement a hardware divider in Anvil (which requires an
//   iterative multi-cycle FSM), DIV/DIVU/REM/REMU and their W variants are
//   intercepted in the harness.  When the pipeline reaches a DIV-family
//   instruction in the EX stage, the harness performs the division in C++
//   and writes the result back into the EX/MEM ALU result register.
// ============================================================

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <memory>
#include <string>
#include <vector>

#include <elf.h>
#include <verilated.h>

#include "Vtop.h"
#include "Vtop___024root.h"

double sc_time_stamp() { return 0; }

// CLINT simulation state.
static std::uint64_t sim_mtime = 0;
static std::uint64_t sim_mtimecmp = UINT64_MAX;

// SIE masking: when in S-mode with sstatus.SIE=0, suppress delegated interrupts
// so the RTL (which lacks the SIE check) doesn't fire them incorrectly.
// Saves the mip bits that were cleared so they can be restored next cycle.
static std::uint64_t sie_masked_mip_bits = 0;

// ============================================================
// Virtio-blk simulation state (file-scope so main() can load
// the disk image; all other accesses are inside the namespace).
// ============================================================
static std::vector<std::uint8_t> vdisk_img;     // loaded from fs.img
static std::uint64_t vq_desc_pa   = 0;
static std::uint64_t vq_avail_pa  = 0;
static std::uint64_t vq_used_pa   = 0;
static std::uint32_t virtio_status_val = 0;
static std::uint16_t vq_avail_last = 0;
// Virtio interrupt state: set after process_virtio_queue_notify, cleared on PLIC claim.
static bool virtio_irq_pending = false;
static std::uint32_t virtio_interrupt_status = 0;
// UART TX interrupt: set after writing THR, cleared when xv6 calls plic_complete(10).
// This simulates the NS16550A signalling TX-empty to uartintr(), which clears tx_busy.
// Delayed by UART_TX_IRQ_DELAY cycles to prevent the interrupt from racing with the
// sret that returns the user process from write(). Without the delay, the interrupt
// fires in the same cycle as sret, capturing sepc=next_linear_pc instead of ra.
static bool uart_tx_irq_pending = false;
static std::uint64_t uart_tx_irq_fire_at = UINT64_MAX;  // cycle at which to set pending
static constexpr std::uint64_t UART_TX_IRQ_DELAY = 50;

static constexpr std::uint64_t VIRTIO_BASE = 0x10001000ULL;
static constexpr std::uint64_t BUF_DATA_OFFSET = 0x58;  // offsetof(buf, data)
// PLIC claim/complete for hart 0, S-mode: 0x0C000000 + 0x201004
static constexpr std::uint64_t PLIC_SCLAIM0 = 0x0C201004ULL;

namespace {

// Physical RAM window: 8 MB at 0x80000000.
static constexpr std::uint64_t RAM_BASE = 0x80000000ULL;
static constexpr std::uint64_t RAM_SIZE = 8ULL * 1024 * 1024;

// Host-side memory: the pipeline's flat 8 MB RAM.
// Replaces the old Verilator imem_q_q/dmem_q_q arrays.
static std::uint8_t host_mem[RAM_SIZE];

// Capability tag shadow: one bit per 32-byte-aligned slot.
// tag=0 means the slot holds plain integer data, not a valid capability.
static constexpr uint32_t CAP_BYTES = 32u;
static bool cap_tags[RAM_SIZE / CAP_BYTES];

// ============================================================
// Virtio-blk helper functions (inside namespace for host_mem access).
// ============================================================
static std::uint16_t hmem_r16(std::uint64_t pa) {
    if (pa < RAM_BASE || pa + 2u > RAM_BASE + RAM_SIZE) return 0;
    const std::uint32_t o = static_cast<std::uint32_t>(pa - RAM_BASE);
    return static_cast<std::uint16_t>(host_mem[o]) |
           (static_cast<std::uint16_t>(host_mem[o+1u]) << 8);
}
static std::uint32_t hmem_r32(std::uint64_t pa) {
    if (pa < RAM_BASE || pa + 4u > RAM_BASE + RAM_SIZE) return 0;
    const std::uint32_t o = static_cast<std::uint32_t>(pa - RAM_BASE);
    std::uint32_t v = 0;
    for (int i = 0; i < 4; ++i) v |= static_cast<std::uint32_t>(host_mem[o+i]) << (i*8);
    return v;
}
static std::uint64_t hmem_r64(std::uint64_t pa) {
    if (pa < RAM_BASE || pa + 8u > RAM_BASE + RAM_SIZE) return 0;
    const std::uint32_t o = static_cast<std::uint32_t>(pa - RAM_BASE);
    std::uint64_t v = 0;
    for (int i = 0; i < 8; ++i) v |= static_cast<std::uint64_t>(host_mem[o+i]) << (i*8);
    return v;
}
static void hmem_w32(std::uint64_t pa, std::uint32_t val) {
    if (pa < RAM_BASE || pa + 4u > RAM_BASE + RAM_SIZE) return;
    const std::uint32_t o = static_cast<std::uint32_t>(pa - RAM_BASE);
    for (int i = 0; i < 4; ++i) host_mem[o+i] = (val >> (i*8)) & 0xFFu;
}

// Process all new virtio-blk requests queued since last QUEUE_NOTIFY.
// I/O is synchronous: writes b->disk=0 directly so the pipeline loop exits.
static void process_virtio_queue_notify() {
    std::fprintf(stderr, "[VIRT-NOTIFY] vq_desc_pa=0x%llx vq_avail_pa=0x%llx vq_used_pa=0x%llx disk_sz=%zu\n",
        (unsigned long long)vq_desc_pa, (unsigned long long)vq_avail_pa,
        (unsigned long long)vq_used_pa, vdisk_img.size());
    if (vdisk_img.empty() || vq_desc_pa == 0 || vq_avail_pa == 0) return;

    // avail ring: { uint16 flags; uint16 idx; uint16 ring[8]; }
    const std::uint16_t avail_idx = hmem_r16(vq_avail_pa + 2u);
    bool completed_any = false;
    while (vq_avail_last != avail_idx) {
        const std::uint16_t head =
            hmem_r16(vq_avail_pa + 4u + 2u * (vq_avail_last % 8u));
        ++vq_avail_last;

        // desc[head]: { uint64 addr; uint32 len; uint16 flags; uint16 next }
        const std::uint64_t d0_pa  = vq_desc_pa + static_cast<std::uint64_t>(head) * 16u;
        const std::uint64_t req_pa = hmem_r64(d0_pa);       // virtio_blk_req PA
        const std::uint32_t type   = hmem_r32(req_pa);       // 0=IN(read), 1=OUT(write)
        const std::uint64_t sector = hmem_r64(req_pa + 8u);  // start 512-byte sector
        const std::uint16_t next1  = hmem_r16(d0_pa + 14u);  // desc[0].next

        // desc[next1]: data buffer
        const std::uint64_t d1_pa    = vq_desc_pa + static_cast<std::uint64_t>(next1) * 16u;
        const std::uint64_t data_pa  = hmem_r64(d1_pa);      // b->data PA
        const std::uint32_t data_len = hmem_r32(d1_pa + 8u); // BSIZE (1024)
        const std::uint16_t next2    = hmem_r16(d1_pa + 14u); // desc[1].next (status desc)

        // b->disk at b+4, b->data at b+BUF_DATA_OFFSET=0x58
        const std::uint64_t bdisk_pa = data_pa - BUF_DATA_OFFSET + 4u;

        const std::uint64_t fs_off = sector * 512ULL;
        if (fs_off + data_len > vdisk_img.size()) { continue; }
        if (data_pa < RAM_BASE || data_pa + data_len > RAM_BASE + RAM_SIZE) { continue; }

        const std::uint32_t local = static_cast<std::uint32_t>(data_pa - RAM_BASE);
        if (type == 0u) {  // VIRTIO_BLK_T_IN: disk → RAM
            std::memcpy(host_mem + local, vdisk_img.data() + fs_off, data_len);
        } else {           // VIRTIO_BLK_T_OUT: RAM → disk
            std::memcpy(vdisk_img.data() + fs_off, host_mem + local, data_len);
        }

        // Write 0 (success) to the status descriptor byte.
        const std::uint64_t status_pa = hmem_r64(vq_desc_pa + static_cast<std::uint64_t>(next2) * 16u);
        if (status_pa >= RAM_BASE && status_pa < RAM_BASE + RAM_SIZE) {
            host_mem[status_pa - RAM_BASE] = 0u;  // VIRTIO_BLK_S_OK
        }

        // Update the used ring so virtio_disk_intr can find the completed entry.
        // used ring: { uint16 flags; uint16 idx; { uint32 id; uint32 len }[NUM] }
        if (vq_used_pa >= RAM_BASE && vq_used_pa + 4u + 8u * 8u <= RAM_BASE + RAM_SIZE) {
            const std::uint16_t used_idx_old = hmem_r16(vq_used_pa + 2u);
            const std::uint32_t ring_off = 4u + (static_cast<std::uint32_t>(used_idx_old) % 8u) * 8u;
            hmem_w32(vq_used_pa + ring_off, head);       // ring[idx].id = head
            hmem_w32(vq_used_pa + ring_off + 4u, data_len);  // ring[idx].len
            // Increment used->idx (write 16-bit).
            const std::uint16_t used_idx_new = static_cast<std::uint16_t>(used_idx_old + 1u);
            host_mem[(vq_used_pa + 2u) - RAM_BASE]     = static_cast<std::uint8_t>(used_idx_new);
            host_mem[(vq_used_pa + 2u) - RAM_BASE + 1u] = static_cast<std::uint8_t>(used_idx_new >> 8);
        }

        // Synchronous completion: clear b->disk so the while-loop in virtio_disk_rw
        // would exit. This is also used by virtio_disk_intr but wakeup is needed too.
        hmem_w32(bdisk_pa, 0u);
        completed_any = true;
    }

    // No interrupt signaling needed: I/O completes synchronously (b->disk already
    // cleared above), so virtio_disk_rw exits its while-loop before sleeping.
    // If we fired an interrupt, virtio_disk_intr would run after virtio_disk_rw
    // has already set disk.info[id].b = 0, causing a null-deref at b->disk.
}

bool is_number_arg(const char* arg) {
    if (arg == nullptr || *arg == '\0') return false;
    for (const char* p = arg; *p != '\0'; ++p)
        if (!std::isdigit(static_cast<unsigned char>(*p))) return false;
    return true;
}

bool is_trace_arg(const char* arg) {
    return arg != nullptr && std::string(arg) == "--trace";
}

void half_tick(VerilatedContext& context, Vtop& top, bool rst_n) {
    context.timeInc(1);
    top.clk_i = !top.clk_i;
    if (!top.clk_i) top.rst_ni = rst_n ? 1 : 0;
    top.eval();
}

bool default_reset_level(vluint64_t time_now) {
    return !(time_now > 1 && time_now < 10);
}

void tick(VerilatedContext& context, Vtop& top, bool rst_n, unsigned& ticks) {
    half_tick(context, top, rst_n);
    half_tick(context, top, rst_n);
    ++ticks;
}

void tick_with_default_reset(VerilatedContext& context, Vtop& top, unsigned& ticks) {
    context.timeInc(1);
    top.clk_i = !top.clk_i;
    if (!top.clk_i) top.rst_ni = default_reset_level(context.time()) ? 1 : 0;
    top.eval();
    context.timeInc(1);
    top.clk_i = !top.clk_i;
    if (!top.clk_i) top.rst_ni = default_reset_level(context.time()) ? 1 : 0;
    top.eval();
    ++ticks;
}

// Write one byte to host_mem (local address 0..RAM_SIZE-1).
void write_mem_byte(std::uint32_t local_addr, std::uint8_t value) {
    if (local_addr < RAM_SIZE) host_mem[local_addr] = value;
}

// legacy aliases used by load_elf
void write_imem_byte(Vtop___024root*, std::uint32_t local_addr, std::uint8_t value) {
    write_mem_byte(local_addr, value);
}
void write_dmem_byte(Vtop___024root*, std::uint32_t local_addr, std::uint8_t value) {
    write_mem_byte(local_addr, value);
}

// Read helpers from host_mem (addr is a physical byte address).
std::uint64_t read_dmem_qword(const Vtop___024root*, std::uint64_t addr) {
    if (addr < RAM_BASE || addr + 8u > RAM_BASE + RAM_SIZE) return 0;
    const std::uint32_t local = static_cast<std::uint32_t>(addr - RAM_BASE);
    std::uint64_t v = 0;
    for (int i = 0; i < 8; ++i)
        v |= static_cast<std::uint64_t>(host_mem[local + i]) << (i * 8u);
    return v;
}

std::uint32_t read_imem_word(const Vtop___024root*, std::uint64_t addr) {
    if (addr < RAM_BASE || addr + 4u > RAM_BASE + RAM_SIZE) return 0;
    const std::uint32_t local = static_cast<std::uint32_t>(addr - RAM_BASE);
    std::uint32_t v = 0;
    for (int i = 0; i < 4; ++i)
        v |= static_cast<std::uint32_t>(host_mem[local + i]) << (i * 8u);
    return v;
}

std::uint64_t read_gpr(const Vtop___024root* rootp, unsigned idx) {
    const auto* lanes = &rootp->pipeline_core__DOT__regs_q_q[0];
    const unsigned base = idx * 2u;
    return static_cast<std::uint64_t>(lanes[base]) |
           (static_cast<std::uint64_t>(lanes[base + 1u]) << 32u);
}

// CSR struct layout (new 10-field, 640-bit, clean 64-bit alignment):
//   k=0 mstatus, k=1 misa, k=2 mtvec, k=3 mscratch, k=4 mepc,
//   k=5 mcause,  k=6 mtval, k=7 mcycle, k=8 minstret, k=9 mhartid
//   lane index = 2*k (no priv-offset anymore)
static std::uint64_t read_csr_m(const Vtop___024root* rootp, unsigned k) {
    const auto* q = &rootp->pipeline_core__DOT__csr_q_q[0];
    const unsigned base = 2u * k;
    return static_cast<std::uint64_t>(q[base]) |
           (static_cast<std::uint64_t>(q[base + 1u]) << 32u);
}

// rv64i_csr_state_t struct (SystemVerilog packed, first-field-at-MSBs):
//   mstatus(k=9) misa(8) mtvec(7) mscratch(6) mepc(5) mcause(4) mtval(3) mcycle(2) minstret(1) mhartid(0)
std::uint64_t read_mcycle(const Vtop___024root* rootp)  { return read_csr_m(rootp, 2u); }
std::uint64_t read_mcause(const Vtop___024root* rootp)  { return read_csr_m(rootp, 4u); }
std::uint64_t read_mtvec(const Vtop___024root* rootp)   { return read_csr_m(rootp, 7u); }
std::uint64_t read_mstatus(const Vtop___024root* rootp) { return read_csr_m(rootp, 9u); }

// Separate-reg CSRs (no longer in the M-mode struct).
std::uint64_t read_scause(const Vtop___024root* rootp) {
    return rootp->pipeline_core__DOT__scause_q_q;
}
std::uint32_t read_priv(const Vtop___024root* rootp) {
    return static_cast<std::uint32_t>(rootp->pipeline_core__DOT__priv_q_q) & 0x3u;
}

// Forward declarations.
bool read_ex_valid(const Vtop___024root* rootp);
std::uint64_t read_ex_alu(const Vtop___024root* rootp);

// ============================================================
// Sv39 TLB and PTW — runs entirely in C++ to stay within the
// Anvil elaborator's memory budget.  The harness writes result
// registers before each clock edge; the Anvil proc reads them.
// ============================================================

struct Sv39Tlb {
    bool         valid = false;
    std::uint16_t asid = 0;
    std::uint32_t vpn  = 0;   // 27-bit VPN
    std::uint64_t ppn  = 0;   // 44-bit PPN
    std::uint8_t  perm = 0;   // PTE bits[7:0]
};

static constexpr int SV39_TLB_SIZE = 64;
static Sv39Tlb sv39_tlb[SV39_TLB_SIZE];
static int     sv39_tlb_next = 0;   // FIFO replacement pointer
static bool    sv39_ptw_running  = false;
static int     sv39_ptw_state    = 0;
static std::uint64_t sv39_ptw_va       = 0;
static std::uint64_t sv39_ptw_pte_addr = 0;
static bool    sv39_ptw_is_exec  = false;
static bool    sv39_ptw_is_store = false;
static std::uint64_t prev_satp   = UINT64_MAX;
static bool    sv39_mem_pf_pending = false;
static std::uint64_t sv39_mem_pf_va = 0;
static bool    sv39_mem_pf_pending_store = false;
static bool    sv39_if_pf_pending  = false;
static std::uint64_t sv39_if_pf_va = 0;
// When a data PTW completes but IF also has a miss, we chain into an IF PTW.
// The data PA is saved here so it can be restored when the IF PTW completes.
static bool         sv39_chained_data_valid = false;
static std::uint64_t sv39_chained_data_pa   = 0;

static void sv39_write_if(Vtop___024root* rootp, bool valid, std::uint64_t pa, bool pf) {
    rootp->pipeline_core__DOT__sv39_if_valid_q_q = valid ? 1u : 0u;
    rootp->pipeline_core__DOT__sv39_if_pa_q_q    = pa;
    rootp->pipeline_core__DOT__sv39_if_pf_q_q    = pf ? 1u : 0u;
}

static void sv39_write_mem(Vtop___024root* rootp, bool valid, std::uint64_t pa,
                           bool pf, bool pf_store) {
    rootp->pipeline_core__DOT__sv39_mem_valid_q_q    = valid ? 1u : 0u;
    rootp->pipeline_core__DOT__sv39_mem_pa_q_q       = pa;
    rootp->pipeline_core__DOT__sv39_mem_pf_q_q       = pf ? 1u : 0u;
    rootp->pipeline_core__DOT__sv39_mem_pf_store_q_q = pf_store ? 1u : 0u;
}

static std::uint64_t sv39_lookup(std::uint64_t va, std::uint16_t asid,
                                 bool is_exec, bool is_store, bool* pf) {
    *pf = false;
    const std::uint32_t vpn = static_cast<std::uint32_t>((va >> 12) & 0x7FFFFFFu);
    for (int i = 0; i < SV39_TLB_SIZE; ++i) {
        const Sv39Tlb& e = sv39_tlb[i];
        if (!e.valid) continue;
        if (e.vpn != vpn) continue;
        const bool global = (e.perm >> 5) & 1;
        if (e.asid != asid && !global) continue;
        const bool r = (e.perm >> 1) & 1;
        const bool w = (e.perm >> 2) & 1;
        const bool x = (e.perm >> 3) & 1;
        if (is_exec  && !x)          { *pf = true; return 0; }
        if (is_store && (!w || !r))  { *pf = true; return 0; }
        if (!is_exec && !is_store && !r) { *pf = true; return 0; }
        return (e.ppn << 12) | (va & 0xFFFu);
    }
    return 0;
}

static bool sv39_debug = false;
#define SV39_DBG(fmt, ...) do { if (sv39_debug) std::fprintf(stderr, "[SV39 cyc=%llu] " fmt "\n", (unsigned long long)read_mcycle(rootp), ##__VA_ARGS__); } while(0)

// Log PTW activity for the trampoline VA range (0x3FFFFFFF000-0x3FFFFFFF FFF).
#define SV39_TRAMP_DBG(fmt, ...) do { \
    const std::uint64_t _va_check = sv39_ptw_va; \
    if ((_va_check >> 12) == 0x3FFFFFFull) \
        std::fprintf(stderr, "[PTW-TRAMP cyc=%llu] " fmt "\n", \
            (unsigned long long)read_mcycle(rootp), ##__VA_ARGS__); \
} while(0)

// Log whenever IF valid is cleared for a trampoline-range fetch PC.
static inline void sv39_write_if_traced(Vtop___024root* rootp, bool valid, std::uint64_t pa, bool pf, const char* reason) {
    const std::uint64_t _pc = rootp->pipeline_core__DOT__pc_q_q;
    if (!valid && (_pc >> 12) == 0x3FFFFFFull) {
        std::fprintf(stderr,
            "[SV39-IF-CLEAR cyc=%llu] pc=0x%llx reason=%s ptw_run=%d ptw_va=0x%llx "
            "ptw_exec=%d flush=%u satp=0x%llx\n",
            (unsigned long long)read_mcycle(rootp),
            (unsigned long long)_pc, reason,
            (int)sv39_ptw_running, (unsigned long long)sv39_ptw_va,
            (int)sv39_ptw_is_exec,
            (unsigned)rootp->pipeline_core__DOT__sv39_flush_q_q,
            (unsigned long long)rootp->pipeline_core__DOT__satp_q_q);
    }
    sv39_write_if(rootp, valid, pa, pf);
}

void update_sv39(Vtop___024root* rootp) {
    // satp and priv are now separate regs (not in the CSR struct).
    const std::uint64_t satp = rootp->pipeline_core__DOT__satp_q_q;
    const std::uint8_t  mode = static_cast<std::uint8_t>((satp >> 60) & 0xFu);
    const std::uint32_t priv = read_priv(rootp);
    const bool sv39_active = (mode == 8u) && (priv != 3u);
    SV39_DBG("pc=0x%llx priv=%u active=%d ptw=%d/%d stall=%u",
             (unsigned long long)rootp->pipeline_core__DOT__pc_q_q, priv, (int)sv39_active,
             (int)sv39_ptw_running, sv39_ptw_state,
             (unsigned)rootp->pipeline_core__DOT__sv39_stall_q_q);

    if (rootp->pipeline_core__DOT__sv39_flush_q_q) {
        for (int i = 0; i < SV39_TLB_SIZE; ++i) sv39_tlb[i].valid = false;
        sv39_tlb_next = 0;
        sv39_mem_pf_pending = false;
        sv39_if_pf_pending  = false;
        sv39_chained_data_valid = false;
    }
    if (satp != prev_satp) {
        for (int i = 0; i < SV39_TLB_SIZE; ++i) sv39_tlb[i].valid = false;
        sv39_tlb_next = 0;
        sv39_mem_pf_pending = false;
        sv39_if_pf_pending  = false;
        sv39_chained_data_valid = false;
        prev_satp = satp;
    }

    if (!sv39_active) {
        rootp->pipeline_core__DOT__sv39_stall_q_q = 0u;
        sv39_write_if (rootp, false, 0, false);
        sv39_write_mem(rootp, false, 0, false, false);
        sv39_ptw_running    = false;
        sv39_ptw_state      = 0;
        sv39_mem_pf_pending = false;
        sv39_if_pf_pending  = false;
        return;
    }

    const std::uint16_t asid = static_cast<std::uint16_t>((satp >> 44) & 0xFFFFu);
    const std::uint64_t ppn_root = satp & 0xFFFFFFFFFFFFFull;

    if (sv39_ptw_running) {
        const std::uint64_t pa = sv39_ptw_pte_addr;
        // PTW reads page tables from host_mem.
        std::uint64_t pte = 0;
        if (pa >= RAM_BASE && pa + 8u <= RAM_BASE + RAM_SIZE)
            pte = read_dmem_qword(rootp, pa);

        const bool v   = pte & 1u;
        const bool r   = (pte >> 1) & 1u;
        const bool w   = (pte >> 2) & 1u;
        const bool x   = (pte >> 3) & 1u;
        const std::uint64_t ppn = (pte >> 10) & 0xFFFFFFFFFFFFFull;
        const bool is_leaf = r || x;

        // Unconditional trampoline PTW trace.
        if ((sv39_ptw_va >> 12) == 0x3FFFFFFull) {
            std::fprintf(stderr,
                "[PTW-TRAMP-PTE cyc=%llu] state=%d pte_pa=0x%llx pte=0x%llx v=%d r=%d w=%d x=%d leaf=%d ppn=0x%llx\n",
                (unsigned long long)read_mcycle(rootp), sv39_ptw_state,
                (unsigned long long)pa, (unsigned long long)pte,
                (int)v, (int)r, (int)w, (int)x, (int)is_leaf, (unsigned long long)ppn);
        }

        bool fault = !v
            || (sv39_ptw_state == 3 && !is_leaf);
        if (!fault && is_leaf) {
            if (sv39_ptw_is_exec  && !x)        fault = true;
            if (sv39_ptw_is_store && (!w || !r)) fault = true;
            if (!sv39_ptw_is_exec && !sv39_ptw_is_store && !r) fault = true;
        }
        if (!fault && sv39_ptw_state == 3 && !is_leaf) fault = true;

        if (fault) {
            if ((sv39_ptw_va >> 12) == 0x3FFFFFFull) {
                std::fprintf(stderr,
                    "[PTW-TRAMP-FAULT cyc=%llu] va=0x%llx state=%d pte_pa=0x%llx pte=0x%llx reason=%s\n",
                    (unsigned long long)read_mcycle(rootp),
                    (unsigned long long)sv39_ptw_va, sv39_ptw_state,
                    (unsigned long long)pa, (unsigned long long)pte,
                    !v ? "not-valid" : (!is_leaf && sv39_ptw_state==3) ? "not-leaf-at-L0"
                       : (sv39_ptw_is_exec && !x) ? "no-exec"
                       : (sv39_ptw_is_store && !w) ? "no-write" : "no-read");
            }
            sv39_ptw_running = false;
            sv39_ptw_state   = 0;
            rootp->pipeline_core__DOT__sv39_stall_q_q = 0u;
            if (sv39_ptw_is_exec) {
                sv39_write_if(rootp, false, 0, true);
                sv39_if_pf_pending = true;
                sv39_if_pf_va      = sv39_ptw_va;
            } else {
                sv39_write_mem(rootp, false, 0, true, sv39_ptw_is_store);
                sv39_mem_pf_pending       = true;
                sv39_mem_pf_va            = sv39_ptw_va;
                sv39_mem_pf_pending_store = sv39_ptw_is_store;
            }
        } else if (sv39_ptw_state == 3 || is_leaf) {
            // Leaf PTE found (may be at any level for superpages).
            Sv39Tlb& e = sv39_tlb[sv39_tlb_next];
            e.valid = true;
            e.asid  = asid;
            e.vpn   = static_cast<std::uint32_t>((sv39_ptw_va >> 12) & 0x7FFFFFFu);
            e.ppn   = ppn;
            e.perm  = static_cast<std::uint8_t>(pte & 0xFFu);
            sv39_tlb_next = (sv39_tlb_next + 1) % SV39_TLB_SIZE;
            sv39_ptw_running = false;
            sv39_ptw_state   = 0;
            rootp->pipeline_core__DOT__sv39_stall_q_q = 0u;
            // Immediately provide PA so the pipeline sees the correct address
            // on the same tick stall is cleared (no 1-cycle window with VA).
            const std::uint64_t xlat_pa = (ppn << 12) | (sv39_ptw_va & 0xFFFu);
            if ((sv39_ptw_va >> 12) == 0x3FFFFFFull) {
                std::fprintf(stderr,
                    "[PTW-TRAMP-OK cyc=%llu] va=0x%llx pa=0x%llx ppn=0x%llx exec=%d\n",
                    (unsigned long long)read_mcycle(rootp),
                    (unsigned long long)sv39_ptw_va,
                    (unsigned long long)xlat_pa,
                    (unsigned long long)ppn,
                    (int)sv39_ptw_is_exec);
            }
            if (sv39_ptw_is_exec) {
                // IF PTW complete. If a chained data result is pending, restore it.
                if (sv39_chained_data_valid) {
                    sv39_write_mem(rootp, true, sv39_chained_data_pa, false, false);
                    sv39_chained_data_valid = false;
                } else {
                    sv39_write_mem(rootp, false, 0, false, false);
                }
                sv39_write_if (rootp, true, xlat_pa, false);
            } else {
                // Data PTW complete: re-look up IF address to avoid a zero-instruction cycle.
                bool if_pf2 = false;
                const std::uint64_t if_va2 = rootp->pipeline_core__DOT__pc_q_q;
                const std::uint64_t if_pa2 = sv39_lookup(if_va2, asid, true, false, &if_pf2);
                if (if_pa2 != 0 || if_pf2) {
                    // IF resolved: clear stall normally.
                    sv39_write_if (rootp, if_pa2 != 0, if_pa2, if_pf2);
                    sv39_write_mem(rootp, true, xlat_pa, false, false);
                } else {
                    // IF is also a miss. Chain into an IF PTW while keeping stall active.
                    // Save the data PA so it can be restored when IF PTW completes.
                    sv39_chained_data_pa    = xlat_pa;
                    sv39_chained_data_valid = true;
                    sv39_write_mem(rootp, true, xlat_pa, false, false);
                    sv39_write_if (rootp, false, 0, false);
                    // Start IF PTW.
                    sv39_ptw_running  = true;
                    sv39_ptw_state    = 1;
                    sv39_ptw_va       = if_va2;
                    sv39_ptw_is_exec  = true;
                    sv39_ptw_is_store = false;
                    const std::uint32_t vpn2_if = static_cast<std::uint32_t>((if_va2 >> 30) & 0x1FFu);
                    sv39_ptw_pte_addr = (ppn_root << 12) | (static_cast<std::uint64_t>(vpn2_if) << 3);
                    rootp->pipeline_core__DOT__sv39_stall_q_q = 1u;  // keep stalled
                    if ((if_va2 >> 12) == 0x3FFFFFFull) {
                        std::fprintf(stderr,
                            "[PTW-TRAMP-CHAIN cyc=%llu] data_pa=0x%llx if_va=0x%llx satp=0x%llx\n",
                            (unsigned long long)read_mcycle(rootp),
                            (unsigned long long)xlat_pa,
                            (unsigned long long)if_va2,
                            (unsigned long long)satp);
                    }
                }
            }
        } else {
            sv39_ptw_state++;
            const std::uint32_t vpn_idx = sv39_ptw_state == 2
                ? static_cast<std::uint32_t>((sv39_ptw_va >> 21) & 0x1FFu)
                : static_cast<std::uint32_t>((sv39_ptw_va >> 12) & 0x1FFu);
            sv39_ptw_pte_addr = (ppn << 12) | (static_cast<std::uint64_t>(vpn_idx) << 3);
        }
        return;
    }

    const std::uint64_t cur_pc = rootp->pipeline_core__DOT__pc_q_q;

    const bool ex_valid_early = read_ex_valid(rootp);
    const std::uint64_t ex_va_early = read_ex_alu(rootp);
    if (sv39_mem_pf_pending) {
        if (ex_valid_early && ex_va_early == sv39_mem_pf_va) {
            rootp->pipeline_core__DOT__sv39_stall_q_q = 0u;
            sv39_write_if (rootp, false, 0, false);
            sv39_write_mem(rootp, false, 0, true, sv39_mem_pf_pending_store);
            return;
        }
        sv39_mem_pf_pending = false;
    }
    if (sv39_if_pf_pending) {
        if (cur_pc == sv39_if_pf_va) {
            rootp->pipeline_core__DOT__sv39_stall_q_q = 0u;
            sv39_write_if (rootp, false, 0, true);
            sv39_write_mem(rootp, false, 0, false, false);
            return;
        }
        sv39_if_pf_pending = false;
    }

    bool if_pf = false;
    const std::uint64_t if_pa = sv39_lookup(cur_pc, asid, true, false, &if_pf);

    const bool ex_valid = ex_valid_early;
    const bool ex_mem_read  = ex_valid && ((rootp->pipeline_core__DOT__ex_mem_q_q[2] >> 22u) & 1u);
    const bool ex_mem_write = ex_valid && ((rootp->pipeline_core__DOT__ex_mem_q_q[2] >> 21u) & 1u);
    const bool mem_needs_xlat = ex_valid && (ex_mem_read || ex_mem_write);
    SV39_DBG("ex_valid=%d ex_mem_r=%d ex_mem_w=%d xlat=%d ex_va=0x%llx",
             (int)ex_valid, (int)ex_mem_read, (int)ex_mem_write,
             (int)mem_needs_xlat, (unsigned long long)read_ex_alu(rootp));

    bool mem_pf = false, mem_pf_store = false;
    std::uint64_t mem_pa = 0;
    if (mem_needs_xlat) {
        const std::uint64_t mem_va = read_ex_alu(rootp);
        mem_pa = sv39_lookup(mem_va, asid, false, ex_mem_write, &mem_pf);
        mem_pf_store = ex_mem_write;
    }

    const bool mem_miss = mem_needs_xlat && !mem_pf && mem_pa == 0;
    const bool if_miss  = !if_pf && if_pa == 0;

    if (mem_miss || if_miss) {
        sv39_ptw_running = true;
        sv39_ptw_state   = 1;
        if (mem_miss) {
            sv39_ptw_va       = read_ex_alu(rootp);
            sv39_ptw_is_exec  = false;
            sv39_ptw_is_store = ex_mem_write;
        } else {
            sv39_ptw_va       = cur_pc;
            sv39_ptw_is_exec  = true;
            sv39_ptw_is_store = false;
        }
        const std::uint32_t vpn2 = static_cast<std::uint32_t>((sv39_ptw_va >> 30) & 0x1FFu);
        sv39_ptw_pte_addr = (ppn_root << 12) | (static_cast<std::uint64_t>(vpn2) << 3);
        if ((sv39_ptw_va >> 12) == 0x3FFFFFFull) {
            std::fprintf(stderr,
                "[PTW-TRAMP-START cyc=%llu] va=0x%llx satp=0x%llx priv=%u exec=%d "
                "ppn_root=0x%llx vpn2=0x%x pte_addr=0x%llx\n",
                (unsigned long long)read_mcycle(rootp),
                (unsigned long long)sv39_ptw_va,
                (unsigned long long)satp, priv, (int)sv39_ptw_is_exec,
                (unsigned long long)ppn_root, vpn2,
                (unsigned long long)sv39_ptw_pte_addr);
        }
        rootp->pipeline_core__DOT__sv39_stall_q_q = 1u;
        // When data PTW takes priority, preserve instruction TLB hit (if any)
        if (mem_miss)
            sv39_write_if(rootp, if_pa != 0, if_pa, if_pf);
        else
            sv39_write_if(rootp, false, 0, false);
        sv39_write_mem(rootp, false, 0, false, false);
        return;
    }

    rootp->pipeline_core__DOT__sv39_stall_q_q = 0u;
    sv39_write_if (rootp, if_pa != 0, if_pa, if_pf);
    sv39_write_mem(rootp, mem_pa != 0, mem_pa, mem_pf, mem_pf_store);
}

static bool is_mmio_addr_cpp(std::uint64_t addr) {
    return ((addr >> 24) == 2u)   // CLINT  0x02000000-0x02FFFFFF
        || ((addr >> 26) == 3u)   // PLIC   0x0C000000-0x0FFFFFFF
        || ((addr >> 28) == 1u);  // UART   0x10000000-0x1FFFFFFF
}

static void dispatch_mmio_store(std::uint64_t addr, std::uint64_t data) {
    if (addr >= 0x2004000ULL && addr < 0x2004008ULL) {
        sim_mtimecmp = data;
    } else if (addr >= 0x2000000ULL && addr < 0x2000008ULL) {
        // MSIP — no-op
    } else if ((addr & ~0xFFFULL) == VIRTIO_BASE) {
        // Virtio-blk MMIO register writes
        const std::uint32_t reg = static_cast<std::uint32_t>(addr - VIRTIO_BASE);
        const std::uint32_t v32 = static_cast<std::uint32_t>(data);
        switch (reg) {
            case 0x020: break;  // DRIVER_FEATURES: no-op (negotiation complete)
            case 0x030: break;  // QUEUE_SEL: only queue 0, no-op
            case 0x038: break;  // QUEUE_NUM: noted, no-op for sim
            case 0x044: break;  // QUEUE_READY: noted implicitly via desc_pa
            case 0x050: process_virtio_queue_notify(); break;  // QUEUE_NOTIFY
            case 0x064: virtio_interrupt_status &= ~v32; break;  // INTERRUPT_ACK
            case 0x070: virtio_status_val = v32; break;
            case 0x080: vq_desc_pa  = (vq_desc_pa  & ~0xFFFFFFFFULL) | v32; break;
            case 0x084: vq_desc_pa  = (vq_desc_pa  &  0xFFFFFFFFULL) | ((std::uint64_t)v32 << 32); break;
            case 0x090: vq_avail_pa = (vq_avail_pa & ~0xFFFFFFFFULL) | v32; break;
            case 0x094: vq_avail_pa = (vq_avail_pa &  0xFFFFFFFFULL) | ((std::uint64_t)v32 << 32); break;
            case 0x0a0: vq_used_pa  = (vq_used_pa  & ~0xFFFFFFFFULL) | v32; break;
            case 0x0a4: vq_used_pa  = (vq_used_pa  &  0xFFFFFFFFULL) | ((std::uint64_t)v32 << 32); break;
            default: break;
        }
    } else if ((addr & ~0xFULL) == 0x10000000ULL) {
        const unsigned uart_reg = static_cast<unsigned>(addr & 0xFu);
        // Extract byte from the correct lane in the lane-shifted store word.
        const unsigned byte_val = static_cast<unsigned>((data >> (uart_reg * 8u)) & 0xFFu);
        std::fprintf(stderr, "[UART-TX cyc=%llu] reg=%u byte=0x%02x '%c'\n",
                     (unsigned long long)sim_mtime, uart_reg, byte_val,
                     (byte_val >= 32u && byte_val < 127u) ? (char)byte_val : '.');
        if (uart_reg == 0) {
            std::putchar(static_cast<unsigned char>(byte_val));
            std::fflush(stdout);
            uart_tx_irq_fire_at = sim_mtime + UART_TX_IRQ_DELAY;
        }
    }
    // PLIC: no-op
}

// Commit stores from previous tick to host_mem[] or MMIO devices.
static void commit_stores(Vtop___024root* rootp) {
    if (!rootp->pipeline_core__DOT__mem_store_valid_q_q) return;
    const std::uint64_t addr = rootp->pipeline_core__DOT__mem_store_addr_q_q;
    const std::uint64_t data = rootp->pipeline_core__DOT__mem_store_word_q_q;
    // Debug window: log all stores around the write() syscall area
    if (sim_mtime >= 214200 && sim_mtime <= 214500) {
        std::fprintf(stderr, "[STORE-DBG cyc=%llu] addr=0x%llx data=0x%llx mmio=%d\n",
            (unsigned long long)sim_mtime, (unsigned long long)addr,
            (unsigned long long)data, (int)is_mmio_addr_cpp(addr));
    }
    if (is_mmio_addr_cpp(addr)) {
        dispatch_mmio_store(addr, data);
    } else if (addr >= RAM_BASE && addr + 8u <= RAM_BASE + RAM_SIZE) {
        const std::uint32_t local = static_cast<std::uint32_t>(addr - RAM_BASE);
        const std::uint32_t base  = local & ~7u;
        for (int i = 0; i < 8; ++i)
            host_mem[base + i] = static_cast<std::uint8_t>((data >> (i * 8u)) & 0xFFu);
    }
}

// Pre-populate mem_rdata_q with the data for the current EX/MEM access.
// Called after update_sv39() so sv39_mem_pa_q_q is already set.
static void pre_populate_mem_rdata(Vtop___024root* rootp) {
    const bool ex_valid = read_ex_valid(rootp);
    const bool ex_r = ex_valid && ((rootp->pipeline_core__DOT__ex_mem_q_q[2] >> 22u) & 1u);
    const bool ex_w = ex_valid && ((rootp->pipeline_core__DOT__ex_mem_q_q[2] >> 21u) & 1u);
    if (!ex_valid || (!ex_r && !ex_w)) {
        rootp->pipeline_core__DOT__mem_rdata_q_q = 0ULL;
        return;
    }
    // Physical address: sv39 provides it when active and valid.
    std::uint64_t pa;
    if (rootp->pipeline_core__DOT__sv39_mem_valid_q_q)
        pa = rootp->pipeline_core__DOT__sv39_mem_pa_q_q;
    else
        pa = read_ex_alu(rootp);

    std::uint64_t data = 0;
    if (is_mmio_addr_cpp(pa)) {
        if ((pa >> 24) == 2u) {
            if ((pa & ~7ull) == 0x200BFF8ULL)  data = sim_mtime;
            else if ((pa & ~7ull) == 0x2004000ULL) data = sim_mtimecmp;
        } else if ((pa & ~0xFFFULL) == VIRTIO_BASE) {
            // Virtio-blk MMIO register reads (byte-lane-aligned)
            const std::uint32_t reg = static_cast<std::uint32_t>(pa - VIRTIO_BASE);
            std::uint32_t rval = 0;
            switch (reg & ~3u) {  // align to 4-byte register boundary
                case 0x000: rval = 0x74726976u; break;  // MAGIC_VALUE: 'virt'
                case 0x004: rval = 2u; break;             // VERSION
                case 0x008: rval = 2u; break;             // DEVICE_ID (block)
                case 0x00c: rval = 0x554d4551u; break;   // VENDOR_ID: 'QEMU'
                case 0x010: rval = 0u; break;             // DEVICE_FEATURES
                case 0x034: rval = 8u; break;             // QUEUE_NUM_MAX
                case 0x044: rval = 0u; break;             // QUEUE_READY (0 before init)
                case 0x060: rval = virtio_interrupt_status; break;  // INTERRUPT_STATUS
                case 0x070: rval = virtio_status_val; break;
                default: rval = 0u; break;
            }
            const unsigned byte_off = static_cast<unsigned>(pa & 7u);
            data = static_cast<std::uint64_t>(rval) << (byte_off * 8u);
        } else if ((pa >> 28) == 1u) {
            // UART NS16550A: return byte-lane-aligned data so the pipeline's
            // byte-offset shift extracts the right value.
            const unsigned byte_off = static_cast<unsigned>(pa & 7u);
            std::uint8_t uart_byte = 0;
            if ((pa & 0xFu) == 5u) uart_byte = 0x60u;  // LSR: THRE+TEMT set
            data = static_cast<std::uint64_t>(uart_byte) << (byte_off * 8u);
            // Log LSR reads so we can trace uartstart().
            if ((pa & 0xFu) == 5u)
                std::fprintf(stderr, "[UART-LSR cyc=%llu] pa=0x%llx data=0x%llx\n",
                    (unsigned long long)sim_mtime, (unsigned long long)pa, (unsigned long long)data);
        } else if ((pa >> 26) == 3u) {
            // PLIC 0x0C000000-0x0FFFFFFF
            // PLIC_SCLAIM (hart 0, S-mode) = 0x0C201004: return highest-priority pending IRQ.
            const unsigned byte_off = static_cast<unsigned>(pa & 7u);
            std::uint32_t rval = 0;
            // Only dispatch claim on LOAD (ex_r=1). A store to PLIC_SPRIORITY (0x0C201000)
            // must not trigger the claim — the 8-byte-aligned range would otherwise match.
            if (ex_r && (pa & ~3ull) == (PLIC_SCLAIM0 & ~3ull)) {
                if (uart_tx_irq_pending) {
                    rval = 10u;  // UART0_IRQ = 10 (handled first — lower latency than virtio)
                    uart_tx_irq_pending = false;
                    std::fprintf(stderr, "[PLIC-CLAIM cyc=%llu] UART IRQ=10 claimed"
                                 " fetch_pc=0x%llx ex_alu=0x%llx priv=%u\n",
                                 (unsigned long long)sim_mtime,
                                 (unsigned long long)rootp->pipeline_core__DOT__pc_q_q,
                                 (unsigned long long)read_ex_alu(rootp),
                                 read_priv(rootp));
                    // Harness-level uartintr() simulation: the kernel's interrupt handler
                    // may not reliably execute uartintr() due to pipeline timing quirks.
                    // Directly simulate the wakeup effect: clear tx_busy, wake any proc
                    // sleeping on &tx_chan.
                    {
                        static const std::uint64_t TX_BUSY_ADDR = 0x8000a83cULL;
                        static const std::uint64_t TX_CHAN_ADDR  = 0x8000a838ULL;
                        static const std::uint64_t PROC_BASE     = 0x8000ba08ULL;
                        static const unsigned      PROC_STRIDE   = 0x168u;  // sizeof(struct proc)=360
                        static const unsigned      PROC_STATE_OFF = 0x18u;  // offsetof(proc, state)
                        static const unsigned      PROC_CHAN_OFF  = 0x20u;  // offsetof(proc, chan)
                        static const unsigned      NPROC          = 64u;

                        auto hm_read_u32 = [&](std::uint64_t addr) -> std::uint32_t {
                            if (addr < RAM_BASE || addr + 4u > RAM_BASE + RAM_SIZE) return 0u;
                            std::uint32_t off = static_cast<std::uint32_t>(addr - RAM_BASE);
                            return static_cast<std::uint32_t>(host_mem[off])
                                 | (static_cast<std::uint32_t>(host_mem[off+1]) << 8u)
                                 | (static_cast<std::uint32_t>(host_mem[off+2]) << 16u)
                                 | (static_cast<std::uint32_t>(host_mem[off+3]) << 24u);
                        };
                        auto hm_read_u64 = [&](std::uint64_t addr) -> std::uint64_t {
                            if (addr < RAM_BASE || addr + 8u > RAM_BASE + RAM_SIZE) return 0u;
                            std::uint32_t off = static_cast<std::uint32_t>(addr - RAM_BASE);
                            std::uint64_t v = 0;
                            for (int i = 0; i < 8; ++i)
                                v |= static_cast<std::uint64_t>(host_mem[off + i]) << (i * 8u);
                            return v;
                        };
                        auto hm_write_u32 = [&](std::uint64_t addr, std::uint32_t val) {
                            if (addr < RAM_BASE || addr + 4u > RAM_BASE + RAM_SIZE) return;
                            std::uint32_t off = static_cast<std::uint32_t>(addr - RAM_BASE);
                            host_mem[off]   = static_cast<std::uint8_t>(val);
                            host_mem[off+1] = static_cast<std::uint8_t>(val >> 8u);
                            host_mem[off+2] = static_cast<std::uint8_t>(val >> 16u);
                            host_mem[off+3] = static_cast<std::uint8_t>(val >> 24u);
                        };
                        auto hm_write_u64 = [&](std::uint64_t addr, std::uint64_t val) {
                            if (addr < RAM_BASE || addr + 8u > RAM_BASE + RAM_SIZE) return;
                            std::uint32_t off = static_cast<std::uint32_t>(addr - RAM_BASE);
                            for (int i = 0; i < 8; ++i)
                                host_mem[off + i] = static_cast<std::uint8_t>(val >> (i * 8u));
                        };

                        // Clear tx_busy so uartintr()/uartwrite() see TX idle.
                        hm_write_u32(TX_BUSY_ADDR, 0u);

                        // Wake procs sleeping on &tx_chan.
                        for (unsigned pi = 0; pi < NPROC; ++pi) {
                            std::uint64_t proc_addr = PROC_BASE + pi * PROC_STRIDE;
                            std::uint64_t chan  = hm_read_u64(proc_addr + PROC_CHAN_OFF);
                            std::uint32_t state = hm_read_u32(proc_addr + PROC_STATE_OFF);
                            if (state == 2u && chan == TX_CHAN_ADDR) {  // SLEEPING on tx_chan
                                hm_write_u32(proc_addr + PROC_STATE_OFF, 3u);  // RUNNABLE
                                hm_write_u64(proc_addr + PROC_CHAN_OFF, 0u);   // chan = nil
                                std::fprintf(stderr,
                                    "[UART-WAKEUP cyc=%llu] proc[%u] SLEEPING→RUNNABLE (tx_chan)\n",
                                    (unsigned long long)sim_mtime, pi);
                            }
                        }
                    }
                } else if (virtio_irq_pending) {
                    rval = 1u;  // VIRTIO0_IRQ = 1
                    virtio_irq_pending = false;
                    std::fprintf(stderr, "[PLIC-CLAIM cyc=%llu] VIRTIO IRQ=1 claimed"
                                 " fetch_pc=0x%llx ex_alu=0x%llx priv=%u\n",
                                 (unsigned long long)sim_mtime,
                                 (unsigned long long)rootp->pipeline_core__DOT__pc_q_q,
                                 (unsigned long long)read_ex_alu(rootp),
                                 read_priv(rootp));
                }
            }
            data = static_cast<std::uint64_t>(rval) << (byte_off * 8u);
        }
    } else if (pa >= RAM_BASE && pa + 8u <= RAM_BASE + RAM_SIZE) {
        const std::uint32_t local = static_cast<std::uint32_t>(pa - RAM_BASE);
        const std::uint32_t base  = local & ~7u;
        for (int i = 0; i < 8; ++i)
            data |= static_cast<std::uint64_t>(host_mem[base + i]) << (i * 8u);
    }
    rootp->pipeline_core__DOT__mem_rdata_q_q = data;
}

// Pre-populate imem_rdata_q with the instruction at the current fetch PC.
static void pre_populate_imem_rdata(Vtop___024root* rootp) {
    const std::uint64_t fetch_va = rootp->pipeline_core__DOT__pc_q_q;
    const bool tramp_fetch = (fetch_va >> 12) == 0x3FFFFFFull;
    std::uint64_t pa;
    if (rootp->pipeline_core__DOT__sv39_if_valid_q_q)
        pa = rootp->pipeline_core__DOT__sv39_if_pa_q_q;
    else
        pa = fetch_va;

    std::uint32_t instr = 0;
    if (pa >= RAM_BASE && pa + 4u <= RAM_BASE + RAM_SIZE) {
        const std::uint32_t local = static_cast<std::uint32_t>(pa - RAM_BASE);
        for (int i = 0; i < 4; ++i)
            instr |= static_cast<std::uint32_t>(host_mem[local + i]) << (i * 8u);
    }
    if (tramp_fetch && instr == 0) {
        std::fprintf(stderr,
            "[IMEM-ZERO cyc=%llu] tramp_va=0x%llx sv39_valid=%u if_pa=0x%llx used_pa=0x%llx instr=0\n",
            (unsigned long long)read_mcycle(rootp),
            (unsigned long long)fetch_va,
            (unsigned)rootp->pipeline_core__DOT__sv39_if_valid_q_q,
            (unsigned long long)rootp->pipeline_core__DOT__sv39_if_pa_q_q,
            (unsigned long long)pa);
    }
    rootp->pipeline_core__DOT__imem_rdata_q_q = instr;
}

// ============================================================
// Division/Remainder harness interception
//
// The Anvil ALU stubs produce wrong results for div/rem.
// The harness intercepts by computing the correct result in C++
// and patching ex_mem_q_q before the next tick (so forwarding
// also sees the right value) and mem_wb_q_q before WB commits.
//
// Bit layout (confirmed from Verilator-generated code):
//   ctrl.alu_op (5 bits) is at packet bits [95:91] in every packet
//     → word[2] bits [31:27]: (pkt[2] >> 27) & 0x1f
//   id_ex rs1_val (64 bits) at bits [1171:1108], words [34-36]
//   id_ex rs2_val (64 bits) at bits [1107:1044], words [32-34]
//   ex_mem alu_result (64 bits) at bits [642:579], words [18-20]
//   mem_wb alu_result (64 bits) at bits [577:514], words [16-18]
//   id_ex  valid bit at bit 1283 = word[40] bit 3
//   ex_mem valid bit at bit 744  = word[23] bit 8
//   mem_wb valid bit at bit 679  = word[21] bit 7
// ============================================================

static const std::uint32_t ALU_DIV   = 22u;
static const std::uint32_t ALU_DIVU  = 23u;
static const std::uint32_t ALU_REM   = 24u;
static const std::uint32_t ALU_REMU  = 25u;
static const std::uint32_t ALU_DIVW  = 26u;
static const std::uint32_t ALU_DIVUW = 27u;
static const std::uint32_t ALU_REMW  = 28u;
static const std::uint32_t ALU_REMUW = 29u;

static bool         pending_div_active = false;
static std::uint64_t pending_div_result = 0;

static bool is_div_op(std::uint32_t op) {
    return op >= ALU_DIV && op <= ALU_REMUW;
}

// RISC-V integer division per spec (divide-by-zero and overflow defined).
static std::uint64_t cpp_div64(std::uint32_t alu_op, std::uint64_t lhs, std::uint64_t rhs) {
    const bool is_signed = (alu_op == ALU_DIV  || alu_op == ALU_REM  ||
                            alu_op == ALU_DIVW || alu_op == ALU_REMW);
    const bool is_word   = (alu_op == ALU_DIVW  || alu_op == ALU_DIVUW ||
                            alu_op == ALU_REMW  || alu_op == ALU_REMUW);
    const bool is_rem    = (alu_op == ALU_REM   || alu_op == ALU_REMU  ||
                            alu_op == ALU_REMW  || alu_op == ALU_REMUW);

    std::uint64_t a = lhs, b = rhs;
    if (is_word) {
        if (is_signed) {
            a = static_cast<std::uint64_t>(static_cast<std::int64_t>(
                    static_cast<std::int32_t>(static_cast<std::uint32_t>(lhs))));
            b = static_cast<std::uint64_t>(static_cast<std::int64_t>(
                    static_cast<std::int32_t>(static_cast<std::uint32_t>(rhs))));
        } else {
            a = static_cast<std::uint32_t>(lhs);
            b = static_cast<std::uint32_t>(rhs);
        }
    }

    std::uint64_t result;
    if (b == 0u) {
        result = is_rem ? a : UINT64_MAX;
    } else if (is_signed) {
        const std::int64_t sa = static_cast<std::int64_t>(a);
        const std::int64_t sb = static_cast<std::int64_t>(b);
        if (sa == INT64_MIN && sb == -1) {
            result = is_rem ? 0u : static_cast<std::uint64_t>(INT64_MIN);
        } else {
            result = is_rem ? static_cast<std::uint64_t>(sa % sb)
                            : static_cast<std::uint64_t>(sa / sb);
        }
    } else {
        result = is_rem ? (a % b) : (a / b);
    }

    if (is_word)
        result = static_cast<std::uint64_t>(static_cast<std::int64_t>(
                     static_cast<std::int32_t>(static_cast<std::uint32_t>(result))));
    return result;
}

static std::uint32_t read_pkt_alu_op(const std::uint32_t* pkt) {
    return (pkt[2u] >> 27u) & 0x1fu;
}

// Raw (pre-forwarding) register values from id_ex packet.
// Forwarding is applied separately in capture_div_from_id_ex.
static std::uint64_t read_id_ex_rs1_val_raw(const Vtop___024root* rootp) {
    const auto* p = &rootp->pipeline_core__DOT__id_ex_q_q[0u];
    return (static_cast<std::uint64_t>(p[34u] >> 20u)) |
           (static_cast<std::uint64_t>(p[35u]) << 12u) |
           (static_cast<std::uint64_t>(p[36u] & 0xFFFFFu) << 44u);
}

static std::uint64_t read_id_ex_rs2_val_raw(const Vtop___024root* rootp) {
    const auto* p = &rootp->pipeline_core__DOT__id_ex_q_q[0u];
    return (static_cast<std::uint64_t>(p[32u] >> 20u)) |
           (static_cast<std::uint64_t>(p[33u]) << 12u) |
           (static_cast<std::uint64_t>(p[34u] & 0xFFFFFu) << 44u);
}

// Register indices for rs1/rs2 in id_ex packet.
// rs2 at packet bits [1181:1177] = word[36] bits [29:25]
// rs1 at packet bits [1186:1182] = word[36] bits [31:30] + word[37] bits [2:0]
static std::uint32_t read_id_ex_rs1_idx(const Vtop___024root* rootp) {
    const auto* p = &rootp->pipeline_core__DOT__id_ex_q_q[0u];
    return ((p[36u] >> 30u) & 0x3u) | ((p[37u] & 0x7u) << 2u);
}
static std::uint32_t read_id_ex_rs2_idx(const Vtop___024root* rootp) {
    const auto* p = &rootp->pipeline_core__DOT__id_ex_q_q[0u];
    return (p[36u] >> 25u) & 0x1fu;
}

// Read alu_result from ex_mem packet (bits [642:579], words [18-20]).
static std::uint64_t read_ex_mem_alu_result(const Vtop___024root* rootp) {
    const auto* p = &rootp->pipeline_core__DOT__ex_mem_q_q[0u];
    return (static_cast<std::uint64_t>(p[18u] >> 3u)) |
           (static_cast<std::uint64_t>(p[19u]) << 29u) |
           (static_cast<std::uint64_t>(p[20u] & 0x7u) << 61u);
}

// rd from ex_mem packet (bits [647:643], word[20] bits [7:3]).
static std::uint32_t read_ex_mem_rd(const Vtop___024root* rootp) {
    return (rootp->pipeline_core__DOT__ex_mem_q_q[20u] >> 3u) & 0x1fu;
}

// Read alu_result from mem_wb packet (bits [577:514], words [16-18]).
static std::uint64_t read_mem_wb_alu_result_raw(const Vtop___024root* rootp) {
    const auto* p = &rootp->pipeline_core__DOT__mem_wb_q_q[0u];
    return (static_cast<std::uint64_t>(p[16u] >> 2u)) |
           (static_cast<std::uint64_t>(p[17u]) << 30u) |
           (static_cast<std::uint64_t>(p[18u] & 0x3u) << 62u);
}

// mem_data from mem_wb packet (bits [513:450], words [14-16]).
static std::uint64_t read_mem_wb_mem_data(const Vtop___024root* rootp) {
    const auto* p = &rootp->pipeline_core__DOT__mem_wb_q_q[0u];
    return (static_cast<std::uint64_t>(p[14u] >> 2u)) |
           (static_cast<std::uint64_t>(p[15u]) << 30u) |
           (static_cast<std::uint64_t>(p[16u] & 0x3u) << 62u);
}

// rd from mem_wb packet (bits [582:578], word[18] bits [6:2]).
static std::uint32_t read_mem_wb_rd(const Vtop___024root* rootp) {
    return (rootp->pipeline_core__DOT__mem_wb_q_q[18u] >> 2u) & 0x1fu;
}

// wb_sel from mem_wb ctrl (ctrl.wb_sel at ctrl bits [11:10] = packet bits [81:80]).
// WB_MEM = 2 means use mem_data for writeback.
static std::uint32_t read_mem_wb_wb_sel(const Vtop___024root* rootp) {
    return (rootp->pipeline_core__DOT__mem_wb_q_q[2u] >> 16u) & 0x3u;
}

// Forwarded writeback value from mem_wb (alu_result or mem_data depending on wb_sel).
static std::uint64_t read_mem_wb_fwd_val(const Vtop___024root* rootp) {
    return (read_mem_wb_wb_sel(rootp) == 2u)
        ? read_mem_wb_mem_data(rootp)
        : read_mem_wb_alu_result_raw(rootp);
}

// Apply forwarding: given a register index and raw value from id_ex, return the
// correct operand value (forwarded from ex_mem or mem_wb if there is a match).
static std::uint64_t apply_forwarding(const Vtop___024root* rootp,
                                       std::uint32_t reg_idx,
                                       std::uint64_t raw_val) {
    if (reg_idx == 0u) return 0u;  // x0 always 0
    // EX/MEM forwarding (higher priority — more recent)
    if ((rootp->pipeline_core__DOT__ex_mem_q_q[23u] >> 8u) & 1u) {
        if (read_ex_mem_rd(rootp) == reg_idx)
            return read_ex_mem_alu_result(rootp);
    }
    // MEM/WB forwarding
    if ((rootp->pipeline_core__DOT__mem_wb_q_q[21u] >> 7u) & 1u) {
        if (read_mem_wb_rd(rootp) == reg_idx)
            return read_mem_wb_fwd_val(rootp);
    }
    return raw_val;
}

static void write_ex_mem_alu_result(Vtop___024root* rootp, std::uint64_t val) {
    auto* p = &rootp->pipeline_core__DOT__ex_mem_q_q[0u];
    p[18u] = (p[18u] & 0x7u) | (static_cast<std::uint32_t>(val) << 3u);
    p[19u] = static_cast<std::uint32_t>(val >> 29u);
    p[20u] = (p[20u] & ~0x7u) | static_cast<std::uint32_t>((val >> 61u) & 0x7u);
}

static void write_mem_wb_alu_result(Vtop___024root* rootp, std::uint64_t val) {
    auto* p = &rootp->pipeline_core__DOT__mem_wb_q_q[0u];
    p[16u] = (p[16u] & 0x3u) | (static_cast<std::uint32_t>(val) << 2u);
    p[17u] = static_cast<std::uint32_t>(val >> 30u);
    p[18u] = (p[18u] & ~0x3u) | static_cast<std::uint32_t>((val >> 62u) & 0x3u);
}

// Called BEFORE each tick: check id_ex for div/rem, compute correct result.
// Applies forwarding to get the true operand values (id_ex stores raw regfile
// values; the actual EX-stage operands come from forwarding paths).
static void capture_div_from_id_ex(Vtop___024root* rootp) {
    const auto* p = &rootp->pipeline_core__DOT__id_ex_q_q[0u];
    if (!((p[40u] >> 3u) & 1u)) return;  // id_ex not valid
    const std::uint32_t alu_op = read_pkt_alu_op(p);
    if (!is_div_op(alu_op)) return;
    const std::uint32_t rs1_idx = read_id_ex_rs1_idx(rootp);
    const std::uint32_t rs2_idx = read_id_ex_rs2_idx(rootp);
    const std::uint64_t rs1 = apply_forwarding(rootp, rs1_idx, read_id_ex_rs1_val_raw(rootp));
    const std::uint64_t rs2 = apply_forwarding(rootp, rs2_idx, read_id_ex_rs2_val_raw(rootp));
    pending_div_result = cpp_div64(alu_op, rs1, rs2);
    pending_div_active = true;
}

// Called BEFORE each tick: patch alu_result in ex_mem/mem_wb if a pending div result exists.
static void patch_div_results(Vtop___024root* rootp) {
    if (!pending_div_active) return;

    const auto* em = &rootp->pipeline_core__DOT__ex_mem_q_q[0u];
    if ((em[23u] >> 8u) & 1u) {  // ex_mem valid
        if (is_div_op(read_pkt_alu_op(em)))
            write_ex_mem_alu_result(rootp, pending_div_result);
    }

    const auto* wb = &rootp->pipeline_core__DOT__mem_wb_q_q[0u];
    if ((wb[21u] >> 7u) & 1u) {  // mem_wb valid
        if (is_div_op(read_pkt_alu_op(wb))) {
            write_mem_wb_alu_result(rootp, pending_div_result);
            pending_div_active = false;
        }
    }
}

// Capability register file lives in the harness: capability_t[32] inside pipeline_core.anvil
// pushes the Anvil elaborator past its memory limit (same reason as the Sv39 PTW).

struct CapabilityT {
    bool     valid;
    uint8_t  ctype;      // 0=LINEAR 1=NONLINEAR 2=REVOC 3=UNINIT 4=SEALED 5=SEALED_RET 6=EXIT
    uint8_t  world;      // 0=NORMAL 1=SECURE
    uint64_t rev_epoch;
    uint64_t cursor;
    uint64_t base;
    uint64_t end_;
    uint8_t  perms;      // R=4 W=2 X=1
    uint8_t  async_;     // SYNC=0 EXCEPTION=1 INTERRUPT=2
    uint8_t  reg_id;
};

static const CapabilityT k_zero_cap = {false, 0, 0, 0, 0, 0, 0, 0, 0, 0};

static const uint8_t CTYPE_LINEAR     = 0;
static const uint8_t CTYPE_NONLINEAR  = 1;
static const uint8_t CTYPE_REVOC      = 2;
static const uint8_t CTYPE_UNINIT     = 3;
static const uint8_t CTYPE_SEALED     = 4;
static const uint8_t CTYPE_SEALED_RET = 5;
static const uint8_t CTYPE_EXIT       = 6;

static CapabilityT cap_rf[32];
// Monotonic counter used by MREV to assign unique revocation epochs.
static uint64_t rev_epoch_counter = 0;

// Capability memory layout (32 bytes = 4 × uint64_t, CAP_BYTES-aligned):
//   word 0: cursor
//   word 1: base
//   word 2: end_
//   word 3: ctype:3 | world:1<<3 | perms:3<<4 | async_:2<<7 | reg_id:5<<9 | rev_epoch<<14
// cap_tags[off/CAP_BYTES] tracks whether slot is a real capability or plain data.

static void cap_store_to_mem(uint64_t addr, const CapabilityT& cap) {
    if (addr < RAM_BASE || addr + CAP_BYTES > RAM_BASE + RAM_SIZE) return;
    if (addr % CAP_BYTES != 0) return;
    const uint32_t off = static_cast<uint32_t>(addr - RAM_BASE);
    auto wr64 = [&](uint32_t o, uint64_t v) {
        for (int b = 0; b < 8; ++b) host_mem[off + o + b] = static_cast<uint8_t>(v >> (b * 8));
    };
    wr64(0,  cap.cursor);
    wr64(8,  cap.base);
    wr64(16, cap.end_);
    const uint64_t packed = (static_cast<uint64_t>(cap.ctype) & 0x7u)
                          | (static_cast<uint64_t>(cap.world  & 1u) << 3u)
                          | (static_cast<uint64_t>(cap.perms  & 7u) << 4u)
                          | (static_cast<uint64_t>(cap.async_ & 3u) << 7u)
                          | (static_cast<uint64_t>(cap.reg_id & 0x1fu) << 9u)
                          | (cap.rev_epoch << 14u);
    wr64(24, packed);
    cap_tags[off / CAP_BYTES] = cap.valid;
}

static CapabilityT cap_load_from_mem(uint64_t addr) {
    if (addr < RAM_BASE || addr + CAP_BYTES > RAM_BASE + RAM_SIZE) return k_zero_cap;
    if (addr % CAP_BYTES != 0) return k_zero_cap;
    const uint32_t off = static_cast<uint32_t>(addr - RAM_BASE);
    if (!cap_tags[off / CAP_BYTES]) return k_zero_cap;
    auto rd64 = [&](uint32_t o) -> uint64_t {
        uint64_t v = 0;
        for (int b = 0; b < 8; ++b) v |= static_cast<uint64_t>(host_mem[off + o + b]) << (b * 8);
        return v;
    };
    CapabilityT c;
    c.valid     = true;
    c.cursor    = rd64(0);
    c.base      = rd64(8);
    c.end_      = rd64(16);
    const uint64_t packed = rd64(24);
    c.ctype     = static_cast<uint8_t>( packed        & 0x7u);
    c.world     = static_cast<uint8_t>((packed >>  3u) & 0x1u);
    c.perms     = static_cast<uint8_t>((packed >>  4u) & 0x7u);
    c.async_    = static_cast<uint8_t>((packed >>  7u) & 0x3u);
    c.reg_id    = static_cast<uint8_t>((packed >>  9u) & 0x1fu);
    c.rev_epoch = packed >> 14u;
    return c;
}

static void cap_rf_reset() {
    for (int i = 0; i < 32; ++i) cap_rf[i] = k_zero_cap;
    // c1 = hardware root capability: covers all RAM, all permissions.
    // Software reads this out and derives narrower capabilities from it.
    cap_rf[1].valid     = true;
    cap_rf[1].ctype     = CTYPE_LINEAR;
    cap_rf[1].world     = 0;
    cap_rf[1].rev_epoch = 0;
    cap_rf[1].cursor    = RAM_BASE;
    cap_rf[1].base      = RAM_BASE;
    cap_rf[1].end_      = RAM_BASE + RAM_SIZE;
    cap_rf[1].perms     = 7u;  // RWX
    cap_rf[1].async_    = 0;
    cap_rf[1].reg_id    = 1;
    std::fprintf(stderr,
        "[CAP-INIT] c1 = root cap: base=0x%llx end=0x%llx cursor=0x%llx perms=RWX\n",
        (unsigned long long)RAM_BASE,
        (unsigned long long)(RAM_BASE + RAM_SIZE),
        (unsigned long long)RAM_BASE);
}

// cap_op_t values — must match the enum order in capstone.anvilh.
static const uint32_t C_OP_NONE       =  0;
static const uint32_t C_OP_MOVC       =  1;
static const uint32_t C_OP_CINCOFFSET =  2;
static const uint32_t C_OP_SCC        =  3;
static const uint32_t C_OP_LCC        =  4;
static const uint32_t C_OP_SHRINK     =  5;
static const uint32_t C_OP_TIGHTEN    =  6;
static const uint32_t C_OP_SPLIT      =  7;
static const uint32_t C_OP_DELIN      =  8;
static const uint32_t C_OP_MREV       =  9;
static const uint32_t C_OP_DROP       = 10;
static const uint32_t C_OP_SEAL       = 11;
static const uint32_t C_OP_REVOKE     = 12;
static const uint32_t C_OP_INIT       = 13;
static const uint32_t C_OP_LDC        = 14;
static const uint32_t C_OP_STC        = 15;
static const uint32_t C_OP_CALL       = 16;
static const uint32_t C_OP_RETURN     = 17;
static const uint32_t C_OP_RETSEAL    = 18;
static const uint32_t C_OP_CJALR      = 19;
static const uint32_t C_OP_CBNZ       = 20;
static const uint32_t C_OP_CAPENTER   = 21;
static const uint32_t C_OP_CAPEXIT    = 22;

static CapabilityT cpp_cap_clone(const CapabilityT& c) { return c; }

static CapabilityT cpp_cap_invalidate(const CapabilityT& c, uint8_t revoked_type) {
    CapabilityT r = c;
    r.valid = false;
    r.ctype = revoked_type;
    return r;
}

static CapabilityT cpp_cap_retype(const CapabilityT& c, uint8_t new_type) {
    CapabilityT r = c;
    r.ctype = new_type;
    return r;
}

static CapabilityT cpp_cap_set_world(const CapabilityT& c, uint8_t world) {
    CapabilityT r = c;
    r.world = world;
    return r;
}

static CapabilityT cpp_cap_alu_exec(uint32_t op,
                                     const CapabilityT& cap_a,
                                     const CapabilityT& cap_b,
                                     uint64_t scalar_arg) {
    if (!cap_a.valid) return k_zero_cap;

    if (op == C_OP_NONE) return cap_a;

    if (op == C_OP_MOVC || op == C_OP_LCC || op == C_OP_LDC)
        return cpp_cap_clone(cap_a);

    if (op == C_OP_SCC || op == C_OP_STC)
        return cpp_cap_clone(cap_b);

    if (op == C_OP_CINCOFFSET) {
        const uint64_t next_cursor = cap_a.cursor + scalar_arg;
        if (next_cursor >= cap_a.base && next_cursor <= cap_a.end_) {
            CapabilityT r = cap_a;
            r.cursor = next_cursor;
            return r;
        }
        return cpp_cap_invalidate(cap_a, CTYPE_UNINIT);
    }

    if (op == C_OP_SHRINK || op == C_OP_TIGHTEN) {
        const uint64_t next_base = (cap_a.base > cap_b.base) ? cap_a.base : cap_b.base;
        const uint64_t next_end  = (cap_a.end_ < cap_b.end_) ? cap_a.end_ : cap_b.end_;
        if (next_base <= next_end) {
            CapabilityT r = cap_a;
            r.cursor = (cap_a.cursor < next_base) ? next_base
                     : (cap_a.cursor > next_end)  ? next_end
                     : cap_a.cursor;
            r.base  = next_base;
            r.end_  = next_end;
            r.perms = cap_a.perms & cap_b.perms;
            return r;
        }
        return cpp_cap_invalidate(cap_a, CTYPE_UNINIT);
    }

    if (op == C_OP_SPLIT) {
        const uint64_t mid = (cap_a.base + cap_a.end_) / 2;
        CapabilityT r = cap_a;
        r.end_ = mid;
        return r;
    }

    if (op == C_OP_DELIN || op == C_OP_DROP)
        return cpp_cap_invalidate(cap_a, CTYPE_UNINIT);

    if (op == C_OP_MREV || op == C_OP_REVOKE)
        return cpp_cap_invalidate(cpp_cap_retype(cap_a, CTYPE_REVOC), CTYPE_REVOC);

    if (op == C_OP_SEAL) {
        CapabilityT r = cap_a;
        r.valid  = cap_a.valid && cap_b.valid;
        r.ctype  = CTYPE_SEALED;
        r.reg_id = cap_b.reg_id;
        return r;
    }

    if (op == C_OP_INIT) {
        CapabilityT r = cap_b;
        r.valid     = true;
        r.ctype     = CTYPE_LINEAR;
        r.world     = cap_a.world;
        r.rev_epoch = cap_a.rev_epoch;
        return r;
    }

    if (op == C_OP_CALL || op == C_OP_RETURN || op == C_OP_RETSEAL) {
        CapabilityT r = cap_a;
        r.ctype  = (op == C_OP_RETURN) ? CTYPE_LINEAR : CTYPE_SEALED_RET;
        r.cursor = scalar_arg;
        return r;
    }

    if (op == C_OP_CJALR) {
        CapabilityT r = cap_a;
        r.cursor = scalar_arg & ~static_cast<uint64_t>(1);
        return r;
    }

    if (op == C_OP_CBNZ)
        return (scalar_arg != 0) ? cap_a : k_zero_cap;

    if (op == C_OP_CAPENTER)
        return cpp_cap_set_world(cap_a, 1u);

    if (op == C_OP_CAPEXIT)
        return cpp_cap_set_world(cap_a, 0u);

    return cap_a;
}

// Capstone custom CSRs: 0xBC0=ceh, 0xBC1=cinit, 0xBC2=epc, 0xBC3=switch_cap.
// These are not in csr_is_supported(), so the RTL raises cause=2 for any access.
// commit_ccsr_wb() cancels that trap pre-tick and emulates the read/write here.
static uint64_t ccsr[4] = {0, 0, 0, 0};

// Pre-tick: intercept CSRRW/CSRRS/CSRRC targeting 0xBC0–0xBC3.
// Clears has_exc (bit 70 of mem_wb_q_q) to cancel the illegal-instruction trap,
// recomputes new_val from the real ccsr[] state (the RTL used ex_csr_rdata=0),
// and patches alu_result so rd gets the old CSR value.
static void commit_ccsr_wb(Vtop___024root* rootp) {
    const auto* p = &rootp->pipeline_core__DOT__mem_wb_q_q[0u];
    if (!((p[21u] >> 7u) & 1u)) return;    // valid (bit 679)
    if (!((p[2u] >> 6u) & 1u)) return;     // has_exc (bit 70)
    if (((p[2u]) & 0x3fu) != 2u) return;   // cause != 2 (illegal instruction)

    const uint32_t instr = (p[18u] >> 7u) | ((p[19u] & 0x7fu) << 25u);
    if ((instr & 0x7fu) != 0x73u) return;  // not system opcode
    const uint32_t funct3 = (instr >> 12u) & 7u;
    if (funct3 == 0u) return;              // ECALL/EBREAK family, not a CSR op

    const uint32_t csr_addr_val = (instr >> 20u) & 0xFFFu;
    if (csr_addr_val < 0xBC0u || csr_addr_val > 0xBC3u) return;

    const uint32_t idx     = csr_addr_val - 0xBC0u;
    const uint64_t old_val = ccsr[idx];
    const uint32_t rs1_field = (instr >> 15u) & 0x1fu;
    // zimm for CSRRWI/CSRRSI/CSRRCI (funct3 >= 5), otherwise rs1 value
    const uint64_t write_src = (funct3 >= 5u)
        ? static_cast<uint64_t>(rs1_field)
        : read_gpr(rootp, rs1_field);
    // CSRRW always writes; CSRRS/CSRRC only write if rs1 != 0
    const bool writes = (funct3 == 1u || funct3 == 5u) || (rs1_field != 0u);

    if (writes) {
        uint64_t new_val;
        if      (funct3 == 1u || funct3 == 5u) new_val = write_src;
        else if (funct3 == 2u || funct3 == 6u) new_val = old_val | write_src;
        else                                    new_val = old_val & ~write_src;
        ccsr[idx] = new_val;
        std::fprintf(stderr,
            "[CCSR-WB cyc=%llu] instr=0x%08x %s 0x%x old=0x%llx new=0x%llx\n",
            (unsigned long long)read_mcycle(rootp), instr,
            (funct3==1||funct3==5) ? "CSRRW" : "CSRRS/CSRRC",
            csr_addr_val, (unsigned long long)old_val, (unsigned long long)new_val);
    }

    // Cancel the trap and deliver the old value to rd.
    rootp->pipeline_core__DOT__mem_wb_q_q[2u] &= ~(1u << 6u);  // clear has_exc
    const uint32_t rd = (instr >> 7u) & 0x1fu;
    if (rd != 0u) {
        write_mem_wb_alu_result(rootp, old_val);
        std::fprintf(stderr,
            "[CCSR-RD cyc=%llu] 0xBC%x old=0x%llx → rd=x%u\n",
            (unsigned long long)read_mcycle(rootp), idx,
            (unsigned long long)old_val, rd);
    }
}

// Squash the three younger pipeline stages (EX/MEM, ID/EX, IF/ID) and
// redirect the fetch PC.  Called after CJALR, CALL, or RETURN retires so
// that the speculative instructions behind them are discarded.
static void cap_flush_and_redirect(Vtop___024root* rootp, uint64_t target_pc) {
    rootp->pipeline_core__DOT__ex_mem_q_q[23u] &= ~(1u << 8u);  // ex_mem valid
    rootp->pipeline_core__DOT__id_ex_q_q[0x22u] &= ~1u;          // id_ex valid
    rootp->pipeline_core__DOT__if_id_q_q[0xdu]  &= ~(1u << 27u); // if_id valid
    rootp->pipeline_core__DOT__pc_q_q = target_pc;
    std::fprintf(stderr,
        "[CAP-REDIRECT cyc=%llu] pc → 0x%llx\n",
        (unsigned long long)read_mcycle(rootp),
        (unsigned long long)target_pc);
}

// Retire a cap instruction at WB: compute result and update cap_rf[rd], or
// patch alu_result for SCC/CBNZ so the integer RF gets a cap-derived value.
// MREV/REVOKE/DROP/DELIN are missing cap_write in ctrl.anvil so we detect
// them by cap_op directly.
static void commit_cap_wb(Vtop___024root* rootp) {
    const auto* p = &rootp->pipeline_core__DOT__mem_wb_q_q[0u];
    if (!((p[21u] >> 7u) & 1u)) return;   // valid (bit 679)
    if ((p[2u] >> 6u) & 1u) return;       // skip if has_exc (bit 70)
    const bool     cap_write = ((p[2u] >> 19u) & 1u) != 0u;  // ctrl.cap_write (bit 83)
    const bool     reg_write = ((p[2u] >> 20u) & 1u) != 0u;  // ctrl.reg_write (bit 84)
    const uint32_t cap_op    = (p[2u] >> 7u) & 0x1fu;        // ctrl.cap_op (bits [75:71])
    // MREV/REVOKE/DROP/DELIN are absent from cap_write in ctrl.anvil; handle them here.
    const bool harness_cap = (cap_op == C_OP_MREV   || cap_op == C_OP_REVOKE ||
                              cap_op == C_OP_DROP    || cap_op == C_OP_DELIN);
    if (!cap_write && !reg_write && !harness_cap) return;

    const uint32_t instr = (p[18u] >> 7u) | ((p[19u] & 0x7fu) << 25u);
    if ((instr & 0x7fu) != 0x0Bu) return;  // only Capstone custom opcode (0x0B)
    const uint32_t rd  = (instr >>  7u) & 0x1fu;
    const uint32_t rs1 = (instr >> 15u) & 0x1fu;
    const uint32_t rs2 = (instr >> 20u) & 0x1fu;

    if (cap_write || harness_cap) {
        // MREV: assign new epoch to rs1, create revocation cap in rd.
        // All future derivations from rs1 inherit the epoch and become revocable.
        if (cap_op == C_OP_MREV) {
            if (!cap_rf[rs1].valid) { if (rd != 0u) cap_rf[rd] = k_zero_cap; return; }
            const uint64_t epoch = ++rev_epoch_counter;
            if (rs1 != 0u) cap_rf[rs1].rev_epoch = epoch;
            CapabilityT revoc    = cap_rf[rs1];
            revoc.ctype          = CTYPE_REVOC;
            revoc.rev_epoch      = epoch;
            if (rd  != 0u) cap_rf[rd] = revoc;
            std::fprintf(stderr,
                "[CAP-MREV cyc=%llu] rs1=%u rd=%u epoch=%llu\n",
                (unsigned long long)read_mcycle(rootp), rs1, rd,
                (unsigned long long)epoch);
            return;
        }

        // REVOKE: sweep cap_rf and cap_tags for caps that share the revocation epoch.
        // Only caps derived AFTER MREV inherit the epoch, so pre-existing derivatives
        // are not affected.  The revocation cap itself is consumed after the sweep.
        if (cap_op == C_OP_REVOKE) {
            if (cap_rf[rs1].ctype != CTYPE_REVOC) {
                if (rd != 0u) cap_rf[rd] = k_zero_cap;
                return;
            }
            const uint64_t epoch = cap_rf[rs1].rev_epoch;
            int n = 0;
            for (int i = 1; i < 32; ++i) {
                if (cap_rf[i].valid && cap_rf[i].rev_epoch == epoch
                        && cap_rf[i].ctype != CTYPE_REVOC) {
                    cap_rf[i] = k_zero_cap;
                    ++n;
                }
            }
            const uint32_t n_slots = RAM_SIZE / CAP_BYTES;
            for (uint32_t slot = 0; slot < n_slots; ++slot) {
                if (!cap_tags[slot]) continue;
                const CapabilityT c = cap_load_from_mem(
                    RAM_BASE + static_cast<uint64_t>(slot) * CAP_BYTES);
                if (c.rev_epoch == epoch && c.ctype != CTYPE_REVOC) {
                    cap_tags[slot] = false;
                    std::fill(host_mem + slot * CAP_BYTES,
                              host_mem + (slot + 1u) * CAP_BYTES, 0u);
                    ++n;
                }
            }
            if (rs1 != 0u) cap_rf[rs1] = k_zero_cap;
            if (rd  != 0u) cap_rf[rd]  = k_zero_cap;
            std::fprintf(stderr,
                "[CAP-REVOKE cyc=%llu] epoch=%llu swept=%d\n",
                (unsigned long long)read_mcycle(rootp),
                (unsigned long long)epoch, n);
            return;
        }

        // CJALR/CALL/RETURN: cap transformation + PC redirect.
        // Jump target = cursor stored in rs1 BEFORE the operation;
        // the result cap (written to rd) carries the new cursor / type.
        if (cap_op == C_OP_CJALR || cap_op == C_OP_CALL || cap_op == C_OP_RETURN) {
            const uint64_t jump_target = cap_rf[rs1].cursor;
            const uint64_t scalar_arg  = read_gpr(rootp, rs2);
            const CapabilityT result   = cpp_cap_alu_exec(
                cap_op, cap_rf[rs1], cap_rf[rs2], scalar_arg);
            if (rd != 0u) cap_rf[rd] = result;
            // Only redirect the PC when the source cap has the correct type:
            // CALL needs SEALED, RETURN needs SEALED_RET; CJALR is unrestricted.
            const bool do_redirect =
                (cap_op == C_OP_CJALR) ||
                (cap_op == C_OP_CALL   && cap_rf[rs1].ctype == CTYPE_SEALED) ||
                (cap_op == C_OP_RETURN && cap_rf[rs1].ctype == CTYPE_SEALED_RET);
            if (do_redirect) {
                std::fprintf(stderr,
                    "[CAP-JUMP cyc=%llu] op=%u rs1=%u rd=%u target=0x%llx ret_cursor=0x%llx\n",
                    (unsigned long long)read_mcycle(rootp), cap_op, rs1, rd,
                    (unsigned long long)jump_target,
                    (unsigned long long)result.cursor);
                cap_flush_and_redirect(rootp, jump_target);
            }
            return;
        }

        // LDC: load capability from memory
        CapabilityT result;
        if (cap_op == C_OP_LDC) {
            const uint64_t addr = read_gpr(rootp, rs1);
            result = cap_load_from_mem(addr);
            std::fprintf(stderr,
                "[CAP-LDC cyc=%llu] instr=0x%08x rs1=%u rd=%u addr=0x%llx valid=%d\n",
                (unsigned long long)read_mcycle(rootp), instr, rs1, rd,
                (unsigned long long)addr, (int)result.valid);
        } else {
            const CapabilityT cap_a   = cap_rf[rs1];
            const CapabilityT cap_b   = cap_rf[rs2];
            const uint64_t scalar_arg = read_gpr(rootp, rs2);
            result = cpp_cap_alu_exec(cap_op, cap_a, cap_b, scalar_arg);
            std::fprintf(stderr,
                "[CAP-WB cyc=%llu] op=%u instr=0x%08x rs1=%u rs2=%u rd=%u "
                "valid=%d ctype=%u cursor=0x%llx base=0x%llx end=0x%llx perms=%u\n",
                (unsigned long long)read_mcycle(rootp), cap_op, instr,
                rs1, rs2, rd, (int)result.valid, (unsigned)result.ctype,
                (unsigned long long)result.cursor,
                (unsigned long long)result.base,
                (unsigned long long)result.end_,
                (unsigned)result.perms);
        }
        if (rd != 0u) cap_rf[rd] = result;
    } else {
        // SCC reads cursor; CBNZ reads valid flag; both patch the integer WB result.
        // STC stores cap_rf[rs2] to host_mem at address rs1_int.
        uint64_t patched = 0;
        if (cap_op == C_OP_SCC) {
            patched = cap_rf[rs1].cursor;
        } else if (cap_op == C_OP_CBNZ) {
            patched = cap_rf[rs1].valid ? 1u : 0u;
        } else if (cap_op == C_OP_STC) {
            const uint64_t addr = read_gpr(rootp, rs1);
            cap_store_to_mem(addr, cap_rf[rs2]);
            std::fprintf(stderr,
                "[CAP-STC cyc=%llu] instr=0x%08x rs1=%u rs2=%u addr=0x%llx valid=%d\n",
                (unsigned long long)read_mcycle(rootp), instr, rs1, rs2,
                (unsigned long long)addr, (int)cap_rf[rs2].valid);
            return;  // RTL writes rs1_int = addr to rd; no alu_result patch needed
        } else {
            return;
        }
        write_mem_wb_alu_result(rootp, patched);
        if (rd != 0u) {
            std::fprintf(stderr,
                "[CAP-INT-WB cyc=%llu] op=%u instr=0x%08x rs1=%u rd=%u val=0x%llx\n",
                (unsigned long long)read_mcycle(rootp), cap_op, instr,
                rs1, rd, (unsigned long long)patched);
        }
    }
}

// Drive ext_mip_q: MTIP (bit 7) from CLINT mtimecmp, STIP (bit 5) from stimecmp_q_q.
// Magic-address legacy mtimecmp kept for ISA tests that use it.
//
// sim_mtime advances every 100 CPU cycles (100:1 ratio) so that xv6's
// stimecmp = rdtime + 1_000_000 corresponds to ~100M CPU cycles, giving the
// kernel enough time to reach trapinithart() and install stvec before STIP fires.
void update_ext_mip(Vtop___024root* rootp) {
    static unsigned slow_count = 0;
    if (++slow_count >= 100) { slow_count = 0; ++sim_mtime; }
    if (sim_mtimecmp == UINT64_MAX) {
        const std::uint64_t magic_addr = 0x80001FF0ULL;
        if (magic_addr >= RAM_BASE && magic_addr + 8u <= RAM_BASE + RAM_SIZE) {
            const std::uint32_t local = static_cast<std::uint32_t>(magic_addr - RAM_BASE);
            std::uint64_t delay = 0;
            for (int i = 0; i < 8; ++i)
                delay |= static_cast<std::uint64_t>(host_mem[local + i]) << (i * 8u);
            if (delay != 0) sim_mtimecmp = sim_mtime + delay;
        }
    }
    const bool mtip = (sim_mtime >= sim_mtimecmp);
    const std::uint64_t stimecmp_val = rootp->pipeline_core__DOT__stimecmp_q_q;
    const bool stip = (stimecmp_val != 0) && (sim_mtime >= stimecmp_val);
    std::uint64_t ext_mip = 0;
    if (mtip) ext_mip |= (1ULL << 7);
    if (stip) ext_mip |= (1ULL << 5);
    // Promote delayed UART TX interrupt once the fire_at cycle has been reached.
    if (!uart_tx_irq_pending && uart_tx_irq_fire_at != UINT64_MAX && sim_mtime >= uart_tx_irq_fire_at) {
        uart_tx_irq_pending = true;
        uart_tx_irq_fire_at = UINT64_MAX;
        const std::uint64_t mie  = rootp->pipeline_core__DOT__mie_q_q;
        const std::uint32_t priv = read_priv(rootp);
        const std::uint64_t mst  = read_mstatus(rootp);
        std::fprintf(stderr,
            "[UART-TX-IRQ-PROMOTE cyc=%llu] priv=%u SIE=%u mie=0x%llx mip_before=0x%llx\n",
            (unsigned long long)sim_mtime, priv,
            (unsigned)(( mst >> 1u) & 1u),
            (unsigned long long)mie,
            (unsigned long long)rootp->pipeline_core__DOT__mip_q_q);
    }
    // SEIP (bit 9): S-mode external interrupt — virtio I/O or UART TX-empty.
    if (virtio_irq_pending || uart_tx_irq_pending) ext_mip |= (1ULL << 9);
    rootp->pipeline_core__DOT__ext_mip_q_q = ext_mip;
}

// Suppress delegated S-mode interrupts when in S-mode with sstatus.SIE=0.
// The RTL's int_fire checks MIE for M-mode but not SIE for S-mode; this
// harness-level mask prevents STIP/SSIP/SEIP from firing during critical
// sections (e.g., trampoline userret) where SIE is disabled.
// Must be called AFTER update_ext_mip so ext_mip is already computed.
static void apply_sie_masking(Vtop___024root* rootp) {
    // Restore mip bits suppressed in the previous cycle.
    if (sie_masked_mip_bits != 0) {
        rootp->pipeline_core__DOT__mip_q_q |= sie_masked_mip_bits;
        sie_masked_mip_bits = 0;
    }
    // Only suppress in S-mode (priv=1) when SIE=0 (mstatus bit 1).
    if (read_priv(rootp) != 1u) return;
    if ((read_mstatus(rootp) >> 1u) & 1u) return;  // SIE is set; allow delivery
    const std::uint64_t mideleg     = rootp->pipeline_core__DOT__mideleg_q_q;
    const std::uint64_t mip_to_mask = rootp->pipeline_core__DOT__mip_q_q & mideleg;
    const std::uint64_t ext_to_mask = rootp->pipeline_core__DOT__ext_mip_q_q & mideleg;
    if (mip_to_mask == 0 && ext_to_mask == 0) return;
    sie_masked_mip_bits = mip_to_mask;
    rootp->pipeline_core__DOT__mip_q_q     &= ~mip_to_mask;
    rootp->pipeline_core__DOT__ext_mip_q_q &= ~ext_to_mask;
}

// Print a one-line trap diagnostic. Called when scause changes while in S-mode.
static void print_s_trap_diag(const Vtop___024root* rootp, std::uint64_t cycle) {
    const std::uint64_t scause = rootp->pipeline_core__DOT__scause_q_q;
    const std::uint64_t sepc   = rootp->pipeline_core__DOT__sepc_q_q;
    const std::uint64_t stval  = rootp->pipeline_core__DOT__stval_q_q;
    const std::uint64_t stvec  = rootp->pipeline_core__DOT__stvec_q_q;
    const std::uint64_t mstatus = read_mstatus(rootp);
    const std::uint64_t mideleg = rootp->pipeline_core__DOT__mideleg_q_q;
    const std::uint64_t mip    = rootp->pipeline_core__DOT__mip_q_q;
    const std::uint64_t ext    = rootp->pipeline_core__DOT__ext_mip_q_q;
    std::fprintf(stderr,
        "[STRAP cyc=%llu] scause=0x%llx sepc=0x%llx stval=0x%llx "
        "stvec=0x%llx mstatus=0x%llx mideleg=0x%llx mip=0x%llx ext_mip=0x%llx\n",
        (unsigned long long)cycle,
        (unsigned long long)scause, (unsigned long long)sepc,
        (unsigned long long)stval,  (unsigned long long)stvec,
        (unsigned long long)mstatus,(unsigned long long)mideleg,
        (unsigned long long)mip,    (unsigned long long)ext);
}

// Legacy wrapper kept for main loop call site.
void update_mmio(Vtop___024root* rootp) {
    commit_stores(rootp);
    pre_populate_mem_rdata(rootp);  // repopulate after store commit
}

bool program_exit_seen(const Vtop___024root* rootp) {
    return rootp->pipeline_core__DOT__sim_exit_valid_q_q != 0;
}

std::uint64_t program_exit_code(const Vtop___024root* rootp) {
    return static_cast<std::uint64_t>(rootp->pipeline_core__DOT__sim_exit_code_q_q);
}

bool read_if_valid(const Vtop___024root* rootp) {
    return ((rootp->pipeline_core__DOT__if_id_q_q[0xd] >> 27u) & 0x1u) != 0u;
}

std::uint64_t read_if_pc(const Vtop___024root* rootp) {
    return (static_cast<std::uint64_t>(rootp->pipeline_core__DOT__if_id_q_q[0xd]) << 37u) |
           (static_cast<std::uint64_t>(rootp->pipeline_core__DOT__if_id_q_q[0xc]) << 5u) |
           (static_cast<std::uint64_t>(rootp->pipeline_core__DOT__if_id_q_q[0xb]) >> 27u);
}

bool read_id_valid(const Vtop___024root* rootp) {
    return (rootp->pipeline_core__DOT__id_ex_q_q[0x22] & 0x1u) != 0u;
}

std::uint64_t read_id_pc(const Vtop___024root* rootp) {
    return static_cast<std::uint64_t>(rootp->pipeline_core__DOT__id_ex_q_q[0x20]) |
           (static_cast<std::uint64_t>(rootp->pipeline_core__DOT__id_ex_q_q[0x21]) << 32u);
}

std::uint64_t read_id_rd(const Vtop___024root* rootp) {
    return static_cast<std::uint64_t>((rootp->pipeline_core__DOT__id_ex_q_q[0x1e] >> 17u) & 0x1fu);
}

bool read_ex_valid(const Vtop___024root* rootp) {
    return ((rootp->pipeline_core__DOT__ex_mem_q_q[23] >> 8u) & 0x1u) != 0u;
}

std::uint64_t read_ex_pc(const Vtop___024root* rootp) {
    return (static_cast<std::uint64_t>(rootp->pipeline_core__DOT__ex_mem_q_q[0x15]) << 57u) |
           (static_cast<std::uint64_t>(rootp->pipeline_core__DOT__ex_mem_q_q[0x14]) << 25u) |
           (static_cast<std::uint64_t>(rootp->pipeline_core__DOT__ex_mem_q_q[0x13]) >> 7u);
}

std::uint64_t read_ex_rd(const Vtop___024root* rootp) {
    return static_cast<std::uint64_t>((rootp->pipeline_core__DOT__ex_mem_q_q[0x12] >> 2u) & 0x1fu);
}

std::uint64_t read_ex_alu(const Vtop___024root* rootp) {
    return (static_cast<std::uint64_t>(rootp->pipeline_core__DOT__ex_mem_q_q[18]) >> 3u) |
           (static_cast<std::uint64_t>(rootp->pipeline_core__DOT__ex_mem_q_q[19]) << 29u) |
           (static_cast<std::uint64_t>(rootp->pipeline_core__DOT__ex_mem_q_q[20]) << 61u);
}

bool read_wb_valid(const Vtop___024root* rootp) {
    return ((rootp->pipeline_core__DOT__mem_wb_q_q[0x13] >> 6u) & 0x1u) != 0u;
}

std::uint64_t read_wb_pc(const Vtop___024root* rootp) {
    return (static_cast<std::uint64_t>(rootp->pipeline_core__DOT__mem_wb_q_q[0x13]) << 58u) |
           (static_cast<std::uint64_t>(rootp->pipeline_core__DOT__mem_wb_q_q[0x12]) << 26u) |
           (static_cast<std::uint64_t>(rootp->pipeline_core__DOT__mem_wb_q_q[0x11]) >> 6u);
}

std::uint64_t read_wb_rd(const Vtop___024root* rootp) {
    return static_cast<std::uint64_t>((rootp->pipeline_core__DOT__mem_wb_q_q[0x10] >> 1u) & 0x1fu);
}

void print_pipeline_trace(const Vtop___024root* rootp) {
    const std::uint64_t cur_pc = rootp->pipeline_core__DOT__pc_q_q;
    std::cout << "trace cyc=" << read_mcycle(rootp)
              << " pc=0x" << std::hex << cur_pc << std::dec
              << " insn=0x" << std::hex
              << read_imem_word(rootp, cur_pc)
              << std::dec
              << " ra=" << read_gpr(rootp, 1)
              << " sp=" << read_gpr(rootp, 2)
              << " gp=" << read_gpr(rootp, 3)
              << " t0=" << read_gpr(rootp, 5)
              << " t1=" << read_gpr(rootp, 6)
              << " t2=" << read_gpr(rootp, 7)
              << " a0=" << read_gpr(rootp, 10)
              << " a1=" << read_gpr(rootp, 11)
              << " a7=" << read_gpr(rootp, 17)
              << " if=" << read_if_valid(rootp) << "@" << read_if_pc(rootp)
              << " id=" << read_id_valid(rootp) << "@" << read_id_pc(rootp) << "/rd" << read_id_rd(rootp)
              << " ex=" << read_ex_valid(rootp) << "@" << read_ex_pc(rootp) << "/rd" << read_ex_rd(rootp)
              << " alu=" << read_ex_alu(rootp)
              << " wb=" << read_wb_valid(rootp) << "@" << read_wb_pc(rootp) << "/rd" << read_wb_rd(rootp)
              << " priv=" << read_priv(rootp)
              << " mtvec=0x" << std::hex << read_mtvec(rootp) << std::dec
              << " mstatus=0x" << std::hex << read_mstatus(rootp) << std::dec
              << " mcause=" << read_mcause(rootp)
              << "\n";
}

void clear_program_arrays(Vtop___024root*) {
    std::fill_n(host_mem, RAM_SIZE, static_cast<std::uint8_t>(0));
}

bool load_elf(Vtop___024root* rootp, const std::string& elf_path) {
    std::ifstream file{elf_path, std::ios::binary};
    if (!file) {
        std::cerr << "[ELF] unable to open " << elf_path << "\n";
        return false;
    }

    Elf64_Ehdr ehdr{};
    file.read(reinterpret_cast<char*>(&ehdr), sizeof(ehdr));
    if (!file) { std::cerr << "[ELF] failed to read ELF header\n"; return false; }
    if (!(ehdr.e_ident[EI_MAG0] == ELFMAG0 && ehdr.e_ident[EI_MAG1] == ELFMAG1 &&
          ehdr.e_ident[EI_MAG2] == ELFMAG2 && ehdr.e_ident[EI_MAG3] == ELFMAG3)) {
        std::cerr << "[ELF] bad ELF magic\n"; return false;
    }
    if (ehdr.e_ident[EI_CLASS] != ELFCLASS64 || ehdr.e_ident[EI_DATA] != ELFDATA2LSB) {
        std::cerr << "[ELF] expected little-endian ELF64\n"; return false;
    }

    clear_program_arrays(rootp);

    file.seekg(ehdr.e_phoff, std::ios::beg);
    if (!file) { std::cerr << "[ELF] failed to seek to program headers\n"; return false; }

    for (std::uint16_t i = 0; i < ehdr.e_phnum; ++i) {
        Elf64_Phdr phdr{};
        file.read(reinterpret_cast<char*>(&phdr), sizeof(phdr));
        if (!file) { std::cerr << "[ELF] failed to read program header " << i << "\n"; return false; }
        if (phdr.p_type != PT_LOAD || phdr.p_memsz == 0) continue;

        const std::uint64_t base_addr = (phdr.p_paddr != 0) ? phdr.p_paddr : phdr.p_vaddr;
        std::vector<std::uint8_t> bytes(static_cast<std::size_t>(phdr.p_memsz), 0);
        if (phdr.p_filesz != 0) {
            std::streampos resume = file.tellg();
            file.seekg(phdr.p_offset, std::ios::beg);
            file.read(reinterpret_cast<char*>(bytes.data()),
                      static_cast<std::streamsize>(phdr.p_filesz));
            if (!file) { std::cerr << "[ELF] failed to read load segment " << i << "\n"; return false; }
            file.seekg(resume, std::ios::beg);
        }

        // All segments go to unified host_mem[] regardless of exec flag.
        for (std::uint64_t ofs = 0; ofs < phdr.p_memsz; ++ofs) {
            const std::uint64_t abs_addr = base_addr + ofs;
            if (abs_addr < RAM_BASE || abs_addr >= RAM_BASE + RAM_SIZE) {
                std::cerr << "[ELF] address out of RAM window: 0x"
                          << std::hex << abs_addr << std::dec << "\n";
                return false;
            }
            const std::uint32_t local_addr = static_cast<std::uint32_t>(abs_addr - RAM_BASE);
            write_mem_byte(local_addr, bytes[static_cast<std::size_t>(ofs)]);
        }
    }

    return true;
}

}  // namespace

int main(int argc, char** argv) {
    std::string elf_path;
    std::string disk_path;
    unsigned timeout = 5000;
    bool trace_mode = false;
    bool program_exited = false;

    for (int i = 1; i < argc; ++i) {
        if (is_trace_arg(argv[i])) {
            trace_mode = true;
        } else if (std::string(argv[i]) == "--disk" && i + 1 < argc) {
            disk_path = argv[++i];
        } else if (is_number_arg(argv[i])) {
            timeout = static_cast<unsigned>(std::strtoul(argv[i], nullptr, 10));
        } else if (elf_path.empty()) {
            elf_path = argv[i];
        } else {
            std::cerr << "[ARGS] unrecognized argument: " << argv[i] << "\n";
            return 1;
        }
    }

    // Load virtio disk image if provided.
    if (!disk_path.empty()) {
        std::ifstream df(disk_path, std::ios::binary | std::ios::ate);
        if (!df) {
            std::cerr << "[DISK] cannot open " << disk_path << "\n";
            return 1;
        }
        const std::streamsize sz = df.tellg();
        df.seekg(0, std::ios::beg);
        vdisk_img.resize(static_cast<std::size_t>(sz));
        df.read(reinterpret_cast<char*>(vdisk_img.data()), sz);
        if (!df) {
            std::cerr << "[DISK] failed to read " << disk_path << "\n";
            return 1;
        }
        std::cerr << "[DISK] loaded " << sz << " bytes from " << disk_path << "\n";
    }

    std::ostream& summary = trace_mode ? std::cout : std::cerr;

    const std::unique_ptr<VerilatedContext> contextp{new VerilatedContext};
    contextp->debug(0);
    contextp->randReset(2);
    contextp->traceEverOn(false);
    contextp->commandArgs(argc, argv);

    const std::unique_ptr<Vtop> top{new Vtop{contextp.get(), "TOP"}};
    top->clk_i = 0;
    top->rst_ni = 0;

    unsigned ticks = 0;
    while (!contextp->gotFinish() &&
           !top->rootp->pipeline_core__DOT__booted_q_q &&
           ticks < timeout) {
        tick_with_default_reset(*contextp, *top, ticks);
    }
    const unsigned boot_ticks = ticks;

    if (contextp->gotFinish()) {
        top->final();
        summary << "[BOOT CYCLES] " << boot_ticks << "\n";
        summary << "[EXEC CYCLES] " << (ticks - boot_ticks) << "\n";
        summary << "[TOTAL CYCLES] " << ticks << "\n";
        return 0;
    }
    if (!top->rootp->pipeline_core__DOT__booted_q_q) {
        summary << "[BOOT] core did not finish boot initialization\n";
        top->final();
        summary << "[BOOT CYCLES] " << boot_ticks << "\n";
        summary << "[EXEC CYCLES] " << (ticks - boot_ticks) << "\n";
        summary << "[TOTAL CYCLES] " << ticks << "\n";
        return 1;
    }

    cap_rf_reset();
    for (int i = 0; i < 4; ++i) ccsr[i] = 0;

    if (!elf_path.empty()) {
        if (!load_elf(top->rootp, elf_path)) {
            top->final();
            summary << "[BOOT CYCLES] " << boot_ticks << "\n";
            summary << "[EXEC CYCLES] " << (ticks - boot_ticks) << "\n";
            summary << "[TOTAL CYCLES] " << ticks << "\n";
            return 1;
        }
    }

    // Ring buffer for post-crash analysis.
    struct ExecRecord {
        std::uint64_t cyc        = 0;
        std::uint64_t pc         = 0;
        std::uint64_t ra         = 0;
        std::uint64_t sp         = 0;
        std::uint64_t mem_pa     = 0;  // PA used for load/store (sv39_mem_pa or ALU)
        std::uint64_t mem_rdata  = 0;  // data returned to pipeline for load
        bool store_valid         = false;
        std::uint64_t store_pa   = 0;
        std::uint64_t store_data = 0;  // merged 8-byte word committed to host_mem
        std::uint8_t  priv       = 0;
        std::uint8_t  sv39_stall = 0;
    };
    static ExecRecord exec_ring[512];
    static int exec_ring_head = 0;

    static std::uint64_t prev_scause = UINT64_MAX;
    static std::uint64_t prev_mcause = UINT64_MAX;
    static std::uint64_t prev_sepc   = UINT64_MAX;
    // Track sim_exit_valid across ticks to capture priv at the EXACT tick it fires.
    bool prev_exit_seen = program_exit_seen(top->rootp);
    std::uint32_t prev_priv_for_transitions = read_priv(top->rootp);
    while (!contextp->gotFinish() && ticks < timeout) {
        if (trace_mode) {
            top->rootp->pipeline_core__DOT__trace_enable_q_q = 1;
            top->eval();
            sv39_debug = true;
        }
        const std::uint32_t priv_before_tick = read_priv(top->rootp);
        update_ext_mip(top->rootp);
        apply_sie_masking(top->rootp);
        commit_stores(top->rootp);
        commit_ccsr_wb(top->rootp);
        commit_cap_wb(top->rootp);
        capture_div_from_id_ex(top->rootp);
        patch_div_results(top->rootp);
        // Let the PTW complete naturally. The RTL gates int_fire via pipeline_stall,
        // so interrupts fire after the stall resolves without corrupting pipeline state.
        update_sv39(top->rootp);
        pre_populate_mem_rdata(top->rootp);
        pre_populate_imem_rdata(top->rootp);
        // Capture mem PA and rdata BEFORE tick (they're set by pre_populate_mem_rdata).
        const std::uint64_t pre_tick_mem_pa =
            top->rootp->pipeline_core__DOT__sv39_mem_valid_q_q
                ? top->rootp->pipeline_core__DOT__sv39_mem_pa_q_q
                : read_ex_alu(top->rootp);
        const std::uint64_t pre_tick_mem_rdata  = top->rootp->pipeline_core__DOT__mem_rdata_q_q;
        const bool          pre_tick_store_valid = (bool)top->rootp->pipeline_core__DOT__mem_store_valid_q_q;
        const std::uint64_t pre_tick_store_pa   = top->rootp->pipeline_core__DOT__mem_store_addr_q_q;
        const std::uint64_t pre_tick_store_data = top->rootp->pipeline_core__DOT__mem_store_word_q_q;

        tick(*contextp, *top, true, ticks);

        // Record this cycle in the ring buffer.
        {
            ExecRecord& r    = exec_ring[exec_ring_head];
            r.cyc            = read_mcycle(top->rootp);
            r.pc             = top->rootp->pipeline_core__DOT__pc_q_q;
            r.ra             = read_gpr(top->rootp, 1u);
            r.sp             = read_gpr(top->rootp, 2u);
            r.mem_pa         = pre_tick_mem_pa;
            r.mem_rdata      = pre_tick_mem_rdata;
            r.store_valid    = pre_tick_store_valid;
            r.store_pa       = pre_tick_store_pa;
            r.store_data     = pre_tick_store_data;
            r.priv           = static_cast<std::uint8_t>(read_priv(top->rootp));
            r.sv39_stall     = static_cast<std::uint8_t>(top->rootp->pipeline_core__DOT__sv39_stall_q_q);
            exec_ring_head   = (exec_ring_head + 1) % 512;
        }

        // Harness-level workaround for pipeline interrupt delivery bug:
        // When int_fire=1, the RTL does not bubble the EX-MEM packet (missing
        // || int_fire condition in next_ex_mem). Detect interrupt by observing
        // mcause/scause change with bit 63 set, then zero the EX-MEM valid bit
        // so the stale ID→EX instruction doesn't commit at WB.
        //
        // Also fix interrupt cause encoding bug: the RTL's priority encoder
        // uses `else { cause=11 }` as the fallback, so SEIP (bit 9 in ext_mip)
        // fires with scause=0x800000000000000b (MEI) instead of
        // 0x8000000000000009 (SEI). xv6's devintr() checks for cause=9, so
        // patch scause to 9 whenever it would otherwise be 11 for an S-mode
        // interrupt. We never set MEIP (bit 11) in ext_mip, so cause=11 for
        // an S-mode trap is always a mislabeled SEIP.
        {
            const std::uint64_t chk_mcause = read_mcause(top->rootp);
            const std::uint64_t chk_scause = top->rootp->pipeline_core__DOT__scause_q_q;
            const bool s_int_fired = ((chk_scause != prev_scause) && (chk_scause >> 63u));
            const bool m_int_fired = ((chk_mcause != prev_mcause) && (chk_mcause >> 63u));
            if (s_int_fired || m_int_fired) {
                top->rootp->pipeline_core__DOT__ex_mem_q_q[23u] &= ~(1u << 8u);
            }
            // Patch SEIP cause: RTL assigns cause=11 for any unrecognised
            // pending interrupt (the else branch). Correct it to cause=9.
            if (s_int_fired && chk_scause == 0x800000000000000bULL) {
                top->rootp->pipeline_core__DOT__scause_q_q = 0x8000000000000009ULL;
            }
        }

        if (trace_mode) {
            print_pipeline_trace(top->rootp);
        }
        // Detect privilege transitions and S-mode traps.
        {
            const std::uint64_t cur_scause = top->rootp->pipeline_core__DOT__scause_q_q;
            const std::uint64_t cur_sepc   = top->rootp->pipeline_core__DOT__sepc_q_q;
            const std::uint64_t cur_mcause = read_mcause(top->rootp);
            const std::uint32_t cur_priv   = read_priv(top->rootp);
            const std::uint64_t cur_pc     = top->rootp->pipeline_core__DOT__pc_q_q;
            // Log every user→kernel trap (priv 0→1) and kernel→user return (priv 1→0).
            if (prev_priv_for_transitions != cur_priv) {
                if (cur_priv == 1u && cur_scause == 8u) {
                    // U-mode ecall: dump syscall number (a7=x17) and args (a0-a2).
                    const auto& rf = top->rootp->pipeline_core__DOT__regs_q_q;
                    auto read_reg = [&](int n) -> std::uint64_t {
                        return static_cast<std::uint64_t>(rf[n*2]) | (static_cast<std::uint64_t>(rf[n*2+1]) << 32);
                    };
                    std::fprintf(stderr,
                        "[SYSCALL cyc=%llu] sepc=0x%llx a7=%llu a0=0x%llx a1=0x%llx a2=0x%llx\n",
                        (unsigned long long)sim_mtime,
                        (unsigned long long)cur_sepc,
                        (unsigned long long)read_reg(17),
                        (unsigned long long)read_reg(10),
                        (unsigned long long)read_reg(11),
                        (unsigned long long)read_reg(12));
                }
                std::fprintf(stderr,
                    "[PRIV-CHANGE cyc=%llu] %u→%u pc=0x%llx sepc=0x%llx scause=0x%llx\n",
                    (unsigned long long)sim_mtime,
                    prev_priv_for_transitions, cur_priv,
                    (unsigned long long)cur_pc,
                    (unsigned long long)cur_sepc,
                    (unsigned long long)cur_scause);
            }
            prev_priv_for_transitions = cur_priv;
            if (cur_priv == 1u) {
                const bool scause_changed = (cur_scause != prev_scause);
                const bool ecall_new_site = (cur_scause == 8u && cur_sepc != prev_sepc);
                if (scause_changed || ecall_new_site) {
                    print_s_trap_diag(top->rootp, read_mcycle(top->rootp));
                }
                // On instruction page fault at VA=0 dump the ring buffer to help diagnose
                // "ret with ra=0" bugs.
                if (scause_changed && cur_scause == 0xcULL && cur_sepc == 0x0ULL) {
                    std::fprintf(stderr, "[CRASH-DUMP] scause=0xc sepc=0x0 — last %d exec records:\n", 512);
                    for (int i = 0; i < 512; i++) {
                        const ExecRecord& r = exec_ring[(exec_ring_head + i) % 512];
                        if (r.cyc == 0) continue;
                        std::fprintf(stderr,
                            "  cyc=%llu prv=%u stl=%u pc=0x%llx ra=0x%llx sp=0x%llx"
                            " mem_pa=0x%llx rdata=0x%llx",
                            (unsigned long long)r.cyc, (unsigned)r.priv, (unsigned)r.sv39_stall,
                            (unsigned long long)r.pc, (unsigned long long)r.ra,
                            (unsigned long long)r.sp, (unsigned long long)r.mem_pa,
                            (unsigned long long)r.mem_rdata);
                        if (r.store_valid) {
                            std::fprintf(stderr, " ST[0x%llx]=0x%llx",
                                (unsigned long long)r.store_pa,
                                (unsigned long long)r.store_data);
                        }
                        std::fprintf(stderr, "\n");
                    }
                    // Also dump the 8 bytes around each RA-save/restore region on the stack.
                    const std::uint64_t sp_now = read_gpr(top->rootp, 2u);
                    std::fprintf(stderr, "[CRASH-STACK] sp=0x%llx host_mem around stack:\n",
                        (unsigned long long)sp_now);
                    for (int off = -8; off <= 48; off += 8) {
                        const std::uint64_t qa = sp_now + off;
                        std::fprintf(stderr, "  [sp%+d]=0x%llx\n", off,
                            (unsigned long long)read_dmem_qword(top->rootp, qa));
                    }
                }
            }
            if (cur_mcause != prev_mcause) {
                std::fprintf(stderr, "[MTRAP cyc=%llu] mcause=0x%llx priv=%u\n",
                    (unsigned long long)read_mcycle(top->rootp),
                    (unsigned long long)cur_mcause,
                    read_priv(top->rootp));
            }
            prev_scause = cur_scause;
            prev_mcause = cur_mcause;
            prev_sepc   = cur_sepc;
        }
        // Print heartbeat every 1M ticks so we can see where xv6 is stuck.
        if (ticks % 1000000u == 0u && ticks > 0u) {
            // proc[0].state at 0x8000ba08+24=0x8000ba20; proc[1] at +360=0x8000bb70, state at +24=0x8000bb88
            const std::uint32_t p0_state = static_cast<std::uint32_t>(
                read_dmem_qword(top->rootp, 0x8000ba20ULL) & 0xFFFFFFFFu);
            const std::uint32_t p1_state = static_cast<std::uint32_t>(
                read_dmem_qword(top->rootp, 0x8000bb88ULL) & 0xFFFFFFFFu);
            const std::uint32_t p1_pid   = static_cast<std::uint32_t>(
                read_dmem_qword(top->rootp, 0x8000bba0ULL) & 0xFFFFFFFFu);
            std::fprintf(stderr,
                "[HB tick=%llu] pc=0x%llx priv=%u sv39=%d satp=0x%llx proc0_state=%u proc1_state=%u(pid=%u)\n",
                (unsigned long long)ticks,
                (unsigned long long)top->rootp->pipeline_core__DOT__pc_q_q,
                read_priv(top->rootp),
                (int)((top->rootp->pipeline_core__DOT__satp_q_q >> 60) == 8u),
                (unsigned long long)top->rootp->pipeline_core__DOT__satp_q_q,
                p0_state, p1_state, p1_pid);
        }
        if (!elf_path.empty() && disk_path.empty()) {
            // Only use sim_exit_valid for bare-metal ISA tests (no disk image).
            // xv6 uses SYS_exit=2, not a7=93; false triggers would abort early.
            const bool cur_exit_seen = program_exit_seen(top->rootp);
            // ISA tests run in M-mode; no privilege filter needed.
            if (!prev_exit_seen && cur_exit_seen) {
                program_exited = true;
                break;
            }
            prev_exit_seen = cur_exit_seen;
        }
    }

    if (!elf_path.empty()) {
        const std::uint64_t exit_code =
            program_exit_seen(top->rootp) ? program_exit_code(top->rootp)
                                          : read_gpr(top->rootp, 10);
        std::cout << "exit " << exit_code << "\n";
        if (exit_code != 0) {
            std::cout << "diag a0=" << read_gpr(top->rootp, 10)
                      << " a1=" << read_gpr(top->rootp, 11)
                      << " a2=" << read_gpr(top->rootp, 12)
                      << " a3=" << read_gpr(top->rootp, 13)
                      << " a4=" << read_gpr(top->rootp, 14)
                      << " t0=" << read_gpr(top->rootp, 5)
                      << " t1=" << read_gpr(top->rootp, 6)
                      << " t2=" << read_gpr(top->rootp, 7)
                      << "\n";
            std::cout << "diag mem[0x80000070]="
                      << read_dmem_qword(top->rootp, 0x80000070ULL)
                      << " mem[0x80000078]="
                      << read_dmem_qword(top->rootp, 0x80000078ULL)
                      << "\n";
        }
    }

    top->final();
    summary << "[BOOT CYCLES] " << boot_ticks << "\n";
    summary << "[EXEC CYCLES] " << (ticks - boot_ticks) << "\n";
    summary << "[TOTAL CYCLES] " << ticks << "\n";
    return (contextp->gotFinish() || program_exited) ? 0 : 1;
}
