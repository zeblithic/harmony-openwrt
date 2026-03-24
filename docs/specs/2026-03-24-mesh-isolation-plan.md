# Mesh Isolation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Isolate the HARMONY-MESH WiFi from br-lan by creating a dedicated bridge, network, DHCP pool, and firewall zone so mesh peers can only reach harmony-node, not the full LAN.

**Architecture:** The uci-defaults script creates a `harmony` network with bridge device, static IP (10.73.0.1/24), dnsmasq DHCP pool, and a REJECT-by-default firewall zone with specific ACCEPT rules for Harmony ports + DNS + DHCP. The mesh VIF's `network` changes from `'lan'` to `'harmony'`. A backfill block handles upgrades from pre-isolation installs.

**Tech Stack:** OpenWRT UCI, shell scripting, nftables/iptables firewall zones

**Spec:** `docs/specs/2026-03-24-mesh-isolation-design.md`

**Bead:** harmony-openwrt-979

---

### Task 1: Create feature branch

**Files:** None (git operation)

- [ ] **Step 1: Create and push feature branch**

```bash
cd /Users/zeblith/work/zeblithic/harmony-openwrt
git checkout main && git pull
git checkout -b jake-openwrt-mesh-isolation
git push -u origin jake-openwrt-mesh-isolation
```

---

### Task 2: Add harmony network/DHCP/firewall zone creation to uci-defaults (fresh install path)

**Files:**
- Modify: `harmony-node/files/harmony-node.uci-defaults`

This task adds a new function `setup_harmony_network()` and calls it from the fresh-install path, before the mesh VIF is created. It also changes `network='lan'` to `network='harmony'` in the VIF creation.

- [ ] **Step 1: Add the network setup helper function**

After the `TAG="harmony-node"` line (line 12), add a shell function that creates the harmony network infrastructure. This function is idempotent — it checks before creating each component.

