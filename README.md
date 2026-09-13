# MediaTek MT7902 (Filogic 310) Linux Driver & Connection Guide

> Complete fix guide, root cause analysis, and step-by-step procedures for getting both Wi-Fi (2.4 GHz & 5 GHz) and Bluetooth fully operational on Linux kernels 6.12–7.0+.

---

## 🔍 Check Your Hardware First (MediaTek vs. Realtek)

Budget laptops such as the **ASUS Vivobook Go 14 (E1404FA / E1404FA_E1404FA)** and Vivobook Go 15 are manufactured with different Wi-Fi cards depending on regional batch:
* **MediaTek MT7902** (PCI ID: `14c3:7902`, combo with AzureWave/Filogic 310) 👉 **This guide and fix are 100% for this card!**
* **Realtek RTL8852BE** (PCI ID: `10ec:b852`) 👉 Uses the in-kernel `rtw89` driver, not this guide.

Run this command in your terminal to identify your card:
```bash
lspci -nnk | grep -iA3 -E 'net|wireless'
```

If the output contains `[14c3:7902]`, you have the **MediaTek MT7902** and this guide will resolve your connection issues.

> [!IMPORTANT]
> **Secure Boot Notice for ASUS Vivobook Laptops**:
> ASUS Vivobook laptops have UEFI Secure Boot enabled by default. Secure Boot blocks unsigned third-party DKMS kernel modules from loading (`Required key not available`).
> Before proceeding:
> 1. Reboot and press `F2` (or `Del`) to enter BIOS/UEFI settings.
> 2. Go to **Security** or **Boot** > **Secure Boot**.
> 3. Set **Secure Boot** to **Disabled**, press `F10` to save and reboot.
> *(Alternatively, if you must keep Secure Boot enabled, you will need to sign the compiled DKMS module using MOK).*

---

## 💻 Hardware Overview

* **Chipset**: MediaTek MT7902 802.11ax PCIe Wireless Adapter (Filogic 310)
* **PCI ID**: `14c3:7902`
* **Subsystem**: AzureWave Device (`1a3b:5520` or `1a3b:5524`)
* **Bluetooth (USB)**: `13d3:3579` or `0489:e0e2` (IMC Networks / MediaTek combo)
* **Common Laptops**: ASUS Vivobook Go (E1404FA, F1504ZA, X1505VA, X1605VA, K6602VV), Acer Extensa 15, HP & Lenovo budget models.

---

## ⚠️ The Issues & Root Cause Analysis

If you installed an out-of-tree MT7902 driver and encountered `authentication timed out`, `Connection failed`, random disconnections, or an infinite `Connecting...` status loop, here is the technical breakdown:

### 1. Hardcoded 2x2 MIMO on 1T1R Hardware
* **The Bug**: Many community driver repos hardcode `dev->phy.antenna_mask = 3` and `dev->phy.chainmask = 3` in `mt7921/mcu.c`.
* **The Cause**: The MT7902 is physically a **1T1R (1 transmit, 1 receive stream)** hardware design. Forcing mask `3` commands the firmware to initialize 2 spatial streams and advertise 2x2 MIMO to the router. The router attempts multi-stream handshakes which the hardware cannot complete.
* **The Fix**: Align `antenna_mask` to the firmware's reported spatial streams (`BIT(cap->nss) - 1`, which evaluates to `1`).

### 2. Bluetooth & 2.4 GHz PTA Coexistence Contention
* **The Bug**: 2.4 GHz Wi-Fi repeatedly fails authentication (`send auth (try 1/3, 2/3, 3/3)` → `timed out`), while 5 GHz connects instantly.
* **The Cause**: On single-antenna laptops, Bluetooth (2.402–2.480 GHz) and 2.4 GHz Wi-Fi share the same physical radio path. The internal Packet Traffic Arbitration (PTA) gives Bluetooth inquiry/scanning priority, starving Wi-Fi 2.4 GHz management frames.
* **The Solution**:
  * **Best option**: Connect to the **5 GHz band** of your router (e.g. `YourNetwork_5G`). 5 GHz operates entirely free from Bluetooth interference at 300–1200 Mbps.
  * If you must use 2.4 GHz: Power off Bluetooth (`bluetoothctl power off`) before authenticating.

