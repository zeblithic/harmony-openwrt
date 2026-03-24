# Tunnel and Relay UCI Configuration

**Date:** 2026-03-24
**Status:** Draft
**Scope:** `harmony-node/files/`, `harmony-node/Makefile`, `README.md`
**Bead:** harmony-openwrt-atf

## Problem

The UCI config has no options for `--relay-url` or `--add-tunnel-peer`.
Internet-connected mesh nodes that peer over iroh-net tunnels must
currently be configured by editing the init script or passing flags
manually. This breaks the UCI/procd management model.

## Solution

Add `relay_url` option and `tunnel_peer` list to the `main` UCI section.
Wire them into the init script using standard `config_get` and
`config_list_foreach` patterns.

## UCI Configuration

```
config harmony-node 'main'
    ...existing options...
    option relay_url ''
    list tunnel_peer ''
```

- `relay_url`: iroh relay URL for NAT-traversal. Empty = disabled.
  Enables tunnel accept when set (e.g., `https://relay.example.com`).
- `tunnel_peer`: repeatable list. Each entry is a peer spec in the
  format `<identity_hash_hex>:<node_id_hex>[@relay_url]`. Mapped to
  `--add-tunnel-peer` CLI flags.

## Init Script Changes

```sh
config_get relay_url main relay_url ''
# ...
[ -n "$relay_url" ] && \
    procd_append_param command --relay-url "$relay_url"

# Tunnel peers (list → multiple --add-tunnel-peer flags)
add_tunnel_peer_cb() {
    procd_append_param command --add-tunnel-peer "$1"
}
config_list_foreach main tunnel_peer add_tunnel_peer_cb
```

## File Changes

| File | Change |
|------|--------|
| `harmony-node/files/harmony-node.conf` | Add `relay_url` option and `tunnel_peer` list |
| `harmony-node/files/harmony-node.init` | Wire both to CLI args |
| `harmony-node/Makefile` | Bump `PKG_RELEASE` 4 → 5 |
| `README.md` | Add relay/tunnel options to config table |

## Not in Scope

- `--tunnel-peer` outbound initiator (incomplete upstream, tracked as
  harmony-openwrt-4km)
- Tunnel-specific firewall rules (UDP 4434-4435 already open)
- TOML config generation (tracked as harmony-openwrt-6e1)

## Testing

- `uci set harmony-node.main.relay_url='https://relay.example.com'`
- `uci add_list harmony-node.main.tunnel_peer='abc123:def456@https://relay.example.com'`
- `uci commit harmony-node` → service restarts via procd trigger
- `ps | grep harmony` → verify `--relay-url` and `--add-tunnel-peer` in args
- Empty `relay_url` → no `--relay-url` flag in command line
- Empty `tunnel_peer` list → no `--add-tunnel-peer` flags
