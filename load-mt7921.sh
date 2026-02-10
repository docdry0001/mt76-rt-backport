#!/bin/bash
# Load custom mt7921u WiFi driver (v5 with RT-preempt fix)
# Installed at: /mnt/data/mt76-modules/load-mt7921.sh
LOG=/tmp/mt7921-load.log
MODDIR=/mnt/data/mt76-modules
FWDIR=$MODDIR/firmware

exec >> "$LOG" 2>&1
echo "$(date): Starting mt7921u driver loading..."

# Setup firmware at /lib/firmware via tmpfs mount (belt and suspenders)
if [ ! -d /lib/firmware/mediatek ]; then
    mount -t tmpfs tmpfs /lib/firmware 2>/dev/null
    mkdir -p /lib/firmware/mediatek
fi
cp "$FWDIR"/mediatek/* /lib/firmware/mediatek/ 2>/dev/null
echo "Firmware at /lib/firmware/mediatek: $(ls /lib/firmware/mediatek/ 2>/dev/null)"

# Also set firmware_class.path as additional source
echo "$FWDIR" > /sys/module/firmware_class/parameters/path 2>/dev/null

# Load mac80211 if not loaded
lsmod | grep -q mac80211 || modprobe mac80211
echo "mac80211: $(lsmod | grep -c mac80211)"

# Load custom modules (skip if already loaded)
for mod in mt76.ko mt76-usb.ko mt76-connac-lib.ko mt7921-common.ko mt7921u.ko; do
    name=$(basename "$mod" .ko | tr - _)
    if ! lsmod | grep -q "^${name} "; then
        insmod "$MODDIR/$mod" 2>&1 && echo "$mod loaded" || echo "$mod FAILED"
    else
        echo "$mod already loaded"
    fi
done

sleep 3
echo "Interfaces: $(ip link show 2>/dev/null | grep -o 'wlan[0-9]*')"
echo "$(date): Module loading complete"
