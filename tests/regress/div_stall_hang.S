# Reproducer: the iterative divider never releases the pipeline when the DIV
# operands are read from the committed register file rather than forwarded
# from the immediately preceding instructions.
#
# With the two `nop`s removed (DIV directly after the two `li`s) the program
# retires in ~79 cycles. With them present the divider reaches
# div_count_q == 64 but div_busy_q is never cleared, pipeline_stall stays
# asserted, and the program never reaches the ecall.
#
# Run:
#   build/pipeline_core_program/obj_dir/Vpipeline_core \
#     tests/regress/div_stall_hang.elf 600
# Expected once fixed: "exit 0" well before the cycle limit.

.section .text
.globl _start
_start:
    li t0, 100
    li t1, 7
    nop
    nop
    div t2, t0, t1
    li a7, 93
    li a0, 0
    ecall
1:  j 1b
