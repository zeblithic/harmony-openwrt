# Broadcast-Optimized Mesh + PKG_SOURCE_VERSION Update

**Date:** 2026-03-24
**Status:** Draft
**Scope:** `harmony-node/files/`, `harmony-node/Makefile`, `docs/`
**Beads:** harmony-openwrt-ua3, harmony-openwrt-1mv

## Problem

The HARMONY-MESH interface (shipped in PR #6) has `mcast_rate=24000` and
`mesh_fwding=0`, but does not explicitly disable `multicast_to_unicast`.
On some OpenWRT builds, hostapd defaults this to enabled, which converts
each multicast frame into N unicast frames (one per mesh peer). In a
20-node swarm, a single Reticulum announce becomes 19 unicast
transmissions — destroying airtime and defeating the broadcast-friendly
design.

Separately, `PKG_SOURCE_VERSION` in the Makefile still points to
`2fc9f06f`, which predates memo fetch, selective discovery, JCS,
JSON-LD credential import, and tunnel infrastructure.

## Solution

1. Add `multicast_to_unicast='0'` to the mesh VIF configuration
2. Update `PKG_SOURCE_VERSION` to `396f97e9311f4d3df8b0087ad0100af9b05d89a5` (current harmony main)
3. Document the new tuning

## Design Decisions

### Disable multicast_to_unicast on mesh

On AP interfaces, `multicast_to_unicast` improves reliability by
converting multicast to per-station unicast. On the HARMONY-MESH
interface this is counterproductive:

- Reticulum announces are broadcast by design — all peers should hear them
- Zenoh multicast scouting uses UDP multicast (224.0.0.224:7446)
- Bloom filter broadcasts are the core CAS/NDN discovery mechanism
- N unicast frames consume N times the airtime of 1 broadcast frame

With `mcast_rate=24000` already culling weak links, true broadcast is
both efficient and appropriate.

### What is NOT changed

- **DTIM period** — irrelevant once power save is disabled (yw6). Default
  DTIM=2 is fine in the interim.
- **Power save** — separate bead (harmony-openwrt-yw6)
- **RSSI threshold** — separate bead (harmony-openwrt-9bl)
- **Beacon interval** — no benefit for this use case
- **Raw 802.11 frames** — requires harmony core changes (harmony-ajv)

## Upgrade Path

On package upgrade (PKG_RELEASE 1 → 2), the `postinst` script re-runs
`99-harmony-node-setup`. The script detects `wireless.harmony_mesh` is
already present, checks for the missing `multicast_to_unicast` option, and
automatically backfills it with `uci set` + `uci commit wireless` +
`wifi reload`. No manual steps are required for existing installs.

If auto-backfill fails (e.g. commit error), the script exits non-zero
(preserving itself for retry on next boot) and logs an error. As a
fallback, apply manually:

```
uci set wireless.harmony_mesh.multicast_to_unicast='0'
uci commit wireless
wifi reload
```

## Docs Cleanup

The manual config examples in `docs/mesh-wifi-setup.md` use
`mesh_id='harmony'` while auto-config uses `mesh_id='HARMONY-MESH'`.
Since we're touching that file, fix the examples to match auto-config.

## File Changes

| File | Change |
|------|--------|
| `harmony-node/files/harmony-node.uci-defaults` | Add `multicast_to_unicast='0'` to mesh VIF creation |
| `harmony-node/Makefile` | Update `PKG_SOURCE_VERSION` from `2fc9f06f` to `396f97e9311f4d3df8b0087ad0100af9b05d89a5` |
| `docs/mesh-wifi-setup.md` | Document `multicast_to_unicast` in config table, fix mesh_id mismatch |
| `README.md` | Add `multicast_to_unicast=0` to tunings bullet |

## Testing

Manual on hardware:

- `uci get wireless.harmony_mesh.multicast_to_unicast` — verify set to `0`
- `grep multicast_to_unicast /var/run/hostapd-phy*.conf` — verify applied
- Two-node mesh: `tcpdump -i <mesh_if>` — verify announces are broadcast,
  not duplicated as unicast per peer
- `opkg info harmony-node | grep Version` — verify new source version
