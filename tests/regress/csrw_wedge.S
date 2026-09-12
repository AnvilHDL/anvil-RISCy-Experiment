# Reproducer: any CSR write wedges the pipeline permanently.
#
# CSR reads are fine: replacing the `csrw` below with `csrr t1, mscratch`
# retires in ~12 cycles. With the `csrw` present the program never reaches its
# ecall and runs to the cycle limit.
#
# Run:
#   build/pipeline_core_program/obj_dir/Vpipeline_core \
#     tests/regress/csrw_wedge.elf 600
# Expected once fixed: "exit 0" well before the cycle limit.

.section .text
.globl _start
_start:
    li t0, 42
    csrw mscratch, t0
    li a7, 93
    li a0, 0
    ecall
1:  j 1b
