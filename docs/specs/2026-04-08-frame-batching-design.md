# Application-Layer Frame Batching for Broadcast Efficiency

**Date:** 2026-04-08
**Status:** Draft
**Bead:** harmony-openwrt-lx0
**Repos:** zeblithic/harmony (implementation), zeblithic/harmony-openwrt (docs)

## Problem

WiFi broadcast frames cannot use 802.11 aggregation (A-MSDU/A-MPDU) because
there is no BlockAck mechanism for broadcast. Each broadcast frame carries
~200us of PHY preamble overhead. When Harmony sends multiple small Zenoh
publishes or Reticulum announces in quick succession, each one becomes a
separate L2 broadcast — wasting airtime on redundant preambles.

On a busy mesh with 10 nodes exchanging Bloom filter broadcasts and Zenoh
samples, the per-frame preamble overhead can consume a significant fraction
of available airtime at the elevated `mcast_rate=24000` (24 Mbps) broadcast
floor.

## Solution

Add a `BatchAccumulator` to `harmony-rawlink` that buffers outgoing Data
(0x02) and Reticulum (0x00) frames within a single bridge poll cycle, then
flushes them as a single Ethernet frame using a new BATCH frame type (0x03).
The receiver decodes the batch and dispatches each sub-frame through the
existing per-type handlers.

## Design Decisions

### Always-on batch format

All Data and Reticulum frames are sent through the batch path, even when
only a single frame is queued. This gives one send path and one receive path
— less code, fewer bugs. The overhead for a solo frame is 3 bytes (sub-frame
header), which is 0.2% of the MTU.

### Scout frames bypass batching

Scout frames (0x01) are sent directly, not through the accumulator. They
fire every 5-10 seconds and serve a timing-sensitive peer discovery purpose.
Batching them would add latency to peer discovery for negligible airtime
savings.

### Full MTU utilization

Batch payloads fill up to 1483 bytes (1500 MTU - 14 Ethernet header - 3
batch header). Maximizing payload per broadcast frame is the primary
goal, since broadcast airtime is the bottleneck.

### Event-loop-integrated flush

The bridge poll loop already has a natural cadence bounded by the 10ms
TPACKET_V3 poll timeout. At the end of each iteration, after draining all
outbound channels, the accumulator is flushed. No additional timers or
configuration knobs are needed.

### Frame types eligible for batching

Data (0x02) and Reticulum (0x00) frames are batched. Both are high-frequency
and variable-rate. Reticulum packets are small (<=500B MTU) and pack well
alongside Data frames.

## Wire Format

### Batch frame (type 0x03)

```
Ethernet header:  [6 dst_mac][6 src_mac][2 EtherType=0x88B5]
Batch payload:    [0x03]                                ← frame type BATCH
                  [2 content_len BE]                    ← total sub-frame bytes
                  [1 sub_type][2 sub_len BE][sub_len B] ← sub-frame 1
                  [1 sub_type][2 sub_len BE][sub_len B] ← sub-frame 2
                  ...until content_len bytes consumed
```

- **Batch type byte (1B):** `0x03`, identifies this as a batch frame.
- **Content length (2B):** Total bytes of sub-frame data that follow, as a
  big-endian u16. The decoder stops after consuming this many bytes,
  ignoring any trailing padding added by `PaddedSocket`.
- **Sub-frame header (3B each):** 1 byte frame type + 2 byte payload length
  (big-endian). The payload length does NOT include the 3-byte header.
- **Sub-frame payload:** Raw bytes, identical to what would follow the frame
  type byte in a standalone frame of that type.
- **Max batch payload:** 1483 bytes (1500 MTU - 14 Ethernet header - 3 batch
  header). Each sub-frame costs 3 bytes of header overhead plus its payload.

### Existing frame types (unchanged)

| Type | Name | Used in batches |
|------|------|-----------------|
| 0x00 | RETICULUM | Yes (as sub-frame) |
| 0x01 | SCOUT | No (sent directly) |
| 0x02 | DATA | Yes (as sub-frame) |
| 0x03 | BATCH | Container only (never nested) |

## Architecture

### BatchAccumulator (new, in `harmony-rawlink`)

A `no_std`-compatible, zero-I/O struct that packs sub-frames into a byte
buffer.

```rust
pub struct BatchAccumulator {
    buf: Vec<u8>,       // Batch payload being assembled (0x03 prefix written on first push)
    max_payload: usize, // 1483 = MTU - ETH_HEADER_LEN - BATCH_HEADER
}
```

**API:**

- `new(mtu: usize)` — creates accumulator, computes max_payload.
- `push(frame_type: u8, payload: &[u8]) -> Option<Vec<u8>>` — appends a
  sub-frame `[type][len BE][payload]`. If adding it would exceed
  max_payload, auto-flushes the current batch (returned as `Some`) and
  starts a new batch containing this frame. Returns `None` if the frame
  fit.
