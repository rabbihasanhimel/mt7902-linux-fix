#!/usr/bin/env bash
# ==============================================================================
#  MediaTek MT7902 Quick Diagnostics, Optimizer & Speed Fix Tool
# ==============================================================================
#  Use this tool to:
#   1. Apply the 1.5–3 Mbps speed fix (enables antenna diversity / antenna_mask=3)
#   2. Disable PCIe ASPM sleep hangs & disconnects (disable_aspm=y)
#   3. Disable Wi-Fi power saving in NetworkManager (wifi.powersave = 2)
#   4. Detect secondary USB Wi-Fi dongles and prevent ARP / routing conflicts
#   5. Check Bluetooth & 2.4 GHz radio contention
#   6. Optimize NetworkManager connection profiles
#   7. Benchmark live link rates (TX/RX bitrate) and real-world download speed
# ==============================================================================

set -euo pipefail

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
RESET='\033[0m'

TARGET_ANTENNA_MASK=3

# ── Parse Arguments ───────────────────────────────────────────────────────────
for arg in "$@"; do
    case "$arg" in
        --antenna=*) TARGET_ANTENNA_MASK="${arg#--antenna=}" ;;
        --antenna)   shift; TARGET_ANTENNA_MASK="${1:-3}" ;;
        -h|--help)
            echo "Usage: sudo bash $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --antenna <1|2|3>  Set specific antenna mask:"
            echo "                       1 = Chain 0 (MAIN only)"
            echo "                       2 = Chain 1 (AUX only)"
            echo "                       3 = Both chains (MIMO & MRC Diversity - Default & Recommended)"
            echo "  -h, --help         Show this help message"
            exit 0
            ;;
    esac
done

echo -e "${CYAN}============================================================${RESET}"
echo -e "${CYAN}${BOLD}       MediaTek MT7902 Optimizer & Diagnostics Tool         ${RESET}"
echo -e "${CYAN}============================================================${RESET}"

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Please run this script with sudo: sudo bash $0${RESET}"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 0. Check if MT7902 driver is installed
if ! lsmod | grep -q mt7921 && ! command -v dkms &>/dev/null; then
    echo -e "\n${YELLOW}⚠️  Driver does not appear to be loaded.${RESET}"
    if [[ -f "$SCRIPT_DIR/install.sh" ]]; then
        echo -e "   Run the full installer first: ${BOLD}sudo bash $SCRIPT_DIR/install.sh${RESET}\n"
    fi
fi

# 1. PCIe ASPM & Antenna Diversity Fix
echo -e "\n${CYAN}[1/6] Configuring PCIe ASPM and Antenna Mask (Speed & Stability Fix)...${RESET}"
mkdir -p /etc/modprobe.d

cat > /etc/modprobe.d/mt7921e.conf << EOF
# MT7902 Driver Performance & Stability Configuration
options mt7921e disable_aspm=y
options mt7921_common antenna_mask=${TARGET_ANTENNA_MASK}
EOF

echo -e "${GREEN}✓ Set disable_aspm=y (PCIe wake sleep fix)${RESET}"
echo -e "${GREEN}✓ Set antenna_mask=${TARGET_ANTENNA_MASK} (Receiver diversity & speed fix) in /etc/modprobe.d/mt7921e.conf${RESET}"

# Reload module if loaded to apply settings immediately
if lsmod | grep -q mt7921e; then
    echo -e "  Applying driver settings cleanly without reboot..."
    rmmod mt7921e 2>/dev/null || true
    rmmod mt7921_common 2>/dev/null || true
    modprobe mt7921_common
    modprobe mt7921e
    sleep 2
    echo -e "${GREEN}✓ mt7921 kernel modules reloaded successfully.${RESET}"
fi

# 2. Wi-Fi Powersave Fix
echo -e "\n${CYAN}[2/6] Disabling NetworkManager Wi-Fi powersave...${RESET}"
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/wifi-powersave-off.conf << 'EOF'
[connection]
# Disable WiFi powersave to eliminate beacon dropouts and latency spikes
wifi.powersave = 2
EOF
echo -e "${GREEN}✓ Powersave disabled in /etc/NetworkManager/conf.d/wifi-powersave-off.conf${RESET}"

# 3. Detect Wireless Interfaces
echo -e "\n${CYAN}[3/6] Inspecting Wireless Interfaces...${RESET}"
PCIE_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^wlp' | head -n1 || true)
USB_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^wlx' | head -n1 || true)

if [[ -n "$PCIE_IFACE" ]]; then
    echo -e "${GREEN}✓ Found primary MT7902 PCIe interface: ${BOLD}${PCIE_IFACE}${RESET}"
else
    echo -e "${YELLOW}! No PCIe wireless interface (wlp*) found yet.${RESET}"
    echo -e "  Verify module status with: ${BOLD}sudo dmesg | grep -i mt79${RESET}"
fi

if [[ -n "$USB_IFACE" ]]; then
    echo -e "\n${YELLOW}⚠️  Detected secondary USB Wi-Fi dongle: ${BOLD}${USB_IFACE}${RESET}"
    echo -e "   ${BOLD}CRITICAL:${RESET} If you no longer need the USB dongle, please ${BOLD}unplug it${RESET}."
    echo -e "   Having both adapters active creates dual default routes and ARP conflicts,"
    echo -e "   forcing your traffic through the slower adapter."
