// Program-oriented Verilator harness for pipeline_core.
//
// Usage:
//   Vpipeline_core program.elf [timeout] [--trace]
//
// The core still performs its internal boot initialization first. Once the
// boot flag goes high, this harness clears IMEM/DMEM and loads the ELF PT_LOAD
// segments directly into the exposed Verilated arrays before allowing the core
// to execute the first real instruction.

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

namespace {

bool is_number_arg(const char* arg) {
    if (arg == nullptr || *arg == '\0') {
        return false;
    }
    for (const char* p = arg; *p != '\0'; ++p) {
        if (!std::isdigit(static_cast<unsigned char>(*p))) {
            return false;
        }
    }
    return true;
}

bool is_trace_arg(const char* arg) {
    return arg != nullptr && std::string(arg) == "--trace";
}

void half_tick(VerilatedContext& context, Vtop& top, bool rst_n) {
    context.timeInc(1);
    top.clk_i = !top.clk_i;
    if (!top.clk_i) {
        top.rst_ni = rst_n ? 1 : 0;
    }
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
    if (!top.clk_i) {
        top.rst_ni = default_reset_level(context.time()) ? 1 : 0;
    }
    top.eval();

    context.timeInc(1);
    top.clk_i = !top.clk_i;
    if (!top.clk_i) {
        top.rst_ni = default_reset_level(context.time()) ? 1 : 0;
    }
    top.eval();

    ++ticks;
}

void write_imem_byte(Vtop___024root* rootp, std::uint32_t addr, std::uint8_t value) {
    const std::uint32_t word_idx = addr >> 2;
    const std::uint32_t byte_shift = (addr & 0x3u) * 8u;
    std::uint32_t& slot = rootp->pipeline_core__DOT__imem_q_q[word_idx];
    slot = (slot & ~(0xffu << byte_shift)) | (static_cast<std::uint32_t>(value) << byte_shift);
}

void write_dmem_byte(Vtop___024root* rootp, std::uint32_t addr, std::uint8_t value) {
    const std::uint32_t word_idx = addr >> 3;
    const std::uint32_t byte_in_word = addr & 0x7u;
    const std::uint32_t lane_idx = (word_idx << 1) | (byte_in_word >> 2);
    const std::uint32_t byte_shift = (byte_in_word & 0x3u) * 8u;
    std::uint32_t& lane = rootp->pipeline_core__DOT__dmem_q_q[lane_idx];
    lane = (lane & ~(0xffu << byte_shift)) | (static_cast<std::uint32_t>(value) << byte_shift);
}

std::uint64_t read_gpr(const Vtop___024root* rootp, unsigned idx) {
    const auto* lanes = &rootp->pipeline_core__DOT__regs_q_q[0];
    const unsigned base = idx * 2u;
    return static_cast<std::uint64_t>(lanes[base]) |
           (static_cast<std::uint64_t>(lanes[base + 1u]) << 32u);
}

std::uint64_t read_dmem_qword(const Vtop___024root* rootp, std::uint32_t addr) {
    const std::uint32_t word_idx = addr >> 3;
    const std::uint32_t lane_idx = word_idx << 1;
    const auto* lanes = &rootp->pipeline_core__DOT__dmem_q_q[0];
    return static_cast<std::uint64_t>(lanes[lane_idx]) |
           (static_cast<std::uint64_t>(lanes[lane_idx + 1u]) << 32u);
}

std::uint64_t read_mcycle(const Vtop___024root* rootp) {
    return static_cast<std::uint64_t>(rootp->pipeline_core__DOT__csr_q_q[4]) |
           (static_cast<std::uint64_t>(rootp->pipeline_core__DOT__csr_q_q[5]) << 32u);
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
    return ((rootp->pipeline_core__DOT__ex_mem_q_q[0x15] >> 7u) & 0x1u) != 0u;
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
    return (static_cast<std::uint64_t>(rootp->pipeline_core__DOT__ex_mem_q_q[0x10]) >> 2u) |
           (static_cast<std::uint64_t>(rootp->pipeline_core__DOT__ex_mem_q_q[0x11]) << 30u) |
           (static_cast<std::uint64_t>(rootp->pipeline_core__DOT__ex_mem_q_q[0x12]) << 62u);
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
    std::cout << "trace cyc=" << read_mcycle(rootp)
              << " pc=" << static_cast<std::uint64_t>(rootp->pipeline_core__DOT__pc_q_q)
              << " if=" << read_if_valid(rootp) << "@" << read_if_pc(rootp)
              << " id=" << read_id_valid(rootp) << "@" << read_id_pc(rootp) << "/rd" << read_id_rd(rootp)
              << " ex=" << read_ex_valid(rootp) << "@" << read_ex_pc(rootp) << "/rd" << read_ex_rd(rootp)
              << " alu=" << read_ex_alu(rootp)
              << " wb=" << read_wb_valid(rootp) << "@" << read_wb_pc(rootp) << "/rd" << read_wb_rd(rootp)
              << "\n";
}

void clear_program_arrays(Vtop___024root* rootp) {
    std::fill_n(&rootp->pipeline_core__DOT__imem_q_q[0], 16384, 0u);
    std::fill_n(&rootp->pipeline_core__DOT__dmem_q_q[0], 16384, 0u);
}

bool load_elf(Vtop___024root* rootp, const std::string& elf_path) {
    std::ifstream file{elf_path, std::ios::binary};
    if (!file) {
        std::cerr << "[ELF] unable to open " << elf_path << "\n";
        return false;
    }

    Elf64_Ehdr ehdr{};
    file.read(reinterpret_cast<char*>(&ehdr), sizeof(ehdr));
    if (!file) {
        std::cerr << "[ELF] failed to read ELF header\n";
        return false;
    }
    if (!(ehdr.e_ident[EI_MAG0] == ELFMAG0 &&
          ehdr.e_ident[EI_MAG1] == ELFMAG1 &&
          ehdr.e_ident[EI_MAG2] == ELFMAG2 &&
          ehdr.e_ident[EI_MAG3] == ELFMAG3)) {
        std::cerr << "[ELF] bad ELF magic\n";
        return false;
    }
    if (ehdr.e_ident[EI_CLASS] != ELFCLASS64 || ehdr.e_ident[EI_DATA] != ELFDATA2LSB) {
        std::cerr << "[ELF] expected little-endian ELF64\n";
        return false;
    }

    clear_program_arrays(rootp);

    file.seekg(ehdr.e_phoff, std::ios::beg);
    if (!file) {
        std::cerr << "[ELF] failed to seek to program headers\n";
        return false;
    }

    for (std::uint16_t i = 0; i < ehdr.e_phnum; ++i) {
        Elf64_Phdr phdr{};
        file.read(reinterpret_cast<char*>(&phdr), sizeof(phdr));
        if (!file) {
            std::cerr << "[ELF] failed to read program header " << i << "\n";
            return false;
        }
        if (phdr.p_type != PT_LOAD || phdr.p_memsz == 0) {
            continue;
        }

        const std::uint64_t base_addr = (phdr.p_paddr != 0) ? phdr.p_paddr : phdr.p_vaddr;
        std::vector<std::uint8_t> bytes(static_cast<std::size_t>(phdr.p_memsz), 0);
        if (phdr.p_filesz != 0) {
            std::streampos resume = file.tellg();
            file.seekg(phdr.p_offset, std::ios::beg);
            file.read(reinterpret_cast<char*>(bytes.data()), static_cast<std::streamsize>(phdr.p_filesz));
            if (!file) {
                std::cerr << "[ELF] failed to read load segment " << i << "\n";
                return false;
            }
            file.seekg(resume, std::ios::beg);
        }

        const bool is_exec = (phdr.p_flags & PF_X) != 0;
        for (std::uint64_t ofs = 0; ofs < phdr.p_memsz; ++ofs) {
            const std::uint64_t abs_addr = base_addr + ofs;
            if (is_exec) {
                if (abs_addr >= 65536ull) {
                    std::cerr << "[ELF] text address out of IMEM range: 0x"
                              << std::hex << abs_addr << std::dec << "\n";
                    return false;
                }
                write_imem_byte(rootp, static_cast<std::uint32_t>(abs_addr), bytes[static_cast<std::size_t>(ofs)]);
            } else {
                if (abs_addr >= 65536ull) {
                    std::cerr << "[ELF] data address out of DMEM range: 0x"
                              << std::hex << abs_addr << std::dec << "\n";
                    return false;
                }
                write_dmem_byte(rootp, static_cast<std::uint32_t>(abs_addr), bytes[static_cast<std::size_t>(ofs)]);
            }
        }
    }

    return true;
}

}  // namespace