### 3. "Connected for a Few Minutes, Then Disconnected & Stuck in Connecting Status" Loop
* **The Bug**: Wi-Fi connects fine, works for 2–5 minutes, then suddenly drops. When trying to reconnect, NetworkManager stays stuck in `Connecting...` status indefinitely.
* **The Causes**:
  1. **Bluetooth Mouse / Peripheral Contention**: If a Bluetooth mouse (`uhid`/`hidraw`) or audio headset is active, it continuously polls and streams over 2.4 GHz. If Wi-Fi tries to roam, re-key (WPA group re-keying), or switch to a 2.4 GHz network, the Wi-Fi authentication packets get dropped by the PTA arbiter, resulting in an infinite auth retry loop.
  2. **Dual-Band SSID Roaming**: If your router broadcasts both 2.4 GHz and 5 GHz bands (or both are saved in NetworkManager), NetworkManager may attempt to roam or connect to the 2.4 GHz band, where it hangs due to Bluetooth collision.
  3. **Secondary USB Wi-Fi Adapter Conflicts**: If a temporary USB Wi-Fi dongle (e.g. MT7601U) was used during driver setup and remains plugged in, both adapters fight for default routes and connection profiles.
* **The Solution**:
  * Lock your connection to the 5 GHz band (`connection.interface-name "wlp2s0"`, `connection.autoconnect-priority 100`).
  * Disable auto-connect on the 2.4 GHz profile (`nmcli connection modify "<SSID_2.4G>" connection.autoconnect no`).
  * Unplug the secondary USB Wi-Fi dongle once the MT7902 driver is active.

### 4. PCIe ASPM (Active State Power Management) L1 Wake Hangs
* **The Bug**: High ping jitter (500ms–1500ms+), sudden drops, or association timeouts.
* **The Cause**: The laptop PCIe bus puts the MT7902 into low-power L1 sleep states that fail to wake in time for 802.11 beacons.
* **The Fix**: Disable ASPM specifically for the `mt7921e` module via `/etc/modprobe.d/mt7921e.conf`.

### 5. Aggressive Background Roaming Scans (`bgscan`)
* **The Bug**: Periodic latency spikes every 30 seconds when signal is around -70 dBm.
* **The Cause**: NetworkManager instructs `wpa_supplicant` to use `bgscan=simple:30:-70:86400`. Background scans freeze traffic on 1T1R hardware.
* **The Fix**: Disable background scanning in NetworkManager configuration.

### 6. Broken NetworkManager Profiles (Missing `key-mgmt`)
* **The Bug**: `Error: 802-11-wireless-security.key-mgmt: property is missing` or recurring WPS PIN loops.
* **The Cause**: Interrupted connection attempts leave corrupted connection profiles in NetworkManager.
* **The Fix**: Cleanly remove stale profiles and store the WPA-PSK directly in the profile.

---

## 🛠️ Step-by-Step Installation & Fix Procedure

### Step 1: Install Build Dependencies & DKMS
Ensure your kernel headers and compilation tools are installed:

```bash
# Debian / Ubuntu / Linux Mint / Pop!_OS
sudo apt update
sudo apt install -y build-essential dkms git linux-headers-$(uname -r)

# Arch / EndeavourOS / CachyOS / Manjaro
sudo pacman -S --needed base-devel dkms git linux-headers

# Fedora / RHEL
sudo dnf install -y kernel-devel-$(uname -r) kernel-headers-$(uname -r) dkms git gcc make

# openSUSE Tumbleweed / Leap
sudo zypper install -y kernel-devel dkms git gcc make
```

---

### Step 2: Clone the Driver Source Code

Clone the community MT7902 driver source into your DKMS directory. You can use any of the active community repositories:

```bash
# Option 1: OnlineLearningTutorials / mt7902_temp (Most popular community repo)
sudo git clone https://github.com/OnlineLearningTutorials/mt7902_temp.git /usr/src/mt7902-wifi-1.0

# Option 2: samveen / mt7902-dkms
sudo git clone https://github.com/samveen/mt7902-dkms.git /usr/src/mt7902-wifi-1.0

# Option 3: hmtheboy154 / gen4-mt7902
sudo git clone https://github.com/hmtheboy154/gen4-mt7902.git /usr/src/mt7902-wifi-1.0
```