- `flush() -> Option<Vec<u8>>` — returns the completed batch if non-empty,
  resets buffer. Returns `None` if empty.
- `is_empty() -> bool` — true if no sub-frames since last flush.

**Auto-flush on push:** When a new sub-frame would overflow, `push()`
returns the current batch and starts a new one. This means the bridge may
send multiple batches per poll cycle if outbound traffic exceeds one MTU.

**Oversized sub-frame:** If a single sub-frame (3B header + payload)
exceeds max_payload, it is placed in a solo batch anyway. The kernel will
drop the oversized Ethernet frame — this matches existing behavior where
oversized standalone frames are silently dropped.

### Decode function (new, in `harmony-rawlink`)

```rust
pub fn decode_batch(payload: &[u8]) -> impl Iterator<Item = (u8, &[u8])>
```

Yields `(frame_type, sub_payload)` tuples from a batch payload (after the
0x03 type byte has been stripped by the caller).

**Error handling:**
- Truncated sub-frame (declared length exceeds remaining bytes): stop
  iteration, log warning. Already-yielded sub-frames remain valid.
- Unknown sub-frame type: skip by length (length field allows skipping
  without understanding content). Log at debug level.
- Fewer than 3 remaining bytes: stop iteration (can't fit a sub-frame
  header).

### Bridge integration

The bridge poll loop in `bridge.rs` changes from:

```
loop {
    poll_inbound()
    drain_zenoh_outbound()   → send_frame() per sample
    drain_reticulum_outbound() → send_frame() per packet
    maybe_send_scout()       → send_frame()
}
```

To:

```
loop {
    poll_inbound()           // recv dispatch adds 0x03 case
    drain_zenoh_outbound()   → accumulator.push(DATA, payload)
                               if auto-flush → send_frame(batch)
    drain_reticulum_outbound() → accumulator.push(RETICULUM, payload)
                                  if auto-flush → send_frame(batch)
    accumulator.flush()      → send_frame(batch) if non-empty
    maybe_send_scout()       → send_frame() directly (no accumulator)
}
```

The inbound path adds a `FRAME_TYPE_BATCH` case that calls
`decode_batch()` and dispatches each sub-frame through the existing
per-type handlers.

## File Changes

### zeblithic/harmony (implementation)

| File | Change |
|------|--------|
| `crates/harmony-rawlink/src/lib.rs` | Add `FRAME_TYPE_BATCH = 0x03` constant, `pub mod batch;` |
| `crates/harmony-rawlink/src/batch.rs` | **New** — `BatchAccumulator` + `decode_batch()` + unit tests |
| `crates/harmony-rawlink/src/bridge.rs` | Integrate accumulator into poll loop, add 0x03 recv dispatch |
| `crates/harmony-rawlink/src/frame.rs` | Add `FRAME_TYPE_BATCH` constant |

### zeblithic/harmony-openwrt (docs)

| File | Change |
|------|--------|
| `docs/mesh-wifi-setup.md` | Note about frame batching in IP-less Transport section |
| `README.md` | Mention batching in L2 Transport section |

## Testing

### Unit tests (in `batch.rs`)

1. **Packing correctness** — push several small frames, flush, verify wire
   format byte-for-byte.
2. **Auto-flush on overflow** — push frames until one exceeds MTU, verify
   push returns completed batch, verify overflowing frame starts new batch.
3. **Single frame** — push one frame, flush, verify valid batch with one
   sub-frame.
4. **Empty flush** — flush without pushing, verify `None`.
5. **Decode roundtrip** — encode N sub-frames via accumulator, decode via
   `decode_batch()`, verify types and payloads match.
6. **Decode truncated** — truncated batch stops iteration, already-yielded
   sub-frames valid.
7. **Decode unknown type** — unknown type skipped by length, next sub-frame
   decodes correctly.
8. **Max-size sub-frame** — single sub-frame fills entire batch payload
   (1480 bytes = 1483 - 3 sub-frame header bytes).

### Integration tests (using MockSocket)

9. **Bridge batch flow** — mock outbound channels with multiple frames, run
   one poll cycle, verify MockSocket received one send_frame call with valid
   batch.
10. **Scout bypass** — verify scout sent directly while data/reticulum in
    same cycle are batched separately.

## What Is NOT Changed

- **UCI configuration** — no new knobs. Batching is always-on.
- **Scout frame format or timing** — unchanged, bypasses accumulator.
- **RawSocket trait** — no new methods. Accumulator produces bytes,
  bridge sends via existing `send_frame()`.
- **TPACKET_V3 ring buffer configuration** — unchanged.
- **Inbound single-frame handling** — existing frame types (0x00, 0x01,
  0x02) received as standalone frames continue to work. The batch path is
  additive.
- **MockSocket** — no changes needed. It records `send_frame()` calls as
  before; tests inspect the batch payload.
