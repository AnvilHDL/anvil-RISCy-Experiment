# sv39_basic.S
# Set up a single identity-mapped page (VA=PA=0x80000000) using Sv39,
# enable paging, verify a load through the virtual address succeeds, exit 0.
#
# Page table layout (all stored in DMEM at 0x80100000):
#   L2 PTE (satp.ppn * 4096 + vpn2 * 8):
#     ppn_root = 0x80100 (0x80100000 >> 12)
#     vpn2 of 0x80000000 = bit[38:30] = 2
#     L2 PTE addr = 0x80100000 + 2*8 = 0x80100010
#     L2 PTE value = (ppn_l1 << 10) | 0x01 (valid, not leaf → pointer)
#     ppn_l1 = 0x80101 → L1 table at 0x80101000
#   L1 PTE (0x80101000 + vpn1 * 8):
#     vpn1 of 0x80000000 = bit[29:21] = 0
#     L1 PTE addr = 0x80101000 + 0*8 = 0x80101000
#     L1 PTE value = (ppn_l0 << 10) | 0x01
#     ppn_l0 = 0x80102 → L0 table at 0x80102000
#   L0 PTE (0x80102000 + vpn0 * 8):
#     vpn0 of 0x80000000 = bit[20:12] = 0
#     L0 PTE addr = 0x80102000 + 0*8 = 0x80102000
#     L0 PTE value = (0x80000 << 10) | 0xCF  (valid, R, W, X, A, D)
#     0xCF = 0b11001111 = D(7) A(6) G(5)=0 U(4)=0 X(3) W(2) R(1) V(0)
#
# After enabling paging:
#   VA 0x80000000 maps to PA 0x80000000 (identity)
#   We load from a known location and check the value.

.section .text
.global main
main:
    # ---- build page tables ----
    # Write L0 PTE: maps VA 0x80000000 → PA 0x80000000
    # PTE = (ppn << 10) | perm = (0x80000 << 10) | 0xCF
    # ppn of 0x80000000 = 0x80000000 >> 12 = 0x80000
    li   t0, 0x80000
    slli t0, t0, 10
    ori  t0, t0, 0xCF         # V R W X A D
    li   t1, 0x80102000       # L0 table base
    sd   t0, 0(t1)            # L0[0] = leaf PTE

    # Write L1 PTE: points to L0 table at 0x80102000
    # PTE = (0x80102 << 10) | 0x01 (valid, non-leaf)
    li   t0, 0x80102
    slli t0, t0, 10
    ori  t0, t0, 0x01
    li   t1, 0x80101000       # L1 table base
    sd   t0, 0(t1)            # L1[0] = pointer to L0

    # Write L2 PTE: points to L1 table at 0x80101000
    # VPN2 of 0x80000000 = 2, so slot 2
    li   t0, 0x80101
    slli t0, t0, 10
    ori  t0, t0, 0x01
    li   t1, 0x80100000       # L2 table (root)
    sd   t0, 16(t1)           # L2[2] = pointer to L1

    # ---- write a sentinel value to test load ----
    li   t0, 0xdeadbeef
    li   t1, 0x80000100       # some address in the mapped page
    sd   t0, 0(t1)

    # ---- enable Sv39: satp = (8 << 60) | (0x80100 ppn) ----
    li   t0, 8
    slli t0, t0, 60
    li   t1, 0x80100           # ppn of root table
    or   t0, t0, t1
    csrw satp, t0
    sfence.vma

    # ---- load through virtual address (identity-mapped) ----
    li   t1, 0x80000100
    ld   t2, 0(t1)
    li   t3, 0xdeadbeef
    bne  t2, t3, fail

    # ---- success: exit 0 ----
    li   a0, 0
    li   a7, 93
    ecall

fail:
    li   a0, 1
    li   a7, 93
    ecall