*(If you already have a community driver downloaded or in another folder, ensure it is copied or placed in `/usr/src/mt7902-wifi-1.0` or adjust the DKMS path accordingly).*

---

### Step 3: Fix Driver Antenna Configuration (mcu.c)

The driver requires aligning the antenna mask to 1T1R hardware instead of hardcoded 2x2 MIMO.

#### Option A: Quick Automated Patch (Recommended)
Run this one-line command to patch `mcu.c` automatically:
```bash
sudo sed -i 's/dev->phy.antenna_mask = 3;/dev->phy.antenna_mask = BIT(cap->nss) - 1;/' /usr/src/mt7902-wifi-1.0/mt7921/mcu.c
```

#### Option B: Manual Edit
If you prefer editing manually, open `/usr/src/mt7902-wifi-1.0/mt7921/mcu.c` and locate `mt7921_mcu_parse_phy_cap`:

```c
// Replace any hardcoded "antenna_mask = 3" with canonical 1T1R handling:
if (mt7921_antenna_mask > 0 && mt7921_antenna_mask <= 3) {
    dev->phy.antenna_mask = mt7921_antenna_mask;
} else {
    dev->phy.antenna_mask = BIT(cap->nss) - 1; // Evaluates to 1 for MT7902
}
dev->phy.chainmask = dev->phy.antenna_mask;
dev->phy.cap.has_2ghz = cap->hw_path & BIT(WF0_24G);
dev->phy.cap.has_5ghz = cap->hw_path & BIT(WF0_5G);
```

Ensure the module parameter is declared in `mt7921/mcu.c` (or `mt7921/init.c`):
```c
static int mt7921_antenna_mask;
module_param_named(antenna_mask, mt7921_antenna_mask, int, 0644);
MODULE_PARM_DESC(antenna_mask, "override antenna mask (0=default from firmware NSS, 1=chain 0 MAIN, 2=chain 1 AUX, 3=both chains)");
```

---

### Step 4: Rebuild and Install DKMS Module

```bash
sudo dkms build -m mt7902-wifi -v 1.0 --force
sudo dkms install -m mt7902-wifi -v 1.0 --force
```

Verify DKMS shows `installed`:
```bash
dkms status
```

---

### Step 5: Configure PCIe ASPM & Powersave Fixes

1. **Disable PCIe ASPM for MT7921**:
```bash
echo "options mt7921e disable_aspm=y" | sudo tee /etc/modprobe.d/mt7921e.conf
```

2. **Disable Wi-Fi Powersave in NetworkManager**:
```bash
sudo mkdir -p /etc/NetworkManager/conf.d
sudo tee /etc/NetworkManager/conf.d/wifi-powersave-off.conf << 'EOF'
[connection]
wifi.powersave = 2
EOF
```

3. **Reload NetworkManager configuration**:
```bash
sudo nmcli general reload
```

---

### Step 6: Reload Driver Modules Cleanly

```bash
sudo rmmod mt7921e 2>/dev/null || true
sudo rmmod mt7921_common 2>/dev/null || true
sudo modprobe mt7921_common
sudo modprobe mt7921e
```

Verify the wireless interface was created and note its name (`wlp2s0`, `wlp1s0`, `wlan0`, etc.):
```bash
ip link show | grep -E 'wl(p|s|o|an)'
```

---

### Step 7: Connect and Prioritize 5 GHz (Crucial to Prevent Drops)

> [!TIP]
> Identify your interface name first (e.g. `wlp2s0`, `wlp1s0`, or `wlan0`) by running `ip link`. In the examples below, replace `wlp2s0` with your actual interface name.

#### Option A: Connect to a 5 GHz SSID (Recommended)
5 GHz operates at 300–1200 Mbps and **completely eliminates Bluetooth mouse/headset interference**:
```bash
# Connect to your 5 GHz SSID
nmcli dev wifi connect "YourNetwork_5G" password "YourPassword" ifname wlp2s0

# Prioritize 5 GHz so NetworkManager never downgrades to 2.4 GHz
nmcli connection modify "YourNetwork_5G" connection.interface-name "wlp2s0" connection.autoconnect yes connection.autoconnect-priority 100

# Disable auto-connect on the 2.4 GHz profile of your router
nmcli connection modify "YourNetwork" connection.autoconnect no 2>/dev/null || true
```

