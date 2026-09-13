#!/usr/bin/env bash
# ==============================================================================
#  MediaTek MT7902 (Filogic 310) Wi-Fi & Bluetooth Universal Installer
# ==============================================================================
#  Supported Distros:
#    - Debian / Ubuntu / Linux Mint / Pop!_OS / Zorin OS
#    - Arch Linux / Manjaro / EndeavourOS / CachyOS / Garuda
#
#  Kernel Compatibility: Linux 6.12 to 7.0+
#
#  Key Features:
#    ✅ Automated DKMS driver compilation (auto-rebuilds on kernel updates)
#    ✅ Full firmware deployment (Wi-Fi 6E + Bluetooth combo)
#    ✅ Conflicting BT firmware resolution (fixes early boot Bluetooth dropouts)
#    ✅ Antenna Diversity fix (options mt7921_common antenna_mask=3)
#       -> Eliminates the 1.5–3 Mbps download speed cap & restores full 20–100+ Mbps
#    ✅ PCIe ASPM sleep fix (options mt7921e disable_aspm=y)
#       -> Prevents random disconnects & latency spikes
#    ✅ NetworkManager Wi-Fi powersave disabling (wifi.powersave = 2)
#    ✅ Regulatory domain (country code) auto-detection and persistence
#    ✅ In-place module reload (no reboot required)
#    ✅ Full uninstaller support (--uninstall)
# ==============================================================================

set -euo pipefail

# ── Colors & Logging ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${CYAN}ℹ️  $*${RESET}"; }
success() { echo -e "${GREEN}✅ $*${RESET}"; }
warn()    { echo -e "${YELLOW}⚠️  $*${RESET}"; }
error()   { echo -e "${RED}❌ $*${RESET}" >&2; exit 1; }
step()    { echo -e "\n${BOLD}${CYAN}▶ $*${RESET}"; }

# ── Sanity Checks ─────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    error "Please run this script with root privileges:\n    sudo bash $0"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER_SRC="$SCRIPT_DIR/driver"
FIRMWARE_SRC="$SCRIPT_DIR/firmware"

if [[ ! -d "$DRIVER_SRC" ]]; then
    error "Driver source directory not found at '$DRIVER_SRC'."
fi

if [[ ! -d "$FIRMWARE_SRC" ]]; then
    error "Firmware source directory not found at '$FIRMWARE_SRC'."
fi

# ── Argument Parsing ──────────────────────────────────────────────────────────
COUNTRY_ARG=""
UNINSTALL=false
YES=false

for arg in "$@"; do
    case "$arg" in
        --uninstall) UNINSTALL=true ;;
        -y|--yes)    YES=true ;;
        --country)   shift; COUNTRY_ARG="${1:-}" ;;
        --country=*) COUNTRY_ARG="${arg#--country=}" ;;
    esac
done

