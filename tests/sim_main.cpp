// Minimal Verilator harness with cycle reporting for RISCy-Experiment tests.

#include <cstdlib>
#include <iostream>
#include <memory>

#include <verilated.h>
#include "Vtop.h"

double sc_time_stamp() { return 0; }

int main(int argc, char** argv) {
    unsigned timeout = 200;
    if (argc > 1) {
        timeout = std::atoi(argv[1]);
    }

    const std::unique_ptr<VerilatedContext> contextp{new VerilatedContext};
    contextp->debug(0);
    contextp->randReset(2);
    contextp->traceEverOn(false);
    contextp->commandArgs(argc, argv);

    const std::unique_ptr<Vtop> top{new Vtop{contextp.get(), "TOP"}};

    top->clk_i = 0;
    top->rst_ni = !0;

    unsigned ticks = 0;
    while (!contextp->gotFinish() && ticks < timeout) {
        contextp->timeInc(1);
        top->clk_i = !top->clk_i;
        if (!top->clk_i) {
            top->rst_ni = (contextp->time() > 1 && contextp->time() < 10) ? !1 : !0;
        }
        top->eval();
        ++ticks;
    }

    top->final();
    std::cerr << "[CYCLES] " << ticks << "\n";
    return contextp->gotFinish() ? 0 : 1;
}
