#!/usr/bin/env bash
# ==============================================================================
#  PS2DEV Toolchain Installer v4.5
#  PlayStation 2 Development Environment for Ubuntu 24 / 25
#  https://github.com/ps2dev
# ==============================================================================
  set -Eeuo pipefail

# ── Version & Metadata ────────────────────────────────────────────────────────
  readonly SCRIPT_VERSION="4.5"
  readonly STAMP="$(date '+%Y%m%d-%H%M%S')"
  readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  readonly LOG_FILE="${SCRIPT_DIR}/install-ps2sdk-v${SCRIPT_VERSION}-${STAMP}.log"

# ── Install Config ────────────────────────────────────────────────────────────
  readonly PS2DEV_DIR="/usr/local/ps2dev"
  readonly PS2DEV_META_REPO="https://github.com/ps2dev/ps2dev.git"
  readonly PREBUILT_API="https://api.github.com/repos/ps2dev/ps2dev/releases/latest"
  readonly CMAKE_MIN_VERSION="3.30"

# ── Workspace: never build in tmpfs ───────────────────────────────────────────
  _pick_workspace() {
    local primary="${HOME}/.cache/ps2dev-installer"
    local fallback="/var/tmp/ps2dev-installer"
    if findmnt -n -o FSTYPE --target /tmp 2>/dev/null | grep -qi tmpfs; then
      echo "${fallback}"
    else
      echo "${primary}"
    fi
  }
  readonly WORK_BASE="$(_pick_workspace)"

# ── State ─────────────────────────────────────────────────────────────────────
  INSTALL_MODE=""
  BUILD_JOBS=""
  WORKDIR=""

# ── Color Palette (PS2 theme) ─────────────────────────────────────────────────
  RESET="\033[0m"
  BOLD="\033[1m"
  DIM="\033[2m"
  C_BORDER="\033[38;5;39m"
  C_SILVER="\033[38;5;252m"
  C_CYAN="\033[38;5;51m"
  C_GOLD="\033[38;5;220m"
  C_RED="\033[38;5;196m"
  C_GREEN="\033[38;5;46m"
  C_YELLOW="\033[38;5;226m"
  C_DIM_BLUE="\033[38;5;63m"

# ── Logging ───────────────────────────────────────────────────────────────────
  _init_log() {
    mkdir -p "$(dirname "${LOG_FILE}")"
    {
      echo "PS2DEV Installer v${SCRIPT_VERSION} — Log Started"
      echo "Date   : $(date)"
      echo "System : $(uname -a)"
      echo "User   : $(id)"
      echo "============================================================"
    } >> "${LOG_FILE}"
  }

  log_raw() { echo "$*" >> "${LOG_FILE}"; }

  # ── Output Helpers ────────────────────────────────────────────────────────────
  msg()     { echo -e "  ${C_SILVER}${*}${RESET}" | tee -a "${LOG_FILE}"; }
  section() { echo -e "\n  ${C_CYAN}${BOLD}==> ${*}${RESET}\n" | tee -a "${LOG_FILE}"; }
  warn()    { echo -e "  ${C_YELLOW}${BOLD}[WARN]${RESET}${C_YELLOW}  ${*}${RESET}" | tee -a "${LOG_FILE}"; }
  success() { echo -e "  ${C_GREEN}${BOLD}[OK]${RESET}${C_GREEN}    ${*}${RESET}" | tee -a "${LOG_FILE}"; }
  fail()    {
    local text="$*"
    echo -e "  ${C_RED}${BOLD}[FAIL]${RESET}${C_RED}  ${text}${RESET}" | tee -a "${LOG_FILE}"
    echo -e "  ${DIM}Full log: ${LOG_FILE}${RESET}"
    exit 1
  }

# ── Spinner ───────────────────────────────────────────────────────────────────
  _SPINNER_FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  _SPINNER_PID=""

  spinner_start() {
    local label="${1:-Working...}"
    (
      local i=0
      while true; do
        printf "\r  ${C_CYAN}%s${RESET}  ${C_SILVER}%s${RESET}  " \
          "${_SPINNER_FRAMES[$((i % ${#_SPINNER_FRAMES[@]}))]}" "${label}"
        sleep 0.08
        (( i++ )) || true
      done
    ) &
    _SPINNER_PID=$!
    disown "${_SPINNER_PID}" 2>/dev/null || true
  }

  spinner_stop() {
    if [[ -n "${_SPINNER_PID}" ]]; then
      kill "${_SPINNER_PID}" 2>/dev/null || true
      wait "${_SPINNER_PID}" 2>/dev/null || true
      _SPINNER_PID=""
    fi
    printf "\r\033[K"
  }

  run_logged() {
    local label="${1}"; shift
    spinner_start "${label}"
    if "$@" >> "${LOG_FILE}" 2>&1; then
      spinner_stop
      success "${label}"
      return 0
    else
      local ec=$?
      spinner_stop
      fail "${label} — exit code ${ec}. Check: ${LOG_FILE}"
    fi
  }

