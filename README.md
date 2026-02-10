# mt76-rt-backport

Cross-compiled [mt76/mt7921u](https://github.com/openwrt/mt76) WiFi driver for **Linux kernel 5.10.x with PREEMPT_RT** patches.

This enables MediaTek MT7921/MT7961 WiFi 6E USB adapters (like EDUP AX3000M) on embedded systems running older or real-time kernels where the driver is not included.

## The Problem

The mt7921u driver was merged into Linux 5.12, but many embedded and industrial systems are stuck on older kernels. Worse, the mt76 driver has a **PREEMPT_RT incompatibility** that causes `BUG: scheduling while atomic` crashes on any RT kernel - even newer ones that include the driver.

This project provides:
- A **reproducible Docker build** that cross-compiles mt76 for kernel 5.10.x (aarch64)
- **11 compatibility patches** to backport the driver from 5.18 to 5.10
- A **critical PREEMPT_RT fix** for the mt76 worker thread scheduling bug
- **CRC injection tooling** for kernels with `CONFIG_MODVERSIONS` enabled
- **Ready-to-use kernel modules** for RevPi / BalenaOS (5.10.152-rt75-v8)

## Quick Start

### Use pre-built modules (RevPi / BalenaOS 5.10.152-rt75-v8)

Download the latest [Release](../../releases) and follow the [Device Setup Guide](docs/device-setup.md).

### Build from source

```bash
git clone https://github.com/Spunky84/mt76-rt-backport.git
cd mt76-rt-backport

# Build (requires Docker, ~20 min)
docker build -t mt76-build .

# Extract modules
mkdir -p output
docker run --rm mt76-build tar cf - -C /output . | tar xf - -C ./output/
ls -la output/*.ko
```

## Tested Hardware

| Adapter | Chip | USB ID | Status |
|---------|------|--------|--------|
| EDUP AX3000M | MT7961 | `0e8d:7961` | Working (2.4 + 5 GHz) |

**Tested on:**
- Revolution Pi Connect S (BCM2711, aarch64)
- BalenaOS 3.0.8+rev2
- Kernel 5.10.152-rt75-v8 (`CONFIG_PREEMPT_RT`, `CONFIG_MODVERSIONS`)

Other MT7921-based adapters with the same USB ID should work. Contributions for other hardware are welcome.

## Compatibility Patches

The OpenWrt mt76 driver targets newer kernels. These patches adapt it to 5.10:

| # | Patch | Kernel change |
|---|-------|---------------|
| 1 | `netif_napi_add_tx` -> `netif_tx_napi_add` | Renamed in 5.13 |
| 2 | `mtk_wed.h` include path | OpenWrt-specific header |
| 3 | Remove `.set_sar_specs` | SAR API added in 5.11 |
| 4 | Remove `.sta_set_decap_offload` | Decap offload added in 5.13 |
| 5 | Remove `.net_fill_forward_path` | Forward path added in 5.16 |
| 6 | `ieee80211_is_bufferable_mmpdu` wrapper | Signature changed in 5.12 |
| 7 | Comment out `of_get_mac_address` | Not needed for USB devices |
| 8 | Remove `.threaded` assignment | `net_device.threaded` added in 5.12 |
| 9 | Replace `wiphy->mbssid_max_interfaces` | MBSSID added in 5.14 |
| 10 | Replace `wiphy->sar_capa` access | SAR capabilities added in 5.11 |
| **11** | **PREEMPT_RT worker fix** | **See below** |

## The PREEMPT_RT Bug

The mt76 driver's worker thread function (`__mt76_worker_fn` in `util.c`) uses:

```c
set_current_state(TASK_INTERRUPTIBLE);
// ...
schedule();
```

On `CONFIG_PREEMPT_RT` kernels, this triggers **"BUG: scheduling while atomic"** because `set_current_state()` acquires a spinlock that becomes a sleeping lock under RT, and `schedule()` cannot be called in that context.

**The fix replaces the blocking wait with RT-safe timer-based sleeping:**

```c
// REMOVED: set_current_state(TASK_INTERRUPTIBLE);
// REPLACED: schedule() -> usleep_range(50, 500);
// REPLACED: set_current_state(TASK_RUNNING) -> __set_current_state(TASK_RUNNING);
```

This trades slightly higher idle CPU usage (~0.1%) for full PREEMPT_RT compatibility. The worker thread polls every 50-500 microseconds instead of blocking.

> **Note:** This bug affects ALL mt76-based drivers on RT kernels, not just mt7921u. If you're running mt7915, mt7603, or any other mt76 driver on a PREEMPT_RT kernel, you likely need this fix.

## CONFIG_MODVERSIONS / CRC Handling

Kernels with `CONFIG_MODVERSIONS` require each module to carry CRC checksums matching the running kernel's exported symbols. The build system handles this in two stages:

1. **modpost** fills inter-module CRCs (between our 5 modules) using `Module.symvers` from the device
2. **`patch_versions.py`** augments each module's `__versions` ELF section with missing kernel/cfg80211/mac80211 CRCs via direct binary patching

If you're building for a different kernel, you'll need to extract a new `Module.symvers` from your target device.

## Repository Structure

```
.
├── Dockerfile              # Reproducible cross-compilation build
├── config                  # Kernel .config from target device
├── Module.symvers          # Symbol CRCs from target device (640 entries)
├── compat-5.10.h           # API compatibility header (5.18 -> 5.10)
├── mtk_wed.h               # Stub header for MediaTek WED
├── patch_versions.py       # ELF binary patcher for CRC injection
├── load-mt7921.sh          # Boot loader script for the device
├── patches/
│   └── 0001-mt76-fix-scheduling-while-atomic-on-PREEMPT_RT.patch
└── docs/
    └── device-setup.md     # Step-by-step device installation guide
```

## Adapting to Other Kernels

To build for a different kernel version:

1. Extract kernel `.config` from your device: `zcat /proc/config.gz > config`
2. Extract `Module.symvers` from your device's running modules
3. Update the `EXTRAVERSION` in the Dockerfile to match your kernel
4. Adjust compatibility patches if your kernel version differs significantly from 5.10

## Contributing

Contributions are welcome! Especially:
- Testing on other MT7921-based adapters
- Patches for other kernel versions (5.11, 5.13, 5.15, etc.)
- Upstream submission of the PREEMPT_RT fix

## License

The mt76 driver is licensed under **Dual BSD/GPL** (same as the upstream project).
The build tooling and patches in this repository are licensed under **GPL-2.0**.

## Acknowledgments

- [OpenWrt mt76 project](https://github.com/openwrt/mt76) for the driver source
- [Revolution Pi](https://revolutionpi.com/) community
- [BalenaOS](https://www.balena.io/os) for the embedded Linux platform
