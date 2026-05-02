```shell
						·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  

				███████████   █████████   ████████  ██████████   ██████████ █████   █████
				░░███░░░░░███ ███░░░░░███ ███░░░░███░░███░░░░███ ░░███░░░░░█░░███   ░░███ 
				░███    ░███░███    ░░░ ░░░    ░███ ░███   ░░███ ░███  █ ░  ░███    ░███ 
				░██████████ ░░█████████    ███████  ░███    ░███ ░██████    ░███    ░███ 
				░███░░░░░░   ░░░░░░░░███  ███░░░░   ░███    ░███ ░███░░█    ░░███   ███  
				░███         ███    ░███ ███      █ ░███    ███  ░███ ░   █  ░░░█████░   
				█████       ░░█████████ ░██████████ ██████████   ██████████    ░░███    
				░░░░░         ░░░░░░░░░  ░░░░░░░░░░ ░░░░░░░░░░   ░░░░░░░░░░      ░░░      

						╔══════════════════════════════════════════════════════╗
						║  Toolchain Installer  v4.5                           ║
						║  PlayStation 2 Development Environment Setup         ║
						╚══════════════════════════════════════════════════════╝

						·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·
```

# PS2DEV Toolchain Installer

A production-grade interactive Bash installer for the full **PS2DEV / PS2SDK** PlayStation 2 development toolchain on Ubuntu 24 and Ubuntu 25. Features a PlayStation 2 dashboard-inspired terminal UI, automatic system detection, prebuilt tarball support, and full source compilation with smart fallback logic.

---

