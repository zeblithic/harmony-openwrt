# rawlink_interface Documentation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Document how to enable IP-less Zenoh/Reticulum transport over the 802.11s mesh using the rawlink_interface UCI option.

**Architecture:** Two doc edits — a high-level section in README.md and a hands-on howto in mesh-wifi-setup.md. No code or test changes.

**Tech Stack:** Markdown

---

### Task 1: README.md — Add "L2 Transport (IP-less)" section

**Files:**
- Modify: `README.md:136-138` (insert new section between the end of "Mesh WiFi" and "## Firewall")

- [ ] **Step 1: Insert the L2 Transport section**

In `README.md`, insert the following block immediately before the `## Firewall` heading (currently line 138). The preceding line 136 is `**[docs/mesh-wifi-setup.md](docs/mesh-wifi-setup.md)**.` followed by a blank line 137.

````markdown
## L2 Transport (IP-less)

The `rawlink_interface` UCI option enables an AF_PACKET bridge that sends Zenoh
and Reticulum frames directly over raw Ethernet (EtherType `0x88B5`), bypassing
the Linux IP stack entirely. Peer discovery uses L2 Scout broadcasts instead of
UDP multicast.

To enable L2 transport on the mesh bridge:

```bash
uci set harmony-node.main.rawlink_interface='br-harmony'
uci commit harmony-node
/etc/init.d/harmony-node restart
```

When `rawlink_interface` is set, the service is automatically granted `CAP_NET_RAW`
via procd capabilities — no manual permission changes needed.

**Which interface name?** Use the mesh bridge (`br-harmony`), not the raw wireless
interface (e.g. `wlan1-1`). The bridge provides a stable name across reboots and
aggregates all mesh VIFs.

**Parallel operation:** IP-based peering (UDP 4242, 7446, 4434-4435) continues to
work alongside L2 transport. WAN and LAN peers connect over IP; intra-mesh peers
use L2 frames. The node accepts traffic from both transports simultaneously.

For a step-by-step setup guide, see
**[docs/mesh-wifi-setup.md](docs/mesh-wifi-setup.md#ip-less-transport-via-rawlink)**.

````

- [ ] **Step 2: Verify the README renders correctly**

Visually scan the file to confirm:
- The new section appears between "Mesh WiFi (Auto-Configured)" and "Firewall"
- The code block is fenced correctly
- The link to mesh-wifi-setup.md uses an anchor that matches the heading in Task 2

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: add L2 Transport (IP-less) section to README"
```

---

### Task 2: mesh-wifi-setup.md — Add "IP-less Transport via rawlink" section

**Files:**
- Modify: `docs/mesh-wifi-setup.md:244-246` (insert new section between "Verify the mesh is working" and "## Band Planning")

- [ ] **Step 1: Insert the IP-less Transport section**

In `docs/mesh-wifi-setup.md`, insert the following block immediately before the `## Band Planning` heading (currently line 246). The preceding line is the end of the "Check Harmony sees the mesh traffic" subsection.

````markdown
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

````

- [ ] **Step 2: Verify the anchor matches the README link**

Confirm the heading `## IP-less Transport via rawlink` produces the anchor
`#ip-less-transport-via-rawlink`, which matches the link added in Task 1.

- [ ] **Step 3: Commit**

```bash
git add docs/mesh-wifi-setup.md
git commit -m "docs: add IP-less transport via rawlink section to mesh WiFi guide"
```
