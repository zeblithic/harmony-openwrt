# Mesh WiFi Setup for Harmony on OpenWRT

This guide configures an 802.11s mesh interface on MediaTek MT7996 (Filogic 880)
routers running OpenWRT 23.x/24.x for Harmony mesh networking.

## Overview

The 802.11s mesh creates a self-forming Layer 2 broadcast domain between Harmony
nodes. Each node discovers peers automatically — no central AP or coordinator needed.

**Key design decisions:**

- **802.11s with HWMP disabled** (`mesh_fwding '0'`) — Reticulum handles its own
  routing. The 802.11s interface is a flat single-hop broadcast domain only.
- **5 GHz band** — 6 GHz has a known regulatory bug (NO-IR) in current OpenWRT
  snapshots that prevents mesh operation.
- **Concurrent AP + Mesh** — The same radio runs both a client AP and the mesh
  interface. All VIFs on a radio share the same channel.
- **Elevated multicast rate** (`mcast_rate '24000'`) — Prevents broadcast airtime
  starvation that would otherwise cripple Reticulum announces and Zenoh scouting.

## Prerequisites

### Install mesh-capable wpad

The default `wpad-basic-wolfssl` does not support 802.11s SAE encryption.
Replace it:

```bash
opkg remove wpad-basic-wolfssl
opkg install wpad-mesh-wolfssl
```

Reboot after installing to ensure the new daemon is loaded.

### Verify hardware

Confirm your 5 GHz radio supports mesh mode:

```bash
iw phy phy1 info | grep -i mesh
```

You should see `mesh point` in the supported interface modes.

## Configuration

### Identify the 5 GHz radio

```bash
uci show wireless | grep band
```

Look for the radio with `band='5g'` — typically `radio1` on GL.iNet devices.
The examples below use `radio1`.

### Add the mesh interface

Add these stanzas to `/etc/config/wireless` (or use `uci` commands below):

```
# ── 5 GHz Radio Configuration ──────────────────────────────────────
# Ensure the radio is configured for Wi-Fi 6 HE mode on a clear channel.

config wifi-device 'radio1'
    option type 'mac80211'
    option band '5g'
    option channel '36'
    option htmode 'HE80'
    option cell_density '0'
    option he_bss_color '8'
    option he_su_beamformee '1'

# ── Existing AP Interface (keep this for client devices) ────────────

config wifi-iface 'default_radio1'
    option device 'radio1'
    option mode 'ap'
    option network 'lan'
    option ssid 'YourExistingSSID'
    option encryption 'sae-mixed'
    option key 'YourExistingPassword'

# ── Harmony Mesh Interface ──────────────────────────────────────────
# 802.11s mesh for Reticulum peer discovery and Zenoh content exchange.

config wifi-iface 'harmony_mesh'
    option device 'radio1'
    option mode 'mesh'
    option network 'lan'
    option mesh_id 'harmony'
    option encryption 'sae'
    option key 'YourMeshKey'
    option mesh_fwding '0'
    option mcast_rate '24000'
```

### Or configure via UCI commands

```bash
# Add the mesh interface
uci set wireless.harmony_mesh=wifi-iface
uci set wireless.harmony_mesh.device='radio1'
uci set wireless.harmony_mesh.mode='mesh'
uci set wireless.harmony_mesh.network='lan'
uci set wireless.harmony_mesh.mesh_id='harmony'
uci set wireless.harmony_mesh.encryption='sae'
uci set wireless.harmony_mesh.key='YourMeshKey'
uci set wireless.harmony_mesh.mesh_fwding='0'
uci set wireless.harmony_mesh.mcast_rate='24000'

# Enable HE features on the radio (if not already set)
uci set wireless.radio1.htmode='HE80'
uci set wireless.radio1.he_bss_color='8'
uci set wireless.radio1.he_su_beamformee='1'

uci commit wireless
wifi reload
```

## Configuration Explained

**Radio-level options** (in `config wifi-device`):

| Option | Value | Why |
|--------|-------|-----|
| `htmode 'HE80'` | Wi-Fi 6 HE, 80 MHz width | High throughput for mesh + AP on 5 GHz |
| `he_bss_color '8'` | BSS coloring | Mitigates co-channel interference in dense deployments |
| `he_su_beamformee '1'` | Beamforming | Improved signal quality to specific peers |

**Interface-level options** (in `config wifi-iface`):

| Option | Value | Why |
|--------|-------|-----|
| `mode 'mesh'` | 802.11s mesh point | Self-forming L2 peering, no coordinator needed |
| `network 'lan'` | Bridge to LAN | Mesh traffic visible to harmony-node on the LAN bridge |
| `mesh_id 'harmony'` | Mesh network name | All Harmony nodes must use the same mesh_id to peer |
| `encryption 'sae'` | WPA3-SAE | Zero-knowledge password proof — secure mesh peering |
| `mesh_fwding '0'` | **Disable HWMP** | Critical — Reticulum handles routing, not 802.11s |
| `mcast_rate '24000'` | 24 Mbps broadcast floor | Prevents airtime starvation from low-rate broadcasts |

