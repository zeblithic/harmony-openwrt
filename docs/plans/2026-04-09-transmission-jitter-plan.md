# Stochastic Transmission Jitter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add response-triggered transmission jitter (100-500ms) to the rawlink bridge to break timing correlation between inbound queries and outbound responses.

**Architecture:** A `JitterHold` struct encapsulates a deadline-based timer state machine. When `process_inbound_frames()` reports that L2 frames were received, the bridge arms the jitter hold with a random 100-500ms delay. The explicit batch flush at the end of each poll iteration is suppressed until the hold expires. Auto-flushes from full batches bypass jitter. Scouts are unaffected.

**Tech Stack:** Rust, `rand` crate (already a dependency), `std::time::{Duration, Instant}`

**Design spec:** `zeblithic/harmony-openwrt/docs/specs/2026-04-09-transmission-jitter-design.md`

---

### Task 1: JitterHold struct + bridge integration

**Files:**
- Modify: `crates/harmony-rawlink/src/bridge.rs`

This task adds a `JitterHold` struct to `bridge.rs`, modifies `process_inbound_frames()` to report whether any frames were received, and wires jitter into the `run()` loop. TDD: tests first, then implementation.

- [ ] **Step 1: Write the JitterHold unit tests**

Add these 6 tests to the `mod tests` block at the bottom of `bridge.rs` (after the existing `standalone_and_batch_frames_coexist` test at line 734):

```rust
    #[test]
    fn jitter_hold_no_jitter_by_default() {
        let mut jitter = JitterHold::new();
        let now = Instant::now();
        assert!(!jitter.is_active());
        assert!(jitter.should_flush(now), "no hold → flush immediately");
    }

    #[test]
    fn jitter_hold_arm_suppresses_flush() {
        let mut jitter = JitterHold::new();
        let now = Instant::now();
        jitter.arm(now, Duration::from_millis(200));
        assert!(jitter.is_active());
        assert!(!jitter.should_flush(now), "armed → suppress flush");
        assert!(
            !jitter.should_flush(now + Duration::from_millis(100)),
            "before deadline → still suppressed"
        );
    }

    #[test]
    fn jitter_hold_expires_and_flushes() {
        let mut jitter = JitterHold::new();
        let now = Instant::now();
        jitter.arm(now, Duration::from_millis(200));
        assert!(
            jitter.should_flush(now + Duration::from_millis(200)),
            "at deadline → flush"
        );
        assert!(!jitter.is_active(), "hold should reset after expiry");
        assert!(
            jitter.should_flush(now + Duration::from_millis(300)),
            "after reset → flush normally"
        );
    }

    #[test]
    fn jitter_hold_not_rearmed_during_active() {
        let mut jitter = JitterHold::new();
        let now = Instant::now();
        jitter.arm(now, Duration::from_millis(200));
        // Second arm with longer delay is ignored.
        jitter.arm(now, Duration::from_millis(500));
        // Original 200ms deadline still applies.
        assert!(
            jitter.should_flush(now + Duration::from_millis(200)),
            "original deadline should apply, not 500ms"
        );
    }

    #[test]
    fn jitter_hold_rearms_after_expiry() {
        let mut jitter = JitterHold::new();
        let now = Instant::now();
        jitter.arm(now, Duration::from_millis(100));
        // Expire it.
        assert!(jitter.should_flush(now + Duration::from_millis(100)));
        // Arm again with new delay.
        let t2 = now + Duration::from_millis(100);
        jitter.arm(t2, Duration::from_millis(200));
        assert!(jitter.is_active());
        assert!(
            !jitter.should_flush(t2 + Duration::from_millis(100)),
            "new hold should suppress"
        );
        assert!(
            jitter.should_flush(t2 + Duration::from_millis(200)),
            "new hold should expire at t2+200ms"
        );
    }

    #[test]
    fn jitter_delay_range_100_to_500ms() {
        let mut rng = rand::thread_rng();
        for _ in 0..1000 {
            let delay_ms: u64 = rng.gen_range(100..=500);
            assert!(
                (100..=500).contains(&delay_ms),
                "delay {delay_ms}ms out of range"
            );
        }
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cargo test -p harmony-rawlink jitter_hold -- --nocapture 2>&1 | head -30`

Expected: compilation error — `JitterHold` is not defined.

- [ ] **Step 3: Implement JitterHold struct**

Add the `JitterHold` struct **above** the `Bridge` struct definition (before line 26 in the current file, after the imports). This placement keeps it co-located with its only consumer.

```rust
/// Transmission jitter hold timer.
///
/// When armed, suppresses explicit batch flushes for a random delay to break
/// timing correlation between inbound queries and outbound responses. See
/// `docs/specs/2026-04-09-transmission-jitter-design.md` in harmony-openwrt.
struct JitterHold {
    deadline: Option<Instant>,
}

impl JitterHold {
    fn new() -> Self {
        Self { deadline: None }
    }

    /// Arm the jitter hold if not already active.
    ///
    /// If a hold is already active, the call is ignored — the existing deadline
    /// is preserved. This prevents indefinite suppression under continuous
    /// inbound traffic.
    fn arm(&mut self, now: Instant, delay: Duration) {
        if self.deadline.is_none() {
            self.deadline = Some(now + delay);
        }
    }

    /// Returns `true` if the explicit flush should proceed.
    ///
    /// - No active hold → `true` (flush normally).
    /// - Hold expired → `true` (resets the hold).
    /// - Hold still active → `false` (suppress flush).
    fn should_flush(&mut self, now: Instant) -> bool {
        match self.deadline {
            None => true,
            Some(deadline) if now >= deadline => {
                self.deadline = None;
                true
            }
            Some(_) => false,
        }
    }

    /// Returns `true` if a jitter hold is currently active (deadline set).
    fn is_active(&self) -> bool {
        self.deadline.is_some()
    }
}
```