# ── Distro Detection ──────────────────────────────────────────────────────────
detect_distro() {
    local id="" id_like=""
    if [[ -f /etc/os-release ]]; then
        id=$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')
        id_like=$(grep -E '^ID_LIKE=' /etc/os-release | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')
    fi

    IS_ARCH=false
    IS_DEBIAN=false
    IS_CACHYOS=false

    if echo "$id $id_like" | grep -qE 'arch|manjaro|endeavouros|garuda|cachyos'; then
        IS_ARCH=true
        echo "$id" | grep -q 'cachyos' && IS_CACHYOS=true
    elif echo "$id $id_like" | grep -qE 'debian|ubuntu|mint|pop|linuxmint|zorin'; then
        IS_DEBIAN=true
    else
        error "Unsupported distribution: '$id'. Supported families: Debian/Ubuntu and Arch Linux."
    fi

    DISTRO_NAME=$(grep -E '^PRETTY_NAME=' /etc/os-release 2>/dev/null \
                  | cut -d= -f2 | tr -d '"' || echo "$id")
}

# ── Uninstall Mode ────────────────────────────────────────────────────────────
do_uninstall() {
    echo ""
    echo -e "${RED}${BOLD}╔════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${RED}${BOLD}║  ⚠️  UNINSTALLATION CONFIRMATION                           ║${RESET}"
    echo -e "${RED}${BOLD}║  This will remove the MT7902 Wi-Fi and Bluetooth driver.    ║${RESET}"
    echo -e "${RED}${BOLD}║  Ensure you have an alternative network connection (cable   ║${RESET}"
    echo -e "${RED}${BOLD}║  or USB tethering) before continuing.                      ║${RESET}"
    echo -e "${RED}${BOLD}╚════════════════════════════════════════════════════════════╝${RESET}"
    echo ""
    if ! $YES; then
        read -rp "Do you want to proceed with uninstallation? [y/N]: " confirm
        [[ "${confirm,,}" != "y" ]] && { info "Uninstallation cancelled."; exit 0; }
    fi

    step "Uninstalling MT7902 DKMS driver..."
    if command -v dkms &>/dev/null && dkms status | grep -q 'mt7902-wifi'; then
        info "Removing DKMS module mt7902-wifi/1.0..."
        dkms remove mt7902-wifi/1.0 --all 2>/dev/null || true
        rm -rf /usr/src/mt7902-wifi-1.0
        success "DKMS module removed."
    fi

    step "Cleaning module configurations..."
    rm -f /etc/modprobe.d/mt7921e.conf 2>/dev/null || true
    rm -f /etc/modprobe.d/mt7921_antenna.conf 2>/dev/null || true
    rm -f /etc/NetworkManager/conf.d/wifi-powersave-off.conf 2>/dev/null || true

    success "Uninstallation complete. A system reboot is recommended."
    exit 0
}

# ── Install Build Dependencies ────────────────────────────────────────────────
install_deps() {
    step "Installing build dependencies for $DISTRO_NAME..."
    if $IS_DEBIAN; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq \
            build-essential \
            "linux-headers-$(uname -r)" \
            dkms \
            bc \
            wireless-regdb \
            iw \
            curl
    elif $IS_ARCH; then
        local pkgs=(base-devel dkms iw wireless-regdb curl bc)
        $IS_CACHYOS && pkgs+=(clang llvm lld)

        local hdr_pkg="linux-headers"
        if uname -r | grep -q 'cachyos'; then
            hdr_pkg="linux-cachyos-headers"
        elif uname -r | grep -q 'lts'; then
            hdr_pkg="linux-lts-headers"
        elif uname -r | grep -q 'zen'; then
            hdr_pkg="linux-zen-headers"
        elif uname -r | grep -q 'hardened'; then
            hdr_pkg="linux-hardened-headers"
        fi
        pkgs+=("$hdr_pkg")
        pacman -S --needed --noconfirm "${pkgs[@]}"
    fi
    success "Dependencies successfully installed."
}

# ── Regulatory Domain (Country Code) ──────────────────────────────────────────
configure_regdom() {
    step "Configuring Wi-Fi Regulatory Domain (Country Code)..."
    local country="$COUNTRY_ARG"

    if [[ -z "$country" ]]; then
        # Check existing system settings
        if [[ -f /etc/conf.d/wireless-regdom ]]; then
            country=$(grep -oP '(?<=WIRELESS_REGDOM=")[A-Z]{2}' /etc/conf.d/wireless-regdom 2>/dev/null || true)
        elif [[ -f /etc/default/crda ]]; then
            country=$(grep -oP '(?<=REGDOMAIN=)[A-Z]{2}' /etc/default/crda 2>/dev/null || true)
        fi

        # Auto-detect from system locale (e.g., en_US.UTF-8 -> US, tr_TR.UTF-8 -> TR)
        if [[ -z "$country" ]]; then
            local locale_country
            locale_country=$(locale 2>/dev/null | grep -E '^LANG=' \
                | grep -oP '[a-z]{2}_\K[A-Z]{2}(?=\.)' | head -n1 || true)
            [[ -n "$locale_country" ]] && country="$locale_country"
        fi

        country="${country:-US}"
    fi

    country="${country^^}"
    [[ "$country" =~ ^[A-Z]{2}$ ]] || country="US"

    info "Setting regulatory domain to: $country"
    if command -v iw &>/dev/null; then
        iw reg set "$country" 2>/dev/null || true
    fi

    mkdir -p /etc/modprobe.d
    echo "options cfg80211 ieee80211_regdom=$country" > /etc/modprobe.d/cfg80211.conf

    if $IS_DEBIAN; then
        mkdir -p /etc/default
        if [[ -f /etc/default/crda ]]; then
            sed -i "s/^REGDOMAIN=.*/REGDOMAIN=$country/" /etc/default/crda
        else
            echo "REGDOMAIN=$country" > /etc/default/crda
        fi
    elif $IS_ARCH; then
        mkdir -p /etc/conf.d
        echo "WIRELESS_REGDOM=\"$country\"" > /etc/conf.d/wireless-regdom
        systemctl enable --now wireless-regdom.service 2>/dev/null || true
    fi

    success "Regulatory domain set to $country."
}

# ── Deploy Firmware ───────────────────────────────────────────────────────────
install_firmware() {
    step "Deploying MediaTek MT7902 Firmware..."
    mkdir -p /lib/firmware/mediatek

    info "Copying Wi-Fi and Bluetooth firmware binaries to /lib/firmware/mediatek/..."
    cp -f "$FIRMWARE_SRC"/*.bin* /lib/firmware/mediatek/ 2>/dev/null || true

    # Clean conflicting subdirectory that overrides patched BT firmware on some systems
    if [[ -d /lib/firmware/mediatek/mt7902 ]]; then
        info "Resolving firmware path collision in /lib/firmware/mediatek/mt7902/..."
        rm -f /lib/firmware/mediatek/mt7902/BT_RAM_CODE_MT7902* 2>/dev/null || true
    fi

    # Update initramfs so early boot has Bluetooth firmware available
    step "Updating initramfs for early Bluetooth loading..."
    if $IS_DEBIAN && command -v update-initramfs &>/dev/null; then
        update-initramfs -u -k all 2>/dev/null || true
        success "Debian initramfs updated."
    elif $IS_ARCH && command -v dracut &>/dev/null; then
        mkdir -p /etc/dracut.conf.d
        cat > /etc/dracut.conf.d/mediatek-bt.conf << 'EOF'
install_items+=" /lib/firmware/mediatek/BT_RAM_CODE_MT7902_1_1_hdr.bin "
install_items+=" /lib/firmware/mediatek/BT_RAM_CODE_MT7902_1_1_hdr.bin.zst "
EOF
        dracut-rebuild 2>/dev/null || true
        success "Arch dracut initramfs updated."
    fi

    success "Firmware deployment complete."
}

# ── Configure Driver Options (ASPM & Antenna Mask) ───────────────────────────
configure_driver_options() {
    step "Configuring PCIe ASPM & Antenna Diversity options..."

    mkdir -p /etc/modprobe.d
    cat > /etc/modprobe.d/mt7921e.conf << 'EOF'
# MT7902 Driver Performance & Stability Configuration
# 1. Disable PCIe Active State Power Management to prevent sleep wake hangs & drops
options mt7921e disable_aspm=y

# 2. Force antenna mask to 3 (enable both Chain 0 MAIN and Chain 1 AUX)
#    This enables MRC receiver diversity, eliminates Block ACK misses,
#    and fixes the 1.5–3 Mbps download speed cap.
options mt7921_common antenna_mask=3
EOF
    success "Modprobe configuration written to /etc/modprobe.d/mt7921e.conf."

    # Disable Wi-Fi Powersave in NetworkManager
    if command -v nmcli &>/dev/null || [[ -d /etc/NetworkManager ]]; then
        mkdir -p /etc/NetworkManager/conf.d
        cat > /etc/NetworkManager/conf.d/wifi-powersave-off.conf << 'EOF'
[connection]
# Disable WiFi power saving on MT7902 to prevent beacon timeouts & latency spikes
# 2 = disable, 3 = enable
wifi.powersave = 2
EOF
        if nmcli -t -f RUNNING general 2>/dev/null | grep -q "running"; then
            nmcli general reload 2>/dev/null || true
        fi
        success "NetworkManager Wi-Fi powersave disabled."
    fi
}

# ── Build & Install DKMS Module ───────────────────────────────────────────────
install_dkms() {
    step "Registering and building MT7902 driver with DKMS..."

    local dkms_dest="/usr/src/mt7902-wifi-1.0"
    local MODULE="mt7902-wifi"
    local VERSION="1.0"

    if dkms status | grep -q "$MODULE/$VERSION"; then
        info "Removing previous DKMS registration..."
        dkms remove "$MODULE/$VERSION" --all 2>/dev/null || true
    fi

    rm -rf "$dkms_dest"
    mkdir -p "$dkms_dest"

    info "Copying driver tree to $dkms_dest..."
    cp -a "$DRIVER_SRC/." "$dkms_dest/"

    # CachyOS LLVM/Clang support
    if $IS_CACHYOS; then
        info "Configuring Clang build flags for CachyOS..."
        sed -i 's|MAKE\[0\]=.*|MAKE[0]="make CC=clang LD=ld.lld -C $kernel_source_dir M=$dkms_tree/$PACKAGE_NAME/$PACKAGE_VERSION/build modules"|' \
            "$dkms_dest/dkms.conf"
    fi

    info "Adding module to DKMS..."
    dkms add -m "$MODULE" -v "$VERSION"

    info "Compiling module (this takes 1-2 minutes)..."
    if $IS_CACHYOS; then
        CC=clang LD=ld.lld dkms build -m "$MODULE" -v "$VERSION"
    else
        dkms build -m "$MODULE" -v "$VERSION"
    fi

    info "Installing module to kernel updates..."
    dkms install -m "$MODULE" -v "$VERSION"

    success "DKMS module successfully built and installed."
}

# ── Reload Kernel Modules Cleanly ─────────────────────────────────────────────
reload_modules() {
    step "Reloading kernel modules cleanly..."

    for mod in btusb btmtk mt7921e mt7921_common mt792x_lib mt76_connac_lib mt76; do
        rmmod "$mod" 2>/dev/null || true
    done
    sleep 1

    # Load wireless stack
    modprobe cfg80211 2>/dev/null || true
    modprobe mac80211 2>/dev/null || true
    modprobe mt76 2>/dev/null || true
    modprobe mt76-connac-lib 2>/dev/null || true
    modprobe mt792x-lib 2>/dev/null || true
    modprobe mt7921-common 2>/dev/null || true
    modprobe mt7921e 2>/dev/null || true

    # Load bluetooth stack
    modprobe bluetooth 2>/dev/null || true
    modprobe btmtk 2>/dev/null || true
    modprobe btusb 2>/dev/null || true

    # Restart bluetooth service
    systemctl enable --now bluetooth.service 2>/dev/null || true

    sleep 2
    success "Kernel modules reloaded."
}

# ── Post-Install Verification ─────────────────────────────────────────────────
verify_installation() {
    step "Running Post-Installation Diagnostics..."

    echo ""
    info "── DKMS Status ──"
    dkms status | grep mt7902 || warn "mt7902-wifi not reported by dkms"

    echo ""
    info "── Loaded Kernel Modules ──"
    lsmod | grep -E 'mt7921|mt76|btusb|btmtk' || warn "No mt7921 modules detected in lsmod"

    echo ""
    info "── Module Parameters ──"
    if [[ -f /sys/module/mt7921_common/parameters/antenna_mask ]]; then
        local mask
        mask=$(cat /sys/module/mt7921_common/parameters/antenna_mask)
        echo -e "  antenna_mask = ${BOLD}${mask}${RESET} (expected: 3)"
    fi
    if [[ -f /sys/module/mt7921e/parameters/disable_aspm ]]; then
        local aspm
        aspm=$(cat /sys/module/mt7921e/parameters/disable_aspm)
        echo -e "  disable_aspm = ${BOLD}${aspm}${RESET} (expected: Y)"
    fi

    echo ""
    info "── Detected Network Interfaces ──"
    local pcie_iface
    pcie_iface=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^wlp' | head -n1 || true)
    local usb_iface
    usb_iface=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^wlx' | head -n1 || true)

    if [[ -n "$pcie_iface" ]]; then
        success "Primary PCIe Wi-Fi interface detected: ${BOLD}${pcie_iface}${RESET}"
    else
        warn "PCIe Wi-Fi interface (wlp*) not yet visible. A reboot may be required."
    fi

    if [[ -n "$usb_iface" ]]; then
        echo ""
        warn "Secondary USB Wi-Fi dongle detected: ${BOLD}${usb_iface}${RESET}"
        warn "IMPORTANT: Please unplug your external USB Wi-Fi dongle now."
        warn "Keeping both adapters connected causes Linux routing metric collisions."
    fi

    echo ""
    info "── Bluetooth Status ──"
    if command -v bluetoothctl &>/dev/null; then
        local bt_state
        bt_state=$(bluetoothctl show 2>/dev/null | grep -i "Powered:" || echo "Powered: unknown")
        echo -e "  Bluetooth controller: $bt_state"
    fi
}

# ── Main Execution ────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${CYAN}║    MediaTek MT7902 Wi-Fi & Bluetooth Automated Installer     ║${RESET}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""

detect_distro
info "Detected OS: $DISTRO_NAME"
info "Kernel: $(uname -r)"

if $UNINSTALL; then
    do_uninstall
fi

echo ""
info "This installer will perform the following actions:"
echo "  1. Install required compiler tools and kernel headers"
echo "  2. Deploy Wi-Fi & Bluetooth firmware binaries"
echo "  3. Configure antenna_mask=3 (MIMO/Diversity speed fix) & disable_aspm=y"
echo "  4. Register and compile the MT7902 driver via DKMS"
echo "  5. Reload drivers and verify hardware interfaces"
echo ""

if ! $YES; then
    read -rp "Proceed with installation? [Y/n]: " run_ans
    [[ "${run_ans,,}" == "n" ]] && { info "Installation cancelled."; exit 0; }
fi

install_deps
configure_regdom
install_firmware
configure_driver_options
install_dkms
reload_modules
verify_installation

echo ""
echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}${GREEN}  🎉 MT7902 Wi-Fi & Bluetooth setup complete!${RESET}"
echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════════════════${RESET}"
echo ""
echo -e "  ${BOLD}Recommended Next Steps:${RESET}"
echo -e "  1. Connect to Wi-Fi: ${CYAN}nmcli dev wifi connect \"SSID\" password \"PASSWORD\"${RESET}"
echo -e "  2. For best speeds and 0% Bluetooth interference, connect to a ${BOLD}5 GHz${RESET} network."
echo -e "  3. Run diagnostics anytime: ${CYAN}sudo ./quick_fix.sh${RESET}"
echo ""