> [!NOTE]
> Currently only tested on Ubuntu 24 (Linux ubuntu 6.8.0-111-generic #111-Ubuntu SMP)

## Features

- **PS2-themed interactive splash menu** — dark navy terminal UI styled after the original PlayStation 2 browser dashboard
- **Three install modes** — Auto (prebuilt → source fallback), Prebuilt Only, Build From Source
- **Smart system detection** — displays RAM, swap, disk, CPU threads, OS version, and CMake version with colour-coded warnings
- **Auto Safe Mode job detection** — automatically selects a safe parallel job count based on available RAM
- **CMake 3.30+ auto-upgrade** — installs the official Kitware APT release if the system CMake is too old (required by ps2sdk-ports)
- **Swap warning** — warns before source builds if RAM < 8 GB and no swap is present
- **Workspace isolation** — never builds in `/tmp`; detects tmpfs and redirects to real disk
- **Idempotent environment exports** — no duplicate PATH entries across multiple runs
- **Braille Unicode spinner** — animated progress indicator during long operations
- **Timestamped log file** — always written beside the script regardless of sudo context
- **Hello World demo project** — auto-creates `~/PS2HelloWorld` with `hello.c`, `Makefile`, and `README.md` on completion

---

## What Gets Installed

| Component | Repository | Description |
|---|---|---|
| ps2toolchain | ps2dev/ps2toolchain | GCC cross-compiler, binutils, newlib for MIPS R5900 |
| ps2sdk | ps2dev/ps2sdk | Core PS2 SDK — EE, IOP, DVP libraries |
| gsKit | ps2dev/gsKit | Graphics Synthesizer library |
| ps2client | ps2dev/ps2client | PC-side client for PS2Link |
| ps2-packer | ps2dev/ps2-packer | ELF executable compressor |
| ps2sdk-ports | ps2dev/ps2sdk-ports | Ported libraries (libogg, libvorbis, libpng, opus, etc.) |

**Install location:** `/usr/local/ps2dev`

---

## System Requirements

| Requirement | Minimum |
|---|---|
| OS | Ubuntu 24.04 (Noble) or Ubuntu 25.04 (Plucky) |
| RAM | 4 GB (8 GB recommended) |
| Disk | 20 GB free |
| CMake | 3.30+ (auto-installed if needed) |
| Network | Internet connection required |
| Privileges | sudo access required |

> **Swap is strongly recommended** if your system has less than 8 GB RAM. GCC may be OOM-killed mid-compile without it.
>
> ```bash
> sudo fallocate -l 4G /swapfile
> sudo chmod 600 /swapfile
> sudo mkswap /swapfile
> sudo swapon /swapfile
> ```

---

## Quick Install

Run directly from GitHub — no download required:

```bash
curl -fsSL https://raw.githubusercontent.com/level42ca/PS2DEV-setup-script/refs/heads/master/install.sh \
  -o /tmp/ps2dev-install.sh && bash /tmp/ps2dev-install.sh
```

The script will request sudo privileges itself. Do **not** prefix the command with `sudo` — the installer escalates internally so that the log file and demo project are created under your real user account.

---

## Manual Install

```bash
# Clone the repository
git clone https://github.com/level42ca/PS2DEV-setup-script.git
cd PS2DEV-setup-script

# Make executable and run
chmod +x install.sh
./install.sh
```

---

## Install Modes

### 1 — Auto Install *(recommended)*
Attempts to download and validate the official prebuilt tarball from the ps2dev GitHub releases. If the tarball is missing, corrupt, or incomplete, automatically falls back to a full source build.

### 2 — Prebuilt Only
Downloads and installs the official prebuilt tarball only. Fails cleanly with a clear message if the tarball is unavailable or invalid.

### 3 — Build From Source
Clones the upstream `ps2dev/ps2dev` meta-repository and runs its `build-all.sh` to compile the complete toolchain from scratch. This is the most compatible option and produces a toolchain tuned to your system.

> Source builds typically take **30–120 minutes** depending on hardware. A machine with 4 CPU cores and 8 GB RAM will take approximately 45–60 minutes.

### 4 — Settings
Configure the number of parallel make jobs used during source compilation.

| Mode | RAM Condition | Jobs |
|---|---|---|
| Auto Safe (default) | < 4 GB | 1 |
| Auto Safe (default) | 4–8 GB | 2 |
| Auto Safe (default) | 8–16 GB | min(4, nproc) |
| Auto Safe (default) | 16 GB+ | nproc |

---

## Environment Variables

After installation, the following variables are exported automatically into `/etc/profile.d/ps2dev.sh` and your `~/.bashrc` / `~/.zshrc`:

```bash
export PS2DEV=/usr/local/ps2dev
export PS2SDK=${PS2DEV}/ps2sdk
export GSKIT=${PS2DEV}/gsKit
export PATH=${PS2DEV}/bin:${PS2DEV}/ee/bin:${PS2DEV}/iop/bin:${PS2DEV}/dvp/bin:${PS2SDK}/bin:${PATH}
```

Reload your shell after installation:

```bash
source /etc/profile.d/ps2dev.sh
# or simply open a new terminal
```

---

## Hello World Demo

After a successful install, a demo project is created at `~/PS2HelloWorld`:

```
~/PS2HelloWorld/
├── hello.c       — PS2 EE application source
├── Makefile      — Uses ps2sdk sample makefiles
└── README.md     — Build instructions
```

Build it:

```bash
cd ~/PS2HelloWorld
make
```

Output: `hello.elf` — ready to run on PCSX2 or real PlayStation 2 hardware.

---

## Build Dependencies

The installer installs all required dependencies automatically via `apt-get`:

```
gcc g++ make cmake patch git texinfo flex bison gettext autopoint
autoconf automake libtool libtool-bin m4
libgsl-dev libgmp-dev libmpfr-dev libmpc-dev zlib1g-dev
build-essential pkg-config python3
libucl-dev libelf-dev libyaml-dev
```

CMake 3.30+ is installed from the official [Kitware APT repository](https://apt.kitware.com) if the system version is too old.

---

## Logging

Every run produces a timestamped log file in the same directory as the script:

```
install-ps2sdk-v4.5-YYYYMMDD-HHMMSS.log
```

If a build step fails, the log contains the full compiler output and the exact line that caused the error.

---

## Troubleshooting

**OOM / GCC killed mid-compile**
Add swap before running a source build. See the swap instructions in [System Requirements](#system-requirements).

**CMake version error from ps2sdk-ports**
The installer handles this automatically by adding the Kitware APT repo. If your network blocks `apt.kitware.com`, run the CMake upgrade manually:
```bash
sudo snap install cmake --classic
```

**Environment variables not found after install**
Open a new terminal, or run:
```bash
source /etc/profile.d/ps2dev.sh
```

**Re-running the installer**
The installer is idempotent. Running it again will not duplicate environment exports. Source builds will re-use the existing workspace if present.

---

## Project Structure

```
ps2dev-installer/
└── install.sh    — Single self-contained Bash installer
```

---

## Acknowledgements

This installer wraps the upstream [PS2DEV](https://github.com/ps2dev) open-source toolchain maintained by the PS2DEV organisation and the wider PlayStation 2 homebrew community.

---

## Licence

MIT — see `LICENSE` for details.
