FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Install cross-compilation tools + clang for OnePlus kernel
RUN apt-get update && apt-get install -y \
    build-essential \
    gcc-aarch64-linux-gnu \
    bc \
    flex \
    bison \
    libssl-dev \
    libelf-dev \
    git \
    wget \
    kmod \
    cpio \
    xz-utils \
    python3 \
    clang \
    lld \
    llvm \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Clone OnePlus SM8475 kernel (branch: oneplus/sm8475_b_16.0.0_oneplus_11r)
RUN git clone --depth 1 --single-branch --branch oneplus/sm8475_b_16.0.0_oneplus_11r \
    https://github.com/OnePlusOSS/android_kernel_oneplus_sm8475.git oneplus-kernel

# Clone OpenWrt mt76 source (use same commit as original)
RUN git clone --depth 1 -b master https://github.com/openwrt/mt76.git mt76-openwrt \
    && cd mt76-openwrt \
    && git fetch --depth 1 origin bdf8ea71700746c634c064d6477aa143f821d6f6 \
    && git checkout bdf8ea71700746c634c064d6477aa143f821d6f6

# Copy device kernel config and stub headers (adjust paths if needed)
# The config and mtk_wed.h should be provided in the build context
COPY config /build/oneplus-kernel/.config
COPY mtk_wed.h /build/oneplus-kernel/include/linux/soc/mediatek/mtk_wed.h

# Prepare kernel headers (no full build, just modules_prepare)
WORKDIR /build/oneplus-kernel
RUN make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LLVM=1 olddefconfig \
    && make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LLVM=1 modules_prepare \
    && echo "=== UTS Release ===" && cat include/generated/utsrelease.h

# Install Module.symvers extracted from device's kernel modules
# Place it in the kernel tree root so modpost reads it for CRC matching
COPY Module.symvers /build/oneplus-kernel/Module.symvers

# Debug: verify Module.symvers format
RUN echo "=== Module.symvers stats ===" \
    && wc -l /build/oneplus-kernel/Module.symvers \
    && head -3 /build/oneplus-kernel/Module.symvers \
    && echo "=== Checking format (5 tab-separated fields) ===" \
    && awk -F'\t' 'NF!=5{print "BAD LINE " NR ": " $0; exit 1}' /build/oneplus-kernel/Module.symvers \
    && echo "All lines have 5 fields - OK"

# Install comprehensive compat header
COPY compat-5.10.h /build/compat-5.10.h

# Copy OpenWrt's mt76 source to a working directory
RUN cp -r /build/mt76-openwrt /build/mt76-src

# Apply compatibility patches for the kernel version (assumes 5.10.x)
WORKDIR /build/mt76-src

# Patch 1: netif_napi_add_tx -> netif_tx_napi_add
RUN sed -i 's/netif_napi_add_tx(/netif_tx_napi_add(/g' $(grep -rl 'netif_napi_add_tx' . 2>/dev/null) 2>/dev/null; true

# Patch 2: Fix mtk_wed.h include location in mt76.h
RUN sed -i 's/#include <linux\/soc\/mediatek\/mtk_wed.h>//' mt76.h 2>/dev/null; true \
    && sed -i '/#ifndef __MT76_H/a #include <linux/soc/mediatek/mtk_wed.h>' mt76.h 2>/dev/null; true

# Patch 3: Remove .set_sar_specs from ieee80211_ops
RUN sed -i '/\.set_sar_specs/d' mt7921/main.c 2>/dev/null; true

# Patch 4: Remove .sta_set_decap_offload
RUN sed -i '/\.sta_set_decap_offload/d' mt7921/main.c 2>/dev/null; true

# Patch 5: Remove .net_fill_forward_path
RUN sed -i '/\.net_fill_forward_path/d' mt7921/main.c 2>/dev/null; true

# Patch 6: ieee80211_is_bufferable_mmpdu signature change
RUN sed -i 's/ieee80211_is_bufferable_mmpdu(skb)/mt76_compat_is_bufferable_mmpdu(skb)/g' tx.c 2>/dev/null; true

# Patch 7: of_get_mac_address – comment out (USB devices don't use DT MAC)
RUN sed -i '/of_get_mac_address/s/^/\/\//' eeprom.c 2>/dev/null; true

# Patch 8: net_device.threaded doesn't exist in 5.10
RUN sed -i '/\.threaded\s*=/d' dma.c 2>/dev/null; true

# Patch 9: wiphy->mbssid_max_interfaces doesn't exist in 5.10
RUN sed -i 's/wiphy->mbssid_max_interfaces/1/g' mt76_connac_mcu.c 2>/dev/null; true \
    && sed -i 's/wiphy->mbssid_max_ema_profile_periodicity/1/g' mt76_connac_mcu.c 2>/dev/null; true