fi

# 4. Bluetooth Coexistence Check
echo -e "\n${CYAN}[4/6] Checking Bluetooth & 2.4 GHz Coexistence...${RESET}"
if command -v bluetoothctl &>/dev/null; then
    BT_POWERED=$(bluetoothctl show 2>/dev/null | grep -i "Powered: yes" || true)
    if [[ -n "$BT_POWERED" ]]; then
        echo -e "${YELLOW}ℹ Bluetooth is currently ON.${RESET}"
        echo -e "  Reminder: MT7902 shares its radio path between 2.4 GHz Wi-Fi and Bluetooth."
        echo -e "  If connecting to 2.4 GHz networks with an active Bluetooth mouse/headset,"
        echo -e "  temporarily toggle Bluetooth off during connection:"
        echo -e "      ${BOLD}bluetoothctl power off${RESET}"
        echo -e "  (Connecting to 5 GHz networks avoids this completely)."
    else
        echo -e "${GREEN}✓ Bluetooth is OFF (No 2.4 GHz radio contention).${RESET}"
    fi
fi

# 5. NetworkManager Profile Optimization
echo -e "\n${CYAN}[5/6] Optimizing NetworkManager Profiles...${RESET}"
if command -v nmcli &>/dev/null && [[ -n "$PCIE_IFACE" ]]; then
    WIFI_CONNS=$(nmcli -t -f NAME,TYPE connection show 2>/dev/null | grep ':802-11-wireless' | awk -F':' '{print $1}' || true)

    if [[ -n "$WIFI_CONNS" ]]; then
        while IFS= read -r conn; do
            [[ -z "$conn" ]] && continue
            nmcli connection modify "$conn" connection.interface-name "$PCIE_IFACE" connection.autoconnect yes connection.autoconnect-priority 50 2>/dev/null || true
            echo -e "  ${GREEN}✓ Bound '${BOLD}${conn}${RESET}${GREEN}' to ${PCIE_IFACE} with priority 50${RESET}"
        done <<< "$WIFI_CONNS"
    fi
    nmcli general reload 2>/dev/null || true
    echo -e "${GREEN}✓ NetworkManager configuration reloaded.${RESET}"
fi

# 6. Live Status & Speed Benchmark
echo -e "\n${CYAN}[6/6] Real-Time Link & Connection Diagnostics...${RESET}"
if [[ -n "$PCIE_IFACE" ]] && command -v iw &>/dev/null; then
    LINK_OUTPUT=$(iw dev "$PCIE_IFACE" link 2>/dev/null || true)
    if echo "$LINK_OUTPUT" | grep -q "Connected to"; then
        SSID=$(echo "$LINK_OUTPUT" | grep "SSID:" | awk '{print $2}')
        FREQ=$(echo "$LINK_OUTPUT" | grep "freq:" | awk '{print $2}')
        SIG=$(echo "$LINK_OUTPUT" | grep "signal:" | awk '{$1=$1};1')
        TX=$(echo "$LINK_OUTPUT" | grep "tx bitrate:" | awk '{$1=$1};1')
        RX=$(echo "$LINK_OUTPUT" | grep "rx bitrate:" | awk '{$1=$1};1' || true)

        echo -e "${GREEN}✓ ${PCIE_IFACE} is CONNECTED to: ${BOLD}${SSID}${RESET}"
        echo -e "  Frequency : ${FREQ} MHz"
        echo -e "  Signal    : ${SIG}"
        echo -e "  TX Rate   : ${TX}"
        if [[ -n "$RX" ]]; then
            echo -e "  RX Rate   : ${RX}"
            if echo "$RX" | grep -q "6.0 MBit/s"; then
                echo -e "  ${YELLOW}⚠️  Notice: RX bitrate is at 6.0 Mbps. Verify antenna_mask=3 is active.${RESET}"
            fi
        fi

        echo -e "\n  Testing gateway latency via ${PCIE_IFACE}..."
        ping -c 3 -I "$PCIE_IFACE" -W 2 1.1.1.1 2>/dev/null || ping -c 3 -W 2 8.8.8.8 2>/dev/null || true

        echo -e "\n  Benchmarking live download throughput via ${PCIE_IFACE}..."
        SPEED=$(curl -s -w "%{speed_download}" -o /dev/null --interface "$PCIE_IFACE" --max-time 6 https://speed.cloudflare.com/__down?bytes=25000000 2>/dev/null || echo "0")
        if [[ "$SPEED" != "0" ]]; then
            MBPS=$(awk -v s="$SPEED" 'BEGIN { printf "%.2f", (s * 8) / 1000000 }')
            echo -e "  ${GREEN}${BOLD}Download Speed: ${MBPS} Mbps${RESET}"
        fi
    else
        echo -e "${YELLOW}! ${PCIE_IFACE} is currently disconnected.${RESET}"
        echo -e "  Connect with: ${BOLD}nmcli dev wifi connect <SSID> password <PASSWORD> ifname ${PCIE_IFACE}${RESET}"
    fi
fi

echo -e "\n${GREEN}============================================================${RESET}"
echo -e "${GREEN}${BOLD}                 Optimization Complete!                    ${RESET}"
echo -e "${GREEN}============================================================${RESET}\n"
