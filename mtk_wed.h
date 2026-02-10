/* SPDX-License-Identifier: GPL-2.0-only */
/* Stub mtk_wed.h for kernel 5.10 compatibility */
#ifndef __MTK_WED_H
#define __MTK_WED_H

#include <linux/kernel.h>
#include <linux/rcupdate.h>
#include <linux/regmap.h>
#include <linux/pci.h>
#include <linux/skbuff.h>
#include <linux/netdevice.h>

struct mtk_wed_bm_desc {
	__le32 buf0;
	__le32 token;
};

struct mtk_wed_device {
};

static inline bool mtk_wed_device_active(struct mtk_wed_device *dev)
{
	return false;
}

#define mtk_wed_device_detach(_dev) do {} while (0)
#define mtk_wed_device_attach(_dev) -ENODEV
#define mtk_wed_device_tx_ring_setup(_dev, _ring, _regs, _reset) -ENODEV
#define mtk_wed_device_txfree_ring_setup(_dev, _regs) -ENODEV
#define mtk_wed_device_rx_ring_setup(_dev, _ring, _regs, _reset) -ENODEV
#define mtk_wed_device_rro_rx_ring_setup(_dev, _ring, _regs) -ENODEV
#define mtk_wed_device_msdu_pg_rx_ring_setup(_dev, _ring, _regs) -ENODEV
#define mtk_wed_device_start(_dev, _mask) do {} while (0)
#define mtk_wed_device_stop(_dev) do {} while (0)
#define mtk_wed_device_dma_reset(_dev) do {} while (0)
#define mtk_wed_device_irq_get(_dev, _mask) 0
#define mtk_wed_device_irq_set_mask(_dev, _mask) do {} while (0)
#define mtk_wed_get_rx_capa(_dev) false

#endif /* __MTK_WED_H */