#### Option B: Routers with Unified SSID (Same Name for 2.4 GHz & 5 GHz)
If your router uses Band Steering / Mesh with a single Wi-Fi name for both bands, force NetworkManager to connect **only** to the 5 GHz band:
```bash
nmcli connection modify "YourUnifiedNetwork" 802-11-wireless.band a
```
*(`band a` locks the profile to 5 GHz 802.11a/n/ac/ax, preventing unexpected 2.4 GHz downgrades).*

#### Option C: Connect to a 2.4 GHz-Only Network (Hotspot)
If you must connect to a 2.4 GHz network while using Bluetooth devices:
1. Temporarily turn off Bluetooth before connecting:
```bash
bluetoothctl power off
```
2. Connect to the network:
```bash
nmcli dev wifi connect "YourNetwork" password "YourPassword" ifname wlp2s0
```
3. Once connected and an IP address is assigned, turn Bluetooth back on:
```bash
bluetoothctl power on
```

#### Option D: Unplug Secondary USB Wi-Fi Dongles
If you used an external USB Wi-Fi adapter (e.g. `MT7601U` or `RTL8188`) while downloading packages, **unplug it now**. Having two active Wi-Fi adapters causes routing metric collisions (`metric 601 vs 602`) and makes NetworkManager route traffic through the slower adapter.

---

## ⚡ Automated Quick Fix Script

You can run the included `quick_fix.sh` script to apply all ASPM, powersave, interface detection, profile prioritization, and live link diagnostics automatically:

```bash
chmod +x quick_fix.sh
sudo ./quick_fix.sh
```

---

## 📊 Verification & Diagnostics Checklist

| Check | Command | Expected Output |
| :--- | :--- | :--- |
| **DKMS Module** | `dkms status` | `mt7902-wifi/1.0: installed` |
| **Driver Loaded** | `lsmod \| grep mt7921e` | `mt7921e`, `mt7921_common`, `mt76` present |
| **Interface Status**| `nmcli dev status` | `<interface> wifi connected <SSID>` |
| **Band Frequency** | `iw dev <interface> link \| grep freq` | `freq: 5xxx.0` (5 GHz recommended) |
| **Link Rates** | `iw dev <interface> link` | `tx bitrate: 140+ MBit/s` (HE/VHT, NSS 1) |
| **Ping Health** | `ping -c 5 1.1.1.1` | `0% packet loss` |

---

## 📌 Kernel 7.1+ Notice
Support for `14c3:7902` is merged upstream into mainline Linux **Kernel 7.1+**. Once distributions upgrade their standard kernel series to 7.1+, out-of-tree DKMS drivers will no longer be necessary.

---

## 🤝 Credits & Acknowledgments

This guide, patch, and diagnostic tooling build upon the collective troubleshooting and development efforts of the open-source Linux community:

* **[OnlineLearningTutorials/mt7902_temp](https://github.com/OnlineLearningTutorials/mt7902_temp)**: For maintaining the primary community MT7902 Linux driver development repository.
* **[hmtheboy154/gen4-mt7902](https://github.com/hmtheboy154/gen4-mt7902)** & **[samveen/mt7902-dkms](https://github.com/samveen/mt7902-dkms)**: For community DKMS packaging and driver build scripts.
* **[morrownr/mt76](https://github.com/morrownr/mt76)**: Nick Morrow for providing out-of-tree Linux driver support and documentation for MediaTek wireless chips.
* **Linux Wireless & `mt76` Maintainers**: Felix Fietkau, Lorenzo Bianconi, and the MediaTek kernel team for maintaining the upstream `mt76` / `mt7921` subsystem.
* **ASUS & Arch Linux Communities**: Enthusiasts across the ASUS Linux forums, Arch BBS, and Reddit (`r/linux4noobs`, `r/asus`) who documented hardware quirks, PTA coexistence clashes, and PCIe ASPM L1 sleep bugs on the ASUS Vivobook Go series.

---

## 📄 Disclaimer

This guide and scripts are community-maintained resources provided "as-is" to assist fellow laptop owners until mainline Linux support is universally deployed in stable distribution releases. Modifications to kernel module parameters and system configs are applied locally under user control.