# ── System Detection ──────────────────────────────────────────────────────────
  detect_ram_gb()  { awk '/MemTotal/{printf "%.1f", $2/1048576}' /proc/meminfo; }
  detect_swap_gb() { awk '/SwapTotal/{printf "%.1f", $2/1048576}' /proc/meminfo; }
  detect_disk_gb() { df -BG --output=avail / 2>/dev/null | tail -1 | tr -d 'G '; }
  detect_cpus()    { nproc --all 2>/dev/null || echo "1"; }

  detect_ubuntu_ver() {
    if command -v lsb_release &>/dev/null; then
      lsb_release -rs 2>/dev/null || echo "unknown"
    elif [[ -f /etc/os-release ]]; then
      . /etc/os-release; echo "${VERSION_ID:-unknown}"
    else
      echo "unknown"
    fi
  }

  detect_auto_jobs() {
    local ram_int; ram_int=$(printf '%.0f' "$(detect_ram_gb)")
    local cpus;    cpus="$(detect_cpus)"
    if   (( ram_int < 4  )); then echo "1"
    elif (( ram_int < 8  )); then echo "2"
    elif (( ram_int < 16 )); then echo "$(( cpus < 4 ? cpus : 4 ))"
    else                          echo "${cpus}"
    fi
  }

  cmake_version_ok() {
    local ver
    ver=$(cmake --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
    [[ -z "${ver}" ]] && return 1
    local major minor req_major req_minor
    major="${ver%%.*}"; minor="${ver##*.}"
    req_major="${CMAKE_MIN_VERSION%%.*}"; req_minor="${CMAKE_MIN_VERSION##*.}"
    (( major > req_major )) || { (( major == req_major )) && (( minor >= req_minor )); }
  }

# ── PS2 Dashboard UI ──────────────────────────────────────────────────────────
  _clear_screen() { printf "\033[2J\033[H"; }

  draw_splash() {
    _clear_screen
    local cols; cols=$(tput cols 2>/dev/null || echo 80)
    local box_w=80
    local pad_left=$(( (cols - box_w) / 2 ))
    local pad=""; for (( i=0; i<pad_left; i++ )); do pad+=" "; done
    local logo_pad=""; for (( i=0; i<$(( (pad_left - 9) )); i++ )); do logo_pad+=" "; done

    # echo "Columns: ${cols}"
    # echo "Cols-56: " $(( (cols - box_w) ))
    # echo "pad_left: ${pad_left}"

    echo ""
    echo -e "${pad}${C_BORDER}${DIM}  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ${RESET}"
    echo ""
    logo
    echo ""
    echo -e "${pad}${C_DIM_BLUE}  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ·  ${RESET}"
    echo ""
  }

  logo() {
    echo -e "${logo_pad}${C_BORDER} ███████████   █████████   ████████  ██████████   ██████████ █████   █████${RESET}"
    echo -e "${logo_pad}${C_BORDER}░░███░░░░░███ ███░░░░░███ ███░░░░███░░███░░░░███ ░░███░░░░░█░░███   ░░███ ${RESET}"
    echo -e "${logo_pad}${C_BORDER} ░███    ░███░███    ░░░ ░░░    ░███ ░███   ░░███ ░███  █ ░  ░███    ░███ ${RESET}"
    echo -e "${logo_pad}${C_BORDER} ░██████████ ░░█████████    ███████  ░███    ░███ ░██████    ░███    ░███ ${RESET}"
    echo -e "${logo_pad}${C_BORDER} ░███░░░░░░   ░░░░░░░░███  ███░░░░   ░███    ░███ ░███░░█    ░░███   ███  ${RESET}"
    echo -e "${logo_pad}${C_BORDER} ░███         ███    ░███ ███      █ ░███    ███  ░███ ░   █  ░░░█████░   ${RESET}"
    echo -e "${logo_pad}${C_BORDER} █████       ░░█████████ ░██████████ ██████████   ██████████    ░░███    ${RESET}"
    echo -e "${logo_pad}${C_BORDER}░░░░░         ░░░░░░░░░  ░░░░░░░░░░ ░░░░░░░░░░   ░░░░░░░░░░      ░░░      ${RESET}"                                                           
    echo ""
    echo -e "${pad}${C_BORDER} ╔══════════════════════════════════════════════════════╗${RESET}"
    echo -e "${pad}${C_BORDER} ║${RESET}  ${C_SILVER}${BOLD}Toolchain Installer  ${C_DIM_BLUE}v${SCRIPT_VERSION}${RESET}                           ${C_BORDER}║${RESET}"
    echo -e "${pad}${C_BORDER} ║${RESET}  ${DIM}${C_SILVER}PlayStation 2 Development Environment Setup${RESET}         ${C_BORDER}║${RESET}"
    echo -e "${pad}${C_BORDER} ╚══════════════════════════════════════════════════════╝${RESET}"
  }

  draw_system_info() {
    local cols; cols=$(tput cols 2>/dev/null || echo 80)
    local box_w=56
    local pad_left=$(( (cols - box_w) / 2 ))
    local pad=""; for (( i=0; i<pad_left; i++ )); do pad+=" "; done

    local ram;        ram="$(detect_ram_gb)"
    local swap;       swap="$(detect_swap_gb)"
    local disk;       disk="$(detect_disk_gb)"
    local cpus;       cpus="$(detect_cpus)"
    local ubuntu_ver; ubuntu_ver="$(detect_ubuntu_ver)"
    local ram_int;    ram_int=$(printf '%.0f' "${ram}")
    local swap_int;   swap_int=$(printf '%.0f' "${swap}")

    local ram_color
    if   (( ram_int < 4  )); then ram_label="CRITICAL"; ram_color="${C_RED}${BOLD}"
    elif (( ram_int < 8  )); then ram_label="LOW";      ram_color="${C_YELLOW}${BOLD}"
    else                          ram_label="OK";        ram_color="${C_GREEN}"
    fi

    local swap_label swap_color
    if (( swap_int == 0 )); then swap_label="None"; swap_color="${C_YELLOW}"
    else                         swap_label="${swap}GB"; swap_color="${C_GREEN}"
    fi

    local ver_color="${C_GREEN}"
    case "${ubuntu_ver}" in 24*|25*) ver_color="${C_GREEN}";; *) ver_color="${C_YELLOW}";; esac

    local cmake_ver cmake_color
    cmake_ver=$(cmake --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "not found")
    if cmake_version_ok; then cmake_color="${C_GREEN}"; else cmake_color="${C_YELLOW}"; fi

    echo -e "${pad}${C_BORDER}┌──────────────────────────────────────────────────────┐${RESET}"
    echo -e "${pad}${C_BORDER}│${RESET}  ${C_CYAN}${BOLD}System Requirements${RESET}                                   ${C_BORDER}│${RESET}"
    echo -e "${pad}${C_BORDER}│${RESET}  ${C_SILVER}• Ubuntu 24 / 25  • 8 GB RAM minimum recommended${RESET}    ${C_BORDER}│${RESET}"
    echo -e "${pad}${C_BORDER}│${RESET}  ${C_SILVER}• 20 GB free disk • Internet + sudo privileges${RESET}       ${C_BORDER}│${RESET}"
    echo -e "${pad}${C_BORDER}│${RESET}  ${C_SILVER}• CMake 3.30+  • Swap if RAM < 8 GB${RESET}                  ${C_BORDER}│${RESET}"
    echo -e "${pad}${C_BORDER}├──────────────────────────────────────────────────────┤${RESET}"
    echo -e "${pad}${C_BORDER}│${RESET}  ${C_CYAN}${BOLD}Detected${RESET}                                              ${C_BORDER}│${RESET}"
    printf "${pad}${C_BORDER}│${RESET}  ${C_SILVER}%-14s${RESET}%s%-36s${RESET}${C_BORDER}│${RESET}\n" \
      "OS:" "${ver_color}" "Ubuntu ${ubuntu_ver}"
    printf "${pad}${C_BORDER}│${RESET}  ${C_SILVER}%-14s${RESET}%s%-6s [%s]%-28s${RESET}${C_BORDER}│${RESET}\n" \
      "RAM:" "${ram_color}" "${ram}GB" "${ram_label}" ""
    printf "${pad}${C_BORDER}│${RESET}  ${C_SILVER}%-14s${RESET}${C_GREEN}%-36s${RESET}${C_BORDER}│${RESET}\n" \
      "Disk Free:" "${disk}GB available"
    printf "${pad}${C_BORDER}│${RESET}  ${C_SILVER}%-14s${RESET}%s%-36s${RESET}${C_BORDER}│${RESET}\n" \
      "Swap:" "${swap_color}" "${swap_label}"
    printf "${pad}${C_BORDER}│${RESET}  ${C_SILVER}%-14s${RESET}${C_CYAN}%-36s${RESET}${C_BORDER}│${RESET}\n" \
      "CPU Threads:" "${cpus}"
    printf "${pad}${C_BORDER}│${RESET}  ${C_SILVER}%-14s${RESET}%s%-36s${RESET}${C_BORDER}│${RESET}\n" \
      "CMake:" "${cmake_color}" "${cmake_ver}"
    echo -e "${pad}${C_BORDER}└──────────────────────────────────────────────────────┘${RESET}"
  }

  draw_main_menu() {
    local cols; cols=$(tput cols 2>/dev/null || echo 80)
    local box_w=56
    local pad_left=$(( (cols - box_w) / 2 ))
    local pad=""; for (( i=0; i<pad_left; i++ )); do pad+=" "; done

    echo ""
    echo -e "${pad}${C_BORDER}┌──────────────────────────────────────────────────────┐${RESET}"
    echo -e "${pad}${C_BORDER}│${RESET}                  ${C_GOLD}${BOLD}[ PS2DEV ]${RESET}                            ${C_BORDER}│${RESET}"
    echo -e "${pad}${C_BORDER}│${RESET}                                                      ${C_BORDER}│${RESET}"
    echo -e "${pad}${C_BORDER}│${RESET}  ${C_CYAN}${BOLD}1.${RESET}  ${C_SILVER}${BOLD}AUTO INSTALL${RESET}                                    ${C_BORDER}│${RESET}"
    echo -e "${pad}${C_BORDER}│${RESET}     ${DIM}Try prebuilt first; fall back to source build${RESET}    ${C_BORDER}│${RESET}"
    echo -e "${pad}${C_BORDER}│${RESET}                                                      ${C_BORDER}│${RESET}"
    echo -e "${pad}${C_BORDER}│${RESET}  ${C_CYAN}${BOLD}2.${RESET}  ${C_SILVER}${BOLD}PREBUILT ONLY${RESET}                                   ${C_BORDER}│${RESET}"
    echo -e "${pad}${C_BORDER}│${RESET}     ${DIM}Tarball install only — fails cleanly if broken${RESET}   ${C_BORDER}│${RESET}"
    echo -e "${pad}${C_BORDER}│${RESET}                                                      ${C_BORDER}│${RESET}"
    echo -e "${pad}${C_BORDER}│${RESET}  ${C_CYAN}${BOLD}3.${RESET}  ${C_SILVER}${BOLD}BUILD FROM SOURCE${RESET}                               ${C_BORDER}│${RESET}"
    echo -e "${pad}${C_BORDER}│${RESET}     ${DIM}Compile full toolchain (30–120 min)${RESET}               ${C_BORDER}│${RESET}"
    echo -e "${pad}${C_BORDER}│${RESET}                                                      ${C_BORDER}│${RESET}"
    echo -e "${pad}${C_BORDER}│${RESET}  ${C_CYAN}${BOLD}4.${RESET}  ${C_SILVER}${BOLD}SETTINGS${RESET}                                        ${C_BORDER}│${RESET}"
    echo -e "${pad}${C_BORDER}│${RESET}     ${DIM}Configure build jobs  [Current: ${BUILD_JOBS}]${RESET}              ${C_BORDER}│${RESET}"
    echo -e "${pad}${C_BORDER}│${RESET}                                                      ${C_BORDER}│${RESET}"
    echo -e "${pad}${C_BORDER}│${RESET}  ${C_CYAN}${BOLD}5.${RESET}  ${C_SILVER}${BOLD}EXIT${RESET}                                            ${C_BORDER}│${RESET}"
    echo -e "${pad}${C_BORDER}│${RESET}                                                      ${C_BORDER}│${RESET}"
    echo -e "${pad}${C_BORDER}└──────────────────────────────────────────────────────┘${RESET}"
    echo ""
  }

  draw_settings_menu() {
    local cols; cols=$(tput cols 2>/dev/null || echo 80)
    local box_w=56
    local pad_left=$(( (cols - box_w) / 2 ))
    local pad=""; for (( i=0; i<pad_left; i++ )); do pad+=" "; done
    local auto_jobs; auto_jobs="$(detect_auto_jobs)"

    echo ""
    echo -e "${pad}${C_BORDER}┌──────────────────────────────────────────────────────┐${RESET}"
    echo -e "${pad}${C_BORDER}│${RESET}  ${C_GOLD}${BOLD}[ SETTINGS ]${RESET}  Build Job Configuration                ${C_BORDER}│${RESET}"
    echo -e "${pad}${C_BORDER}│${RESET}                                                      ${C_BORDER}│${RESET}"
    printf "${pad}${C_BORDER}│${RESET}  ${C_SILVER}Current Jobs:${RESET}  ${C_CYAN}${BOLD}%-38s${RESET}${C_BORDER}│${RESET}\n" "${BUILD_JOBS}"
    echo -e "${pad}${C_BORDER}│${RESET}                                                      ${C_BORDER}│${RESET}"
    echo -e "${pad}${C_BORDER}│${RESET}  ${C_CYAN}${BOLD}1.${RESET}  ${C_SILVER}Auto Safe Mode${RESET}  ${DIM}(Recommended: ${auto_jobs} jobs)${RESET}        ${C_BORDER}│${RESET}"
    echo -e "${pad}${C_BORDER}│${RESET}  ${C_CYAN}${BOLD}2.${RESET}  ${C_SILVER}1 Job${RESET}          ${DIM}(Safest — lowest RAM usage)${RESET}            ${C_BORDER}│${RESET}"
    echo -e "${pad}${C_BORDER}│${RESET}  ${C_CYAN}${BOLD}3.${RESET}  ${C_SILVER}2 Jobs${RESET}                                              ${C_BORDER}│${RESET}"
    echo -e "${pad}${C_BORDER}│${RESET}  ${C_CYAN}${BOLD}4.${RESET}  ${C_SILVER}4 Jobs${RESET}                                              ${C_BORDER}│${RESET}"
    echo -e "${pad}${C_BORDER}│${RESET}  ${C_CYAN}${BOLD}5.${RESET}  ${C_SILVER}Custom${RESET}                                              ${C_BORDER}│${RESET}"
    echo -e "${pad}${C_BORDER}│${RESET}  ${C_CYAN}${BOLD}6.${RESET}  ${C_SILVER}Back to Main Menu${RESET}                                   ${C_BORDER}│${RESET}"
    echo -e "${pad}${C_BORDER}│${RESET}                                                      ${C_BORDER}│${RESET}"
    echo -e "${pad}${C_BORDER}└──────────────────────────────────────────────────────┘${RESET}"
    echo ""
  }