- [ ] **Step 4: Run JitterHold tests to verify they pass**

Run: `cargo test -p harmony-rawlink jitter_hold -- --nocapture`

Expected: all 6 `jitter_hold_*` tests PASS.

- [ ] **Step 5: Add `had_inbound` tracking to `process_inbound_frames`**

Make two changes to `process_inbound_frames()`:

**5a.** Change the return type from `Result<HashSet<u64>, RawLinkError>` to `Result<(HashSet<u64>, bool), RawLinkError>`.

The signature (currently at line 209) becomes:

```rust
    async fn process_inbound_frames(
        &mut self,
        local_mac: &[u8; 6],
    ) -> Result<(HashSet<u64>, bool), RawLinkError> {
```

**5b.** Add `let mut had_inbound = false;` after the `let mut inbound_data` line (currently line 210), and set it to `true` inside the `recv_frames` closure, right after the `payload.is_empty()` guard (currently at line 301). The closure becomes:

```rust
        socket.recv_frames(&mut |src_mac, payload| {
            // Skip frames from ourselves (loopback on the interface).
            if src_mac == local_mac {
                return;
            }
            if payload.is_empty() {
                return;
            }
            had_inbound = true;

            if payload[0] == frame_type::BATCH {
                for (sub_type, sub_body) in decode_batch(payload) {
                    dispatch(src_mac, sub_type, sub_body);
                }
            } else {
                dispatch(src_mac, payload[0], &payload[1..]);
            }
        })?;
```

**5c.** Change the return statement (currently `Ok(published_hashes)` at line 326) to:

```rust
        Ok((published_hashes, had_inbound))
```

- [ ] **Step 6: Wire JitterHold into the `run()` loop**

Make four changes to the `run()` method:

**6a.** Add `let mut jitter = JitterHold::new();` after `let mut batch = BatchAccumulator::new(1500);` (currently line 99).

**6b.** Destructure the new return value from `process_inbound_frames`. Change line 120 from:

```rust
                let inbound_hashes = self.process_inbound_frames(&local_mac).await?;
```

To:

```rust
                let (inbound_hashes, had_inbound) =
                    self.process_inbound_frames(&local_mac).await?;

                // Arm jitter hold on inbound traffic to break timing correlation.
                if had_inbound {
                    let delay_ms = rand::thread_rng().gen_range(100u64..=500);
                    jitter.arm(now, Duration::from_millis(delay_ms));
                }
```

**6c.** Gate the explicit flush on `jitter.should_flush()`. Change lines 151-154 from:

```rust
                // 6. Flush remaining batch.
                if let Some(flushed) = batch.flush() {
                    self.socket.send_frame(BROADCAST_MAC, &flushed)?;
                }
```

To:

```rust
                // 6. Flush remaining batch (jitter-gated).
                if jitter.should_flush(now) {
                    if let Some(flushed) = batch.flush() {
                        self.socket.send_frame(BROADCAST_MAC, &flushed)?;
                    }
                }
```

**6d.** Update the module doc comment at the top of the file. Add a line after "3. Drains the zenoh subscriber and broadcasts outbound Data frames." (currently line 6):

```rust
//! 4. Applies stochastic jitter to outbound flushes when inbound traffic
//!    was received, breaking timing correlation for traffic analysis resistance.
```

- [ ] **Step 7: Run the full test suite**

Run: `cargo test -p harmony-rawlink -- --nocapture`

Expected: all tests pass (existing 11 tests + 6 new `jitter_hold_*` tests = 17 total). The existing tests should be unaffected — they don't exercise the `run()` method, and `JitterHold` starts with `deadline: None` (no jitter = flush every cycle, matching existing behavior).

- [ ] **Step 8: Commit**

```bash
git add crates/harmony-rawlink/src/bridge.rs
git commit -m "feat(rawlink): add stochastic transmission jitter for traffic analysis resistance

Adds response-triggered jitter (100-500ms) to the bridge poll loop.
When inbound L2 frames are received, the explicit batch flush is delayed
by a random interval to break timing correlation between queries and
responses. Auto-flushes from full batches bypass jitter.

Bead: harmony-openwrt-7vf"
```

---

### Task 2: Documentation updates

**Files:**
- Modify: `docs/mesh-wifi-setup.md` (in zeblithic/harmony-openwrt)
- Modify: `README.md` (in zeblithic/harmony-openwrt)

**Important:** This task runs in the `zeblithic/harmony-openwrt` repo, NOT the harmony core repo. Commit directly to `main` (no PR needed for docs).

- [ ] **Step 1: Update mesh-wifi-setup.md "How it works" section**

After step 4 ("Batch flush") which ends at line 302, add step 5 before the blank line at line 303:

```markdown
5. **Transmission jitter** — when inbound frames were received in the same poll
   cycle, the batch flush is delayed by a random 100-500ms. This breaks timing
   correlation between received queries and sent responses, defeating passive
   traffic analysis. Auto-flushes from full batches bypass the jitter hold.
```

- [ ] **Step 2: Update README.md L2 Transport section**

After the "Frame batching" paragraph (lines 145-147), add a new paragraph:

```markdown
**Transmission jitter:** When inbound frames are received, outbound batch flushes
are delayed by a random 100-500ms to break timing correlation between queries and
responses. This prevents passive observers from mapping cause-and-effect packet
sequences across the mesh.
```

- [ ] **Step 3: Commit and push**

```bash
cd /Users/zeblith/work/zeblithic/harmony-openwrt
git add docs/mesh-wifi-setup.md README.md
git commit -m "docs: document transmission jitter in L2 transport sections"
git push origin main
```
