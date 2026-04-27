// See LICENSE for license details.

#ifndef _ENV_PHYSICAL_SINGLE_CORE_H
#define _ENV_PHYSICAL_SINGLE_CORE_H

#include "encoding.h"

#define MASK_XLEN(x) ((x) & 0xFFFFFFFFFFFFFFFF)
#define SEXT_IMM(x) ((x) | (-(((x) >> 11) & 1) << 11))

#define TEST_INSERT_NOPS_0
#define TEST_INSERT_NOPS_1 nop;
#define TEST_INSERT_NOPS_2 nop; nop;
#define TEST_INSERT_NOPS_3 nop; nop; nop;
#define TEST_INSERT_NOPS_4 nop; nop; nop; nop;
#define TEST_INSERT_NOPS_5 nop; nop; nop; nop; nop;
#define TEST_INSERT_NOPS_6 nop; nop; nop; nop; nop; nop;
#define TEST_INSERT_NOPS_7 nop; nop; nop; nop; nop; nop; nop;
#define TEST_INSERT_NOPS_8 nop; nop; nop; nop; nop; nop; nop; nop;
#define TEST_INSERT_NOPS_9 nop; nop; nop; nop; nop; nop; nop; nop; nop;
#define TEST_INSERT_NOPS_10 nop; nop; nop; nop; nop; nop; nop; nop; nop; nop;

#define TEST_DATA

#define RVTEST_RV64U                                                    \
  .macro init;                                                          \
  .endm

#define RVTEST_CODE_BEGIN                                               \
        .section .text.init;                                            \
        .align  6;                                                      \
        .globl main;                                                    \
main:                                                                   \
        li TESTNUM, 0;                                                  \
        init;

#define RVTEST_CODE_END                                                 \
        unimp

//-----------------------------------------------------------------------
// Pass/Fail Macro
//-----------------------------------------------------------------------

#define RVTEST_PASS                                                     \
        li a7, 93;                                                      \
        li a0, 0;                                                       \
        ecall

#define TESTNUM gp
#define RVTEST_FAIL                                                     \
        li a7, 93;                                                      \
        addi a0, TESTNUM, 0;                                            \
        ecall

//-----------------------------------------------------------------------
// Data Section Macro
//-----------------------------------------------------------------------

#define RVTEST_DATA_BEGIN                                               \
        .data;                                                          \
        .align 4; .global begin_signature; begin_signature:

#define RVTEST_DATA_END .align 4; .global end_signature; end_signature:

#endif
