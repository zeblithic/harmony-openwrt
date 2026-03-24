# Broadcast-Optimized Mesh + PKG_SOURCE_VERSION Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Disable multicast-to-unicast conversion on the HARMONY-MESH VIF, update PKG_SOURCE_VERSION to latest harmony main, and fix docs inconsistencies.

**Architecture:** Shell script config changes (uci-defaults), one Makefile hash update, and documentation updates. No Rust code. No automated tests — manual hardware verification only.

**Tech Stack:** OpenWRT UCI, shell scripting, Makefile

**Spec:** `docs/specs/2026-03-24-broadcast-optimized-mesh-design.md`

**Beads:** harmony-openwrt-ua3, harmony-openwrt-1mv

---

### Task 1: Create feature branch

**Files:** None (git operation)

- [ ] **Step 1: Create and push feature branch**

```bash
cd /Users/zeblith/work/zeblithic/harmony-openwrt
git checkout main
git pull
git checkout -b jake-openwrt-broadcast-opt
git push -u origin jake-openwrt-broadcast-opt
```

---

### Task 2: Add multicast_to_unicast='0' to mesh VIF

**Files:**
- Modify: `harmony-node/files/harmony-node.uci-defaults:95` (add one line after `mcast_rate`)

- [ ] **Step 1: Add the uci set line**

After line 95 (`uci set wireless.harmony_mesh.mcast_rate='24000'`), add:

```sh
uci set wireless.harmony_mesh.multicast_to_unicast='0'
```

This goes in the mesh VIF creation block alongside the other `uci set wireless.harmony_mesh.*` calls.

- [ ] **Step 2: Verify the script is syntactically valid**

```bash
sh -n harmony-node/files/harmony-node.uci-defaults
```

Expected: no output (success).

- [ ] **Step 3: Commit**

```bash
git add harmony-node/files/harmony-node.uci-defaults
git commit -m "feat: disable multicast_to_unicast on HARMONY-MESH VIF

Prevents hostapd from converting each multicast frame into N unicast
frames (one per mesh peer). In a 20-node swarm, a single Reticulum
announce would become 19 unicast transmissions — destroying airtime.
True broadcast is both efficient and appropriate for CAS/NDN traffic."
```

---

### Task 3: Update PKG_SOURCE_VERSION

**Files:**
- Modify: `harmony-node/Makefile:9`

- [ ] **Step 1: Update the commit hash**

Change line 9 from:

```makefile
PKG_SOURCE_VERSION:=2fc9f06fc1af424b1271e505677055016c18359c
```

To:

```makefile
PKG_SOURCE_VERSION:=396f97e9311f4d3df8b0087ad0100af9b05d89a5
```

- [ ] **Step 2: Commit**

```bash
git add harmony-node/Makefile
git commit -m "chore: update PKG_SOURCE_VERSION to latest harmony main

Picks up memo fetch orchestration, selective discovery opt-in,
RFC 8785 JCS canonicalization, W3C JSON-LD credential import,
and tunnel infrastructure from recent harmony core PRs."
```

---

### Task 4: Fix mesh_id mismatch and add multicast_to_unicast to docs

**Files:**
- Modify: `docs/mesh-wifi-setup.md` (mesh_id, key, multicast_to_unicast, auto-config note, upgrade path)
- Modify: `README.md:109` (add multicast_to_unicast to tunings bullet)

**Note:** All line numbers below refer to the original file. Match by content string, not line number, since earlier edits shift lines.

- [ ] **Step 1: Update auto-config note block (docs/mesh-wifi-setup.md)**

Find the line containing `(mesh_fwding=0, mcast_rate=24000).` (near line 6) and change to:
```
> and applies all recommended tunings (mesh_fwding=0, mcast_rate=24000, multicast_to_unicast=0).
```

- [ ] **Step 2: Fix mesh_id and key in config stanza (docs/mesh-wifi-setup.md)**

Find `option mesh_id 'harmony'` (near line 104) → change to `option mesh_id 'HARMONY-MESH'`
Find `option key 'YourMeshKey'` (near line 106) → change to `option key 'ZEBLITHIC'`

