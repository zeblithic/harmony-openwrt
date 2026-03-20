# harmony-openwrt

OpenWRT package feed for [Harmony](https://github.com/zeblithic/harmony) mesh networking.

## Packages

| Package | Description |
|---------|-------------|
| `harmony-node` | Harmony decentralized mesh node (~3 MB static binary) |

## Prerequisites

- Rust toolchain with the `aarch64-unknown-linux-musl` target:
  ```bash
  rustup target add aarch64-unknown-linux-musl
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

To cross-compile harmony-node directly:

```bash
git clone https://github.com/zeblithic/harmony.git
cd harmony
cargo build -p harmony-node --features no-neon \
    --target aarch64-unknown-linux-musl \
    --profile release-cross \
    --locked
```

The binary is at `target/aarch64-unknown-linux-musl/release-cross/harmony`.
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

## Firewall

The package installs a firewall include (`/etc/harmony-node.firewall`) that automatically:
- **Allows** inbound UDP 4242 on the **LAN** zone (mesh peer communication)
- **Blocks** inbound UDP 4242 on the **WAN** zone (defense-in-depth)

These rules are applied automatically on package install and on every firewall reload. No manual configuration is needed.

To verify the rules are active:

```bash
iptables -L input_lan_rule -n | grep 4242
iptables -L input_wan_rule -n | grep 4242
```

To allow Harmony traffic on WAN (e.g., for cross-site mesh links):

```bash
# Edit the firewall include to remove or comment out the WAN DROP rule
vi /etc/harmony-node.firewall
/etc/init.d/firewall reload
```

**Note:** Removing the `harmony-node` package also removes the identity key at
`/etc/harmony/identity.key`. Back up the key before uninstalling if you plan to
reinstall on the same device.

## BLAKE3 NEON Performance

By default, the build uses `--features no-neon` which disables BLAKE3 NEON
assembly. This avoids the need for a C cross-compiler (the `cc` crate requires
one for NEON intrinsics). Pure Rust BLAKE3 is ~3x slower but negligible for
mesh node workloads.

To enable NEON (requires a musl cross-compiler):

```bash
# Find your musl cross-compiler, e.g.:
#   apt install gcc-aarch64-linux-gnu
#   MUSL_CC=$(which aarch64-linux-gnu-gcc)
# Or from the OpenWRT SDK:
#   MUSL_CC=./staging_dir/toolchain-*/bin/aarch64-openwrt-linux-musl-gcc
CC_aarch64_unknown_linux_musl=$MUSL_CC cargo build -p harmony-node \
    --target aarch64-unknown-linux-musl \
    --profile release-cross \
    --locked
```

Note: omit `--features no-neon` when using a cross-compiler — NEON is enabled by default.

## License

Apache-2.0 OR MIT — same as [harmony core](https://github.com/zeblithic/harmony).
