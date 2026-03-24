# Auto-Join HARMONY-MESH + Firewall-Free WAN

**Date:** 2026-03-24
**Status:** Draft
**Scope:** `harmony-node/files/` (uci-defaults, firewall, conf)
**Beads:** harmony-openwrt-im5, harmony-openwrt-4jl

## Problem

Installing the harmony-node package on OpenWRT requires manual WiFi mesh
configuration (following a multi-step guide) and manual firewall edits to
allow Harmony traffic from WAN peers. This friction prevents zero-touch
mesh deployment.

## Solution

Auto-configure the 802.11s mesh VIF and open Harmony ports on WAN during
package install, so that installing harmony-node is all a user needs to do
to join the communal Harmony mesh.

## Design Decisions

### Well-known credentials (SSID: HARMONY-MESH, PSK: ZEBLITHIC)

The mesh uses intentionally public credentials. WiFi encryption (SAE/WPA3)
provides defense-in-depth against casual packet injection, but all real
security comes from Harmony's E2E crypto (Reticulum key exchange, ML-KEM,
ML-DSA). Any device knowing the PSK can join — that's the point.

### Auto-detect 5GHz radio with UCI override

The uci-defaults script iterates all radios looking for `band='5g'`. Users
can override with `harmony-node.mesh.radio='radioN'` for edge cases
(tri-band routers, future 6GHz when NO-IR is fixed). If no 5GHz radio
exists, mesh setup is skipped with a syslog warning.

### Bridge to LAN (network='lan')

The mesh VIF joins `br-lan`. Harmony-node listens on `0.0.0.0:4242` and
sees mesh traffic alongside LAN traffic. No harmony-node code changes
needed. Zenoh multicast scouting works across the bridge.

### Skip if already configured

If `wireless.harmony_mesh` UCI section already exists, the script does not
modify it. Respects manual configuration and previous installs.

### Harmony ports open on WAN

With E2E encryption, there is no meaningful trust difference between LAN
and WAN for Harmony traffic. Open the specific Harmony protocol ports on
WAN while keeping everything else firewalled.

## Architecture

### Mesh Auto-Join (uci-defaults)

The `99-harmony-node-setup` script runs on first boot after install:

1. Check `wireless.harmony_mesh` — if exists, skip mesh setup
2. Check `harmony-node.mesh.radio` UCI override — if set, use that radio
3. Otherwise, iterate radios: find first with `band='5g'`
4. If no radio found, log warning via `logger -t harmony-node` and skip
5. Create mesh VIF:
   ```
   wireless.harmony_mesh=wifi-iface
   wireless.harmony_mesh.device='<radio>'
   wireless.harmony_mesh.mode='mesh'
   wireless.harmony_mesh.network='lan'
   wireless.harmony_mesh.mesh_id='HARMONY-MESH'
   wireless.harmony_mesh.encryption='sae'
   wireless.harmony_mesh.key='ZEBLITHIC'
   wireless.harmony_mesh.mesh_fwding='0'
   wireless.harmony_mesh.mcast_rate='24000'
   ```
6. Set radio HE features: `htmode='HE80'` (beamformee enabled by default on HE hardware)
7. `uci commit wireless`
8. Trigger `wifi reload` if wireless subsystem is available

### Firewall (harmony-node.firewall)

Replace the current script (which blocks WAN, allows LAN) with:

**Allowed on both LAN and WAN:**
- UDP 4242 (Reticulum mesh packets)
- UDP 7446 (Zenoh multicast scouting)
- UDP 4434-4435 (iroh-net QUIC tunnels)

**Implementation:** The script auto-detects fw3 (iptables) vs fw4 (nftables)
and applies the rules to both zones. Non-Harmony traffic remains firewalled
on WAN as before.

### UCI Config (harmony-node.conf)

Add a `mesh` section for overrides:

```
config mesh 'mesh'
    option radio ''
    # Empty = auto-detect 5GHz. Set to 'radio0', 'radio1', etc. to override.
```

## File Changes

| File | Change |
|------|--------|
| `harmony-node/files/harmony-node.uci-defaults` | Add mesh VIF auto-config, rename to `99-harmony-node-setup` |
| `harmony-node/files/harmony-node.firewall` | Open Harmony ports on WAN (was: block on WAN) |
| `harmony-node/files/harmony-node.conf` | Add `mesh` config section with `radio` option |
| `harmony-node/Makefile` | Update uci-defaults install path if renamed |
| `docs/mesh-wifi-setup.md` | Add note about auto-config on fresh installs |

## Testing

Since this is OpenWRT configuration (not Rust code), testing is manual
on hardware. Verification steps:

- `uci show wireless.harmony_mesh` — verify mesh VIF was created
- `iw dev` — verify mesh point interface exists
- `nft list chain inet fw4 input_wan` — verify Harmony ports open on WAN
- `logread | grep harmony` — verify no errors, mesh detection logged
- Two devices on same channel — verify they peer via `iw dev <mesh> station dump`
- `harmony-node` on both — verify Reticulum announces cross the mesh

## What is NOT in Scope

- Power save disable (separate bead openwrt-yw6)
- BSS Coloring (separate bead openwrt-a3c)
- Raw Ethernet transport (harmony core bead harmony-ajv)
- Broadcast optimization beyond mcast_rate (separate bead openwrt-ua3)