```sh
# ── Harmony network infrastructure ──────────────────────────────────────
# Creates the dedicated harmony bridge, network interface, DHCP pool,
# and firewall zone. Idempotent — skips components that already exist.
setup_harmony_network() {
  # Read the Reticulum port from UCI config; fall back to 4242.
  HARMONY_PORT=$(uci -q get harmony-node.main.listen_address | sed 's/.*://')
  case "$HARMONY_PORT" in
    ''|*[!0-9]*) HARMONY_PORT=4242 ;;
    *)
      [ "$HARMONY_PORT" -lt 1 ] 2>/dev/null && HARMONY_PORT=4242
      [ "$HARMONY_PORT" -gt 65535 ] 2>/dev/null && HARMONY_PORT=4242
      ;;
  esac

  CREATED=""

  # Bridge device (OpenWRT 21.02+ DSA)
  if [ -z "$(uci -q get network.br_harmony)" ]; then
    uci set network.br_harmony=device
    uci set network.br_harmony.type='bridge'
    uci set network.br_harmony.name='br-harmony'
    CREATED="$CREATED bridge"
  fi

  # Network interface
  if [ -z "$(uci -q get network.harmony)" ]; then
    uci set network.harmony=interface
    uci set network.harmony.device='br-harmony'
    uci set network.harmony.proto='static'
    uci set network.harmony.ipaddr='10.73.0.1'
    uci set network.harmony.netmask='255.255.255.0'
    CREATED="$CREATED network"
  fi

  # DHCP pool
  if [ -z "$(uci -q get dhcp.harmony)" ]; then
    uci set dhcp.harmony=dhcp
    uci set dhcp.harmony.interface='harmony'
    uci set dhcp.harmony.start='100'
    uci set dhcp.harmony.limit='100'
    uci set dhcp.harmony.leasetime='1h'
    CREATED="$CREATED dhcp"
  fi

  # Firewall zone
  if [ -z "$(uci -q get firewall.harmony_zone)" ]; then
    uci set firewall.harmony_zone=zone
    uci set firewall.harmony_zone.name='harmony'
    uci set firewall.harmony_zone.network='harmony'
    uci set firewall.harmony_zone.input='REJECT'
    uci set firewall.harmony_zone.output='ACCEPT'
    uci set firewall.harmony_zone.forward='REJECT'
    CREATED="$CREATED zone"
  fi

  # Firewall rules — Harmony protocol ports
  if [ -z "$(uci -q get firewall.harmony_reticulum)" ]; then
    uci set firewall.harmony_reticulum=rule
    uci set firewall.harmony_reticulum.name='Harmony-Reticulum'
    uci set firewall.harmony_reticulum.src='harmony'
    uci set firewall.harmony_reticulum.proto='udp'
    uci set firewall.harmony_reticulum.dest_port="$HARMONY_PORT"
    uci set firewall.harmony_reticulum.target='ACCEPT'
    CREATED="$CREATED reticulum-rule"
  fi

  if [ -z "$(uci -q get firewall.harmony_zenoh)" ]; then
    uci set firewall.harmony_zenoh=rule
    uci set firewall.harmony_zenoh.name='Harmony-Zenoh'
    uci set firewall.harmony_zenoh.src='harmony'
    uci set firewall.harmony_zenoh.proto='udp'
    uci set firewall.harmony_zenoh.dest_port='7446'
    uci set firewall.harmony_zenoh.target='ACCEPT'
    CREATED="$CREATED zenoh-rule"
  fi

  if [ -z "$(uci -q get firewall.harmony_iroh)" ]; then
    uci set firewall.harmony_iroh=rule
    uci set firewall.harmony_iroh.name='Harmony-iroh'
    uci set firewall.harmony_iroh.src='harmony'
    uci set firewall.harmony_iroh.proto='udp'
    uci set firewall.harmony_iroh.dest_port='4434-4435'
    uci set firewall.harmony_iroh.target='ACCEPT'
    CREATED="$CREATED iroh-rule"
  fi

  # DNS — mesh peers need name resolution (e.g., iroh relay lookups)
  if [ -z "$(uci -q get firewall.harmony_dns)" ]; then
    uci set firewall.harmony_dns=rule
    uci set firewall.harmony_dns.name='Harmony-DNS'
    uci set firewall.harmony_dns.src='harmony'
    uci set firewall.harmony_dns.proto='tcpudp'
    uci set firewall.harmony_dns.dest_port='53'
    uci set firewall.harmony_dns.target='ACCEPT'
    CREATED="$CREATED dns-rule"
  fi

  # DHCP — allow DHCP requests from mesh peers
  if [ -z "$(uci -q get firewall.harmony_dhcp)" ]; then
    uci set firewall.harmony_dhcp=rule
    uci set firewall.harmony_dhcp.name='Harmony-DHCP'
    uci set firewall.harmony_dhcp.src='harmony'
    uci set firewall.harmony_dhcp.proto='udp'
    uci set firewall.harmony_dhcp.dest_port='67'
    uci set firewall.harmony_dhcp.target='ACCEPT'
    CREATED="$CREATED dhcp-rule"
  fi

  if [ -n "$CREATED" ]; then
    # Commit all subsystems that were touched
    uci commit network 2>/dev/null
    uci commit dhcp 2>/dev/null
    uci commit firewall 2>/dev/null
    logger -t "$TAG" "harmony network infrastructure created:$CREATED"
  fi
}
```

- [ ] **Step 2: Call setup_harmony_network before mesh VIF creation**

Find the line `# ── Create the mesh VIF` (line 112) and add a call before it:

```sh
# ── Create the harmony network infrastructure ───────────────────────────
setup_harmony_network
```

- [ ] **Step 3: Change network='lan' to network='harmony' in VIF creation**

Change line 118 from:
```sh
uci set wireless.harmony_mesh.network='lan'
```
To:
```sh
uci set wireless.harmony_mesh.network='harmony'
```

- [ ] **Step 4: Add service reloads after wifi reload**

After the wifi reload if-block (the one ending with `logger -t "$TAG" "WARNING: wifi reload failed..."`), add network and firewall reloads so the new bridge, DHCP, and zone take effect. Note: `network reload` triggers dnsmasq to pick up the new DHCP pool via procd.

```sh
# Reload network and firewall for the harmony zone/bridge.
[ -x /etc/init.d/network ] && /etc/init.d/network reload
[ -x /etc/init.d/firewall ] && /etc/init.d/firewall reload
```

- [ ] **Step 5: Verify syntax**

```bash
sh -n harmony-node/files/harmony-node.uci-defaults
```
Expected: no output (success).

- [ ] **Step 6: Commit**

