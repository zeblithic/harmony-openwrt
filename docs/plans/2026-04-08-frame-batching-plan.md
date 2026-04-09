# Application-Layer Frame Batching Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pack multiple Data and Reticulum sub-frames into single Ethernet broadcasts to reduce PHY preamble overhead on WiFi mesh.

**Architecture:** A `BatchAccumulator` struct in `harmony-rawlink` buffers outgoing sub-frames and flushes them as a single BATCH frame (type 0x03) at the end of each bridge poll cycle. A `decode_batch()` function on the receiver side yields sub-frames for dispatch through existing handlers.

**Tech Stack:** Rust, harmony-rawlink crate (in zeblithic/harmony repo), shell docs in zeblithic/harmony-openwrt repo.

**Spec:** `zeblithic/harmony-openwrt/docs/specs/2026-04-08-frame-batching-design.md`

**Cross-repo:** Tasks 1-4 are in `zeblithic/harmony` on branch `jake-openwrt-frame-batching`. Task 5 is in `zeblithic/harmony-openwrt` on the same branch name.

---

## File Structure

| File | Responsibility |
|------|---------------|
| `crates/harmony-rawlink/src/batch.rs` | **New** — `BatchAccumulator` (encode) + `decode_batch()` (decode) + unit tests |
| `crates/harmony-rawlink/src/lib.rs` | Add `FRAME_TYPE_BATCH` constant + `pub mod batch;` declaration |
| `crates/harmony-rawlink/src/frame.rs` | Add `FRAME_TYPE_BATCH` to frame_type module (for symmetry with existing constants) |
| `crates/harmony-rawlink/src/bridge.rs` | Integrate accumulator into poll loop + add 0x03 dispatch in recv |
| `harmony-openwrt: docs/mesh-wifi-setup.md` | Document batching in "How it works" section |
| `harmony-openwrt: README.md` | Mention batching in L2 Transport section |

---

### Task 1: BatchAccumulator — encode path

**Repo:** `zeblithic/harmony` (branch `jake-openwrt-frame-batching`)

**Files:**
- Create: `crates/harmony-rawlink/src/batch.rs`
- Modify: `crates/harmony-rawlink/src/lib.rs:21-28` (add BATCH constant to frame_type module)
- Modify: `crates/harmony-rawlink/src/lib.rs:7-13` (add `pub mod batch;`)

**Context:** The existing `lib.rs` has frame type constants in `mod frame_type` (lines 21-28: RETICULUM=0x00, SCOUT=0x01, DATA=0x02) and module declarations (lines 7-13). The constant `MAX_PAYLOAD` (line 37) is 1485 bytes — the max payload after Ethernet header within 1500-byte MTU.

- [ ] **Step 1: Add BATCH frame type constant and module declaration to lib.rs**

In `crates/harmony-rawlink/src/lib.rs`, add to the `frame_type` module (after line 27 `pub const DATA: u8 = 0x02;`):

```rust
    /// Batch container — multiple sub-frames in one Ethernet frame.
    pub const BATCH: u8 = 0x03;
```

And add the module declaration (after line 11 `pub mod frame;`):

```rust
pub mod batch;
```

- [ ] **Step 2: Write failing test for single-frame batch encoding**

Create `crates/harmony-rawlink/src/batch.rs` with:

```rust
//! Batch frame encoding and decoding for the Harmony L2 protocol.
//!
//! Packs multiple Data/Reticulum sub-frames into a single Ethernet broadcast
//! to reduce PHY preamble overhead on WiFi mesh (where broadcast frames cannot
//! use A-MSDU/A-MPDU aggregation).
//!
//! Wire format:
//! ```text
//! [0x03]                                ← BATCH frame type
//! [1 sub_type][2 sub_len BE][payload…]  ← sub-frame 1
//! [1 sub_type][2 sub_len BE][payload…]  ← sub-frame 2
//! …
//! ```

use crate::frame_type;

/// Overhead per sub-frame entry: 1 byte type + 2 bytes length (big-endian).
const SUB_FRAME_HEADER: usize = 3;

/// Accumulates outgoing sub-frames into a single BATCH frame payload.
///
/// The bridge drains outbound channels into the accumulator each poll cycle,
/// then calls [`flush`] to get a complete batch payload for `send_frame()`.
pub struct BatchAccumulator {
    buf: Vec<u8>,
    max_payload: usize,
}

impl BatchAccumulator {
    /// Creates a new accumulator for the given Ethernet MTU.
    ///
    /// `max_payload` is computed as `mtu - 14 (ETH_HEADER_LEN) - 1 (batch type byte)`.
    /// For standard 1500-byte MTU, this is 1485.
    pub fn new(mtu: usize) -> Self {
        let max_payload = mtu.saturating_sub(14 + 1);
        Self {
            buf: Vec::new(),
            max_payload,
        }
    }

