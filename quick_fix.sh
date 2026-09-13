#!/usr/bin/env bash
# ============================================================
#  MediaTek MT7902 Quick Diagnostics & Network Optimizer
#  Targeted for: ASUS Vivobook Go E1404FA & MT7902 laptops
#  Credits: Community MT7902 DKMS contributors & mt76 maintainers
# ============================================================
set -euo pipefail

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}${BOLD}     MediaTek MT7902 Optimizer & Diagnostics Tool           ${NC}"
echo -e "${CYAN}============================================================${NC}"

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Please run this script with sudo: sudo bash $0${NC}"
   exit 1
fi

# 1. PCIe ASPM Fix
echo -e "\n${CYAN}[1/6] Configuring PCIe ASPM settings...${NC}"
mkdir -p /etc/modprobe.d
echo "options mt7921e disable_aspm=y" > /etc/modprobe.d/mt7921e.conf
echo -e "${GREEN}✓ PCIe ASPM disabled for mt7921e in /etc/modprobe.d/mt7921e.conf${NC}"

# 2. Wi-Fi Powersave Fix
echo -e "\n${CYAN}[2/6] Disabling NetworkManager Wi-Fi powersave...${NC}"
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/wifi-powersave-off.conf << 'EOF'
[connection]
wifi.powersave = 2
EOF
echo -e "${GREEN}✓ Powersave disabled in /etc/NetworkManager/conf.d/wifi-powersave-off.conf${NC}"

# 3. Detect Wireless Interfaces & Driver State
echo -e "\n${CYAN}[3/6] Inspecting Wireless Interfaces & Driver State...${NC}"

# Check if kernel module is loaded
if ! lsmod 2>/dev/null | grep -qE '^mt7921e '; then
    echo -e "${YELLOW}ℹ mt7921e driver module is not loaded yet. Attempting to load...${NC}"
    modprobe mt7921e 2>/dev/null || true
fi

PCIE_IFACE=""
USB_IFACE=""