```bash
git add harmony-node/files/harmony-node.uci-defaults
git commit -m "feat: isolate HARMONY-MESH with dedicated network/firewall zone

Create br-harmony bridge, 10.73.0.1/24 network, DHCP pool, and
REJECT-by-default firewall zone with ACCEPT rules for Harmony
protocol ports (Reticulum, Zenoh, iroh) plus DNS and DHCP.

Mesh VIF now uses network='harmony' instead of 'lan'. Mesh peers
can reach harmony-node on the router but not the LAN."
```

---

### Task 3: Add isolation backfill for existing installations

**Files:**
- Modify: `harmony-node/files/harmony-node.uci-defaults` (backfill block, lines 28-58)

This task adds a backfill inside the existing `wireless.harmony_mesh already configured` block that creates the harmony network infrastructure and migrates the VIF from `network='lan'` to `network='harmony'`.

- [ ] **Step 1: Add isolation backfill inside the existing backfill block**

Inside the `if [ -n "$(uci -q get wireless.harmony_mesh)" ]` block, insert the following code **immediately before the `exit 0`** line (which is the last line of the block). It goes after the closing `fi` of the existing BACKFILL commit/reload section. The surrounding context looks like:

```sh
    fi   # ← end of "if [ -n "$BACKFILL" ]" block
  fi     # ← end of powersave backfill check
  # >>> INSERT NEW CODE HERE <<<
  exit 0
fi
```

Add:

```sh
  # ── Isolation backfill: migrate mesh VIF from br-lan to br-harmony ──
  if [ -z "$(uci -q get network.harmony)" ]; then
    logger -t "$TAG" "backfilling harmony network isolation"
    setup_harmony_network

    # Migrate the mesh VIF from lan to harmony
    if uci set wireless.harmony_mesh.network='harmony'; then
      if uci commit wireless; then
        logger -t "$TAG" "migrated wireless.harmony_mesh.network to harmony"
        [ -x /sbin/wifi ] && wifi reload 2>/tmp/harmony-wifi-reload.err
        [ -x /etc/init.d/network ] && /etc/init.d/network reload
        [ -x /etc/init.d/firewall ] && /etc/init.d/firewall reload
      else
        logger -t "$TAG" "ERROR: uci commit wireless failed during isolation backfill"
        exit 1
      fi
    else
      logger -t "$TAG" "ERROR: uci set network='harmony' failed during isolation backfill"
      exit 1
    fi
  fi
```

- [ ] **Step 2: Verify syntax**

```bash
sh -n harmony-node/files/harmony-node.uci-defaults
```

- [ ] **Step 3: Commit**

```bash
git add harmony-node/files/harmony-node.uci-defaults
git commit -m "feat: backfill mesh isolation for upgrades from pre-isolation installs

Creates harmony network infrastructure and migrates
wireless.harmony_mesh.network from 'lan' to 'harmony' on upgrade.
Runs inside the existing backfill block before exit 0."
```

---

### Task 4: Update postrm to clean up harmony network infrastructure

**Files:**
- Modify: `harmony-node/Makefile` (postrm section, lines 120-147)

- [ ] **Step 1: Rewrite postrm to consolidate all cleanup**

Replace the entire postrm body (between `#!/bin/sh` and `exit 0`) with consolidated cleanup that does all firewall deletions together, then commits each subsystem once:

```sh
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] && exit 0
# Only clean up on full removal, not on upgrade.
case "$$1" in
  upgrade) exit 0 ;;
esac
rm -rf /etc/harmony
# Remove all harmony UCI configuration.
# Firewall: include + zone + all port rules
uci -q delete firewall.harmony_node
uci -q delete firewall.harmony_reticulum
uci -q delete firewall.harmony_zenoh
uci -q delete firewall.harmony_iroh
uci -q delete firewall.harmony_dns
uci -q delete firewall.harmony_dhcp
uci -q delete firewall.harmony_zone
uci commit firewall 2>/dev/null
[ -x /etc/init.d/firewall ] && /etc/init.d/firewall reload
# Wireless: mesh VIF
if [ -n "$$(uci -q get wireless.harmony_mesh)" ]; then
  uci delete wireless.harmony_mesh
  if uci commit wireless; then
    [ -x /sbin/wifi ] && wifi reload
  else
    logger -t "harmony-node" "WARNING: uci commit wireless failed during removal — harmony_mesh may persist"
  fi
fi
# Network: bridge device + interface; DHCP pool
uci -q delete dhcp.harmony
uci -q delete network.harmony
uci -q delete network.br_harmony
uci commit dhcp 2>/dev/null
uci commit network 2>/dev/null
[ -x /etc/init.d/network ] && /etc/init.d/network reload
exit 0
```

