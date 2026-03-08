#!/usr/bin/env bash
# Build GCC 13 with NVPTX GPU offloading and native arch tuning.
#
# Usage:
#   ./build-gcc13-nvptx.sh
#
# Optional env:
#   CUDA_DIR=/usr/local/cuda        # CUDA toolkit location
#   INSTALL_PREFIX=$PWD/gcc13        # where to install the toolchain
#   BUILD_DIR=$PWD/build             # where intermediate build trees go
#   GCC_JOBS=<n>                     # parallel make jobs (default: nproc/2)
#   FORCE_REBUILD=0                  # set to 1 to clean and rebuild from scratch

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NPROC_ALL="$(nproc 2>/dev/null || echo 8)"
NPROC=$(( NPROC_ALL / 2 ))
GCC_JOBS="${GCC_JOBS:-${NPROC}}"
FORCE_REBUILD="${FORCE_REBUILD:-0}"

INSTALL_PREFIX="${INSTALL_PREFIX:-${SCRIPT_DIR}/gcc13}"
BUILD_DIR="${BUILD_DIR:-${SCRIPT_DIR}/build}"

# ── CUDA auto-detection ──────────────────────────────────────────────────────

CUDA_DIR="${CUDA_DIR:-/usr/local/cuda}"
CUDA_INCLUDE=""
CUDA_LIB=""

for cand_dir in "${CUDA_DIR}" /usr/local/cuda /usr/lib/cuda /opt/cuda; do
  if [[ -f "${cand_dir}/include/cuda.h" ]]; then
    CUDA_INCLUDE="${cand_dir}/include"
    break
  fi
done

for cand_lib in \
    "${CUDA_DIR}/lib64" \
    /usr/lib/x86_64-linux-gnu \
    /usr/local/cuda/lib64 \
    /usr/lib/cuda/lib64 \
    /opt/cuda/lib64; do
  if [[ -f "${cand_lib}/libcuda.so" || -L "${cand_lib}/libcuda.so" ]]; then
    CUDA_LIB="${cand_lib}"
    break
  fi
done

if [[ -z "${CUDA_INCLUDE}" ]]; then
  echo "ERROR: CUDA include dir not found (need cuda.h). Set CUDA_DIR=/path/to/cuda."
  exit 1
fi
if [[ -z "${CUDA_LIB}" ]]; then
  echo "ERROR: CUDA driver library not found (need libcuda.so). Set CUDA_DIR=/path/to/cuda."
  exit 1
fi

echo "==> Configuration"
echo "   CUDA include:    ${CUDA_INCLUDE}"
echo "   CUDA lib:        ${CUDA_LIB}"
echo "   Install prefix:  ${INSTALL_PREFIX}"
echo "   Build dir:       ${BUILD_DIR}"
echo "   Parallel jobs:   ${GCC_JOBS} (${NPROC_ALL} threads / 2)"

# ── Optionally throttle CPU governor during build ────────────────────────────

PREV_GOVERNOR="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown)"
if [[ "${PREV_GOVERNOR}" == "performance" ]]; then
  echo "==> Switching CPU governor to 'schedutil' for build stability..."
  for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo schedutil | sudo tee "$gov" >/dev/null 2>&1 || true
  done
fi

restore_governor() {
  if [[ "${PREV_GOVERNOR}" == "performance" ]]; then
    echo "==> Restoring CPU governor to '${PREV_GOVERNOR}'..."
    for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
      echo "${PREV_GOVERNOR}" | sudo tee "$gov" >/dev/null 2>&1 || true
    done
  fi
}
trap restore_governor EXIT

# ── Handle force rebuild ─────────────────────────────────────────────────────

NEEDS_BUILD=0
if [[ "${FORCE_REBUILD}" == "1" ]]; then
  echo "==> FORCE_REBUILD=1 — cleaning stale build state..."
  rm -rf "${BUILD_DIR}/build-host" "${BUILD_DIR}/build-nvptx"
  rm -rf "${INSTALL_PREFIX}"
  NEEDS_BUILD=1
elif [[ ! -x "${INSTALL_PREFIX}/bin/gcc" || \
        ! -x "${INSTALL_PREFIX}/bin/g++" || \
        ! -x "${INSTALL_PREFIX}/bin/gfortran" ]]; then
  echo "==> GCC 13 binaries not found — cleaning stale partial builds..."
  rm -rf "${BUILD_DIR}/build-host" "${BUILD_DIR}/build-nvptx"
  rm -rf "${INSTALL_PREFIX}"
  NEEDS_BUILD=1
else
  echo "==> GCC 13 already installed at ${INSTALL_PREFIX}, nothing to do."
  echo "   Set FORCE_REBUILD=1 to rebuild from scratch."
  "${INSTALL_PREFIX}/bin/gcc" --version | head -1
  exit 0
fi

