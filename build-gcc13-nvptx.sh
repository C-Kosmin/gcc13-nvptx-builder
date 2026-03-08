#!/usr/bin/env bash
# Build GCC 13 with NVPTX GPU offloading and native arch tuning.
#
# Usage:
#   ./build-gcc13-nvptx.sh
#
# Optional env:
#   CUDA_DIR=/usr/local/cuda        # CUDA toolkit location
#   INSTALL_PREFIX=/usr/local         # where to install the toolchain
#   BUILD_DIR=$PWD/build             # where intermediate build trees go
#   GCC_JOBS=<n>                     # parallel make jobs (default: nproc/2)
#   FORCE_REBUILD=0                  # set to 1 to clean and rebuild from scratch

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Dependency check ─────────────────────────────────────────────────────────

REQUIRED_PKGS=(
  build-essential git curl bison flex texinfo
  libgmp-dev libmpfr-dev libmpc-dev libisl-dev zlib1g-dev
)
REQUIRED_CMDS=(gcc g++ make git curl bison flex makeinfo)

missing_pkgs=()
for pkg in "${REQUIRED_PKGS[@]}"; do
  if ! dpkg -s "$pkg" &>/dev/null; then
    missing_pkgs+=("$pkg")
  fi
done

missing_cmds=()
for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$cmd" &>/dev/null; then
    missing_cmds+=("$cmd")
  fi
done