    /// Returns true if no sub-frames have been pushed since the last flush.
    pub fn is_empty(&self) -> bool {
        self.buf.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_accumulator_is_empty() {
        let acc = BatchAccumulator::new(1500);
        assert!(acc.is_empty());
        assert_eq!(acc.max_payload, 1485);
    }
}
```

- [ ] **Step 3: Run test to verify it passes**

Run: `cargo test -p harmony-rawlink batch::tests::new_accumulator_is_empty`
Expected: PASS

- [ ] **Step 4: Write failing test for push + flush**

Add to the `tests` module in `batch.rs`:

```rust
    #[test]
    fn push_single_frame_and_flush() {
        let mut acc = BatchAccumulator::new(1500);
        let payload = b"hello";
        let auto_flush = acc.push(frame_type::DATA, payload);
        assert!(auto_flush.is_none(), "single small frame should not auto-flush");
        assert!(!acc.is_empty());

        let batch = acc.flush().expect("should produce a batch");
        assert!(acc.is_empty(), "flush should reset");

        // Verify wire format: [0x03][0x02][0x00][0x05][hello]
        assert_eq!(batch[0], frame_type::BATCH);
        assert_eq!(batch[1], frame_type::DATA);
        assert_eq!(u16::from_be_bytes([batch[2], batch[3]]), 5);
        assert_eq!(&batch[4..9], b"hello");
        assert_eq!(batch.len(), 1 + 3 + 5); // batch_type + sub_header + payload
    }
```

- [ ] **Step 5: Run test to verify it fails**

Run: `cargo test -p harmony-rawlink batch::tests::push_single_frame_and_flush`
Expected: FAIL — `push` and `flush` methods don't exist yet.

- [ ] **Step 6: Implement push and flush**

Add to `BatchAccumulator` impl in `batch.rs`:

```rust
    /// Appends a sub-frame to the batch.
    ///
    /// Returns `Some(batch)` if the current batch was full and had to be flushed
    /// to make room. The returned batch is ready to pass to `send_frame()`.
    /// Returns `None` if the frame fit in the current batch.
    pub fn push(&mut self, frame_type: u8, payload: &[u8]) -> Option<Vec<u8>> {
        let entry_size = SUB_FRAME_HEADER + payload.len();

        // If the buffer is empty, start a new batch with the type byte.
        if self.buf.is_empty() {
            self.buf.reserve(1 + entry_size);
            self.buf.push(crate::frame_type::BATCH);
        }

        // Check if this entry fits in the current batch.
        // buf already contains the 0x03 prefix + previous entries.
        if self.buf.len() + entry_size > 1 + self.max_payload {
            // Auto-flush: take current batch, start fresh with this entry.
            let completed = std::mem::take(&mut self.buf);
            self.buf.reserve(1 + entry_size);
            self.buf.push(crate::frame_type::BATCH);
            self.append_entry(frame_type, payload);
            Some(completed)
        } else {
            self.append_entry(frame_type, payload);
            None
        }
    }

    /// Returns the completed batch if non-empty, resetting the buffer.
    ///
    /// Returns `None` if no sub-frames have been pushed since the last flush.
    pub fn flush(&mut self) -> Option<Vec<u8>> {
        if self.buf.is_empty() {
            None
        } else {
            Some(std::mem::take(&mut self.buf))
        }
    }

    /// Appends a sub-frame entry `[type][len BE][payload]` to the buffer.
    fn append_entry(&mut self, frame_type: u8, payload: &[u8]) {
        self.buf.push(frame_type);
        self.buf
            .extend_from_slice(&(payload.len() as u16).to_be_bytes());
        self.buf.extend_from_slice(payload);
    }
```

- [ ] **Step 7: Run test to verify it passes**

Run: `cargo test -p harmony-rawlink batch::tests::push_single_frame_and_flush`
Expected: PASS

- [ ] **Step 8: Write test for multi-frame batch**

Add to tests:

```rust
    #[test]
    fn push_multiple_frames_and_flush() {
        let mut acc = BatchAccumulator::new(1500);

        let ret_payload = vec![0xAA; 100];
        assert!(acc.push(frame_type::RETICULUM, &ret_payload).is_none());

        let data_payload = b"harmony/test";
        assert!(acc.push(frame_type::DATA, data_payload).is_none());

        let batch = acc.flush().expect("should produce a batch");

        // [0x03] [0x00][0x00][0x64][100 bytes] [0x02][0x00][0x0C][12 bytes]
        assert_eq!(batch[0], frame_type::BATCH);

        // Sub-frame 1: RETICULUM, len=100
        assert_eq!(batch[1], frame_type::RETICULUM);
        assert_eq!(u16::from_be_bytes([batch[2], batch[3]]), 100);
        assert_eq!(&batch[4..104], &ret_payload[..]);

        // Sub-frame 2: DATA, len=12
        assert_eq!(batch[104], frame_type::DATA);
        assert_eq!(u16::from_be_bytes([batch[105], batch[106]]), 12);
        assert_eq!(&batch[107..119], data_payload);

        assert_eq!(batch.len(), 1 + (3 + 100) + (3 + 12));
    }
```

- [ ] **Step 9: Run test to verify it passes**

Run: `cargo test -p harmony-rawlink batch::tests::push_multiple_frames_and_flush`
Expected: PASS (implementation already handles this case)

- [ ] **Step 10: Write test for auto-flush on overflow**

Add to tests:

```rust
    #[test]
    fn auto_flush_on_overflow() {
        // Use a tiny MTU to force overflow quickly.
        // MTU=50 → max_payload = 50 - 14 - 1 = 35
        // Batch buf can hold: 1 (type) + 35 = 36 bytes total.
        // First push: 1 (type) + 3 (header) + 20 (payload) = 24 bytes — fits.
        // Second push: 24 + 3 + 20 = 47 > 36 — triggers auto-flush.
        let mut acc = BatchAccumulator::new(50);
        let payload = vec![0xBB; 20];

        assert!(acc.push(frame_type::DATA, &payload).is_none());

        let flushed = acc.push(frame_type::DATA, &payload);
        assert!(flushed.is_some(), "second push should auto-flush");

        let batch1 = flushed.unwrap();
        // First batch contains only the first sub-frame.
        assert_eq!(batch1[0], frame_type::BATCH);
        assert_eq!(batch1.len(), 1 + 3 + 20);

        // Second sub-frame is in the accumulator, waiting for flush.
        let batch2 = acc.flush().expect("should have second batch");
        assert_eq!(batch2[0], frame_type::BATCH);
        assert_eq!(batch2.len(), 1 + 3 + 20);
    }
```

- [ ] **Step 11: Run test to verify it passes**

Run: `cargo test -p harmony-rawlink batch::tests::auto_flush_on_overflow`
Expected: PASS

- [ ] **Step 12: Write test for empty flush**

Add to tests:

```rust
    #[test]
    fn empty_flush_returns_none() {
        let mut acc = BatchAccumulator::new(1500);
        assert!(acc.flush().is_none());
    }