Add after the `option mcast_rate '24000'` line:
```
    option multicast_to_unicast '0'
```

- [ ] **Step 3: Fix mesh_id and key in UCI commands section (docs/mesh-wifi-setup.md)**

Find `uci set wireless.harmony_mesh.mesh_id='harmony'` → change to `uci set wireless.harmony_mesh.mesh_id='HARMONY-MESH'`
Find `uci set wireless.harmony_mesh.key='YourMeshKey'` → change to `uci set wireless.harmony_mesh.key='ZEBLITHIC'`

Add after the `uci set wireless.harmony_mesh.mcast_rate='24000'` line:
```bash
uci set wireless.harmony_mesh.multicast_to_unicast='0'
```

- [ ] **Step 4: Fix mesh_id in config table and add multicast_to_unicast row (docs/mesh-wifi-setup.md)**

Find `| \`mesh_id 'harmony'\`` in the interface options table → change to `| \`mesh_id 'HARMONY-MESH'\` | Mesh network name | Well-known communal mesh — all Harmony nodes must use the same mesh_id |`

Add a new row after the `mcast_rate` row:
```
| `multicast_to_unicast '0'` | **Disable mcast→unicast** | Prevents N×airtime from per-peer unicast conversion |
```

- [ ] **Step 5: Add upgrade path note (docs/mesh-wifi-setup.md)**

Add a new subsection after the "Configuration Explained" section (after the interface options table):

```markdown
### Upgrading from earlier versions

If you installed harmony-node before `multicast_to_unicast` was added to the
auto-config, apply it manually:

\`\`\`bash
uci set wireless.harmony_mesh.multicast_to_unicast='0'
uci commit wireless
wifi reload
\`\`\`
```

- [ ] **Step 6: Update README tunings bullet (README.md)**

Find the tunings line and change to:
```
- **Tunings:** `mesh_fwding=0` (Reticulum handles routing), `mcast_rate=24000` (24Mbps broadcast floor), `multicast_to_unicast=0` (true broadcast, no per-peer duplication)
```

- [ ] **Step 7: Commit**

```bash
git add docs/mesh-wifi-setup.md README.md
git commit -m "docs: add multicast_to_unicast, fix mesh_id mismatch

- Document multicast_to_unicast='0' in config examples and table
- Fix mesh_id from 'harmony' to 'HARMONY-MESH' to match auto-config
- Fix key from 'YourMeshKey' to 'ZEBLITHIC' to match auto-config
- Update auto-config note to include multicast_to_unicast
- Add upgrade path for existing installations"
```

---

### Task 5: Push and create PR

**Files:** None (git operations)

- [ ] **Step 1: Push branch**

```bash
git push
```

- [ ] **Step 2: Create PR**

```bash
gh pr create --title "feat: broadcast-optimized mesh + PKG_SOURCE_VERSION update" --body "$(cat <<'EOF'
## Summary
- Disable `multicast_to_unicast` on HARMONY-MESH VIF to prevent N× airtime duplication in broadcast-heavy mesh swarms
- Update `PKG_SOURCE_VERSION` to latest harmony main (`396f97e`) — picks up memo fetch, selective discovery, JCS, JSON-LD import, tunnels
- Fix `mesh_id` mismatch in docs (`harmony` → `HARMONY-MESH`) and document new tuning

## Beads
- Closes harmony-openwrt-ua3 (broadcast-optimized WiFi)
- Closes harmony-openwrt-1mv (PKG_SOURCE_VERSION update)

## Test plan
- [ ] `uci get wireless.harmony_mesh.multicast_to_unicast` → `0`
- [ ] `grep multicast_to_unicast /var/run/hostapd-phy*.conf` → applied
- [ ] Two-node mesh: tcpdump confirms broadcast frames, not per-peer unicast
- [ ] Verify AP VIF unaffected: `uci get wireless.default_radio1.multicast_to_unicast` → unset
- [ ] `opkg info harmony-node | grep Version` → new source version

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```
