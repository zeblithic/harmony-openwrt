# harmony-openwrt

OpenWRT package feed for [Harmony](https://github.com/zeblithic/harmony) mesh networking.

## Packages

| Package | Description |
|---------|-------------|
| `harmony-node` | Harmony decentralized mesh node (~33 MB static binary) |

## Prerequisites

- Rust toolchain with the musl target for your architecture:
  ```bash
  rustup target add aarch64-unknown-linux-musl  # ARM64 routers
  rustup target add x86_64-unknown-linux-musl   # x86_64 devices/VMs
  ```
- OpenWRT buildroot (or SDK) for your target device

## Feed Setup

Add this feed to your OpenWRT buildroot:

```bash
echo "src-git harmony https://github.com/zeblithic/harmony-openwrt.git" >> feeds.conf
./scripts/feeds update harmony
./scripts/feeds install harmony-node
```

Then select the package in menuconfig:

```bash
make menuconfig
# Navigate: Network → harmony-node → <*> (built-in) or <M> (module)
```

Build:

```bash
make package/harmony-node/compile
```

The output `.ipk` is in `bin/packages/<arch>/harmony/`.

## Standalone Build (without OpenWRT buildroot)

To cross-compile harmony-node directly (replace target as needed):

```bash
git clone https://github.com/zeblithic/harmony.git
cd harmony
# For aarch64 (ARM64 routers):
cargo build -p harmony-node --features no-neon \
    --target aarch64-unknown-linux-musl \
    --profile release-cross \
    --locked

# For x86_64 (VMs, x86 devices — requires musl C cross-compiler for SSE/AVX):
cargo build -p harmony-node \
    --target x86_64-unknown-linux-musl \
    --profile release-cross \
    --locked
```

The binary is at `target/<target-triple>/release-cross/harmony`.
Copy it to `/usr/bin/harmony` on your router via scp.

## Configuration

The service is managed via UCI and procd.

### Enable the service

```bash
uci set harmony-node.main.enabled=1
uci commit harmony-node
/etc/init.d/harmony-node enable
/etc/init.d/harmony-node start
```

### Configuration options

| Option | Default | Description |
|--------|---------|-------------|
| `enabled` | `1` | Enable/disable the service |
| `identity_file` | `/etc/harmony/identity.key` | Path to the node identity key file |
| `listen_address` | `0.0.0.0:4242` | UDP listen address for Reticulum mesh packets |
| `cache_capacity` | `256` | W-TinyLFU cache items (CLI default: 1024) |
| `compute_budget` | `100000` | WASM compute fuel per tick |
| `filter_broadcast_ticks` | `30` | Bloom filter broadcast interval |
| `filter_mutation_threshold` | `100` | Bloom filter mutation threshold |
| `encrypted_durable_persist` | `0` | Accept encrypted durable content |
| `encrypted_durable_announce` | `0` | Announce encrypted durable content |
| `no_public_ephemeral_announce` | `0` | Disable public ephemeral announcements |
| `relay_url` | *(empty)* | iroh relay URL for NAT-traversal tunnels (enables tunnel accept) |
| `tunnel_peer` | *(list)* | Tunnel peer node IDs (hex, repeatable) |

Edit with `uci`:

```bash
uci set harmony-node.main.cache_capacity=512
uci commit harmony-node
# Service restarts automatically via procd trigger
```

Or edit `/etc/config/harmony-node` directly and restart:

```bash
/etc/init.d/harmony-node restart
```

The init script generates `/tmp/harmony-node.toml` from UCI options on each service
start and passes `--config /tmp/harmony-node.toml` to the binary. Always configure
via UCI — do not edit the generated TOML directly (it is overwritten on restart).

## Mesh WiFi (Auto-Configured)

On first install, the package **automatically** configures an 802.11s mesh interface:

- **SSID:** `HARMONY-MESH` — well-known, communal mesh network
- **PSK:** `ZEBLITHIC` — intentionally public (Harmony provides E2E encryption)
- **Radio:** Auto-detected 5GHz (override with `uci set harmony-node.mesh.radio='radioN'`)
- **Tunings:** `mesh_fwding=0` (Reticulum handles routing), `mcast_rate=24000` (24Mbps broadcast floor), `multicast_to_unicast=0` (true broadcast), `powersave=0` (no DTIM delay), `mesh_rssi_threshold=-70` (cull weak peers), `he_bss_color=37` (spatial reuse)

Any Harmony device within WiFi range automatically joins the mesh. No manual setup needed.

**Network isolation:** The mesh VIF runs on a dedicated `br-harmony` bridge
(`10.73.0.0/24`), isolated from `br-lan`. Mesh peers can reach harmony-node
on the router (UDP 4242, 7446, 4434-4435) but cannot access LAN devices,
the router admin UI, or forward traffic to WAN.

For advanced configuration, troubleshooting, and band planning, see
**[docs/mesh-wifi-setup.md](docs/mesh-wifi-setup.md)**.

## Firewall

The package installs a firewall include (`/etc/harmony-node.firewall`) that automatically
opens Harmony protocol ports on **both LAN and WAN**:

- **UDP 4242** — Reticulum mesh packets
- **UDP 7446** — Zenoh multicast scouting / peer discovery
- **UDP 4434-4435** — iroh-net QUIC tunnels (4433 excluded — IANA HTTPS-alt overlap)

Harmony provides its own E2E encryption (Reticulum + ML-KEM + ML-DSA), so there is
no meaningful trust difference between LAN and WAN for Harmony traffic. Non-Harmony
traffic remains firewalled on WAN as before.

These rules are applied automatically on package install and on every firewall reload.
No manual configuration is needed. Both fw3 (iptables, OpenWRT <22.03) and fw4
(nftables, OpenWRT >=22.03) are supported — the script auto-detects which is active.

To verify the rules are active:

```bash
# fw4 (nftables, OpenWRT 22.03+):
nft list chain inet fw4 input_lan | grep 4242
nft list chain inet fw4 input_wan | grep 4242

# fw3 (iptables, older OpenWRT):
iptables -L input_lan_rule -n | grep 4242
iptables -L input_wan_rule -n | grep 4242
```

To restrict Harmony traffic to LAN only (not recommended — breaks WAN peering):

```bash
# Edit the firewall include to change WAN ACCEPT rules to DROP
vi /etc/harmony-node.firewall
/etc/init.d/firewall reload
```

**Important:** Always apply changes via `/etc/init.d/firewall reload` — do not
run the firewall script directly, as rules will accumulate without the flush
that the firewall framework performs before sourcing includes.

**Upgrade note:** `/etc/harmony-node.firewall` is a conffile — local edits are
preserved across `opkg upgrade`. If a future package version ships changes to
the firewall script (e.g., new chain names), `opkg` will keep your version and
save the new one as `.opkg-new`. Review and merge manually if prompted.

**Note:** Removing the `harmony-node` package also removes the identity key at
`/etc/harmony/identity.key`. Back up the key before uninstalling if you plan to
reinstall on the same device.

## BLAKE3 SIMD Performance

BLAKE3 uses architecture-specific SIMD assembly for performance. The build
behavior differs by target:

- **aarch64:** Uses `--features no-neon` which disables NEON assembly, falling
  back to pure Rust. This avoids needing a C cross-compiler for standalone
  builds. ~3x slower but negligible for mesh node workloads. The OpenWRT SDK
  build always has `$(TARGET_CC)` available, but the feature flag is used for
  consistency with standalone builds.

- **x86_64:** No feature flag — SSE2/SSE4.1/AVX2 assembly compiles using
  `$(TARGET_CC)` from the OpenWRT SDK (always available). For standalone builds
  without an SDK, a musl C cross-compiler is required.

To enable NEON on aarch64 standalone builds (requires a musl cross-compiler):

```bash
CC_aarch64_unknown_linux_musl=$(which aarch64-linux-gnu-gcc) \
cargo build -p harmony-node \
    --target aarch64-unknown-linux-musl \
    --profile release-cross \
    --locked
```

Note: omit `--features no-neon` when using a cross-compiler — NEON is enabled by default.

## Testing

Run the init script TOML generation tests (requires Python 3.11+):

```bash
sh tests/test_toml_gen.sh
```

## License

Apache-2.0 OR MIT — same as [harmony core](https://github.com/zeblithic/harmony).
