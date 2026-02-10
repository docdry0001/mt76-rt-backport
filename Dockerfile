FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Install cross-compilation tools
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
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Download kernel 5.10.152 and OpenWrt mt76 source
RUN wget -q https://cdn.kernel.org/pub/linux/kernel/v5.x/linux-5.10.152.tar.xz \
    && tar xf linux-5.10.152.tar.xz \
    && rm linux-5.10.152.tar.xz \
    && git clone --depth 1 -b master https://github.com/openwrt/mt76.git mt76-openwrt \
    && cd mt76-openwrt \
    && git fetch --depth 1 origin bdf8ea71700746c634c064d6477aa143f821d6f6 \
    && git checkout bdf8ea71700746c634c064d6477aa143f821d6f6

# Copy device kernel config and stub headers
COPY config /build/linux-5.10.152/.config
COPY mtk_wed.h /build/linux-5.10.152/include/linux/soc/mediatek/mtk_wed.h

# Set EXTRAVERSION to match RT kernel (-rt75) and prepare kernel headers
WORKDIR /build/linux-5.10.152
RUN sed -i 's/^EXTRAVERSION =$/EXTRAVERSION = -rt75/' Makefile \
    && make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig \
    && make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- modules_prepare \
    && echo "=== UTS Release ===" && cat include/generated/utsrelease.h

# Install Module.symvers extracted from device's kernel modules
# Place it in the kernel tree root so modpost reads it for CRC matching
COPY Module.symvers /build/linux-5.10.152/Module.symvers

# Debug: verify Module.symvers format is readable by modpost
RUN echo "=== Module.symvers stats ===" \
    && wc -l /build/linux-5.10.152/Module.symvers \
    && head -3 /build/linux-5.10.152/Module.symvers \
    && echo "=== Checking format (5 tab-separated fields) ===" \
    && awk -F'\t' 'NF!=5{print "BAD LINE " NR ": " $0; exit 1}' /build/linux-5.10.152/Module.symvers \
    && echo "All lines have 5 fields - OK"

# Install comprehensive compat header
COPY compat-5.10.h /build/compat-5.10.h

# Copy OpenWrt's mt76 source
RUN cp -r /build/mt76-openwrt /build/mt76-src

# Apply compatibility patches for 5.10 kernel API
WORKDIR /build/mt76-src

# Patch 1: netif_napi_add_tx -> netif_tx_napi_add (renamed between 5.10 and 5.13)
RUN sed -i 's/netif_napi_add_tx(/netif_tx_napi_add(/g' $(grep -rl 'netif_napi_add_tx' . 2>/dev/null) 2>/dev/null; true

# Patch 2: Fix mtk_wed.h include location in mt76.h
RUN sed -i 's/#include <linux\/soc\/mediatek\/mtk_wed.h>//' mt76.h 2>/dev/null; true \
    && sed -i '/#ifndef __MT76_H/a #include <linux/soc/mediatek/mtk_wed.h>' mt76.h 2>/dev/null; true

# Patch 3: Remove .set_sar_specs from ieee80211_ops (SAR ops added in 5.11)
RUN sed -i '/\.set_sar_specs/d' mt7921/main.c 2>/dev/null; true

# Patch 4: Remove .sta_set_decap_offload from ieee80211_ops (added in 5.13)
RUN sed -i '/\.sta_set_decap_offload/d' mt7921/main.c 2>/dev/null; true

# Patch 5: Remove .net_fill_forward_path (added in 5.16)
RUN sed -i '/\.net_fill_forward_path/d' mt7921/main.c 2>/dev/null; true

# Patch 6: ieee80211_is_bufferable_mmpdu signature change (5.10 takes __le16 fc, 5.12+ takes skb)
RUN sed -i 's/ieee80211_is_bufferable_mmpdu(skb)/mt76_compat_is_bufferable_mmpdu(skb)/g' tx.c 2>/dev/null; true

# Patch 7: of_get_mac_address - comment out (USB devices don't use devicetree MAC)
RUN sed -i '/of_get_mac_address/s/^/\/\//' eeprom.c 2>/dev/null; true

# Patch 8: net_device.threaded doesn't exist in 5.10 (added in 5.12)
RUN sed -i '/\.threaded\s*=/d' dma.c 2>/dev/null; true

# Patch 9: wiphy->mbssid_max_interfaces doesn't exist in 5.10 (added in 5.14)
RUN sed -i 's/wiphy->mbssid_max_interfaces/1/g' mt76_connac_mcu.c 2>/dev/null; true \
    && sed -i 's/wiphy->mbssid_max_ema_profile_periodicity/1/g' mt76_connac_mcu.c 2>/dev/null; true

# Patch 10: wiphy->sar_capa member doesn't exist in 5.10
RUN sed -i '/wiphy->sar_capa\s*=/d' mac80211.c mt7921/init.c 2>/dev/null; true \
    && sed -i 's/wiphy->sar_capa->num_freq_ranges/mt76_sar_capa.num_freq_ranges/g' mac80211.c 2>/dev/null; true \
    && sed -i 's/phy->hw->wiphy->sar_capa/\&mt76_sar_capa/g' mac80211.c 2>/dev/null; true \
    && sed -i 's/hw->wiphy->sar_capa/\&mt76_sar_capa/g' mac80211.c 2>/dev/null; true

# Patch 11: RT-preempt kernel compatibility for mt76 worker threads
# Remove set_current_state() calls and replace schedule() with usleep_range()
# to avoid "BUG: scheduling while atomic" on CONFIG_PREEMPT_RT kernels
RUN sed -i '/set_current_state(TASK_INTERRUPTIBLE)/d' util.c \
    && sed -i 's/set_current_state(TASK_RUNNING)/__set_current_state(TASK_RUNNING)/' util.c \
    && sed -i '/test_and_clear_bit(MT76_WORKER_SCHEDULED/{n;s/schedule();/usleep_range(50, 500);/}' util.c \
    && echo "=== Patched worker in util.c ===" \
    && grep -B2 -A2 "usleep_range" util.c

# Build with Module.symvers from device for correct CRC matching
RUN make -C /build/linux-5.10.152 M=/build/mt76-src \
    ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
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
        /build/linux-5.10.152/scripts/mod/modpost -v 2>&1 || true ; \
        echo "=== Trying build without Module.symvers as fallback ===" ; \
        rm /build/linux-5.10.152/Module.symvers ; \
        make -C /build/linux-5.10.152 M=/build/mt76-src \
            ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
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

# Copy the Module.symvers with device CRCs for post-processing
COPY Module.symvers /build/device-symvers/Module.symvers

# Post-processing: If __versions sections are empty, inject device CRCs via binary patching
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
