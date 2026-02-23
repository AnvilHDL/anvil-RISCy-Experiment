# A Very RISCy Processor

This goal is to build a single core RISC-V processor from scratch, using only Anvil with minimal FFI to systemverilog.


Primarily we will be implementing the following extensions:


1. RISCV I Extension
2. Caplifive Extension

Then iterate to implement the other extensions as we go along.



## Design

1. Fetch

2. Decode

3. Issue (In order now, out of order later)

4. Execute

5. Writeback/Commit




## Design Principles

1. Modularity: The design should be modular, allowing for easy addition of new features and extensions.
2. Self-Documenting Interface: Each component interface should be well-defined and should be self documenting of the behaviour
3. Language Improvement over Hacks : Anytime we discover something is missing, we first add it to the language rather than working around it with hacks.


## Implementation Plan

1. Decoder:
2. Issue : Minimal in order issue logic
3. Execute : ALU, Branch Unit, Load/Store Unit, Capstone Unit : FLU, Dynamic Unit, **Rev Node** (Later CSR : Commit Stage) 
4. Writeback/Commit : Minimal in order commit logic based on a scoreboard data structure
5. Memory System : Start with no memory hierarchy, no caches, just a simple memory interface. Then add a simple L1 cache.


## Things we need to FFI to SystemVerilog

1. UART for debugging and output
2. Memory Bus Interface for FPGA implementation : or we need to understand how the protocol in detail (FPGA documentation)