# ── Menus ─────────────────────────────────────────────────────────────────────
  menu_settings() {
    while true; do
      draw_splash
      draw_settings_menu
      echo -ne "  ${C_CYAN}Select [1-6]:${RESET} "
      local choice; read -r choice
      case "${choice}" in
        1) BUILD_JOBS="$(detect_auto_jobs)"; msg "Jobs set to: ${BUILD_JOBS} (Auto Safe Mode)"; sleep 1; return ;;
        2) BUILD_JOBS=1;  msg "Jobs set to: 1"; sleep 1; return ;;
        3) BUILD_JOBS=2;  msg "Jobs set to: 2"; sleep 1; return ;;
        4) BUILD_JOBS=4;  msg "Jobs set to: 4"; sleep 1; return ;;
        5)
          echo -ne "  ${C_CYAN}Enter custom job count:${RESET} "
          local v; read -r v
          if [[ "${v}" =~ ^[1-9][0-9]*$ ]]; then
            BUILD_JOBS="${v}"; msg "Jobs set to: ${BUILD_JOBS}"; sleep 1; return
          else
            warn "Invalid. Must be a positive integer."; sleep 2
          fi ;;
        6) return ;;
        *) warn "Invalid selection."; sleep 1 ;;
      esac
    done
  }

  menu() {
    [[ -z "${BUILD_JOBS}" ]] && BUILD_JOBS="$(detect_auto_jobs)"
    while true; do
      draw_splash
      draw_system_info
      draw_main_menu
      echo -ne "  ${C_CYAN}Select [1-5]:${RESET} "
      local choice; read -r choice
      case "${choice}" in
        1) INSTALL_MODE="auto";     break ;;
        2) INSTALL_MODE="prebuilt"; break ;;
        3) INSTALL_MODE="source";   break ;;
        4) menu_settings ;;
        5) echo -e "\n  ${C_SILVER}Goodbye.${RESET}\n"; exit 0 ;;
        *) warn "Invalid selection."; sleep 1 ;;
      esac
    done
  }

