# GCC 13 with NVPTX Offloading

Build script for a custom GCC 13 toolchain with NVIDIA PTX GPU offloading support and native architecture tuning (`-march=native`).

The resulting compiler supports OpenMP `target` directives that offload computation to NVIDIA GPUs via the NVPTX backend. The script automatically registers GCC 13 as the **system default** compiler.

## Prerequisites

- **Linux x86_64** (tested on Ubuntu 22.04+)
- **System GCC** (any version that can bootstrap GCC 13)
- **CUDA toolkit** — auto-installed (CUDA 12.8) if not detected; or provide your own via `CUDA_DIR`
- **sudo access** (needed for CUDA install and `update-alternatives` registration)
- Standard build tools: `make`, `git`, `curl`, `bison`, `flex`, `texinfo`

Install build dependencies on Debian/Ubuntu:

```bash
sudo apt install build-essential git curl bison flex texinfo \
  libgmp-dev libmpfr-dev libmpc-dev libisl-dev zlib1g-dev
```

> **Note:** The script checks for all required packages and commands at startup and will exit with a clear error message if anything is missing. If no CUDA toolkit is detected, it automatically installs CUDA 12.8 from NVIDIA's official apt repository (Ubuntu/Debian x86_64 only).

## Usage

```bash
./build-gcc13-nvptx.sh
```

The script will:

1. **Check** that all build dependencies are installed
2. Auto-detect your CUDA installation — **installs CUDA 12.8** if not found
3. Clone and build **nvptx-tools**
4. Clone **GCC 13** and **newlib** for NVPTX
5. Build the NVPTX target cross-compiler
6. Build the host GCC 13 with `--enable-offload-targets=nvptx-none` and `--with-arch=<native>`
7. **Register** GCC 13 as the system default via `update-alternatives`
8. **Persist** `PATH` and `LD_LIBRARY_PATH` in `~/.bashrc`

### Environment Variables

| Variable | Default | Description |
|---|---|---|
| `CUDA_DIR` | `/usr/local/cuda` | CUDA toolkit root |
| `INSTALL_PREFIX` | `/usr/local` | Where to install the toolchain |
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

## After Installation

Once the script completes, GCC 13 is the system default. Open a new terminal (or run `source ~/.bashrc`) and verify:

```bash
gcc --version    # should show GCC 13.x.x
```

Compile with OpenMP GPU offloading:

```bash
gcc -fopenmp -foffload=nvptx-none -o my_app my_app.c
```

### Reverting to the Previous System GCC

The script uses `update-alternatives`, so you can switch back at any time:

```bash
sudo update-alternatives --config gcc
sudo update-alternatives --config g++
sudo update-alternatives --config gfortran
```

To also remove the `~/.bashrc` entries, delete the block between `# >>> gcc13-nvptx-builder >>>` and `# <<< gcc13-nvptx-builder <<<`.

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
