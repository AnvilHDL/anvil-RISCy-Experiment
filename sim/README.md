# sim/ — Simulation Support Files

| File | Description |
|------|-------------|
| `sim_main.cpp` | Verilator harness: ELF loader, MMIO shims, Sv39 PTW, UART/PLIC, virtio-blk |
| `startup.S` | Minimal CRT for freestanding C++ program tests (sets up stack, calls main) |
| `link.ld` | Linker script: places `.text` at 0x80000000 to match the processor boot PC |

## How the harness works

The `Vpipeline_core` binary is produced by:

```
Anvil → pipeline_core.sv → Verilator → pipeline_core_driver.o + Vpipeline_core__ALL.a → Vpipeline_core
```

The harness owns the clock: it calls `top->eval()` once per simulated cycle,
wrapping each eval with:

1. **Pre-populate** `imem_rdata_q` and `mem_rdata_q` from `host_mem[]` or MMIO
2. **Tick** `top->eval()`
3. **Commit** any store from `mem_store_*_q` to `host_mem[]` or MMIO side-effect

This split avoids combinatorial loops between the read path (what the RTL needs
to compute this cycle) and the write path (what the RTL committed last cycle).