# ── Build ────────────────────────────────────────────────────────────────────

export CC_FOR_BUILD=/usr/bin/gcc
export CXX_FOR_BUILD=/usr/bin/g++
export CC=/usr/bin/gcc
export CXX=/usr/bin/g++
echo "==> Using system compiler: $(/usr/bin/gcc --version | head -1)"

mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

# ── 1. nvptx-tools ──────────────────────────────────────────────────────────

echo "==> [1/3] Building nvptx-tools..."
if [[ ! -d nvptx-tools ]]; then
  git clone --depth 1 https://github.com/MentorEmbedded/nvptx-tools
fi
(
  cd nvptx-tools
  if [[ ! -f config.status ]] || [[ "${FORCE_REBUILD}" == "1" ]]; then
    make distclean 2>/dev/null || true
    ./configure \
      --with-cuda-driver-include="${CUDA_INCLUDE}" \
      --with-cuda-driver-lib="${CUDA_LIB}" \
      --prefix="${INSTALL_PREFIX}"
  fi
  make -j"${GCC_JOBS}"
  make install
)

# ── 2. GCC source + newlib ──────────────────────────────────────────────────

if [[ ! -d gcc ]]; then
  echo "==> Cloning GCC 13 source..."
  git clone --depth 1 --branch releases/gcc-13 https://gcc.gnu.org/git/gcc.git gcc
  ( cd gcc && ./contrib/download_prerequisites )
fi
if [[ ! -d nvptx-newlib ]]; then
  echo "==> Cloning newlib for NVPTX..."
  git clone --depth 1 git://sourceware.org/git/newlib-cygwin.git nvptx-newlib
fi
ln -sfn ../nvptx-newlib/newlib gcc/newlib

TARGET="$( cd gcc && ./config.guess )"

# ── 3. NVPTX target cross-compiler ─────────────────────────────────────────

echo "==> [2/3] Building NVPTX target cross-compiler..."
mkdir -p build-nvptx
(
  cd build-nvptx
  if [[ ! -f Makefile ]]; then
    ../gcc/configure \
      --target=nvptx-none \
      --build="${TARGET}" \
      --host="${TARGET}" \
      --with-build-time-tools="${INSTALL_PREFIX}/nvptx-none/bin" \
      --enable-as-accelerator-for="${TARGET}" \
      --disable-sjlj-exceptions \
      --enable-newlib-io-long-long \
      --enable-languages="c,c++,fortran,lto" \
      --prefix="${INSTALL_PREFIX}"
  fi
  make -j"${GCC_JOBS}"
  make install
)

# ── 4. Host GCC with NVPTX offloading + native arch ────────────────────────

echo "==> [3/3] Building host GCC 13 with NVPTX offloading..."
mkdir -p build-host
(
  cd build-host
  if [[ ! -f Makefile ]]; then
    HOST_ARCH="$(gcc -march=native -Q --help=target 2>/dev/null \
                 | awk '/^\s*-march=/{print $2}')"
    HOST_ARCH="${HOST_ARCH:-x86-64}"
    echo "   Host architecture: ${HOST_ARCH}"

    ../gcc/configure \
      --build="${TARGET}" \
      --host="${TARGET}" \
      --target="${TARGET}" \
      --enable-offload-targets="nvptx-none=${INSTALL_PREFIX}" \
      --with-cuda-driver-include="${CUDA_INCLUDE}" \
      --with-cuda-driver-lib="${CUDA_LIB}" \
      --enable-bootstrap \
      --disable-multilib \
      --with-arch="${HOST_ARCH}" \
      --enable-languages="c,c++,fortran,lto" \
      --enable-checking=release \
      --prefix="${INSTALL_PREFIX}"
  fi
  make -j"${GCC_JOBS}"
  make install
)

# ── Verify ───────────────────────────────────────────────────────────────────

echo "==> Verifying installation..."
if [[ ! -x "${INSTALL_PREFIX}/bin/gcc" ]]; then
  echo "ERROR: Build completed but gcc binary not found at ${INSTALL_PREFIX}/bin/gcc"
  exit 1
fi

echo ""
echo "==> GCC 13 with NVPTX offloading built successfully!"
"${INSTALL_PREFIX}/bin/gcc" --version
echo ""
echo "   Install prefix: ${INSTALL_PREFIX}"
echo ""
echo "   To use this toolchain:"
echo "     export PATH=\"${INSTALL_PREFIX}/bin:\${PATH}\""
echo "     export LD_LIBRARY_PATH=\"${INSTALL_PREFIX}/lib64:\${LD_LIBRARY_PATH:-}\""
echo "     export CC=\"${INSTALL_PREFIX}/bin/gcc\""
echo "     export CXX=\"${INSTALL_PREFIX}/bin/g++\""
echo "     export FC=\"${INSTALL_PREFIX}/bin/gfortran\""