int main(int argc, char** argv) {
    std::string elf_path;
    unsigned timeout = 5000;
    bool trace_mode = false;

    for (int i = 1; i < argc; ++i) {
        if (is_trace_arg(argv[i])) {
            trace_mode = true;
        } else if (is_number_arg(argv[i])) {
            timeout = static_cast<unsigned>(std::strtoul(argv[i], nullptr, 10));
        } else if (elf_path.empty()) {
            elf_path = argv[i];
        } else {
            std::cerr << "[ARGS] unrecognized argument: " << argv[i] << "\n";
            return 1;
        }
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

    if (!elf_path.empty()) {
        if (!load_elf(top->rootp, elf_path)) {
            top->final();
            summary << "[BOOT CYCLES] " << boot_ticks << "\n";
            summary << "[EXEC CYCLES] " << (ticks - boot_ticks) << "\n";
            summary << "[TOTAL CYCLES] " << ticks << "\n";
            return 1;
        }
    }

    while (!contextp->gotFinish() && ticks < timeout) {
        if (trace_mode) {
            top->rootp->pipeline_core__DOT__trace_enable_q_q = 1;
            top->eval();
        }
        tick(*contextp, *top, true, ticks);
        if (trace_mode) {
            print_pipeline_trace(top->rootp);
        }
    }

    if (!elf_path.empty()) {
        const std::uint64_t exit_code = read_gpr(top->rootp, 10);
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
            std::cout << "diag dmem[0x70]=" << read_dmem_qword(top->rootp, 0x70)
                      << " dmem[0x78]=" << read_dmem_qword(top->rootp, 0x78)
                      << "\n";
        }
    }

    top->final();
    summary << "[BOOT CYCLES] " << boot_ticks << "\n";
    summary << "[EXEC CYCLES] " << (ticks - boot_ticks) << "\n";
    summary << "[TOTAL CYCLES] " << ticks << "\n";
    return contextp->gotFinish() ? 0 : 1;
}
