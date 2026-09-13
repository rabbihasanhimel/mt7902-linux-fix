# MediaTek MT7902 (Filogic 310) Linux Driver & Easy Fix Guide

> **All-in-one repository and automated installer for the MediaTek MT7902 Wi-Fi 6E & Bluetooth combo adapter on modern Linux kernels (6.12 to 7.0+).**  
> Includes the complete root cause analysis, the 1.5–3 Mbps speed cap fix (`antenna_mask=3`), PCIe ASPM stability fixes, Bluetooth coexistence workarounds, pre-packaged firmware, and pre-patched DKMS driver sources.

---

## 💻 Hardware Identification

* **Wireless Chipset**: MediaTek MT7902 802.11ax PCIe Wireless Network Adapter (Filogic 310)
* **PCI ID**: `14c3:7902`
* **Subsystem ID**: AzureWave Device (`1a3b:5520` or `1a3b:5524`)
* **Bluetooth Controller (USB)**: `13d3:3579` or `0489:e0e2` (IMC Networks / MediaTek combo)
* **Common Laptops**:
  * **ASUS**: Vivobook Go 14/15 (E1404FA, F1504ZA, X1505VA, X1605VA, K6602VV, Vivobook 15/16)
  * **Acer**: Extensa 15, Aspire 3 series
  * **Lenovo & HP**: Budget 2023–2025 Ryzen & Intel laptop lines

---

## ⚡ Quick Start: 1-Step Automated Fix (Recommended)

If you have a fresh Linux install or your MT7902 is not working, this repository includes everything needed (driver sources, patches, and firmware) so you don't have to search across multiple repositories:

```bash
# 1. Clone this repository (use phone USB tethering or Ethernet if offline)
git clone https://github.com/<your-username>/mt7902-fix-guide.git
cd mt7902-fix-guide

# 2. Run the universal installer
sudo bash install.sh
```

### What `install.sh` does automatically:
1. **Installs build tools & kernel headers** (`dkms`, `build-essential` / `base-devel`, `linux-headers-$(uname -r)`).
2. **Deploys Wi-Fi & Bluetooth firmwares** into `/lib/firmware/mediatek/`.
3. **Resolves Bluetooth firmware conflicts** by cleaning duplicate paths and updating `initramfs`.
4. **Applies the Antenna Diversity fix (`antenna_mask=3`)** into `/etc/modprobe.d/mt7921e.conf` — eliminating the 1.5–3 Mbps speed cap and restoring full 20–100+ Mbps throughput.
5. **Disables PCIe ASPM (`disable_aspm=y`)** to eliminate sleep hangs, beacon loss, and random disconnects.
6. **Disables NetworkManager Wi-Fi powersave** (`wifi.powersave = 2`).
7. **Compiles & installs the driver via DKMS** so it **automatically recompiles on future kernel updates**.
8. **Reloads modules cleanly** — Wi-Fi and Bluetooth activate immediately without rebooting!

---

## 🛠️ Diagnostics & Speed Optimizer Tool (`quick_fix.sh`)

If you already have the driver installed and want to check your link health, optimize connection profiles, or resolve sudden slowdowns, run the included `quick_fix.sh`:

```bash
sudo bash quick_fix.sh
```

### Features:
* Verifies `antenna_mask=3` and `disable_aspm=y` are active.
* Inspects Wi-Fi link parameters (Frequency, RSSI, TX bitrate, and RX bitrate).
* Alerts you if RX bitrate is throttled down to legacy OFDM (6.0 Mbps).
* Warns if a secondary USB Wi-Fi dongle is causing dual-routing ARP collisions.
* Checks Bluetooth radio state and warns of 2.4 GHz contention.
* Runs a live gateway ping test and download speed benchmark.

---

## 🔍 Root Cause Analysis: The Failures & What Actually Worked

During development and testing, several subtle bugs caused connection timeouts, drops, and speed caps. Here is the technical breakdown of why each occurred and the verified fix:

### 1. The 1.5–3 Mbps Download Speed Cap: Disabled Antenna Diversity (`antenna_mask`)
* **The Symptom**: Wi-Fi connects successfully, but internet download speed is stuck at **1.5–3 Mbps**, while an external USB dongle or phone tethering on the exact same laptop gets **20–50+ Mbps**. Running `iw dev wlp2s0 link` shows the RX bitrate collapsing down to **6.0 MBit/s**, and `ethtool -S wlp2s0` reports hundreds of thousands of `ba_miss_count` (Block ACK misses).
* **The Cause**: The MT7902 module has two physical antenna paths (Main and Aux, Chains 0 & 1). The firmware reports NSS=1. In standard drivers where `antenna_mask` defaults to `1` (or `BIT(cap->nss) - 1`), the MCU powers off Chain 1 (Aux). Without the second physical antenna path and MRC (Maximal Ratio Combining) receiver diversity:
  1. High-speed 802.11ax/ac A-MPDU aggregation frames and Block ACKs are dropped.
  2. The router's rate control algorithm detects massive packet drops and steps the connection down from Wi-Fi 6 (143+ Mbps) all the way to 802.11a/g legacy OFDM (6.0 Mbps).
