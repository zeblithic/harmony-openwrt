# Mesh WiFi Setup for Harmony on OpenWRT

> **Note:** As of v0.2.0, the harmony-node package **automatically configures**
> the HARMONY-MESH interface on first install. The auto-config detects the 5GHz
> radio, creates the mesh VIF with SSID `HARMONY-MESH` and PSK `ZEBLITHIC`,
> and applies all recommended tunings (mesh_fwding=0, mcast_rate=24000, multicast_to_unicast=0, powersave=0, mesh_rssi_threshold=-70, he_bss_color=37, network='harmony' (isolated from LAN)).
> `htmode` is intentionally left at the radio's existing value (see below
> to enable HE80 manually on WiFi 6 hardware).
> **You only need this guide if** you want to customize the configuration, use
> a different radio, or troubleshoot mesh issues.

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

**WARNING:** Removing wpad kills all WiFi immediately. Run this over **Ethernet**,
not a WiFi SSH session — you will be locked out before the install completes.

```bash
# Run over Ethernet only!
opkg remove wpad-basic-wolfssl && opkg install wpad-mesh-wolfssl
```

Reboot after installing to ensure the new daemon is loaded.

### Verify hardware

Confirm your 5 GHz radio supports mesh mode:

```bash
iw list | grep -i "mesh point"
```

If you see at least one match, your hardware supports mesh mode. This scans all
radios regardless of phy numbering (phy index varies by driver probe order).

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
    option he_bss_color '37'
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
    option network 'harmony'
    option mesh_id 'HARMONY-MESH'
    option encryption 'sae'
    option key 'ZEBLITHIC'
    option mesh_fwding '0'
    option mcast_rate '24000'
    option multicast_to_unicast '0'
    option powersave '0'
```

### Or configure via UCI commands

```bash
# Add the mesh interface
uci set wireless.harmony_mesh=wifi-iface
uci set wireless.harmony_mesh.device='radio1'
uci set wireless.harmony_mesh.mode='mesh'
uci set wireless.harmony_mesh.network='harmony'
uci set wireless.harmony_mesh.mesh_id='HARMONY-MESH'
uci set wireless.harmony_mesh.encryption='sae'
uci set wireless.harmony_mesh.key='ZEBLITHIC'
uci set wireless.harmony_mesh.mesh_fwding='0'
uci set wireless.harmony_mesh.mcast_rate='24000'
uci set wireless.harmony_mesh.multicast_to_unicast='0'
uci set wireless.harmony_mesh.powersave='0'

# Enable HE features on the radio (if not already set)
uci set wireless.radio1.htmode='HE80'
# BSS Color 37: unified across all Harmony mesh nodes (auto-configured).
# Only change if you have a specific reason to use a different value.
uci set wireless.radio1.he_bss_color='37'
uci set wireless.radio1.he_su_beamformee='1'

uci commit wireless
wifi reload
```

## Configuration Explained

**Radio-level options** (in `config wifi-device`):

| Option | Value | Why |
|--------|-------|-----|
| `htmode 'HE80'` | Wi-Fi 6 HE, 80 MHz width | High throughput for mesh + AP on 5 GHz |
| `he_bss_color '37'` | Unified Harmony BSS color | Spatial reuse against non-Harmony networks; mesh peers cooperate on CSMA/CA |
| `he_su_beamformee '1'` | Beamforming | Improved signal quality to specific peers |

**Interface-level options** (in `config wifi-iface`):

| Option | Value | Why |
|--------|-------|-----|
| `mode 'mesh'` | 802.11s mesh point | Self-forming L2 peering, no coordinator needed |
| `network 'harmony'` | Dedicated mesh bridge | Isolated from LAN — harmony-node sees both bridges via 0.0.0.0 binding |
| `mesh_id 'HARMONY-MESH'` | Mesh network name | Well-known communal mesh — all Harmony nodes must use the same mesh_id to peer |
| `encryption 'sae'` | WPA3-SAE | Zero-knowledge password proof — secure mesh peering |
| `mesh_fwding '0'` | **Disable HWMP** | Critical — Reticulum handles routing, not 802.11s |
| `mcast_rate '24000'` | 24 Mbps broadcast floor | Prevents airtime starvation from low-rate broadcasts |
| `multicast_to_unicast '0'` | **Disable mcast→unicast** | Prevents N×airtime from per-peer unicast conversion |
| `powersave '0'` | **Disable power save** | Routers are always-on — power save adds DTIM buffering latency |
| `mesh_rssi_threshold '-70'` | Min signal for peering | Reject weak-signal peers below -70 dBm (complements mcast_rate) |

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

### Upgrading from earlier versions

Settings added after the initial auto-config are automatically backfilled on
package upgrade. This includes the network isolation migration: `network='lan'`
is migrated to `network='harmony'` on upgrade, and the `harmony` network interface,
`br-harmony` bridge (`10.73.0.0/24`), and dedicated firewall zone are created
automatically.

If auto-backfill fails, apply manually:

```bash
uci set wireless.harmony_mesh.network='harmony'
uci set wireless.harmony_mesh.multicast_to_unicast='0'
uci set wireless.harmony_mesh.powersave='0'
uci commit wireless
wifi reload
```

## Verify the mesh is working

**Note:** OpenWRT assigns kernel interface names automatically (e.g., `wlan1-1`),
not the UCI section name (`harmony_mesh`) or `mesh0`. Find the actual name first:

### Find the mesh interface name

```bash
# Find the kernel interface name for the mesh VIF
MESH_IF=$(iw dev | awk '/Interface/{iface=$2} /type mesh point/{print iface; exit}')
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

