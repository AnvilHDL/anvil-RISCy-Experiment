#!/usr/bin/env bash
# Build the Anvil compiler from the upstream master branch into a
# repository-local prefix.
#
# The RISCy core is developed against Anvil upstream `master`. Upstream master
# additionally needs the fix in
# third_party/anvil-patches/0001-fix-literal_eval-digit-order.patch, without
# which constant array indices are mis-evaluated (see that file and
# docs/WORK_LOG.md). The patch is applied automatically unless
# ANVIL_SKIP_PATCHES=1.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
: "${TOOLCHAIN_PREFIX:="$ROOT/.toolchain"}"
: "${ANVIL_REPO:=https://github.com/kisp-nus/anvil.git}"
: "${ANVIL_REF:=master}"
: "${ANVIL_SKIP_PATCHES:=0}"
PATCH_DIR="$ROOT/third_party/anvil-patches"
SRC_DIR="$TOOLCHAIN_PREFIX/anvil"

for tool in git opam; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "[anvil] required tool not found: $tool" >&2
    exit 1
  fi
done

mkdir -p "$TOOLCHAIN_PREFIX"

if [ -d "$SRC_DIR/.git" ]; then
  echo "[anvil] updating existing checkout" >&2
  git -C "$SRC_DIR" fetch --depth 1 origin "$ANVIL_REF"
else
  echo "[anvil] cloning $ANVIL_REPO ($ANVIL_REF)" >&2
  rm -rf "$SRC_DIR"
  git clone --depth 1 --branch "$ANVIL_REF" "$ANVIL_REPO" "$SRC_DIR"
fi

# Reset to the fetched upstream commit so patches apply to a clean tree.
git -C "$SRC_DIR" checkout -q --detach FETCH_HEAD 2>/dev/null || \
  git -C "$SRC_DIR" checkout -q --detach "origin/$ANVIL_REF"
git -C "$SRC_DIR" reset -q --hard
git -C "$SRC_DIR" clean -qfd

UPSTREAM_REV="$(git -C "$SRC_DIR" rev-parse --short HEAD)"
echo "[anvil] upstream master at $UPSTREAM_REV" >&2

if [ "$ANVIL_SKIP_PATCHES" != "1" ] && [ -d "$PATCH_DIR" ]; then
  shopt -s nullglob
  for patch in "$PATCH_DIR"/*.patch; do
    echo "[anvil] applying $(basename "$patch")" >&2
    git -C "$SRC_DIR" apply "$patch"
  done
  shopt -u nullglob
fi

# Anvil's OCaml dependencies (menhir, yojson, dune, ...) come from the opam
# switch. Install them into the active switch unless told not to.
: "${ANVIL_SKIP_DEPS:=0}"
if [ "$ANVIL_SKIP_DEPS" != "1" ]; then
  echo "[anvil] installing opam dependencies" >&2
  (cd "$SRC_DIR" && opam install -y --deps-only .)
fi

echo "[anvil] building (dune)" >&2
(cd "$SRC_DIR" && opam exec -- dune build)

BIN="$SRC_DIR/_build/default/bin/main.exe"
if [ ! -x "$BIN" ]; then
  echo "[anvil] build did not produce $BIN" >&2
  exit 1
fi

echo "[anvil] built: $BIN" >&2
echo "$BIN"