* **The Working Fix**: 
  Pass `options mt7921_common antenna_mask=3` in `/etc/modprobe.d/mt7921e.conf`. This forces both physical antenna chains to remain active, enabling receiver diversity, eliminating Block ACK misses, and restoring full 20–100+ Mbps throughput.

---

### 2. Connection Timed Out / Auth Loops on 2.4 GHz: Bluetooth Coexistence
* **The Symptom**: 2.4 GHz Wi-Fi repeatedly fails authentication (`send auth (try 1/3, 2/3, 3/3)` → `timed out`), while 5 GHz connects instantly.
* **The Cause**: On single-antenna laptops or shared-path designs, Bluetooth (2.402–2.480 GHz) and 2.4 GHz Wi-Fi share the same physical radio path. When Bluetooth peripherals (e.g. a wireless mouse or headset) are actively transmitting or polling, the Packet Traffic Arbitration (PTA) gives Bluetooth priority, starving Wi-Fi 2.4 GHz management frames and causing association timeouts.
* **The Working Fix**:
  * **Option A (Recommended)**: Connect to your router's **5 GHz** SSID (`nmcli dev wifi connect "MyNetwork_5G"`). 5 GHz operates outside the Bluetooth frequency spectrum and has **zero** Bluetooth contention.
  * **Option B**: If you must connect to a 2.4 GHz network:
    ```bash
    bluetoothctl power off
    nmcli dev wifi connect "MyNetwork" password "MyPassword" ifname wlp2s0
    bluetoothctl power on
    ```

---

### 3. "Connected for a few minutes then disconnected": PCIe ASPM Sleep Hangs
* **The Symptom**: Wi-Fi connects, works for 2–5 minutes, then abruptly disconnects and enters an infinite `Connecting...` status loop.
* **The Cause**: The Linux PCIe bus puts the MT7902 adapter into low-power L1 sleep states. On many AMD and Intel laptop chipsets, the card fails to exit L1 sleep in time to receive 802.11 beacon frames from the router, causing the access point to de-authenticate the client.
* **The Working Fix**:
  Disable ASPM for `mt7921e` via `/etc/modprobe.d/mt7921e.conf`:
  ```ini
  options mt7921e disable_aspm=y
  ```
  and disable Wi-Fi powersave in NetworkManager (`/etc/NetworkManager/conf.d/wifi-powersave-off.conf`):
  ```ini
  [connection]
  wifi.powersave = 2
  ```

---

### 4. Dual-Adapter Routing & ARP Metric Collisions
* **The Symptom**: Wi-Fi speed is erratic or web traffic does not route through the MT7902 card.
* **The Cause**: Users often plug in an external USB Wi-Fi dongle (`wlx*`) to download the driver. If both the USB dongle and internal MT7902 card (`wlp*`) remain connected to the same network, Linux creates two competing default routes (metrics 601 vs 602). Linux reverse-path filtering (`rp_filter`) and ARP flux cause packets to route through the slower adapter.
* **The Working Fix**:
  **Unplug the secondary USB Wi-Fi adapter** once the internal MT7902 driver is installed and connected.

---

### 5. Bluetooth Controller Not Found: Duplicate Firmware Collision
* **The Symptom**: Wi-Fi works, but Bluetooth adapter is missing (`bluetoothctl show` reports `No default controller available`).
* **The Cause**: Some distributions include an outdated or incompatible Bluetooth firmware binary inside `/lib/firmware/mediatek/mt7902/` which takes precedence over `/lib/firmware/mediatek/BT_RAM_CODE_MT7902_1_1_hdr.bin`.
* **The Working Fix**:
  Remove the conflicting subdirectory file and update `initramfs`:
  ```bash
  sudo rm -f /lib/firmware/mediatek/mt7902/BT_RAM_CODE_MT7902*
  sudo update-initramfs -u -k all   # Debian/Ubuntu
  # or sudo dracut-rebuild          # Arch Linux
  ```

---

## 📖 Manual Step-by-Step Installation (Alternative to `install.sh`)

If you prefer executing the steps manually:

### 1. Install Dependencies
```bash
# Debian / Ubuntu / Mint / Pop!_OS
sudo apt update
sudo apt install -y build-essential dkms git linux-headers-$(uname -r) iw wireless-regdb

# Arch / EndeavourOS / CachyOS / Manjaro
sudo pacman -S --needed base-devel dkms git linux-headers iw wireless-regdb
```

### 2. Copy Firmware Binaries
```bash
sudo mkdir -p /lib/firmware/mediatek
sudo cp -f firmware/*.bin* /lib/firmware/mediatek/
sudo rm -f /lib/firmware/mediatek/mt7902/BT_RAM_CODE_MT7902* 2>/dev/null || true
```

### 3. Register & Compile DKMS Module
```bash
sudo rm -rf /usr/src/mt7902-wifi-1.0
sudo cp -a driver /usr/src/mt7902-wifi-1.0
sudo dkms add -m mt7902-wifi -v 1.0
sudo dkms build -m mt7902-wifi -v 1.0
sudo dkms install -m mt7902-wifi -v 1.0
```

### 4. Configure ASPM, Antenna Mask & Powersave
```bash
# 1. Modprobe configuration
sudo tee /etc/modprobe.d/mt7921e.conf << 'EOF'
options mt7921e disable_aspm=y
options mt7921_common antenna_mask=3
EOF

# 2. Disable NetworkManager powersave
sudo mkdir -p /etc/NetworkManager/conf.d
sudo tee /etc/NetworkManager/conf.d/wifi-powersave-off.conf << 'EOF'
[connection]
wifi.powersave = 2
EOF
sudo nmcli general reload 2>/dev/null || true
```

### 5. Reload Modules
```bash
sudo rmmod mt7921e mt7921_common 2>/dev/null || true
sudo modprobe mt7921_common
sudo modprobe mt7921e
sudo modprobe btusb 2>/dev/null || true
sudo systemctl enable --now bluetooth.service 2>/dev/null || true
```

---

## 📊 Verification & Diagnostics Checklist

| Component | Check Command | Expected Healthy Output |
| :--- | :--- | :--- |
| **DKMS Module** | `dkms status` | `mt7902-wifi/1.0: installed` |
| **Loaded Modules** | `lsmod \| grep mt7921e` | `mt7921e`, `mt7921_common`, `mt76` |
| **Antenna Mask** | `cat /sys/module/mt7921_common/parameters/antenna_mask` | `3` |
| **PCIe ASPM** | `cat /sys/module/mt7921e/parameters/disable_aspm` | `Y` |
| **Interface Status** | `nmcli dev status` | `wlp2s0 wifi connected <SSID>` |
| **RX Bitrate** | `iw dev wlp2s0 link \| grep "rx bitrate"` | `140+ MBit/s` (HE/VHT, > 6.0 Mbps) |
| **Bluetooth State**| `bluetoothctl show` | `Powered: yes` |
| **Gateway Ping** | `ping -c 5 1.1.1.1` | `0% packet loss, low latency` |

---

## 📌 Kernel 7.1+ Mainline Notice
Initial upstream driver support for PCI ID `14c3:7902` is staged for Linux **Kernel 7.1+**. Once distributions update to 7.1+ standard kernels, out-of-tree DKMS modules will no longer be necessary.

---

## 🤝 Credits & Acknowledgments

This guide, driver tree, and installer build upon the foundational work and research of the open-source Linux wireless community:

* **[SkimerPM](https://github.com/SkimerPM/MediaTek-MT7902-Linux-Driver-Installer)**: Original packaging of the out-of-tree MT7902 installer, kernel 6.12+ compatibility shims, and Bluetooth setup scripts.
* **[morrownr](https://github.com/morrownr/mt76)**: Comprehensive repository for out-of-tree Linux mt76 / mt7921 wireless drivers and module documentation.
* **[abdullaabdullazade](https://github.com/abdullaabdullazade/mt7902_driver)**: Identification of MediaTek MT7902 USB Bluetooth device IDs and base `btusb`/`btmtk` patches.
* **Linux Kernel MediaTek Wireless Developers**: Sean Wang, Felix Fietkau, Ryder Lee, Lorenzo Bianconi, Shayne Chen, and Deren Wu for the mainline `mt76` architecture and ongoing patch submissions on `lore.kernel.org`.
* **MediaTek Inc.** & **AzureWave Technologies**: Hardware manufacturers of the MT7902 / Filogic 310 PCIe wireless module and microcode firmwares.

---

## 📜 License
The driver source code is licensed under the **GNU General Public License v3.0 (GPL-3.0)** in accordance with Linux kernel module licensing requirements. Microcode firmwares are proprietary binaries provided by MediaTek Inc. for hardware initialization.