if (( ${#missing_pkgs[@]} > 0 )) || (( ${#missing_cmds[@]} > 0 )); then
  echo "ERROR: Missing build dependencies."
  (( ${#missing_pkgs[@]} > 0 )) && echo "   Missing packages: ${missing_pkgs[*]}"
  (( ${#missing_cmds[@]} > 0 )) && echo "   Missing commands: ${missing_cmds[*]}"
  echo ""
  echo "   Install with:"
  echo "     sudo apt install ${REQUIRED_PKGS[*]}"
  exit 1
fi
echo "==> All build dependencies satisfied."

NPROC_ALL="$(nproc 2>/dev/null || echo 8)"
NPROC=$(( NPROC_ALL / 2 ))
GCC_JOBS="${GCC_JOBS:-${NPROC}}"
FORCE_REBUILD="${FORCE_REBUILD:-0}"

INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local}"
BUILD_DIR="${BUILD_DIR:-${SCRIPT_DIR}/build}"

# ── CUDA auto-detection / auto-install ────────────────────────────────────────

CUDA_DIR="${CUDA_DIR:-/usr/local/cuda}"
CUDA_INCLUDE=""
CUDA_LIB=""
CUDA_VERSION_TARGET="12-8"

detect_cuda() {
  CUDA_INCLUDE=""
  CUDA_LIB=""

  for cand_dir in "${CUDA_DIR}" /usr/local/cuda-12.8 /usr/local/cuda /usr/lib/cuda /opt/cuda; do
    if [[ -f "${cand_dir}/include/cuda.h" ]]; then
      CUDA_INCLUDE="${cand_dir}/include"
      break
    fi
  done

  for cand_lib in \
      "${CUDA_DIR}/lib64" \
      "${CUDA_DIR}/lib64/stubs" \
      /usr/local/cuda-12.8/lib64 \
      /usr/local/cuda-12.8/lib64/stubs \
      /usr/local/cuda/lib64 \
      /usr/local/cuda/lib64/stubs \
      /usr/lib/x86_64-linux-gnu \
      /usr/lib/cuda/lib64 \
      /opt/cuda/lib64; do
    if [[ -f "${cand_lib}/libcuda.so" || -L "${cand_lib}/libcuda.so" ]]; then
      CUDA_LIB="${cand_lib}"
      break
    fi
  done
}

install_cuda_toolkit() {
  echo "==> CUDA toolkit not found — installing CUDA ${CUDA_VERSION_TARGET//-/.} ..."

  if ! command -v lsb_release &>/dev/null; then
    echo "ERROR: lsb_release not found. Install with: sudo apt install lsb-release"
    exit 1
  fi

  local distro_id distro_version distro_tag arch
  distro_id="$(lsb_release -si | tr '[:upper:]' '[:lower:]')"
  distro_version="$(lsb_release -sr)"
  arch="$(dpkg --print-architecture)"

  if [[ "${distro_id}" != "ubuntu" && "${distro_id}" != "debian" ]]; then
    echo "ERROR: Automatic CUDA install is only supported on Ubuntu/Debian."
    echo "   Install the CUDA toolkit manually and re-run, or set CUDA_DIR."
    exit 1
  fi
  if [[ "${arch}" != "amd64" ]]; then
    echo "ERROR: Automatic CUDA install only supports x86_64 (amd64). Detected: ${arch}"
    exit 1
  fi

  local distro_tag="${distro_id}${distro_version//./}"
  local keyring_url="https://developer.download.nvidia.com/compute/cuda/repos/${distro_tag}/x86_64/cuda-keyring_1.1-1_all.deb"
  local keyring_deb
  keyring_deb="$(mktemp --suffix=.deb)"

  echo "   Distribution: ${distro_id} ${distro_version} (${distro_tag})"
  echo "   Keyring URL:  ${keyring_url}"

  if ! curl -fsSL "${keyring_url}" -o "${keyring_deb}"; then
    echo "ERROR: Failed to download CUDA keyring for ${distro_tag}."
    echo "   Your distro may not be supported by NVIDIA's repo."
    echo "   Install the CUDA toolkit manually and re-run, or set CUDA_DIR."
    rm -f "${keyring_deb}"
    exit 1
  fi

  sudo dpkg -i "${keyring_deb}"
  rm -f "${keyring_deb}"
  sudo apt-get update -qq

  echo "==> Installing cuda-toolkit-${CUDA_VERSION_TARGET} ..."
  sudo apt-get install -y "cuda-toolkit-${CUDA_VERSION_TARGET}"

  if [[ -d "/usr/local/cuda-${CUDA_VERSION_TARGET//-/.}" ]]; then
    CUDA_DIR="/usr/local/cuda-${CUDA_VERSION_TARGET//-/.}"
  fi

  echo "==> CUDA toolkit ${CUDA_VERSION_TARGET//-/.} installed successfully."
}

detect_cuda

if [[ -z "${CUDA_INCLUDE}" || -z "${CUDA_LIB}" ]]; then
  install_cuda_toolkit
  detect_cuda
fi

if [[ -z "${CUDA_INCLUDE}" ]]; then
  echo "ERROR: CUDA include dir not found (need cuda.h) even after install."
  echo "   Set CUDA_DIR=/path/to/cuda and re-run."
  exit 1
fi
if [[ -z "${CUDA_LIB}" ]]; then
  echo "ERROR: CUDA driver library not found (need libcuda.so) even after install."
  echo "   Set CUDA_DIR=/path/to/cuda and re-run."
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
  git clone --depth 1 https://sourceware.org/git/newlib-cygwin.git nvptx-newlib
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

GCC13_VERSION="$("${INSTALL_PREFIX}/bin/gcc" -dumpfullversion)"
GCC13_MAJOR="${GCC13_VERSION%%.*}"
GCC13_PRIORITY=$(( GCC13_MAJOR * 10 ))

echo ""
echo "==> GCC 13 with NVPTX offloading built successfully!"
"${INSTALL_PREFIX}/bin/gcc" --version
echo "   Install prefix: ${INSTALL_PREFIX}"

# ── Register with update-alternatives (system default) ───────────────────────

echo ""
echo "==> Registering GCC ${GCC13_MAJOR} as the system default via update-alternatives..."

ALTERNATIVES=(
  "gcc      ${INSTALL_PREFIX}/bin/gcc"
  "g++      ${INSTALL_PREFIX}/bin/g++"
  "gfortran ${INSTALL_PREFIX}/bin/gfortran"
  "gcc-ar   ${INSTALL_PREFIX}/bin/gcc-ar"
  "gcc-nm   ${INSTALL_PREFIX}/bin/gcc-nm"
  "gcov     ${INSTALL_PREFIX}/bin/gcov"
)

for entry in "${ALTERNATIVES[@]}"; do
  read -r name path <<< "$entry"
  if [[ -x "$path" ]]; then
    sudo update-alternatives --install "/usr/bin/${name}" "${name}" "${path}" "${GCC13_PRIORITY}" 2>/dev/null || true
    sudo update-alternatives --set "${name}" "${path}" 2>/dev/null || true
  fi
done

echo "   update-alternatives configured (priority ${GCC13_PRIORITY})."
echo "   To revert:  sudo update-alternatives --config gcc"

# ── Persist PATH and LD_LIBRARY_PATH in ~/.bashrc ────────────────────────────

BASHRC="${HOME}/.bashrc"
MARKER="# >>> gcc13-nvptx-builder >>>"
MARKER_END="# <<< gcc13-nvptx-builder <<<"

BLOCK="${MARKER}
export PATH=\"${INSTALL_PREFIX}/bin:\${PATH}\"
export LD_LIBRARY_PATH=\"${INSTALL_PREFIX}/lib64:\${LD_LIBRARY_PATH:-}\"
${MARKER_END}"

if [[ -f "${BASHRC}" ]] && grep -qF "${MARKER}" "${BASHRC}"; then
  echo "==> Updating existing gcc13-nvptx-builder block in ${BASHRC}..."
  tmpfile="$(mktemp)"
  awk -v marker="${MARKER}" -v marker_end="${MARKER_END}" -v block="${BLOCK}" '
    $0 == marker { skip=1; printed=1; print block; next }
    $0 == marker_end { skip=0; next }
    !skip { print }
  ' "${BASHRC}" > "${tmpfile}"
  mv "${tmpfile}" "${BASHRC}"
else
  echo "==> Adding gcc13-nvptx-builder PATH to ${BASHRC}..."
  printf '\n%s\n' "${BLOCK}" >> "${BASHRC}"
fi

echo ""
echo "==> Setup complete!"
echo "   GCC ${GCC13_VERSION} is now the system default."
echo "   PATH and LD_LIBRARY_PATH have been added to ${BASHRC}."
echo ""
echo "   Run 'source ~/.bashrc' or open a new terminal to activate."
echo "   Verify with: gcc --version"
