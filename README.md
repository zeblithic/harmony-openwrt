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
CARGO_FEATURE_NO_NEON=1 cargo build -p harmony-node \
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
| `enabled` | `0` | Enable/disable the service |
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

## BLAKE3 NEON Performance

By default, the build disables BLAKE3 NEON assembly (`CARGO_FEATURE_NO_NEON=1`)
because cross-compilation requires a C cross-compiler for NEON intrinsics. This
uses a pure Rust fallback (~3x slower hashing, negligible for mesh workloads).

To enable NEON (requires a musl cross-compiler):

```bash
# Find your musl cross-compiler, e.g.:
#   apt install gcc-aarch64-linux-gnu
#   MUSL_CC=$(which aarch64-linux-gnu-gcc)
# Or from the OpenWRT SDK:
#   MUSL_CC=./staging_dir/toolchain-*/bin/aarch64-openwrt-linux-musl-gcc
CC_aarch64_unknown_linux_musl=$MUSL_CC cargo build -p harmony-node \
    --target aarch64-unknown-linux-musl \
    --profile release-cross
```

## License

Apache-2.0 OR MIT — same as [harmony core](https://github.com/zeblithic/harmony).