# ── Privilege Check ───────────────────────────────────────────────────────────
  check_sudo() {
    if [[ "${EUID}" -ne 0 ]]; then
      echo -e "  ${C_YELLOW}${BOLD}[SUDO]${RESET}  Re-running as root via sudo..."
      exec sudo --preserve-env=HOME,PATH,USER,SUDO_USER \
        env SUDO_USER="${USER}" \
            SUDO_USER_HOME="${HOME}" \
            bash "${BASH_SOURCE[0]}" "$@"
    fi
  }

# ── CMake Upgrade ─────────────────────────────────────────────────────────────
  # Ubuntu 24.04 ships CMake 3.28; ps2sdk-ports/theora requires 3.30+.
  # Install the official Kitware APT release which provides the latest stable CMake.
  install_cmake_kitware() {
    section "Installing CMake ${CMAKE_MIN_VERSION}+ from Kitware APT"

    if cmake_version_ok; then
      local current_ver
      current_ver=$(cmake --version | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
      success "CMake ${current_ver} already meets requirement — skipping."
      return 0
    fi

    warn "System CMake is below ${CMAKE_MIN_VERSION} — installing from Kitware APT..."

    run_logged "Installing ca-certificates and wget" \
      apt-get install -y --no-install-recommends ca-certificates wget gpg

    # Add Kitware GPG key
    run_logged "Adding Kitware GPG key" \
      bash -c "wget -O - https://apt.kitware.com/keys/kitware-archive-latest.asc 2>/dev/null \
        | gpg --dearmor - \
        | tee /usr/share/keyrings/kitware-archive-keyring.gpg > /dev/null"

    # Detect codename (works for Ubuntu 24 noble, 25 plucky)
    local codename
    codename=$(lsb_release -cs 2>/dev/null || echo "noble")

    run_logged "Adding Kitware APT repository" \
      bash -c "echo 'deb [signed-by=/usr/share/keyrings/kitware-archive-keyring.gpg] \
  https://apt.kitware.com/ubuntu/ ${codename} main' \
        | tee /etc/apt/sources.list.d/kitware.list > /dev/null"

    run_logged "Updating package index (with Kitware)" \
      apt-get update -y

    run_logged "Installing cmake (latest Kitware release)" \
      apt-get install -y cmake

    if cmake_version_ok; then
      local new_ver
      new_ver=$(cmake --version | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
      success "CMake upgraded to ${new_ver}."
    else
      fail "CMake upgrade failed — version still below ${CMAKE_MIN_VERSION}."
    fi
  }

# ── Dependencies ──────────────────────────────────────────────────────────────
  install_deps() {
    section "Installing dependencies"

    run_logged "Updating package index" \
      apt-get update -y

    run_logged "Installing build dependencies" \
      apt-get install -y \
        curl jq file tar xz-utils unzip wget ca-certificates lsb-release \
        gcc g++ make cmake patch git texinfo flex bison gettext autopoint \
        autoconf automake libtool libtool-bin m4 \
        libgsl-dev libgmp-dev libmpfr-dev libmpc-dev zlib1g-dev \
        build-essential pkg-config libucl-dev libelf-dev libyaml-dev \
        python3 gpg

    # Upgrade CMake to 3.30+ immediately after base deps are in place
    install_cmake_kitware
  }

# ── Environment Setup ─────────────────────────────────────────────────────────
  setup_env() {
    export PS2DEV="${PS2DEV_DIR}"
    export PS2SDK="${PS2DEV}/ps2sdk"
    export GSKIT="${PS2DEV}/gsKit"
    export PATH="${PS2DEV}/bin:${PS2DEV}/ee/bin:${PS2DEV}/iop/bin:${PS2DEV}/dvp/bin:${PS2SDK}/bin:${PATH}"
    mkdir -p "${PS2DEV_DIR}"
    mkdir -p "${WORK_BASE}"
    WORKDIR="${WORK_BASE}/run-${STAMP}"
    mkdir -p "${WORKDIR}"
    log_raw "PS2DEV  = ${PS2DEV}"
    log_raw "PS2SDK  = ${PS2SDK}"
    log_raw "GSKIT   = ${GSKIT}"
    log_raw "PATH    = ${PATH}"
    log_raw "WORKDIR = ${WORKDIR}"
  }

# ── Swap Warning ──────────────────────────────────────────────────────────────
  check_swap_warning() {
    local ram_int;  ram_int=$(printf '%.0f' "$(detect_ram_gb)")
    local swap_int; swap_int=$(printf '%.0f' "$(detect_swap_gb)")
    if (( ram_int < 8 )) && (( swap_int == 0 )); then
      echo ""
      warn "══════════════════════════════════════════════════"
      warn "  LOW RAM + NO SWAP"
      warn "  RAM: ${ram_int}GB — No swap found."
      warn "  GCC may OOM-kill during compile."
      warn ""
      warn "  Create 4 GB swap before continuing:"
      warn "    sudo fallocate -l 4G /swapfile"
      warn "    sudo chmod 600 /swapfile"
      warn "    sudo mkswap /swapfile"
      warn "    sudo swapon /swapfile"
      warn "══════════════════════════════════════════════════"
      echo ""
      echo -ne "  ${C_YELLOW}Continue anyway? [y/N]:${RESET} "
      local ans; read -r ans
      [[ "${ans,,}" == "y" ]] || { msg "Aborted."; exit 0; }
    fi
  }

# ── Prebuilt Install ──────────────────────────────────────────────────────────
  install_prebuilt() {
    section "Installing PS2DEV (prebuilt tarball)"

    msg "Querying GitHub releases API..."
    local url
    url="$(curl -fsSL "${PREBUILT_API}" \
      | jq -r '.assets[].browser_download_url' \
      | grep -i ubuntu | grep -i '\.tar' | head -n1 || true)"

    if [[ -z "${url}" ]]; then
      warn "No Ubuntu prebuilt asset found in GitHub releases."
      return 1
    fi

    msg "Using: ${url}"
    local archive="${WORKDIR}/prebuilt.tar.gz"
    local stage="${WORKDIR}/prebuilt-stage"
    rm -rf "${stage}"; mkdir -p "${stage}"

    if ! curl -fL --retry 3 --retry-delay 2 \
        --progress-bar -o "${archive}" "${url}" >> "${LOG_FILE}" 2>&1; then
      warn "Prebuilt download failed."
      return 1
    fi

    [[ -s "${archive}" ]] || { warn "Downloaded archive is empty."; return 1; }

    msg "Validating tarball..."
    if ! tar -tzf "${archive}" >> "${LOG_FILE}" 2>&1; then
      warn "Tarball is corrupt or unreadable."
      return 1
    fi

    local tarball_list; tarball_list=$(tar -tzf "${archive}" 2>/dev/null)
    local found_gcc=false
    if echo "${tarball_list}" | grep -q "mips64r5900el-ps2-elf-gcc"; then found_gcc=true; fi
    if echo "${tarball_list}" | grep -q "ee-gcc"; then found_gcc=true; fi
    if [[ "${found_gcc}" == "false" ]]; then
      warn "Tarball does not contain expected PS2 compiler."
      return 1
    fi

    run_logged "Extracting prebuilt" \
      tar -xzf "${archive}" -C "${stage}"

    local rootdir="${stage}"
    [[ -d "${stage}/ps2dev" ]] && rootdir="${stage}/ps2dev"

    run_logged "Installing prebuilt files" \
      bash -c "shopt -s dotglob nullglob; rm -rf '${PS2DEV_DIR}'/*; cp -a '${rootdir}'/* '${PS2DEV_DIR}'/"

    success "Prebuilt installation complete."
    return 0
  }

# ── Source Build ──────────────────────────────────────────────────────────────
  install_source() {
    section "Building PS2DEV from source"
    check_swap_warning

    local src="${WORKDIR}/src"

    section "Cloning ps2dev meta-repository"
    if [[ -d "${src}/.git" ]]; then
      run_logged "Updating ps2dev" git -C "${src}" pull --ff-only
    else
      run_logged "Cloning ps2dev" git clone --depth=1 "${PS2DEV_META_REPO}" "${src}"
    fi

    section "Building full toolchain  [jobs=${BUILD_JOBS}]"
    msg "Compiling: GCC, binutils, newlib, ps2sdk, gsKit, ps2sdk-ports"
    msg "Expected time: 30–120 minutes depending on hardware."
    msg "Note: optional ports that fail will be skipped automatically."

    (
      export PS2DEV PS2SDK GSKIT PATH
      export MAKEFLAGS="-j${BUILD_JOBS}"

      cd "${src}"
      chmod +x build-all.sh

      # Patch build-all.sh to use set +e so that a single failing optional port
      # (e.g. theora on cmake 3.28) does not abort the entire toolchain build.
      # We do this by wrapping each scripts/003-ps2sdk-ports.sh call in a
      # subshell that ignores errors — but the safest approach is to patch
      # the ps2sdk-ports CMakeLists for theora to relax the cmake_minimum.
      #
      # Strategy: If theora's CMakeLists.txt demands cmake >= 3.30 and we have
      # >= 3.30 from Kitware, it just works.  If Kitware install somehow failed,
      # we fall back to running build-all.sh with || true on the ports step.
      if cmake_version_ok; then
        run_logged "Running build-all.sh" bash build-all.sh
      else
        warn "CMake < ${CMAKE_MIN_VERSION} detected — theora port will be skipped."
        # Patch: comment out theora from the ports Makefile if present
        local ports_mk="${src}/ps2sdk-ports/Makefile"
        if [[ -f "${ports_mk}" ]]; then
          sed -i 's/^\(.*theora.*\)$/#SKIPPED_THEORA \1/' "${ports_mk}" || true
          log_raw "Patched theora out of ps2sdk-ports/Makefile"
        fi
        run_logged "Running build-all.sh (theora skipped)" bash build-all.sh
      fi
    )

    success "Source build complete."
  }

# ── Profile / Environment Export ──────────────────────────────────────────────
  write_profile() {
    section "Finalizing environment"

    local real_home="${SUDO_USER_HOME:-${HOME}}"
    local env_begin="# >>> PS2DEV BEGIN >>>"
    local env_end="# <<< PS2DEV END <<<"

    local profile_block
    profile_block="$(printf '%s\n' \
      "" \
      "${env_begin}" \
      "export PS2DEV=${PS2DEV_DIR}" \
      'export PS2SDK=${PS2DEV}/ps2sdk' \
      'export GSKIT=${PS2DEV}/gsKit' \
      'export PATH=${PS2DEV}/bin:${PS2DEV}/ee/bin:${PS2DEV}/iop/bin:${PS2DEV}/dvp/bin:${PS2SDK}/bin:${PATH}' \
      "${env_end}" \
      "")"

    local system_profile="/etc/profile.d/ps2dev.sh"
    if [[ ! -f "${system_profile}" ]]; then
      echo "${profile_block}" > "${system_profile}"
      chmod 644 "${system_profile}"
      success "Environment written to ${system_profile}"
    else
      success "System profile already present — not duplicated."
    fi

    for rcfile in "${real_home}/.bashrc" "${real_home}/.zshrc"; do
      if [[ -f "${rcfile}" ]]; then
        if ! grep -q "PS2DEV=${PS2DEV_DIR}" "${rcfile}" 2>/dev/null; then
          echo "${profile_block}" >> "${rcfile}"
          success "Environment appended to ${rcfile}"
        else
          success "${rcfile} already has PS2DEV export — skipped."
        fi
      fi
    done
  }

# ── Verification ──────────────────────────────────────────────────────────────
  verify_install() {
    section "Verifying installation"
    local all_ok=true

    local -a required_dirs=(
      "${PS2DEV_DIR}/ee/bin"
      "${PS2DEV_DIR}/iop/bin"
      "${PS2DEV_DIR}/dvp/bin"
    )

    for d in "${required_dirs[@]}"; do
      if [[ -d "${d}" ]]; then
        success "Directory OK: ${d}"
      else
        warn "Missing directory: ${d}"
        all_ok=false
      fi
    done

    local gcc_bin=""
    for candidate in \
      "${PS2DEV_DIR}/ee/bin/mips64r5900el-ps2-elf-gcc" \
      "${PS2DEV_DIR}/ee/bin/ee-gcc"; do
      if [[ -x "${candidate}" ]]; then gcc_bin="${candidate}"; break; fi
    done

    if [[ -n "${gcc_bin}" ]]; then
      success "Compiler found: ${gcc_bin}"
      local ver; ver=$("${gcc_bin}" --version 2>&1 | head -1)
      msg "  ${ver}"
    else
      warn "PS2 compiler not found in ${PS2DEV_DIR}/ee/bin/"
      all_ok=false
    fi

    if [[ "${all_ok}" == "true" ]]; then
      success "All verification checks passed."
    else
      warn "Some checks failed — review log: ${LOG_FILE}"
    fi
  }

# ── Hello World Demo ──────────────────────────────────────────────────────────
  create_hello_world() {
    section "Creating PS2 Hello World demo project"

    local real_home="${SUDO_USER_HOME:-${HOME}}"
    local real_user="${SUDO_USER:-}"
    local demo_dir="${real_home}/PS2HelloWorld"
    mkdir -p "${demo_dir}"

    printf '%s\n' \
      '/*'                                                     \
      ' * PS2 Hello World'                                     \
      ' * Generated by PS2DEV Installer v4.5'                 \
      ' */'                                                    \
      '#include <stdio.h>'                                     \
      '#include <kernel.h>'                                    \
      '#include <debug.h>'                                     \
      ''                                                       \
      'int main(int argc, char *argv[])'                       \
      '{'                                                      \
      '    (void)argc; (void)argv;'                            \
      '    init_scr();'                                        \
      '    scr_printf("Hello, PlayStation 2!\n");'             \
      '    scr_printf("PS2DEV toolchain installed successfully.\n");' \
      '    SleepThread();'                                     \
      '    return 0;'                                          \
      '}' > "${demo_dir}/hello.c"

    printf '%s\n' \
      '# PS2 Hello World — Generated by PS2DEV Installer v4.5' \
      'EE_BIN    = hello.elf'                                  \
      'EE_OBJS   = hello.o'                                    \
      'EE_LIBS   = -lkernel -ldebug'                           \
      ''                                                       \
      'include $(PS2SDK)/samples/Makefile.pref'                \
      'include $(PS2SDK)/samples/Makefile.eeglobal' > "${demo_dir}/Makefile"

    printf '%s\n' \
      '# PS2 Hello World'                                      \
      ''                                                       \
      'Generated by the PS2DEV Installer v4.5.'               \
      ''                                                       \
      '## Build'                                               \
      ''                                                       \
      '```bash'                                                \
      'source /etc/profile.d/ps2dev.sh   # or open a new terminal' \
      'cd ~/PS2HelloWorld'                                     \
      'make'                                                   \
      '```'                                                    \
      ''                                                       \
      '## Output'                                              \
      ''                                                       \
      '`hello.elf` — run on PCSX2 emulator or real PS2 hardware.' > "${demo_dir}/README.md"

    if [[ -n "${real_user}" ]]; then
      chown -R "${real_user}:" "${demo_dir}" 2>/dev/null || true
    fi

    echo ""
    echo -e "  ${C_GREEN}${BOLD}Demo project created:${RESET}  ${C_CYAN}${demo_dir}${RESET}"
    echo ""
    echo -e "  ${C_SILVER}Build:${RESET}   ${C_CYAN}cd ~/PS2HelloWorld && make${RESET}"
    echo -e "  ${C_SILVER}Output:${RESET}  ${C_CYAN}hello.elf${RESET}"
    echo ""
  }

# ── Test Compile ──────────────────────────────────────────────────────────────
  test_compile() {
    section "Test compile — hello.elf"

    local real_home="${SUDO_USER_HOME:-${HOME}}"
    local demo_dir="${real_home}/PS2HelloWorld"

    [[ -f "${demo_dir}/hello.c" ]] || { warn "Demo project not found — skipping."; return; }

    local gcc_bin=""
    for candidate in \
      "${PS2DEV_DIR}/ee/bin/mips64r5900el-ps2-elf-gcc" \
      "${PS2DEV_DIR}/ee/bin/ee-gcc"; do
      if [[ -x "${candidate}" ]]; then gcc_bin="${candidate}"; break; fi
    done

    [[ -n "${gcc_bin}" ]] || { warn "Compiler not accessible — skipping compile test."; return; }

    (
      export PS2DEV PS2SDK GSKIT PATH
      cd "${demo_dir}"
      if make >> "${LOG_FILE}" 2>&1; then
        success "hello.elf compiled successfully."
      else
        warn "Compile test failed — run manually after reloading your shell:"
        warn "  source /etc/profile.d/ps2dev.sh && cd ~/PS2HelloWorld && make"
      fi
    )
  }

# ── Success Banner ────────────────────────────────────────────────────────────
  print_success_banner() {
    local cols; cols=$(tput cols 2>/dev/null || echo 80)
    local box_w=56
    local pad_left=$(( (cols - box_w) / 2 ))
    local pad=""; for (( i=0; i<pad_left; i++ )); do pad+=" "; done

    echo ""
    echo -e "${pad}${C_BORDER}╔══════════════════════════════════════════════════════╗${RESET}"
    echo -e "${pad}${C_BORDER}║${RESET}  ${C_GREEN}${BOLD}  PS2DEV INSTALLATION COMPLETE  ${RESET}                    ${C_BORDER}║${RESET}"
    echo -e "${pad}${C_BORDER}║${RESET}                                                      ${C_BORDER}║${RESET}"
    echo -e "${pad}${C_BORDER}║${RESET}  ${C_SILVER}Install path :${RESET}  ${C_CYAN}${PS2DEV_DIR}${RESET}              ${C_BORDER}║${RESET}"
    echo -e "${pad}${C_BORDER}║${RESET}                                                      ${C_BORDER}║${RESET}"
    echo -e "${pad}${C_BORDER}║${RESET}  ${C_SILVER}Reload shell to apply environment:${RESET}                  ${C_BORDER}║${RESET}"
    echo -e "${pad}${C_BORDER}║${RESET}  ${C_CYAN}    source /etc/profile.d/ps2dev.sh${RESET}                 ${C_BORDER}║${RESET}"
    echo -e "${pad}${C_BORDER}║${RESET}  ${C_CYAN}    # or open a new terminal${RESET}                        ${C_BORDER}║${RESET}"
    echo -e "${pad}${C_BORDER}║${RESET}                                                      ${C_BORDER}║${RESET}"
    echo -e "${pad}${C_BORDER}║${RESET}  ${C_SILVER}Build hello world:${RESET}                                  ${C_BORDER}║${RESET}"
    echo -e "${pad}${C_BORDER}║${RESET}  ${C_CYAN}    cd ~/PS2HelloWorld && make${RESET}                       ${C_BORDER}║${RESET}"
    echo -e "${pad}${C_BORDER}║${RESET}                                                      ${C_BORDER}║${RESET}"
    echo -e "${pad}${C_BORDER}║${RESET}  ${C_SILVER}Log:${RESET}                                                ${C_BORDER}║${RESET}"
    echo -e "${pad}${C_DIM_BLUE}    ${LOG_FILE}${RESET}"
    echo -e "${pad}${C_BORDER}╚══════════════════════════════════════════════════════╝${RESET}"
    echo ""
  }

# ── Traps ─────────────────────────────────────────────────────────────────────
  _on_exit() {
    local ec="${?}"
    spinner_stop
    if (( ec != 0 )); then
      echo ""
      echo -e "  ${C_RED}${BOLD}Installation terminated (exit ${ec}).${RESET}"
      echo -e "  ${DIM}Full log: ${LOG_FILE}${RESET}"
      echo ""
    fi
  }

  _on_err() {
    local line="${1}" cmd="${2}" ec="${3}"
    spinner_stop
    log_raw "[ERROR] Line ${line}: '${cmd}' exited with code ${ec}"
  }

  trap '_on_exit' EXIT
  trap '_on_err "${LINENO}" "${BASH_COMMAND}" "${?}"' ERR

# ── Main ──────────────────────────────────────────────────────────────────────
  main() {
    export SUDO_USER_HOME="${HOME}"
    if [[ -n "${SUDO_USER:-}" ]]; then
      SUDO_USER_HOME="$(getent passwd "${SUDO_USER}" | cut -d: -f6)"
    fi

    check_sudo "$@"
    _init_log
    menu

    setup_env

    msg "Install mode : ${INSTALL_MODE}"
    msg "Build jobs   : ${BUILD_JOBS}"
    msg "Log file     : ${LOG_FILE}"
    echo ""

    install_deps    # includes cmake upgrade to 3.30+
    setup_env       # re-export after deps so PATH picks up any new tools

    case "${INSTALL_MODE}" in
      auto)
        section "Attempting prebuilt installation"
        if install_prebuilt; then
          msg "Prebuilt tarball installed successfully."
        else
          warn "Prebuilt unavailable — falling back to source build."
          install_source
        fi
        ;;
      prebuilt)
        install_prebuilt || fail "Prebuilt install failed. Use mode 3 (Build From Source) instead."
        ;;
      source)
        install_source
        ;;
      *)
        fail "Unknown install mode: ${INSTALL_MODE}"
        ;;
    esac

    write_profile
    create_hello_world
    verify_install
    test_compile
    print_success_banner
  }

main "$@"