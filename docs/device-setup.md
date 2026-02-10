# Device Setup Guide

Step-by-step instructions for installing the MT7921 WiFi driver on a RevPi / BalenaOS device.

## Prerequisites

- RevPi Connect S (or compatible BCM2711 device) running BalenaOS
- Kernel 5.10.152-rt75-v8
- SSH access to the host OS (`balena device ssh <UUID>`)
- MediaTek MT7921 USB WiFi adapter (e.g., EDUP AX3000M)

## Step 1: Transfer files to the device

Copy the following files to `/mnt/data/mt76-modules/` on the device:

```
/mnt/data/mt76-modules/
├── mt76.ko
├── mt76-usb.ko
├── mt76-connac-lib.ko
├── mt7921-common.ko
├── mt7921u.ko
├── load-mt7921.sh
└── firmware/
    └── mediatek/
        ├── WIFI_MT7961_patch_mcu_1_2_hdr.bin
        └── WIFI_RAM_CODE_MT7961_1.bin
```

You can use `balena tunnel` + `scp`, or transfer via base64 encoding over SSH.

### Transfer via base64 (no tunnel required)

```bash
# On your build machine, for each file:
base64 < output/mt76.ko | balena device ssh <UUID> \
  'base64 -d > /mnt/data/mt76-modules/mt76.ko'
```

## Step 2: Set kernel firmware path

```bash
# SSH into the device host OS
echo 'grep -q "firmware_class.path" /mnt/boot/cmdline.txt || \
  sed -i "s/$/ firmware_class.path=\/mnt\/data\/mt76-modules\/firmware/" \
  /mnt/boot/cmdline.txt && echo "OK" || echo "FAILED"; exit' \
  | balena device ssh <UUID>
```

This tells the kernel to search `/mnt/data/mt76-modules/firmware/` for firmware files. This setting persists across reboots (stored on the boot partition).

## Step 3: Install systemd service

```bash
echo 'mount -o remount,rw / && \
cat > /etc/systemd/system/mt7921-wifi.service << "SVC"
[Unit]
Description=Load MT7921 WiFi driver modules
After=local-fs.target
Before=NetworkManager.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/mnt/data/mt76-modules/load-mt7921.sh
[Install]
WantedBy=multi-user.target
SVC
systemctl enable mt7921-wifi.service && \
mount -o remount,ro / && \
echo "Service installed"; exit' | balena device ssh <UUID>
```

> **Note:** BalenaOS has a read-only root filesystem. The `remount,rw` makes it temporarily writable. This change persists until the next BalenaOS OTA update, after which you'll need to reinstall the service.

## Step 4: Reboot and verify

```bash
balena device reboot <UUID>

# After reboot (~90 seconds), verify:
echo 'systemctl status mt7921-wifi --no-pager; \
echo "---"; iw dev; echo "---"; \
dmesg | grep -c "scheduling while atomic"; exit' \
| balena device ssh <UUID>
```

Expected output:
- Service: `active (exited)` with `status=0/SUCCESS`
- `iw dev`: Shows `wlan1` interface with `phy#0`
- Scheduling bugs: `0`

## Step 5: Connect to WiFi (optional)

BalenaOS uses NetworkManager. To connect to a WiFi network:

```bash
echo 'nmcli dev wifi list ifname wlan1; exit' | balena device ssh <UUID>

echo 'nmcli dev wifi connect "YOUR_SSID" password "YOUR_PASSWORD" ifname wlan1; exit' \
| balena device ssh <UUID>
```

## Troubleshooting

### Service not found after reboot

BalenaOS OTA updates overwrite the root filesystem. Reinstall the service (Step 3).

### Firmware load failed (error -2)

Check that firmware files exist and the kernel cmdline is set:

```bash
echo 'cat /proc/cmdline | tr " " "\n" | grep firmware; \
ls /mnt/data/mt76-modules/firmware/mediatek/; exit' \
| balena device ssh <UUID>
```

### No wlan1 interface

Check the boot log:

```bash
echo 'cat /tmp/mt7921-load.log; exit' | balena device ssh <UUID>
```

### Module load fails with "Unknown symbol"

Ensure `mac80211` is loaded first. The load script handles this automatically, but you can verify:

```bash
echo 'lsmod | grep mac80211; exit' | balena device ssh <UUID>
```
