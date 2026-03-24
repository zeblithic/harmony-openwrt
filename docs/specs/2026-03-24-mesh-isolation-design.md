# Isolate HARMONY-MESH from br-lan

**Date:** 2026-03-24
**Status:** Draft
**Scope:** `harmony-node/files/`, `harmony-node/Makefile`
**Bead:** harmony-openwrt-979

## Problem

The HARMONY-MESH VIF bridges to `br-lan` (`network='lan'`). Any device
with the well-known PSK (`ZEBLITHIC`) gets full L2 LAN access — router
admin UI, NAS, printers, IoT devices. Harmony's E2E encryption protects
Harmony traffic, but non-Harmony LAN services are fully exposed.

## Solution

Create a dedicated `harmony` network with its own bridge, subnet, DHCP
pool, and firewall zone. Mesh peers are isolated from LAN — they can
only reach harmony-node on the router itself.

## Network Architecture

```
Router (dual-homed):
  192.168.1.1 on br-lan       10.73.0.1 on br-harmony
       │                            │
br-lan (192.168.1.0/24)      br-harmony (10.73.0.0/24)
  ├── eth0 (LAN ports)         └── wlan1-1 (HARMONY-MESH VIF)
  ├── wlan0 (2.4GHz AP)
  └── wlan1 (5GHz AP)

harmony-node listens on 0.0.0.0:4242 → sees both bridges
Acts as Reticulum routing bridge between mesh and LAN.
```

No harmony-node code changes needed — `0.0.0.0` binding covers both
bridges. The router is dual-homed: it has IPs on both subnets and
routes Reticulum announces between them at the application layer.

## Design Decisions

### Firewall: INPUT rules, not FORWARD

Mesh peers only need to reach the router's own daemons (harmony-node,
Zenoh), not forward through to LAN devices. The `harmony` zone:

- INPUT: REJECT by default, ACCEPT for Harmony ports + DHCP + DNS
- FORWARD: REJECT (no traffic to lan/wan zones)
- OUTPUT: ACCEPT

This is simpler and more secure than inter-zone forwarding with port
filters.

### Bridge device configuration (OpenWRT 21.02+ DSA)

Modern OpenWRT requires an explicit bridge device definition. The
wireless subsystem attaches the mesh VIF to the bridge when
`wireless.harmony_mesh.network='harmony'`, but the bridge device
itself must be declared:

```
config device 'br_harmony'
    option type 'bridge'
    option name 'br-harmony'

config interface 'harmony'
    option device 'br-harmony'
    option proto 'static'
    ...
```

Without this, the interface may fail to come up on OpenWRT 22.03+.

### DHCP on the mesh bridge

The router runs dnsmasq on `br-harmony` handing out `10.73.0.100–199`
with 1-hour leases. Mesh peers get IPs automatically — consistent with
the zero-touch philosophy. `10.73.0.0/24` is unlikely to collide with
typical LAN ranges. (`73` = ASCII `H` for Harmony.)

### DNS for mesh peers

Mesh peers receive the router as their DNS server via DHCP. The firewall
zone allows DNS (UDP/TCP 53) so mesh peers can resolve hostnames. This
is needed for basic network operation (e.g., iroh relay lookups).

### Multicast isolated per zone

Zenoh multicast scouting (224.0.0.224:7446) stays isolated to each
bridge. Mesh peers discover each other on `br-harmony`, LAN clients
discover each other on `br-lan`. The router sees both. Reticulum's
announce propagation handles cross-network content discovery — no
multicast relay needed.

### Firewall include unchanged

The `harmony-node.firewall` script currently adds rules to `input_lan`
and `input_wan`. The dedicated `harmony` zone handles its own INPUT
rules via zone-level firewall rules. The include does not need to
touch the harmony zone.

For fw4 (nftables), the zone creates `input_harmony` chain automatically.

### Dynamic Reticulum port

The firewall include reads the Reticulum port from
`harmony-node.main.listen_address` (defaulting to 4242). The zone-level
firewall rules also use this dynamic port — the uci-defaults script
reads it at setup time and applies it to the zone rule. If the user
later changes the port, they must update the zone rule manually (or
reinstall the package). This matches the existing behavior where the
firewall include bakes in the port at reload time.

### Backfill for existing installations

The backfill runs inside the existing `wireless.harmony_mesh already
configured` block in the uci-defaults script (before the `exit 0`),
alongside the existing `multicast_to_unicast` and `powersave` backfills.