# Method A: Search through sysfs for interface bound to mt7921e or PCI wireless
for dev in /sys/class/net/*; do
    [[ ! -d "$dev" ]] && continue
    iface_name=$(basename "$dev")
    [[ "$iface_name" == "lo" ]] && continue
    
    # Must be a wireless device (has /wireless or /phy80211)
    if [[ -d "$dev/wireless" || -d "$dev/phy80211" ]]; then
        driver=""
        if [[ -e "$dev/device/driver" ]]; then
            driver=$(basename "$(readlink -f "$dev/device/driver" 2>/dev/null || true)")
        fi
        device_path=$(readlink -f "$dev/device" 2>/dev/null || true)
        
        # Check if driver is mt7921e/mt7921 or device is on PCIe bus
        if [[ "$driver" =~ mt7921|mt7902 ]] || [[ "$device_path" =~ /pci ]]; then
            if [[ -z "$PCIE_IFACE" ]]; then
                PCIE_IFACE="$iface_name"
            fi
        elif [[ "$device_path" =~ /usb ]] || [[ "$driver" =~ mt7601|rtl|rtw ]]; then
            if [[ -z "$USB_IFACE" ]]; then
                USB_IFACE="$iface_name"
            fi
        fi
    fi
done

# Method B Fallback: Predictable interface names via ip link
if [[ -z "$PCIE_IFACE" ]]; then
    PCIE_IFACE=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^wl(p|s|o)' | head -n1 || true)
fi
if [[ -z "$PCIE_IFACE" ]]; then
    # Fallback to wlan* if it's the only wireless interface
    PCIE_IFACE=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^wlan[0-9]' | head -n1 || true)
fi
if [[ -z "$USB_IFACE" ]]; then
    USB_IFACE=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^wlx' | head -n1 || true)
fi

if [[ -n "$PCIE_IFACE" ]]; then
    echo -e "${GREEN}✓ Found primary MT7902 wireless interface: ${BOLD}${PCIE_IFACE}${NC}"
else
    echo -e "${YELLOW}! No MT7902 wireless interface found.${NC}"
    echo -e "  If you haven't built the DKMS module yet, follow Step 1-4 in README.md."
    echo -e "  If already built, try: ${BOLD}sudo modprobe mt7921e${NC}"
fi

if [[ -n "$USB_IFACE" ]]; then
    echo -e "${YELLOW}⚠️  Detected secondary USB Wi-Fi dongle: ${BOLD}${USB_IFACE}${NC}"
    echo -e "   If you no longer need the USB dongle, please unplug it to avoid routing metric conflicts."
fi

# 4. Bluetooth Coexistence Check
echo -e "\n${CYAN}[4/6] Checking Bluetooth & 2.4 GHz Coexistence...${NC}"
if command -v bluetoothctl &>/dev/null; then
    BT_POWERED=$(bluetoothctl show 2>/dev/null | grep -i "Powered: yes" || true)
    if [[ -n "$BT_POWERED" ]]; then
        echo -e "${YELLOW}ℹ Bluetooth is currently ON.${NC}"
        echo -e "  Reminder: MT7902 uses a single antenna shared between 2.4 GHz Wi-Fi and Bluetooth."
        echo -e "  If connecting to a 2.4 GHz network while using a Bluetooth mouse/headset,"
        echo -e "  temporarily toggle Bluetooth off during connection: ${BOLD}bluetoothctl power off${NC}"
    else
        echo -e "${GREEN}✓ Bluetooth is OFF (No 2.4 GHz radio contention).${NC}"
    fi
else
    echo -e "  bluetoothctl not found, skipping Bluetooth status check."
fi

# 5. Prioritize 5 GHz Networks in NetworkManager
echo -e "\n${CYAN}[5/6] Optimizing NetworkManager Profiles...${NC}"
if command -v nmcli &>/dev/null && [[ -n "$PCIE_IFACE" ]]; then
    # Look for connections explicitly named with 5G / 5GHz
    CONNS_5G=$(nmcli -t -f NAME,TYPE connection show 2>/dev/null | grep ':802-11-wireless$' | sed 's/:802-11-wireless$//' | grep -iE '(_5G|-5G| 5G|_5GHz|-5GHz| 5GHz)' || true)
    
    if [[ -n "$CONNS_5G" ]]; then
        while IFS= read -r conn; do
            [[ -z "$conn" ]] && continue
            echo -e "  Prioritizing 5 GHz connection profile: ${BOLD}${conn}${NC}"
            nmcli connection modify "$conn" connection.interface-name "$PCIE_IFACE" connection.autoconnect yes connection.autoconnect-priority 100 2>/dev/null || true
            echo -e "  ${GREEN}✓ Set autoconnect-priority=100 and bound to ${PCIE_IFACE}${NC}"
        done <<< "$CONNS_5G"
    else
        echo -e "  No profiles with explicit '5G' naming detected."
        echo -e "  ${YELLOW}Tip:${NC} If your router uses a single unified SSID for 2.4GHz and 5GHz, you can"
        echo -e "       force NetworkManager to stick to 5 GHz using:"
        echo -e "       ${BOLD}nmcli connection modify \"<SSID>\" 802-11-wireless.band a${NC}"
    fi
    nmcli general reload 2>/dev/null || true
    echo -e "${GREEN}✓ NetworkManager configuration reloaded.${NC}"
else
    echo -e "  NetworkManager (nmcli) or PCIe interface not available, skipping profile tuning."
fi

# 6. Live Status & Diagnostics
echo -e "\n${CYAN}[6/6] Real-Time Link & Connection Diagnostics...${NC}"
if [[ -n "$PCIE_IFACE" ]]; then
    LINK_OK=false
    
    if command -v iw &>/dev/null; then
        LINK_OUTPUT=$(iw dev "$PCIE_IFACE" link 2>/dev/null || true)
        if echo "$LINK_OUTPUT" | grep -q "Connected to"; then
            LINK_OK=true
            SSID=$(echo "$LINK_OUTPUT" | grep "SSID:" | awk '{$1=""; print $0}' | sed 's/^ //')
            FREQ=$(echo "$LINK_OUTPUT" | grep "freq:" | awk '{print $2}')
            SIG=$(echo "$LINK_OUTPUT" | grep "signal:" | awk '{$1=$1};1')
            TX=$(echo "$LINK_OUTPUT" | grep "tx bitrate:" | awk '{$1=$1};1')
            
            echo -e "${GREEN}✓ ${PCIE_IFACE} is CONNECTED to: ${BOLD}${SSID}${NC}"
            echo -e "  Frequency : ${FREQ} MHz"
            echo -e "  Signal    : ${SIG}"
            echo -e "  Bitrate   : ${TX}"
        fi
    fi
    
    if [[ "$LINK_OK" = false ]] && command -v nmcli &>/dev/null; then
        NM_STATUS=$(nmcli -t -f DEVICE,TYPE,STATE,CONNECTION dev 2>/dev/null | grep "^${PCIE_IFACE}:wifi:connected:" || true)
        if [[ -n "$NM_STATUS" ]]; then
            LINK_OK=true
            SSID=$(echo "$NM_STATUS" | cut -d':' -f4)
            echo -e "${GREEN}✓ ${PCIE_IFACE} is CONNECTED via NetworkManager to: ${BOLD}${SSID}${NC}"
        fi
    fi
    
    if [[ "$LINK_OK" = true ]]; then
        echo -e "\n  Testing internet latency via ${PCIE_IFACE}..."
        ping -c 3 -W 2 1.1.1.1 2>/dev/null || ping -c 3 -W 2 8.8.8.8 2>/dev/null || true
    else
        echo -e "${YELLOW}! ${PCIE_IFACE} is currently disconnected.${NC}"
        echo -e "  Connect via: nmcli dev wifi connect <SSID> password <PASSWORD> ifname ${PCIE_IFACE}"
    fi
else
    echo -e "${YELLOW}! No interface detected to run link diagnostics.${NC}"
fi

echo -e "\n${GREEN}============================================================${NC}"
echo -e "${GREEN}${BOLD}                  Optimization Complete!                   ${NC}"
echo -e "${GREEN}============================================================${NC}\n"