    #[test]
    fn double_flush_returns_none() {
        let mut acc = BatchAccumulator::new(1500);
        acc.push(frame_type::DATA, b"hello");
        acc.flush().expect("first flush should produce batch");
        assert!(acc.flush().is_none(), "second flush should be empty");
    }
```

- [ ] **Step 13: Run tests to verify they pass**

Run: `cargo test -p harmony-rawlink batch::tests::empty_flush_returns_none batch::tests::double_flush_returns_none`
Expected: PASS

- [ ] **Step 14: Write test for max-size sub-frame**

Add to tests:

```rust
    #[test]
    fn max_size_sub_frame() {
        let acc = BatchAccumulator::new(1500);
        // Max sub-frame payload: max_payload - SUB_FRAME_HEADER = 1485 - 3 = 1482
        let max_sub_payload = acc.max_payload - SUB_FRAME_HEADER;
        assert_eq!(max_sub_payload, 1482);

        let mut acc = BatchAccumulator::new(1500);
        let payload = vec![0xCC; 1482];
        assert!(acc.push(frame_type::DATA, &payload).is_none());

        let batch = acc.flush().expect("should produce batch");
        // 1 (batch type) + 3 (sub header) + 1482 (payload) = 1486
        assert_eq!(batch.len(), 1 + 3 + 1482);
    }
```

- [ ] **Step 15: Run test to verify it passes**

Run: `cargo test -p harmony-rawlink batch::tests::max_size_sub_frame`
Expected: PASS

- [ ] **Step 16: Run full crate tests**

Run: `cargo test -p harmony-rawlink`
Expected: All tests pass (existing + new batch tests).

- [ ] **Step 17: Run clippy**

Run: `cargo clippy -p harmony-rawlink -- -D warnings`
Expected: No warnings.

- [ ] **Step 18: Commit**

```bash
git add crates/harmony-rawlink/src/batch.rs crates/harmony-rawlink/src/lib.rs
git commit -m "feat(rawlink): add BatchAccumulator for frame batching

Introduces FRAME_TYPE_BATCH (0x03) and BatchAccumulator that packs
multiple Data/Reticulum sub-frames into a single Ethernet payload.
Reduces PHY preamble overhead for WiFi broadcast traffic.

Bead: harmony-openwrt-lx0"
```

---

### Task 2: decode_batch — decode path

**Repo:** `zeblithic/harmony` (branch `jake-openwrt-frame-batching`)

**Files:**
- Modify: `crates/harmony-rawlink/src/batch.rs` (add `decode_batch()` + tests)

**Context:** The `BatchAccumulator` from Task 1 produces batch payloads with format `[0x03][sub_type][sub_len BE][payload]...`. The decode function needs to yield `(frame_type, sub_payload)` tuples from a batch payload (the 0x03 prefix is included — decoder skips it).

- [ ] **Step 1: Write failing test for decode roundtrip**

Add to the `tests` module in `batch.rs`:

```rust
    #[test]
    fn decode_roundtrip() {
        let mut acc = BatchAccumulator::new(1500);
        acc.push(frame_type::RETICULUM, &[0xAA; 50]);
        acc.push(frame_type::DATA, b"harmony/topic/data-payload-here");
        acc.push(frame_type::RETICULUM, &[0xBB; 10]);
        let batch = acc.flush().unwrap();

        let subs: Vec<(u8, Vec<u8>)> = decode_batch(&batch)
            .map(|(t, p)| (t, p.to_vec()))
            .collect();

        assert_eq!(subs.len(), 3);
        assert_eq!(subs[0].0, frame_type::RETICULUM);
        assert_eq!(subs[0].1, vec![0xAA; 50]);
        assert_eq!(subs[1].0, frame_type::DATA);
        assert_eq!(subs[1].1, b"harmony/topic/data-payload-here");
        assert_eq!(subs[2].0, frame_type::RETICULUM);
        assert_eq!(subs[2].1, vec![0xBB; 10]);
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cargo test -p harmony-rawlink batch::tests::decode_roundtrip`
Expected: FAIL — `decode_batch` does not exist.

- [ ] **Step 3: Implement decode_batch**

Add above the `tests` module in `batch.rs`:

```rust
/// Iterator over sub-frames in a BATCH payload.
///
/// Yields `(frame_type, sub_payload)` for each sub-frame. Stops when the
/// payload is exhausted or a sub-frame header is truncated.
pub struct BatchIter<'a> {
    data: &'a [u8],
    pos: usize,
}

impl<'a> Iterator for BatchIter<'a> {
    type Item = (u8, &'a [u8]);

    fn next(&mut self) -> Option<Self::Item> {
        let remaining = self.data.len() - self.pos;
        if remaining < SUB_FRAME_HEADER {
            return None;
        }

        let frame_type = self.data[self.pos];
        let len =
            u16::from_be_bytes([self.data[self.pos + 1], self.data[self.pos + 2]]) as usize;
        let payload_start = self.pos + SUB_FRAME_HEADER;
        let payload_end = payload_start + len;

        if payload_end > self.data.len() {
            // Truncated sub-frame — stop iteration.
            return None;
        }

        self.pos = payload_end;
        Some((frame_type, &self.data[payload_start..payload_end]))
    }
}

/// Decodes a BATCH frame payload into an iterator of sub-frames.
///
/// The input `payload` must include the leading `0x03` batch type byte
/// (as produced by [`BatchAccumulator::flush`]). The iterator skips the
/// first byte and yields `(frame_type, sub_payload)` for each sub-frame.
///
/// Stops cleanly on truncated data — already-yielded sub-frames are valid.
pub fn decode_batch(payload: &[u8]) -> BatchIter<'_> {
    // Skip the 0x03 batch type byte.
    let start = if payload.first() == Some(&crate::frame_type::BATCH) {
        1
    } else {
        0
    };
    BatchIter {
        data: payload,
        pos: start,
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cargo test -p harmony-rawlink batch::tests::decode_roundtrip`
Expected: PASS

- [ ] **Step 5: Write test for truncated sub-frame**

Add to tests:

```rust
    #[test]
    fn decode_truncated_stops_cleanly() {
        let mut acc = BatchAccumulator::new(1500);
        acc.push(frame_type::DATA, b"valid");
        acc.push(frame_type::RETICULUM, &[0xCC; 40]);
        let mut batch = acc.flush().unwrap();

        // Truncate the second sub-frame's payload (chop 10 bytes off the end).
        batch.truncate(batch.len() - 10);

        let subs: Vec<(u8, Vec<u8>)> = decode_batch(&batch)
            .map(|(t, p)| (t, p.to_vec()))
            .collect();

        // Only the first sub-frame should be yielded.
        assert_eq!(subs.len(), 1);
        assert_eq!(subs[0].0, frame_type::DATA);
        assert_eq!(subs[0].1, b"valid");
    }
```

- [ ] **Step 6: Run test to verify it passes**

Run: `cargo test -p harmony-rawlink batch::tests::decode_truncated_stops_cleanly`
Expected: PASS

- [ ] **Step 7: Write test for unknown sub-frame type skipped by length**

Add to tests:

```rust
    #[test]
    fn decode_unknown_type_skipped_by_length() {
        // Manually build a batch with an unknown type (0xFF) between two valid ones.
        let mut batch = vec![frame_type::BATCH];
        // Sub-frame 1: RETICULUM, 3 bytes
        batch.push(frame_type::RETICULUM);
        batch.extend_from_slice(&3u16.to_be_bytes());
        batch.extend_from_slice(&[0xAA; 3]);
        // Sub-frame 2: unknown type 0xFF, 5 bytes
        batch.push(0xFF);
        batch.extend_from_slice(&5u16.to_be_bytes());
        batch.extend_from_slice(&[0x00; 5]);
        // Sub-frame 3: DATA, 2 bytes
        batch.push(frame_type::DATA);
        batch.extend_from_slice(&2u16.to_be_bytes());
        batch.extend_from_slice(&[0xBB; 2]);

        let subs: Vec<(u8, Vec<u8>)> = decode_batch(&batch)
            .map(|(t, p)| (t, p.to_vec()))
            .collect();

        // All three should be yielded — the caller decides what to do with unknown types.
        assert_eq!(subs.len(), 3);
        assert_eq!(subs[0].0, frame_type::RETICULUM);
        assert_eq!(subs[1].0, 0xFF);
        assert_eq!(subs[2].0, frame_type::DATA);
        assert_eq!(subs[2].1, vec![0xBB; 2]);
    }
```

- [ ] **Step 8: Run test to verify it passes**

Run: `cargo test -p harmony-rawlink batch::tests::decode_unknown_type_skipped_by_length`
Expected: PASS

- [ ] **Step 9: Write test for empty batch**

Add to tests:

```rust
    #[test]
    fn decode_empty_batch() {
        // Just the batch type byte, no sub-frames.
        let batch = vec![frame_type::BATCH];
        let subs: Vec<_> = decode_batch(&batch).collect();
        assert!(subs.is_empty());
    }

    #[test]
    fn decode_completely_empty_slice() {
        let subs: Vec<_> = decode_batch(&[]).collect();
        assert!(subs.is_empty());
    }
```

- [ ] **Step 10: Run all batch tests**

Run: `cargo test -p harmony-rawlink batch::tests`
Expected: All pass.

- [ ] **Step 11: Run clippy**

Run: `cargo clippy -p harmony-rawlink -- -D warnings`
Expected: No warnings.

- [ ] **Step 12: Commit**

```bash
git add crates/harmony-rawlink/src/batch.rs
git commit -m "feat(rawlink): add decode_batch() for batch frame decoding

BatchIter yields (frame_type, payload) tuples from a BATCH frame.
Handles truncated sub-frames by stopping cleanly, unknown types by
skipping via the length field.

Bead: harmony-openwrt-lx0"
```

---

### Task 3: Bridge send path — accumulator integration

**Repo:** `zeblithic/harmony` (branch `jake-openwrt-frame-batching`)

**Files:**
- Modify: `crates/harmony-rawlink/src/bridge.rs:1-174` (import batch, add accumulator to poll loop)

**Context:** The bridge poll loop (lines 99-173 in `bridge.rs`) currently:
1. Sends scout directly (line 106)
2. Processes inbound frames (line 118)
3. Drains zenoh outbound, calling `process_outbound_sample()` which calls `send_frame()` per sample (lines 123-130)
4. Drains reticulum outbound, calling `send_frame()` per packet (lines 132-140)
5. Sleeps 10ms (line 172)

After this change:
- Steps 3 and 4 push into the accumulator instead of calling `send_frame()` directly
- A new step 4.5 flushes the accumulator and sends the batch
- Scout (step 1) still sends directly

The key change is in the `run()` method. `process_outbound_sample()` changes to return the payload bytes instead of sending directly. The reticulum drain builds payload bytes and pushes to the accumulator.

- [ ] **Step 1: Add batch import to bridge.rs**

At the top of `bridge.rs`, add to the `use crate::` block (line 16-22):

```rust
use crate::{
    batch::BatchAccumulator,
    error::RawLinkError,
    frame::{self, BROADCAST_MAC},
    frame_type,
    peer_table::PeerTable,
    socket::RawSocket,
};
```

- [ ] **Step 2: Create the accumulator in `run()` before the loop**

In `bridge.rs`, after line 97 (`let mut consecutive_errors: u32 = 0;`), add:

```rust
        let mut batch = BatchAccumulator::new(1500);
```

- [ ] **Step 3: Replace direct zenoh send with accumulator push**

Replace the zenoh outbound drain block (lines 123-130) with:

```rust
                // 4. Drain outbound zenoh samples → push into batch accumulator.
                //    Skip samples whose content hash matches something we just
                //    published from inbound L2 (echo prevention).
                while let Ok(Some(sample)) = subscriber.try_recv() {
                    let h = content_hash(sample.key_expr().as_str(), &sample.payload().to_bytes());
                    if inbound_hashes.contains(&h) {
                        trace!("skipping echo of L2-originated publish");
                        continue;
                    }
                    if let Some(payload) = self.build_outbound_data_payload(&sample) {
                        if let Some(flushed) = batch.push(frame_type::DATA, &payload) {
                            self.socket.send_frame(BROADCAST_MAC, &flushed)?;
                        }
                    }
                }
```

- [ ] **Step 4: Replace direct reticulum send with accumulator push**

Replace the reticulum outbound drain block (lines 132-140) with:

```rust
                // 5. Drain outbound Reticulum packets → push into batch accumulator.
                if let Some(ref mut rx) = self.reticulum_outbound_rx {
                    while let Ok(packet) = rx.try_recv() {
                        if let Some(flushed) = batch.push(frame_type::RETICULUM, &packet) {
                            self.socket.send_frame(BROADCAST_MAC, &flushed)?;
                        }
                    }
                }
```

- [ ] **Step 5: Add batch flush after all drains**

After the reticulum drain (before the `Ok(())` at the end of the iteration body), add:

```rust
                // 6. Flush remaining batch.
                if let Some(flushed) = batch.flush() {
                    self.socket.send_frame(BROADCAST_MAC, &flushed)?;
                }
```

- [ ] **Step 6: Rename `process_outbound_sample` to `build_outbound_data_payload`**

The existing `process_outbound_sample` method (lines 305-350) builds a payload AND sends it. We need it to only build the payload (the sub-frame payload, without the type byte — the accumulator prepends that). Rename and refactor it:

Replace the entire `process_outbound_sample` method with:

```rust
    /// Build the sub-frame payload for an outbound zenoh sample.
    ///
    /// Returns `None` if the sample should be dropped (key too long, payload
    /// exceeds MTU). The returned bytes are the DATA sub-frame payload:
    /// `[6 origin_mac][2 key_len BE][key bytes][payload]`.
    fn build_outbound_data_payload(
        &self,
        sample: &zenoh::sample::Sample,
    ) -> Option<Vec<u8>> {
        let key_expr = sample.key_expr().as_str();
        let payload = sample.payload().to_bytes();

        if key_expr.len() > u16::MAX as usize {
            warn!(key_expr, "outbound key_expr exceeds u16 max length, dropping frame");
            return None;
        }

        // Guard against oversized sub-frames.
        // Sub-frame overhead within DATA: 6 (origin_mac) + 2 (key_len) + key_expr.len()
        // Max sub-frame payload in a batch: max_payload - 3 (sub-frame header) = 1482
        const MAX_SUB_PAYLOAD: usize = 1500 - 14 - 1 - 3;
        let data_overhead = 6 + 2 + key_expr.len();
        if payload.len() > MAX_SUB_PAYLOAD.saturating_sub(data_overhead) {
            trace!(
                key_expr,
                payload_len = payload.len(),
                "outbound payload exceeds batch sub-frame limit, dropping"
            );
            return None;
        }

        let local_mac = self.socket.local_mac();
        let mut buf = Vec::with_capacity(6 + 2 + key_expr.len() + payload.len());
        buf.extend_from_slice(&local_mac);
        buf.extend_from_slice(&(key_expr.len() as u16).to_be_bytes());
        buf.extend_from_slice(key_expr.as_bytes());
        buf.extend_from_slice(&payload);

        trace!(key_expr, payload_len = payload.len(), "queued outbound data frame");
        Some(buf)
    }
```

- [ ] **Step 7: Run all crate tests**

Run: `cargo test -p harmony-rawlink`
Expected: All pass. The existing bridge tests don't call `run()` (they test lower-level helpers), so the refactored method should not break them. The `reticulum_outbound_encoding` test (line 574) tests standalone encoding, not the bridge method.

- [ ] **Step 8: Run clippy**

Run: `cargo clippy -p harmony-rawlink -- -D warnings`
Expected: No warnings.

- [ ] **Step 9: Commit**

```bash
git add crates/harmony-rawlink/src/bridge.rs
git commit -m "feat(rawlink): integrate BatchAccumulator into bridge send path

Zenoh samples and Reticulum packets are now pushed into the accumulator
during each poll cycle, then flushed as a single BATCH frame. Scout
frames continue to send directly. Auto-flush on overflow ensures no
data is lost when outbound traffic exceeds one MTU per cycle.

Bead: harmony-openwrt-lx0"
```

---

### Task 4: Bridge receive path — batch dispatch

**Repo:** `zeblithic/harmony` (branch `jake-openwrt-frame-batching`)

**Files:**
- Modify: `crates/harmony-rawlink/src/bridge.rs:195-302` (add BATCH case to recv dispatch)

**Context:** The `process_inbound_frames` method (lines 195-302 in `bridge.rs`) dispatches inbound frames by matching `payload[0]` against frame type constants (line 213). The existing `other =>` arm at line 282 logs unknown types. We add a `BATCH` case that calls `decode_batch()` and re-dispatches each sub-frame through the same logic.

- [ ] **Step 1: Add batch import if not already present**

Ensure `use crate::batch::decode_batch;` is imported at the top of `bridge.rs`. If the import block was already updated in Task 3 Step 1 to include `batch::BatchAccumulator`, update it to:

```rust
use crate::{
    batch::{decode_batch, BatchAccumulator},
    error::RawLinkError,
    frame::{self, BROADCAST_MAC},
    frame_type,
    peer_table::PeerTable,
    socket::RawSocket,
};
```

- [ ] **Step 2: Extract the per-frame dispatch logic into a closure**

The current `recv_frames` callback (lines 204-286) has inline match arms for each frame type. To reuse this for sub-frames inside a batch, extract the match body into a closure that `process_inbound_frames` defines before calling `recv_frames`.

Replace the callback inside `socket.recv_frames(...)` (lines 204-286) with:

```rust
        // Closure that dispatches a single sub-frame payload by type.
        // Used for both standalone frames and sub-frames inside a BATCH.
        let mut dispatch = |src_mac: &[u8; 6], frame_type_byte: u8, body: &[u8]| {
            match frame_type_byte {
                frame_type::RETICULUM => {
                    if !body.is_empty() {
                        if let Some(ref reticulum_tx) = reticulum_tx {
                            let packet = body.to_vec();
                            let _ = reticulum_tx.try_send(packet);
                        }
                    }
                }
                frame_type::SCOUT => {
                    if body.len() < 16 {
                        debug!(len = body.len(), "scout frame too short, ignoring");
                        return;
                    }
                    let mut identity_hash = [0u8; 16];
                    identity_hash.copy_from_slice(&body[..16]);
                    peer_table.update(identity_hash, *src_mac);
                    debug!(
                        identity = hex::encode(identity_hash),
                        src_mac = hex::encode(src_mac),
                        "peer scouted"
                    );
                }
                frame_type::DATA => {
                    // Data body: [6-byte origin_mac][u16 BE key_len][key][payload]
                    if body.len() < 6 + 2 {
                        debug!(len = body.len(), "data frame too short, ignoring");
                        return;
                    }
                    let mut origin_mac = [0u8; 6];
                    origin_mac.copy_from_slice(&body[..6]);
                    if &origin_mac == local_mac {
                        trace!("discarding self-originated data frame");
                        return;
                    }
                    let key_len = u16::from_be_bytes([body[6], body[7]]) as usize;
                    let key_start = 8;
                    let key_end = key_start + key_len;
                    if body.len() < key_end {
                        debug!(
                            key_len,
                            frame_len = body.len(),
                            "data frame truncated key_expr, ignoring"
                        );
                        return;
                    }
                    let key_expr = match std::str::from_utf8(&body[key_start..key_end]) {
                        Ok(s) => s,
                        Err(_) => {
                            debug!("data frame has invalid UTF-8 key_expr, ignoring");
                            return;
                        }
                    };
                    let mut prefix = allowed_prefix.trim_end_matches("**").trim_end_matches('/').to_string();
                    prefix.push('/');
                    if !key_expr.starts_with(&prefix) {
                        debug!(
                            key_expr,
                            "data frame key_expr outside allowed namespace, ignoring"
                        );
                        return;
                    }
                    let data_payload = body[key_end..].to_vec();
                    inbound_data.push((key_expr.to_string(), data_payload));
                }
                other => {
                    trace!(frame_type = other, "ignoring unknown frame type");
                }
            }
        };

        socket.recv_frames(&mut |src_mac, payload| {
            if src_mac == local_mac {
                return;
            }
            if payload.is_empty() {
                return;
            }

            if payload[0] == frame_type::BATCH {
                // Decode batch and dispatch each sub-frame.
                for (sub_type, sub_payload) in decode_batch(payload) {
                    dispatch(src_mac, sub_type, sub_payload);
                }
            } else {
                // Standalone frame: type byte is payload[0], body is payload[1..].
                dispatch(src_mac, payload[0], &payload[1..]);
            }
        })?;
```

**Important note about the refactor:** The existing dispatch code accesses `payload[1..]` for the body (e.g., line 217 `payload[1..]` for Reticulum, line 228 `payload[1..17]` for Scout, line 243 `payload[1..7]` for Data origin_mac). In the new dispatch closure, the `body` parameter is already `payload[1..]` for standalone frames, and `sub_payload` for batch sub-frames. So all the offsets shift: what was `payload[1..7]` becomes `body[..6]`, `payload[7]` becomes `body[6]`, etc.

- [ ] **Step 3: Run all crate tests**

Run: `cargo test -p harmony-rawlink`
Expected: All pass. The existing tests (`inbound_scout_updates_peer_table`, `reticulum_frame_routed_to_channel`, `interleaved_frame_types_routed_correctly`) should still pass because standalone frames are handled by the `else` branch which strips `payload[0]` and passes `payload[1..]` as body — exactly what the original code did.

- [ ] **Step 4: Write integration test — batch received and dispatched**

Add to the `tests` module in `bridge.rs`:

```rust
    #[test]
    fn batch_frame_dispatches_sub_frames() {
        use crate::batch::BatchAccumulator;

        let (mut socket_a, mut socket_b) = MockSocket::pair(MAC_A, MAC_B);
        let (ret_tx, ret_rx) = std::sync::mpsc::channel();

        // Build a batch containing a Reticulum packet and a Scout.
        let mut acc = BatchAccumulator::new(1500);
        let ret_packet = vec![0xDD; 80];
        acc.push(frame_type::RETICULUM, &ret_packet);

        let mut scout_body = vec![0u8; 16];
        scout_body.copy_from_slice(&IDENTITY);
        acc.push(frame_type::SCOUT, &scout_body);

        let batch = acc.flush().unwrap();
        socket_b.send_frame(MAC_A, &batch).expect("mock send");

        // Simulate bridge's inbound dispatch.
        let local_mac = MAC_A;
        let mut peer_table = PeerTable::new(Duration::from_secs(30));

        socket_a
            .recv_frames(&mut |src_mac, payload| {
                if src_mac == &local_mac || payload.is_empty() {
                    return;
                }
                if payload[0] == frame_type::BATCH {
                    for (sub_type, sub_payload) in crate::batch::decode_batch(payload) {
                        match sub_type {
                            frame_type::RETICULUM if !sub_payload.is_empty() => {
                                let _ = ret_tx.send(sub_payload.to_vec());
                            }
                            frame_type::SCOUT if sub_payload.len() >= 16 => {
                                let mut hash = [0u8; 16];
                                hash.copy_from_slice(&sub_payload[..16]);
                                peer_table.update(hash, *src_mac);
                            }
                            _ => {}
                        }
                    }
                }
            })
            .expect("recv");

        // Verify both sub-frames were dispatched.
        let received_ret = ret_rx.try_recv().expect("should receive Reticulum packet");
        assert_eq!(received_ret, ret_packet);
        assert_eq!(peer_table.peer_count(), 1);
        assert_eq!(peer_table.lookup(&IDENTITY), Some(MAC_B));
    }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cargo test -p harmony-rawlink bridge::tests::batch_frame_dispatches_sub_frames`
Expected: PASS

- [ ] **Step 6: Write test — standalone frames still work alongside batch**

Add to the `tests` module in `bridge.rs`:

```rust
    #[test]
    fn standalone_and_batch_frames_coexist() {
        use crate::batch::BatchAccumulator;

        let (mut socket_a, mut socket_b) = MockSocket::pair(MAC_A, MAC_B);
        let (ret_tx, ret_rx) = std::sync::mpsc::channel();

        // Send a standalone Reticulum frame.
        let standalone_packet = vec![0x11; 30];
        let mut standalone_payload = vec![frame_type::RETICULUM];
        standalone_payload.extend_from_slice(&standalone_packet);
        socket_b.send_frame(MAC_A, &standalone_payload).expect("mock send");

        // Send a batch containing another Reticulum frame.
        let mut acc = BatchAccumulator::new(1500);
        let batch_packet = vec![0x22; 40];
        acc.push(frame_type::RETICULUM, &batch_packet);
        let batch = acc.flush().unwrap();
        socket_b.send_frame(MAC_A, &batch).expect("mock send");

        let local_mac = MAC_A;
        let mut received: Vec<Vec<u8>> = Vec::new();

        socket_a
            .recv_frames(&mut |src_mac, payload| {
                if src_mac == &local_mac || payload.is_empty() {
                    return;
                }
                if payload[0] == frame_type::BATCH {
                    for (sub_type, sub_payload) in crate::batch::decode_batch(payload) {
                        if sub_type == frame_type::RETICULUM {
                            received.push(sub_payload.to_vec());
                        }
                    }
                } else if payload[0] == frame_type::RETICULUM && payload.len() > 1 {
                    received.push(payload[1..].to_vec());
                }
            })
            .expect("recv");

        assert_eq!(received.len(), 2);
        assert_eq!(received[0], standalone_packet);
        assert_eq!(received[1], batch_packet);
    }
```

- [ ] **Step 7: Run test to verify it passes**

Run: `cargo test -p harmony-rawlink bridge::tests::standalone_and_batch_frames_coexist`
Expected: PASS

- [ ] **Step 8: Run full workspace tests and clippy**

Run: `cargo test --workspace && cargo clippy --workspace -- -D warnings`
Expected: All pass, no warnings.

- [ ] **Step 9: Commit**

```bash
git add crates/harmony-rawlink/src/bridge.rs
git commit -m "feat(rawlink): add BATCH frame dispatch to bridge receive path

Inbound BATCH frames (0x03) are decoded into sub-frames and dispatched
through the same handlers as standalone frames. Standalone Reticulum,
Scout, and Data frames continue to work unchanged.

Bead: harmony-openwrt-lx0"
```

---

### Task 5: Documentation updates

**Repo:** `zeblithic/harmony-openwrt` (branch `jake-openwrt-frame-batching`)

**Files:**
- Modify: `docs/mesh-wifi-setup.md:286-302` ("How it works" section)
- Modify: `README.md:139-165` ("L2 Transport" section)

**Context:** The "How it works" section in `mesh-wifi-setup.md` (lines 286-302) describes the bridge loop with 3 numbered steps. The README "L2 Transport" section (lines 139-165) gives a brief description. Both need a mention of frame batching.

- [ ] **Step 1: Update mesh-wifi-setup.md "How it works" section**

In `docs/mesh-wifi-setup.md`, replace lines 288-298:

```markdown
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
```

With:

```markdown
The `harmony-rawlink` crate opens an AF_PACKET socket on the specified interface
and runs a bridge loop:

1. **Scout broadcasts** — periodic L2 announcements (frame type `0x01`) advertise
   the node's 128-bit identity hash. Peers populate a local peer table with TTL
   expiry. Scouts are sent directly (not batched).
2. **Zenoh data frames** — Zenoh pub/sub payloads (frame type `0x02`) are queued
   for batching.
3. **Reticulum packets** — Reticulum announces and link packets (frame type `0x00`)
   are queued for batching.
4. **Batch flush** — all queued frames from steps 2-3 are packed into a single
   BATCH frame (type `0x03`) and broadcast as one Ethernet transmission. This
   reduces PHY preamble overhead on WiFi, where broadcast frames cannot use
   802.11 A-MSDU/A-MPDU aggregation. If the combined payload exceeds the Ethernet
   MTU (1500 bytes), multiple batch frames are sent.
```

- [ ] **Step 2: Update README.md L2 Transport section**

In `README.md`, after the paragraph "The `rawlink_interface` UCI option enables an AF_PACKET bridge..." (line 140-143), add a new paragraph:

After line 143 (`UDP multicast.`), add:

```markdown

**Frame batching:** Outgoing Zenoh and Reticulum frames are automatically packed
into batch frames (type `0x03`) to reduce broadcast airtime overhead. WiFi broadcast
cannot use 802.11 aggregation, so Harmony batches at the application layer instead.
```

- [ ] **Step 3: Run TOML generation tests (ensure no regression)**

Run: `sh tests/test_toml_gen.sh`
Expected: All pass (docs-only change, no init script changes).

- [ ] **Step 4: Commit**

```bash
git add docs/mesh-wifi-setup.md README.md
git commit -m "docs: document frame batching in L2 transport sections

Updates the 'How it works' section in mesh-wifi-setup.md and the L2
Transport section in README.md to describe BATCH frame packing.

Bead: harmony-openwrt-lx0"
```

---

## Self-Review

**Spec coverage:**
- BatchAccumulator with push/flush/is_empty → Task 1 ✓
- decode_batch iterator → Task 2 ✓
- Wire format (0x03 + sub-frame headers) → Task 1 Step 6, Task 2 Step 3 ✓
- Bridge send path integration → Task 3 ✓
- Bridge receive path dispatch → Task 4 ✓
- Scout bypass → Task 3 Steps 3-4 (scout still in send_scout, not pushed to accumulator) ✓
- Auto-flush on overflow → Task 1 Step 10 ✓
- Documentation → Task 5 ✓
- No UCI changes → confirmed, no task needed ✓

**Placeholder scan:** No TBD/TODO/placeholders found.

**Type consistency:**
- `BatchAccumulator::new(mtu: usize)` — consistent across Task 1 and Task 3
- `push(frame_type: u8, payload: &[u8]) -> Option<Vec<u8>>` — consistent across Task 1 and Task 3
- `flush() -> Option<Vec<u8>>` — consistent across Task 1 and Task 3
- `decode_batch(payload: &[u8]) -> BatchIter<'_>` — consistent across Task 2 and Task 4
- `build_outbound_data_payload()` — Task 3 Step 6 defines it, Step 3 calls it ✓
- `frame_type::BATCH` constant — Task 1 Step 1 adds it, used in Task 1-4 ✓
