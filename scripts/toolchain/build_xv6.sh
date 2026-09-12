#!/usr/bin/env bash
# Build the xv6-riscv submodule for this core.
#
# Stock xv6 targets rv64gc with the lp64d ABI; this core is RV64IMA with
# Zicsr/Zifencei, no compressed instructions and no floating point. The
# overrides below supply the ISA, ABI, NCPU and PHYSTOP this core needs
# without modifying the submodule's working tree.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC_DIR="$ROOT/third_party/xv6-riscv"
: "${TOOLCHAIN_PREFIX:="$ROOT/.toolchain"}"
: "${XV6_MARCH:=rv64ima_zicsr_zifencei}"
: "${XV6_MABI:=lp64}"
: "${XV6_PHYSTOP:=0x80800000L}"

if [ ! -f "$SRC_DIR/Makefile" ]; then
  echo "[xv6] submodule not checked out; run: git submodule update --init third_party/xv6-riscv" >&2
  exit 1
fi

# Prefer the bundled RISC-V toolchain when it is installed.
if [ -x "$TOOLCHAIN_PREFIX/riscv/bin/riscv64-unknown-elf-gcc" ]; then
  PATH="$TOOLCHAIN_PREFIX/riscv/bin:$PATH"
  export PATH
fi
if ! command -v riscv64-unknown-elf-gcc >/dev/null 2>&1; then
  echo "[xv6] riscv64-unknown-elf-gcc not found; run scripts/toolchain/install_riscv_toolchain.sh" >&2
  exit 1
fi

# The submodule stays pristine: copy it to a scratch tree and patch that.
BUILD_DIR="$TOOLCHAIN_PREFIX/xv6-build"
rm -rf "$BUILD_DIR"
mkdir -p "$(dirname "$BUILD_DIR")"
cp -a "$SRC_DIR" "$BUILD_DIR"
rm -rf "$BUILD_DIR/.git"

make -C "$BUILD_DIR" clean >/dev/null 2>&1 || true

sed -i "s|-march=rv64gc|-march=$XV6_MARCH -mabi=$XV6_MABI|g" "$BUILD_DIR/Makefile"
sed -i "s|^#define NCPU .*|#define NCPU        1|" "$BUILD_DIR/kernel/param.h"
sed -i "s|^#define PHYSTOP .*|#define PHYSTOP  $XV6_PHYSTOP|" "$BUILD_DIR/kernel/memlayout.h"

make -C "$BUILD_DIR" kernel/kernel fs.img >&2

KERNEL="$BUILD_DIR/kernel/kernel"
FS_IMG="$BUILD_DIR/fs.img"
for artefact in "$KERNEL" "$FS_IMG"; do
  if [ ! -r "$artefact" ]; then
    echo "[xv6] build did not produce $artefact" >&2
    exit 1
  fi
done

echo "XV6_KERNEL=$KERNEL"
echo "XV6_FS_IMG=$FS_IMG"
