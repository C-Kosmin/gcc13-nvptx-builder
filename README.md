# GCC 13 with NVPTX Offloading

Build script for a custom GCC 13 toolchain with NVIDIA PTX GPU offloading support and native architecture tuning (`-march=native`).

The resulting compiler supports OpenMP `target` directives that offload computation to NVIDIA GPUs via the NVPTX backend.

## Prerequisites

- **Linux x86_64** (tested on Ubuntu 22.04+)
- **System GCC** (any version that can bootstrap GCC 13)
- **CUDA toolkit** with `cuda.h` and `libcuda.so` (driver API)
- Standard build tools: `make`, `git`, `curl`, `bison`, `flex`, `texinfo`

Install build dependencies on Debian/Ubuntu:

```bash
sudo apt install build-essential git curl bison flex texinfo \
  libgmp-dev libmpfr-dev libmpc-dev libisl-dev zlib1g-dev
```

## Usage

```bash
./build-gcc13-nvptx.sh
```

The script will:

1. Auto-detect your CUDA installation
2. Clone and build **nvptx-tools**
3. Clone **GCC 13** and **newlib** for NVPTX
4. Build the NVPTX target cross-compiler
5. Build the host GCC 13 with `--enable-offload-targets=nvptx-none` and `--with-arch=<native>`

### Environment Variables

| Variable | Default | Description |
|---|---|---|
| `CUDA_DIR` | `/usr/local/cuda` | CUDA toolkit root |
| `INSTALL_PREFIX` | `./gcc13` | Where to install the toolchain |
| `BUILD_DIR` | `./build` | Intermediate build tree location |
| `GCC_JOBS` | `nproc / 2` | Parallel make jobs |
| `FORCE_REBUILD` | `0` | Set to `1` to clean and rebuild from scratch |

### Examples

```bash
# Default build
./build-gcc13-nvptx.sh

# Custom install location + CUDA path
INSTALL_PREFIX=/opt/gcc13-nvptx CUDA_DIR=/usr/local/cuda-12.4 ./build-gcc13-nvptx.sh

# Force full rebuild
FORCE_REBUILD=1 ./build-gcc13-nvptx.sh
```

## Using the Toolchain

After the build completes, activate the toolchain:

```bash
export PATH="$PWD/gcc13/bin:$PATH"
export LD_LIBRARY_PATH="$PWD/gcc13/lib64:${LD_LIBRARY_PATH:-}"
export CC="$PWD/gcc13/bin/gcc"
export CXX="$PWD/gcc13/bin/g++"
export FC="$PWD/gcc13/bin/gfortran"
```

Compile with OpenMP GPU offloading:

```bash
gcc -fopenmp -foffload=nvptx-none -o my_app my_app.c
```

## What Gets Built

```
build/
├── nvptx-tools/          # NVIDIA PTX assembler/linker
├── gcc/                  # GCC 13 source (releases/gcc-13)
├── nvptx-newlib/         # C library for NVPTX target
├── build-nvptx/          # NVPTX cross-compiler build tree
└── build-host/           # Host GCC build tree

gcc13/                    # ← installed toolchain (INSTALL_PREFIX)
├── bin/gcc, g++, gfortran, ...
├── lib64/
├── libexec/
└── nvptx-none/           # NVPTX target libraries
```
