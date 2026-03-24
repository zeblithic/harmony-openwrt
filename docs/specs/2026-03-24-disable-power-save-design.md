# Disable Power Save on HARMONY-MESH

**Date:** 2026-03-24
**Status:** Draft
**Scope:** `harmony-node/files/`, `harmony-node/Makefile`, `docs/`
**Bead:** harmony-openwrt-yw6

## Problem

802.11 power management causes stations to doze between beacons. The
AP/mesh buffers multicast frames and releases them only at DTIM intervals.
For always-on mesh routers, this adds unnecessary latency to Reticulum
announces and Zenoh scouting broadcasts. Power save is designed for
battery devices — routers are always plugged in.

## Solution

Add `powersave='0'` to the HARMONY-MESH VIF configuration in the
uci-defaults script, with a backfill check for existing installations
(same pattern as `multicast_to_unicast`).

## Design Decisions

### UCI powersave vs iw runtime command

Using UCI `powersave='0'` rather than `iw dev <iface> set power_save off`
because:

- Declarative — applied at `wifi reload` time, survives reboots
- No need to discover the dynamic kernel interface name (e.g., `wlan1-1`)
- Consistent with all other mesh VIF settings in the script

### Backfill for existing installations

The uci-defaults script skips mesh VIF creation if `wireless.harmony_mesh`
exists. A backfill block inside the early-exit guard checks for the missing
option and applies it, with `wifi reload` and error handling (exit 1 on
commit failure to preserve script for retry). Same pattern shipped for
`multicast_to_unicast` in PR #7.

### PKG_RELEASE bump

Increment 2 → 3 so `opkg upgrade` offers the new build to existing installs,
triggering the `postinst` → uci-defaults → backfill path.

### What is NOT changed

- **DTIM period** — irrelevant with power save off (no stations buffering)
- **AP interface power save** — only the mesh VIF is affected

## File Changes

| File | Change |
|------|--------|
| `harmony-node/files/harmony-node.uci-defaults` | Add `powersave='0'` in VIF creation block + backfill |
| `harmony-node/Makefile` | Bump `PKG_RELEASE` 2 → 3 |
| `docs/mesh-wifi-setup.md` | Add `powersave` to config stanza, UCI commands, config table, upgrade path |
| `README.md` | Add `powersave=0` to tunings bullet |

## Testing

Manual on hardware:

- `uci get wireless.harmony_mesh.powersave` — verify set to `0`
- `iw dev <mesh_if> get power_save` — verify `Power save: off`
- Upgrade path: install PR #7 build first, then upgrade — verify backfill logs