# Patch 10: wiphy->sar_capa member doesn't exist in 5.10
RUN sed -i '/wiphy->sar_capa\s*=/d' mac80211.c mt7921/init.c 2>/dev/null; true \
    && sed -i 's/wiphy->sar_capa->num_freq_ranges/mt76_sar_capa.num_freq_ranges/g' mac80211.c 2>/dev/null; true \
    && sed -i 's/phy->hw->wiphy->sar_capa/\&mt76_sar_capa/g' mac80211.c 2>/dev/null; true \
    && sed -i 's/hw->wiphy->sar_capa/\&mt76_sar_capa/g' mac80211.c 2>/dev/null; true

# Patch 11: RT-preempt kernel compatibility for mt76 worker threads
RUN sed -i '/set_current_state(TASK_INTERRUPTIBLE)/d' util.c \
    && sed -i 's/set_current_state(TASK_RUNNING)/__set_current_state(TASK_RUNNING)/' util.c \
    && sed -i '/test_and_clear_bit(MT76_WORKER_SCHEDULED/{n;s/schedule();/usleep_range(50, 500);/}' util.c \
    && echo "=== Patched worker in util.c ===" \
    && grep -B2 -A2 "usleep_range" util.c

# Build the mt76 module against the OnePlus kernel tree
RUN make -C /build/oneplus-kernel M=/build/mt76-src \
    ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LLVM=1 \
    EXTRA_CFLAGS="-include /build/compat-5.10.h" \
    KCFLAGS="-Wno-error" \
    CONFIG_MT76_USB=m \
    CONFIG_MT76_SDIO= \
    CONFIG_MT76_CONNAC_LIB=m \
    CONFIG_MT7921_COMMON=m \
    CONFIG_MT7921U=m \
    CONFIG_MT7921E= \
    CONFIG_MT7921S= \
    CONFIG_MT76x0_COMMON= \
    CONFIG_MT76x2_COMMON= \
    CONFIG_MT7603E= \
    CONFIG_MT7615_COMMON= \
    CONFIG_MT7915E= \
    CONFIG_MT7996E= \
    modules -j$(nproc) 2>&1 || { \
        echo "=== Build failed, checking Module.symvers parsing ===" ; \
        echo "=== Running modpost manually for diagnostics ===" ; \
        /build/oneplus-kernel/scripts/mod/modpost -v 2>&1 || true ; \
        echo "=== Trying build without Module.symvers as fallback ===" ; \
        rm /build/oneplus-kernel/Module.symvers ; \
        make -C /build/oneplus-kernel M=/build/mt76-src \
            ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- LLVM=1 \
            EXTRA_CFLAGS="-include /build/compat-5.10.h" \
            KCFLAGS="-Wno-error" \
            CONFIG_MT76_USB=m \
            CONFIG_MT76_SDIO= \
            CONFIG_MT76_CONNAC_LIB=m \
            CONFIG_MT7921_COMMON=m \
            CONFIG_MT7921U=m \
            CONFIG_MT7921E= \
            CONFIG_MT7921S= \
            CONFIG_MT76x0_COMMON= \
            CONFIG_MT76x2_COMMON= \
            CONFIG_MT7603E= \
            CONFIG_MT7615_COMMON= \
            CONFIG_MT7915E= \
            CONFIG_MT7996E= \
            modules -j$(nproc) ; \
    }

# Copy device Module.symvers for post-processing (if needed)
COPY Module.symvers /build/device-symvers/Module.symvers

# Post-processing: Inject device CRCs via binary patching if __versions empty
COPY patch_versions.py /build/patch_versions.py
RUN mkdir -p /output && \
    find /build/mt76-src -name "*.ko" -exec cp {} /output/ \; && \
    echo "=== Built modules ===" && \
    ls -la /output/ && \
    echo "=== Module vermagic ===" && \
    modinfo /output/mt76.ko | grep vermagic && \
    echo "=== Checking __versions sections ===" && \
    for ko in /output/*.ko; do \
        size=$(aarch64-linux-gnu-objdump -h "$ko" 2>/dev/null | grep __versions | awk '{print $3}'); \
        echo "$(basename $ko): __versions size=${size:-not_found}"; \
    done && \
    echo "=== Patching CRCs if needed ===" && \
    python3 /build/patch_versions.py /output /build/device-symvers/Module.symvers && \
    echo "=== Post-patch verification ===" && \
    for ko in /output/*.ko; do \
        size=$(aarch64-linux-gnu-objdump -h "$ko" 2>/dev/null | grep __versions | awk '{print $3}'); \
        echo "$(basename $ko): __versions size=${size:-not_found}"; \
    done && \
    echo "=== Final module info ===" && \
    modinfo /output/mt76.ko | grep vermagic && \
    modinfo /output/mt7921u.ko | grep depends

CMD ["ls", "-la", "/output/"]