### Why disable mesh_fwding

802.11s includes HWMP (Hybrid Wireless Mesh Protocol) for Layer 2 path selection.
When enabled, HWMP floods multicast frames across the entire multihop mesh. Since
Reticulum already does its own cryptographic routing and Zenoh handles content
scouting, enabling HWMP causes:

- **Broadcast storms** — every multicast is redundantly forwarded at L2
- **Routing conflicts** — two routing layers fighting over path selection
- **Latency spikes** — HWMP path discovery adds unpredictable delays

With `mesh_fwding '0'`, the mesh interface is a flat single-hop broadcast domain.
Reticulum announces go out once over the air. Only the receiving node's Reticulum
daemon decides whether to propagate further.

### Why mcast_rate 24000

WiFi broadcast frames transmit at the lowest "basic rate" by default (6 Mbps on
5 GHz). A swarm of 20-30 Harmony nodes sending Reticulum announces and Zenoh
scouting at 6 Mbps would saturate the channel airtime — each slow broadcast blocks
all other traffic.

Setting `mcast_rate '24000'` forces broadcasts to 24 Mbps, reducing airtime by 4x.
This also culls weak links — nodes with poor signal won't receive the higher-rate
broadcasts, which is beneficial: Reticulum automatically routes through strong,
reliable adjacencies instead of fragile fringe connections.

## Verify the mesh is working

**Note:** OpenWRT assigns kernel interface names automatically (e.g., `wlan1-1`),
not the UCI section name (`harmony_mesh`) or `mesh0`. Find the actual name first:

### Find the mesh interface name

```bash
# Find the kernel interface name for the mesh VIF
MESH_IF=$(iw dev | awk '/type mesh point/{getline; getline; print prev} {prev=$0}' | awk '/Interface/{print $2}')
echo "Mesh interface: $MESH_IF"
```

Or simply look for `mesh point` in `iw dev` output:

```bash
iw dev
```

Look for an interface with `type mesh point` — note its `Interface` name (e.g., `wlan1-1`).

### Check for mesh peers

```bash
iw dev "$MESH_IF" station dump | grep -E "Station|signal|mesh"
```

Each neighboring Harmony node should appear as a station with signal strength.

### Check Harmony sees the mesh traffic

```bash
logread | grep harmony
```

Look for Reticulum announce/packet messages indicating peer communication.

## Band Planning

| Radio | Band | Use |
|-------|------|-----|
| `radio0` | 2.4 GHz | Legacy IoT devices, wide coverage |
| `radio1` | 5 GHz | **Harmony mesh + client AP** (shared channel) |
| `radio2` | 6 GHz | Not usable for mesh (NO-IR bug in current OpenWRT) |

All VIFs on the same radio must share the same channel. The AP and mesh interfaces
on `radio1` both operate on channel 36 (or whichever you configure).

## Troubleshooting

### Mesh interface won't start

```bash
logread | grep hostapd
```

Common causes:
- Missing `wpad-mesh-wolfssl` package (SAE not available)
- Radio not configured for the correct band/channel
- `mesh_fwding` not recognized (ensure OpenWRT 23.x+)

### No mesh peers discovered

- Verify all nodes use the same `mesh_id` and `key`
- Verify all nodes are on the same channel
- Check signal strength: `iw dev "$MESH_IF" station dump`
- Ensure `harmony-node` is running: `ps | grep harmony`

### Broadcast storms or high CPU

- Verify `mesh_fwding '0'` is set: `uci get wireless.harmony_mesh.mesh_fwding`
- Check `mcast_rate '24000'` is applied: `grep mcast_rate /var/run/hostapd-phy*.conf`

## Known Limitations

- **6 GHz mesh** — blocked by NO-IR regulatory bug in OpenWRT. Track upstream:
  [openwrt/openwrt#20276](https://github.com/openwrt/openwrt/issues/20276)
- **WED hardware offload** — may cause instability with mesh traffic. If you
  experience sporadic frame drops, disable WED in `/etc/config/network`.
- **Channel selection** — DFS channels (52-144) may cause the mesh to go down
  during radar detection events. Use non-DFS channels (36-48, 149-165) for
  reliability.
- **Single-hop L2 topology** — with `mesh_fwding '0'`, nodes not in direct RF
  range have no L2 adjacency. This is intentional: Reticulum's routing layer
  provides end-to-end connectivity across multi-hop paths. But L2-dependent
  behavior (ARP, same-subnet broadcast discovery) only works between nodes
  that can directly hear each other. Plan node placement accordingly.

## Security Notes

- The SAE mesh key authenticates peers at the 802.11s layer. This is **in addition
  to** Harmony's end-to-end Reticulum encryption (Curve25519 + ML-KEM-768).
- Even without SAE (`encryption 'none'`), Harmony traffic is encrypted. SAE adds
  defense-in-depth against casual packet injection at the radio layer.
- Use a unique, strong mesh key. All Harmony nodes on the same mesh must share it.
