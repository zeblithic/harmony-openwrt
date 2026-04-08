# rawlink_interface Documentation

**Date:** 2026-04-08
**Status:** Approved
**Scope:** `README.md`, `docs/mesh-wifi-setup.md`
**Bead:** harmony-openwrt-3rd

## Context

The rawlink UCI plumbing shipped upstream: UCI option (`rawlink_interface`),
TOML generation with IFNAMSIZ validation, `CAP_NET_RAW` via procd capabilities
JSON, Makefile `rawlink` feature flag for both architectures, and 6 test cases
(present, absent, hyphen, injection, IFNAMSIZ, slash). All 32 TOML generation
tests pass.

What remains is documentation that connects the dots for users: how to enable
IP-less Zenoh/Reticulum transport over the 802.11s mesh they've already set up.

## Changes

### 1. README.md — "L2 Transport (IP-less)" section

Insert after "Mesh WiFi (Auto-Configured)" and before "Firewall".

Content:

- **What it does:** The `rawlink_interface` option enables an AF_PACKET bridge
  that sends Zenoh and Reticulum frames directly over raw Ethernet (EtherType
  0x88B5), bypassing the Linux IP stack entirely. Peer discovery uses L2 Scout
  broadcasts instead of UDP multicast.

- **How to enable:** `uci set harmony-node.main.rawlink_interface='br-harmony'`
  followed by `uci commit harmony-node` and service restart. The service is
  automatically granted `CAP_NET_RAW` via procd capabilities when this option
  is set.

- **Interface name:** Use the mesh bridge name (`br-harmony`), not the raw
  wireless interface (`wlan1-1`). The bridge aggregates all mesh VIFs and
  provides a stable name across reboots.

- **Parallel operation:** IP-based peering (UDP 4242, 7446, 4434-4435) continues
  to work alongside rawlink. WAN and LAN peers use IP; intra-mesh peers use L2.
  The node accepts packets from both transports simultaneously.

### 2. mesh-wifi-setup.md — "IP-less Transport via rawlink" section

Insert after "Verify the mesh is working" and before "Band Planning".

Content:

- **Prerequisite:** HARMONY-MESH must be up and peering (verify with
  `iw dev "$MESH_IF" station dump`).

- **Enable:** Point `rawlink_interface` at the mesh bridge:
  ```
  uci set harmony-node.main.rawlink_interface='br-harmony'
  uci commit harmony-node
  /etc/init.d/harmony-node restart
  ```

- **What this means:** Zenoh pub/sub and Reticulum announces travel as raw
  Ethernet frames (EtherType 0x88B5) over the mesh — no DHCP, no ARP, no UDP
  ports needed for intra-mesh traffic. The firewall rules for UDP 4242/7446/
  4434-4435 remain active for IP-based WAN and LAN peering.

- **Verify:** `logread | grep rawlink` should show the AF_PACKET bridge
  starting on the configured interface.

- **Disable:** Remove the option and restart:
  ```
  uci delete harmony-node.main.rawlink_interface
  uci commit harmony-node
  /etc/init.d/harmony-node restart
  ```
  The service reverts to unprivileged operation (no `CAP_NET_RAW`).

## What is NOT in scope

- No code changes (plumbing is complete).
- No test changes (6 rawlink tests already pass).
- No firewall changes (rawlink uses EtherType 0x88B5, not IP ports).
- No changes to `harmony-rawlink` crate or `harmony-node`.
