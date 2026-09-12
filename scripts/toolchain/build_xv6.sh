#!/usr/bin/env bash
# Fetch and build xv6-riscv so it can boot on this core.
#
# Stock xv6 targets rv64gc with the lp64d ABI. This core implements RV64IMA
# with Zicsr/Zifencei and no compressed instructions or floating point, so the
# kernel must be rebuilt for that ISA. The patch in
# third_party/xv6-patches/ makes the three required changes:
#
#   - build for rv64ima_zicsr_zifencei with -mabi=lp64
#   - NCPU = 1
#   - PHYSTOP = 0x80800000 (the simulator provides 8 MiB of RAM)
#
# Prints the kernel ELF and fs.img paths on success.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
: "${TOOLCHAIN_PREFIX:="$ROOT/.toolchain"}"
: "${XV6_REPO:=https://github.com/mit-pdos/xv6-riscv.git}"
: "${XV6_REF:=riscv}"
: "${XV6_SKIP_PATCHES:=0}"
PATCH_DIR="$ROOT/third_party/xv6-patches"
SRC_DIR="$TOOLCHAIN_PREFIX/xv6-riscv"

for tool in git make; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "[xv6] required tool not found: $tool" >&2
    exit 1
  fi
done

# The bundled RISC-V toolchain takes precedence when it is installed.
if [ -x "$TOOLCHAIN_PREFIX/riscv/bin/riscv64-unknown-elf-gcc" ]; then
  PATH="$TOOLCHAIN_PREFIX/riscv/bin:$PATH"
  export PATH
fi
if ! command -v riscv64-unknown-elf-gcc >/dev/null 2>&1; then
  echo "[xv6] riscv64-unknown-elf-gcc not found; run scripts/toolchain/install_riscv_toolchain.sh" >&2
  exit 1
fi

mkdir -p "$TOOLCHAIN_PREFIX"

if [ -d "$SRC_DIR/.git" ]; then
  echo "[xv6] updating existing checkout" >&2
  git -C "$SRC_DIR" fetch --depth 1 origin "$XV6_REF"
else
  echo "[xv6] cloning $XV6_REPO ($XV6_REF)" >&2
  rm -rf "$SRC_DIR"
  git clone --depth 1 --branch "$XV6_REF" "$XV6_REPO" "$SRC_DIR"
fi

git -C "$SRC_DIR" checkout -q --detach FETCH_HEAD 2>/dev/null || \
  git -C "$SRC_DIR" checkout -q --detach "origin/$XV6_REF"
git -C "$SRC_DIR" reset -q --hard
git -C "$SRC_DIR" clean -qfdx

echo "[xv6] upstream at $(git -C "$SRC_DIR" rev-parse --short HEAD)" >&2

if [ "$XV6_SKIP_PATCHES" != "1" ] && [ -d "$PATCH_DIR" ]; then
  shopt -s nullglob
  for patch in "$PATCH_DIR"/*.patch; do
    echo "[xv6] applying $(basename "$patch")" >&2
    git -C "$SRC_DIR" apply "$patch"
  done
  shopt -u nullglob
fi

echo "[xv6] building kernel and fs.img" >&2
make -C "$SRC_DIR" kernel/kernel fs.img >&2

KERNEL="$SRC_DIR/kernel/kernel"
FS_IMG="$SRC_DIR/fs.img"
for artefact in "$KERNEL" "$FS_IMG"; do
  if [ ! -r "$artefact" ]; then
    echo "[xv6] build did not produce $artefact" >&2
    exit 1
  fi
done

echo "[xv6] kernel: $KERNEL" >&2
echo "[xv6] fs.img: $FS_IMG" >&2
echo "XV6_KERNEL=$KERNEL"
echo "XV6_FS_IMG=$FS_IMG"