## IP-less Transport via rawlink

Once the HARMONY-MESH interface is up and peering (verify with
`iw dev "$MESH_IF" station dump`), you can enable IP-less transport. This sends
Zenoh pub/sub and Reticulum announces as raw Ethernet frames (EtherType `0x88B5`)
directly over the mesh — no DHCP, no ARP, no UDP ports needed for intra-mesh
traffic.

### Enable

```bash
uci set harmony-node.main.rawlink_interface='br-harmony'
uci commit harmony-node
/etc/init.d/harmony-node restart
```

The service is automatically granted `CAP_NET_RAW` via procd capabilities when
`rawlink_interface` is set. No other permission changes are needed.

### Verify

```bash
logread | grep rawlink
```

You should see the AF_PACKET bridge starting on `br-harmony`. Once running, mesh
peers exchange Zenoh data and Reticulum packets at Layer 2 without touching the
IP stack.

### Disable

```bash
uci delete harmony-node.main.rawlink_interface
uci commit harmony-node
/etc/init.d/harmony-node restart
```

The service reverts to unprivileged operation (no `CAP_NET_RAW`) and all mesh
traffic falls back to IP-based transport (UDP 4242, 7446, 4434-4435).

### How it works

The `harmony-rawlink` crate opens an AF_PACKET socket on the specified interface
and runs a bridge loop:

1. **Scout broadcasts** — periodic L2 announcements (frame type `0x01`) advertise
   the node's 128-bit identity hash. Peers populate a local peer table with TTL
   expiry.
2. **Zenoh data frames** — Zenoh pub/sub payloads are wrapped in Ethernet frames
   (frame type `0x02`) and broadcast to all mesh peers. Received frames are
   published into the local Zenoh session.
3. **Reticulum packets** — Reticulum announces and link packets travel as raw
   Ethernet frames (frame type `0x00`), fed into the node's Reticulum event loop.

IP-based transport continues to work in parallel. WAN peers, LAN peers, and iroh
QUIC tunnels all use the existing UDP ports. The rawlink bridge only handles
traffic on the configured interface — it does not affect other network paths.

### Notes

- **Interface name:** Always use the bridge name (`br-harmony`), not the raw
  wireless interface (e.g. `wlan1-1`). The bridge is stable across reboots;
  kernel interface names can change with driver probe order.
- **Firewall:** The rawlink bridge uses EtherType `0x88B5`, not IP ports. The
  existing firewall rules for UDP 4242/7446/4434-4435 are unrelated and remain
  active for IP-based peering.
- **Security:** Raw Ethernet frames are not encrypted at the rawlink layer.
  Security comes from two other layers: SAE encryption on the 802.11s mesh
  (configured in the wireless setup above) and Harmony's end-to-end Reticulum
  encryption (Curve25519 + ML-KEM-768). Both are active regardless of whether
  rawlink is enabled.

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
- **WED hardware offload** — WED is automatically disabled on the mesh radio
  by the auto-config script (`wed='0'`). OpenWrt bug
  [openwrt/openwrt#18703](https://github.com/openwrt/openwrt/issues/18703)
  documents TX collapse to 2-3 Mbps on MT7981/MT7986 with 802.11s mesh when
  WED is active. The NPU cannot accelerate mesh broadcasts anyway, so
  disabling WED costs nothing. If you configured the mesh manually, ensure
  `option wed '0'` is set on the mesh radio in `/etc/config/wireless`.
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
