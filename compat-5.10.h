/* Compatibility header for building mt76 (OpenWrt) against vanilla kernel 5.10 */
#ifndef __MT76_COMPAT_510_H
#define __MT76_COMPAT_510_H

#include <linux/ieee80211.h>
#include <net/cfg80211.h>

/* SAR (Specific Absorption Rate) - added in kernel 5.11 */
#ifndef NL80211_SAR_TYPE_POWER
enum nl80211_sar_type {
	NL80211_SAR_TYPE_POWER,
};

struct cfg80211_sar_freq_ranges {
	u32 start_freq;
	u32 end_freq;
};

struct cfg80211_sar_capa {
	enum nl80211_sar_type type;
	u32 num_freq_ranges;
	const struct cfg80211_sar_freq_ranges *freq_ranges;
};

struct cfg80211_sar_sub_specs {
	s32 power;
	u32 freq_range_index;
};

struct cfg80211_sar_specs {
	enum nl80211_sar_type type;
	u32 num_sub_specs;
	struct cfg80211_sar_sub_specs sub_specs[];
};
#endif /* NL80211_SAR_TYPE_POWER */

/* Threaded NAPI - added in kernel 5.12 */
#ifndef dev_set_threaded
static inline int dev_set_threaded(struct net_device *dev, bool threaded)
{
	return 0;
}
#endif

/* RX_FLAG_8023 - added in kernel 5.13 for rx decap offload */
#ifndef RX_FLAG_8023
#define RX_FLAG_8023 0
#endif

#ifndef IEEE80211_HW_SUPPORTS_RX_DECAP_OFFLOAD
#define IEEE80211_HW_SUPPORTS_RX_DECAP_OFFLOAD 0
#endif

/* NL80211_EXT_FEATURE_BEACON_RATE_HE - added in kernel 5.13 */
#ifndef NL80211_EXT_FEATURE_BEACON_RATE_HE
#define NL80211_EXT_FEATURE_BEACON_RATE_HE NL80211_EXT_FEATURE_BEACON_RATE_VHT
#endif

/* ieee80211_is_bufferable_mmpdu - signature changed in 5.12
 * 5.10: takes __le16 fc
 * 5.12+: takes struct sk_buff *skb
 * We wrap calls from mt76 tx.c that pass skb */
static inline bool
mt76_compat_is_bufferable_mmpdu(struct sk_buff *skb)
{
	struct ieee80211_hdr *hdr = (struct ieee80211_hdr *)skb->data;
	return ieee80211_is_bufferable_mmpdu(hdr->frame_control);
}

/* HE capability constant renames between 5.10 and 5.18 */
#ifndef IEEE80211_HE_MAC_CAP3_MAX_AMPDU_LEN_EXP_EXT_3
#define IEEE80211_HE_MAC_CAP3_MAX_AMPDU_LEN_EXP_EXT_3 \
	IEEE80211_HE_MAC_CAP3_MAX_AMPDU_LEN_EXP_VHT_1
#endif

#ifndef IEEE80211_HE_MAC_CAP4_AMSDU_IN_AMPDU
#ifdef IEEE80211_HE_MAC_CAP4_AMDSU_IN_AMPDU
#define IEEE80211_HE_MAC_CAP4_AMSDU_IN_AMPDU IEEE80211_HE_MAC_CAP4_AMDSU_IN_AMPDU
#else
#define IEEE80211_HE_MAC_CAP4_AMSDU_IN_AMPDU 0
#endif
#endif

#ifndef IEEE80211_HE_PHY_CAP7_POWER_BOOST_FACTOR_SUPP
#ifdef IEEE80211_HE_PHY_CAP7_POWER_BOOST_FACTOR_AR
#define IEEE80211_HE_PHY_CAP7_POWER_BOOST_FACTOR_SUPP IEEE80211_HE_PHY_CAP7_POWER_BOOST_FACTOR_AR
#else
#define IEEE80211_HE_PHY_CAP7_POWER_BOOST_FACTOR_SUPP 0
#endif
#endif

#ifndef IEEE80211_HE_PHY_CAP9_NOMINAL_PKT_PADDING_16US
#ifdef IEEE80211_HE_PHY_CAP9_NOMIMAL_PKT_PADDING_16US
#define IEEE80211_HE_PHY_CAP9_NOMINAL_PKT_PADDING_16US IEEE80211_HE_PHY_CAP9_NOMIMAL_PKT_PADDING_16US
#define IEEE80211_HE_PHY_CAP9_NOMINAL_PKT_PADDING_MASK IEEE80211_HE_PHY_CAP9_NOMIMAL_PKT_PADDING_MASK
#else
#define IEEE80211_HE_PHY_CAP9_NOMINAL_PKT_PADDING_16US 0
#define IEEE80211_HE_PHY_CAP9_NOMINAL_PKT_PADDING_MASK 0
#endif
#endif

/* ieee80211_disconnect - added in 5.17 */
/* Use macro instead of inline function to avoid implicit declaration of ieee80211_connection_loss */
#ifndef ieee80211_disconnect
#define ieee80211_disconnect(vif, reconnect) ieee80211_connection_loss(vif)
#endif

#endif /* __MT76_COMPAT_510_H */
