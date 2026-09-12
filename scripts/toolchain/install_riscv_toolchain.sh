#!/usr/bin/env bash
# Install a prebuilt riscv64 bare-metal GCC toolchain into a user-local prefix.
#
# The ISA tests and freestanding C++ programs need riscv64-unknown-elf-g++
# (or clang++ with the RISC-V target and lld). This script provides the GCC
# path without requiring root.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
: "${TOOLCHAIN_PREFIX:="$ROOT/.toolchain"}"
: "${RISCV_RELEASE:=2026.08.27}"
: "${RISCV_UBUNTU:=24.04}"
: "${RISCV_ASSET:=riscv64-elf-ubuntu-${RISCV_UBUNTU}-gcc.tar.xz}"
BASE_URL="https://github.com/riscv-collab/riscv-gnu-toolchain/releases/download/${RISCV_RELEASE}"

INSTALL_DIR="$TOOLCHAIN_PREFIX/riscv"
STAMP="$INSTALL_DIR/.installed-${RISCV_RELEASE}-${RISCV_UBUNTU}"

if [ -f "$STAMP" ] && [ -x "$INSTALL_DIR/bin/riscv64-unknown-elf-g++" ]; then
  echo "[toolchain] already installed: $INSTALL_DIR"
  echo "$INSTALL_DIR/bin"
  exit 0
fi

for tool in curl tar xz; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "[toolchain] required tool not found: $tool" >&2
    exit 1
  fi
done

mkdir -p "$TOOLCHAIN_PREFIX"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

echo "[toolchain] downloading $RISCV_ASSET ($RISCV_RELEASE)" >&2
curl -fL --retry 3 --retry-delay 5 -o "$tmpdir/toolchain.tar.xz" \
  "$BASE_URL/$RISCV_ASSET"

echo "[toolchain] extracting" >&2
mkdir -p "$tmpdir/extract"
tar -xJf "$tmpdir/toolchain.tar.xz" -C "$tmpdir/extract"

# The archive unpacks to a single top-level directory (usually "riscv").
src="$(find "$tmpdir/extract" -maxdepth 1 -mindepth 1 -type d | head -1)"
if [ -z "$src" ]; then
  echo "[toolchain] unexpected archive layout" >&2
  exit 1
fi

rm -rf "$INSTALL_DIR"
mv "$src" "$INSTALL_DIR"

if [ ! -x "$INSTALL_DIR/bin/riscv64-unknown-elf-g++" ]; then
  echo "[toolchain] riscv64-unknown-elf-g++ missing after extraction" >&2
  exit 1
fi

touch "$STAMP"
echo "[toolchain] installed: $INSTALL_DIR" >&2
echo "$INSTALL_DIR/bin"
