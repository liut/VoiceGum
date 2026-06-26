#!/bin/bash
# Build ggml static libraries for CFunASREngine.
# Uses FunASR runtime's CMake setup (which includes llama.cpp as a dependency)
# to produce matching libggml*.a for the pinned llama.cpp version.
#
# Prerequisites:
#   - Local llama.cpp checkout (default: ~/workspace/ai/llama.cpp)
#   - CMake, Xcode CLI tools
#
# Usage:
#   ./Scripts/build-funasr-libs.sh                          # clone FunASR fresh
#   ./Scripts/build-funasr-libs.sh /path/to/FunASR           # use local FunASR checkout
#   LLAMA_CPP=/path/to/llama.cpp ./Scripts/build-funasr-libs.sh

set -euo pipefail

FUNASR_REPO="https://github.com/modelscope/FunASR.git"
LLAMA_CPP="${LLAMA_CPP:-$HOME/workspace/ai/llama.cpp}"
OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/Sources/CFunASREngine/libs"
WORK_DIR=""

cleanup() {
    if [ -n "${WORK_DIR}" ] && [ -d "${WORK_DIR}" ]; then
        rm -rf "${WORK_DIR}"
    fi
}
trap cleanup EXIT

# Resolve FunASR source
if [ $# -ge 1 ]; then
    FUNASR_SRC="$1"
    echo "[build-funasr-libs] Using local FunASR: ${FUNASR_SRC}"
else
    WORK_DIR=$(mktemp -d /tmp/build-funasr-libs.XXXXXX)
    echo "[build-funasr-libs] Cloning FunASR (runtime/llama.cpp only)..."
    git clone --depth 1 --filter=blob:none --sparse "${FUNASR_REPO}" "${WORK_DIR}"
    (cd "${WORK_DIR}" && git sparse-checkout set runtime/llama.cpp)
    FUNASR_SRC="${WORK_DIR}"
fi

BUILD_DIR="${FUNASR_SRC}/runtime/llama.cpp/build"

# Verify llama.cpp
if [ ! -f "${LLAMA_CPP}/ggml/include/ggml.h" ]; then
    echo "[build-funasr-libs] ERROR: llama.cpp not found at ${LLAMA_CPP}"
    echo "  Set LLAMA_CPP=/path/to/llama.cpp or clone:"
    echo "  git clone https://github.com/ggml-org/llama.cpp.git ~/workspace/ai/llama.cpp"
    exit 1
fi

echo "[build-funasr-libs] llama.cpp: ${LLAMA_CPP}"
echo "[build-funasr-libs] Building FunASR runtime (this builds ggml static libs as a side effect)..."

cmake -B "${BUILD_DIR}" -DCMAKE_BUILD_TYPE=Release \
    -DFETCHCONTENT_SOURCE_DIR_LLAMA="${LLAMA_CPP}" \
    -S "${FUNASR_SRC}/runtime/llama.cpp"

cmake --build "${BUILD_DIR}" -j"$(sysctl -n hw.ncpu)" --target llama-funasr-cli

# Locate and copy static libs
LLAMA_BUILD=$(find "${BUILD_DIR}/_deps" -maxdepth 2 -name "llama-build" -type d | head -1)
if [ -z "${LLAMA_BUILD}" ]; then
    echo "[build-funasr-libs] ERROR: could not find llama-build directory in _deps"
    exit 1
fi

echo "[build-funasr-libs] Copying static libs to ${OUT_DIR}..."
mkdir -p "${OUT_DIR}"
cp "${LLAMA_BUILD}/ggml/src/libggml-base.a"     "${OUT_DIR}/"
cp "${LLAMA_BUILD}/ggml/src/libggml-cpu.a"      "${OUT_DIR}/"
cp "${LLAMA_BUILD}/ggml/src/libggml.a"          "${OUT_DIR}/"
cp "${LLAMA_BUILD}/ggml/src/ggml-metal/libggml-metal.a" "${OUT_DIR}/"
cp "${LLAMA_BUILD}/ggml/src/ggml-blas/libggml-blas.a"   "${OUT_DIR}/"
cp "${LLAMA_BUILD}/src/libllama.a"                        "${OUT_DIR}/"

echo "[build-funasr-libs] Done."
echo "  libggml-base.a  $(wc -c < "${OUT_DIR}/libggml-base.a" | xargs) bytes"
echo "  libggml-cpu.a   $(wc -c < "${OUT_DIR}/libggml-cpu.a" | xargs) bytes"
echo "  libggml-metal.a $(wc -c < "${OUT_DIR}/libggml-metal.a" | xargs) bytes"
echo "  libggml-blas.a  $(wc -c < "${OUT_DIR}/libggml-blas.a" | xargs) bytes"
echo "  libllama.a      $(wc -c < "${OUT_DIR}/libllama.a" | xargs) bytes"
echo "  libggml.a       $(wc -c < "${OUT_DIR}/libggml.a" | xargs) bytes"