This consolidates all firewall deletions into a single commit+reload (was two separate blocks).

- [ ] **Step 2: Bump PKG_RELEASE**

Change line 5 of `harmony-node/Makefile` from `PKG_RELEASE:=3` to `PKG_RELEASE:=4`.

- [ ] **Step 3: Commit**

```bash
git add harmony-node/Makefile
git commit -m "feat: clean up harmony network on removal, bump PKG_RELEASE

postrm now deletes network.harmony, dhcp.harmony, firewall.harmony_zone,
and all firewall.harmony_* rules on full package removal.
PKG_RELEASE 3→4 for opkg upgrade path."
```

---

### Task 5: Update documentation

**Files:**
- Modify: `docs/mesh-wifi-setup.md`
- Modify: `README.md`

- [ ] **Step 1: Update README security note**

Find the security note paragraph (starts with `**Security note:**`) and replace it with:

```markdown
**Network isolation:** The mesh VIF runs on a dedicated `br-harmony` bridge
(`10.73.0.0/24`), isolated from `br-lan`. Mesh peers can reach harmony-node
on the router (UDP 4242, 7446, 4434-4435) but cannot access LAN devices,
the router admin UI, or forward traffic to WAN.
```

- [ ] **Step 2: Update docs/mesh-wifi-setup.md network references**

Find all `option network 'lan'` references in config examples and UCI command examples and change to `option network 'harmony'` / `uci set wireless.harmony_mesh.network='harmony'`.

Update the interface options table row for `network` from:
```
| `network 'lan'` | Bridge to LAN | Mesh traffic visible to harmony-node on the LAN bridge |
```
To:
```
| `network 'harmony'` | Dedicated mesh bridge | Mesh traffic isolated from LAN — harmony-node sees both bridges |
```

- [ ] **Step 3: Update auto-config note block in mesh-wifi-setup.md**

The note block near the top that lists tunings — add a mention of network isolation.

- [ ] **Step 4: Update the upgrade path section**

Add the network migration to the upgrade path section, noting it happens automatically via backfill.

- [ ] **Step 5: Commit**

```bash
git add docs/mesh-wifi-setup.md README.md
git commit -m "docs: update for mesh network isolation

- Replace security note with network isolation description
- Change network='lan' to 'harmony' in all config examples
- Update interface options table
- Document automatic upgrade migration"
```

---

### Task 6: Push and create PR

**Files:** None (git operations)

- [ ] **Step 1: Push branch**

```bash
git push
```

- [ ] **Step 2: Create PR**

```bash
gh pr create --title "feat: isolate HARMONY-MESH from br-lan with dedicated network zone" --body "$(cat <<'EOF'
## Summary
- Create dedicated `br-harmony` bridge, `10.73.0.1/24` network, DHCP pool (100-199), and firewall zone
- Firewall zone: REJECT by default, ACCEPT for Harmony ports (UDP 4242/7446/4434-4435) + DNS + DHCP
- Mesh VIF `network` changed from `'lan'` to `'harmony'` — peers isolated from LAN
- Backfill migrates existing installs automatically on upgrade
- postrm cleans up all harmony network infrastructure on removal

## Bead
- Closes harmony-openwrt-979 (isolate HARMONY-MESH from br-lan)

## Test plan
**Positive:**
- [ ] `uci get network.harmony.ipaddr` → `10.73.0.1`
- [ ] `uci get wireless.harmony_mesh.network` → `harmony`
- [ ] `uci get firewall.harmony_zone.name` → `harmony`
- [ ] Mesh peer gets DHCP in `10.73.0.x` range
- [ ] Mesh peer can reach `10.73.0.1:4242` (harmony-node)
- [ ] Mesh peer DNS works (`nslookup example.com 10.73.0.1`)

**Negative:**
- [ ] Mesh peer cannot reach `192.168.1.1` (router LAN UI)
- [ ] Mesh peer cannot ping LAN devices
- [ ] Zenoh scouting from mesh does NOT discover LAN-only peers

**Upgrade:**
- [ ] Install pre-isolation build, upgrade → backfill creates zone + migrates VIF

**Removal:**
- [ ] `opkg remove harmony-node` → all harmony_* UCI sections removed

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```