It triggers when `wireless.harmony_mesh` exists but `network.harmony`
does not (upgrade from pre-isolation install):

1. Create bridge device, network interface, DHCP pool
2. Create firewall zone and port rules
3. Change `wireless.harmony_mesh.network` from `'lan'` to `'harmony'`
4. Commit network + dhcp + firewall + wireless
5. Reload wifi + network + firewall

### Fresh install path

On fresh install, the VIF creation block sets `network='harmony'`
directly (not `'lan'`). The network/DHCP/firewall zone are created
before the VIF, so the bridge is ready when `wifi reload` runs.

## UCI Configuration

### Bridge device (OpenWRT 21.02+ DSA)

```
config device 'br_harmony'
    option type 'bridge'
    option name 'br-harmony'
```

### Network interface

```
config interface 'harmony'
    option device 'br-harmony'
    option proto 'static'
    option ipaddr '10.73.0.1'
    option netmask '255.255.255.0'
```

### DHCP pool

```
config dhcp 'harmony'
    option interface 'harmony'
    option start '100'
    option limit '100'
    option leasetime '1h'
```

### Firewall zone

```
config zone 'harmony_zone'
    option name 'harmony'
    option network 'harmony'
    option input 'REJECT'
    option output 'ACCEPT'
    option forward 'REJECT'
```

### Firewall rules (Harmony ports + services on harmony zone)

```
config rule 'harmony_reticulum'
    option name 'Harmony-Reticulum'
    option src 'harmony'
    option proto 'udp'
    option dest_port '<dynamic from listen_address, default 4242>'
    option target 'ACCEPT'

config rule 'harmony_zenoh'
    option name 'Harmony-Zenoh'
    option src 'harmony'
    option proto 'udp'
    option dest_port '7446'
    option target 'ACCEPT'

config rule 'harmony_iroh'
    option name 'Harmony-iroh'
    option src 'harmony'
    option proto 'udp'
    option dest_port '4434-4435'
    option target 'ACCEPT'

config rule 'harmony_dns'
    option name 'Harmony-DNS'
    option src 'harmony'
    option proto 'tcpudp'
    option dest_port '53'
    option target 'ACCEPT'

config rule 'harmony_dhcp'
    option name 'Harmony-DHCP'
    option src 'harmony'
    option proto 'udp'
    option dest_port '67'
    option target 'ACCEPT'
```

### Mesh VIF change

```
wireless.harmony_mesh.network='harmony'  (was 'lan')
```

## File Changes

| File | Change |
|------|--------|
| `harmony-node/files/harmony-node.uci-defaults` | Create harmony bridge/network/DHCP/firewall zone; set mesh VIF `network='harmony'`; backfill for upgrades (inside existing backfill block) |
| `harmony-node/Makefile` | Bump `PKG_RELEASE` (current + 1); update `postrm` to clean up `network.harmony`, `dhcp.harmony`, `firewall.harmony_zone`, and all `firewall.harmony_*` rules |
| `docs/mesh-wifi-setup.md` | Update `network='lan'` references to `'harmony'`; document zone architecture |
| `README.md` | Update security note (mesh peers now isolated from LAN) |

## Testing

Manual on hardware:

**Positive (mesh peer can reach Harmony services):**
- `uci get network.harmony.ipaddr` → `10.73.0.1`
- `uci get wireless.harmony_mesh.network` → `harmony`
- `uci get firewall.harmony_zone.name` → `harmony`
- From mesh peer: DHCP lease received in `10.73.0.x` range
- From mesh peer: DNS resolution works (`nslookup example.com 10.73.0.1`)
- From mesh peer: can reach `10.73.0.1:4242` (harmony-node)

**Negative (mesh peer cannot reach LAN):**
- From mesh peer: cannot reach `192.168.1.1` (router LAN UI)
- From mesh peer: cannot ping any device on `192.168.1.0/24`
- From mesh peer: Zenoh scouting does NOT discover LAN-only peers

**Upgrade path:**
- Install pre-isolation build, upgrade, verify backfill creates zone
- Verify `wireless.harmony_mesh.network` changed from `lan` to `harmony`
- `logread | grep harmony` → backfill logged, no errors

**Removal:**
- `opkg remove harmony-node` → verify `network.harmony`, `dhcp.harmony`,
  `firewall.harmony_zone`, and all `firewall.harmony_*` rules removed
