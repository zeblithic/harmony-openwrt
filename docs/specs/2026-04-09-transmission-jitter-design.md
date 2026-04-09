# Stochastic Transmission Jitter for Traffic Analysis Resistance

**Date:** 2026-04-09
**Status:** Draft
**Bead:** harmony-openwrt-7vf
**Repos:** zeblithic/harmony (implementation), zeblithic/harmony-openwrt (docs)

## Problem

A passive WiFi observer can correlate inbound and outbound broadcast frames at
a node to map cause-and-effect relationships across the mesh. When node B
receives a Zenoh query from node A and immediately broadcasts a response, the
tight temporal coupling (~20ms round-trip in the current bridge loop) reveals
who is responding to what — exposing content access patterns and routing
topology.

Frame batching (0x03) reduces the *number* of frames an observer sees but does
not address *timing*. The two features are complementary: batching defeats
volume analysis, jitter defeats timing analysis.

## Solution

Add a **jitter hold timer** to the bridge poll loop in `harmony-rawlink`. When
inbound L2 frames are processed, the explicit batch flush is suppressed for a
random 100-500ms delay. Outbound frames continue to accumulate in the
`BatchAccumulator` during the hold. When the timer expires, the accumulated
batch flushes normally.

## Design Decisions

### Response-triggered jitter only

Jitter activates only when the bridge processes inbound frames in a poll
cycle. Self-originated traffic (Zenoh publications with no preceding inbound
trigger) flushes at the normal 10ms cadence. This targets the specific threat
— timing correlation between received queries and sent responses — without
penalizing all traffic.

### 100-500ms delay range

The range is large enough to break statistical timing correlation across many
observations, but short enough to keep interactive mesh traffic responsive.
For comparison:
- Current round-trip: ~20ms (one poll cycle each way)
- Tunnel dial jitter: 500-4000ms (one-time setup, not per-message)
- Scout interval jitter: 5-10s (rare, timing-insensitive)

The mesh is primarily async (Reticulum announces, Zenoh pub/sub, Bloom filter
broadcasts), so 100-500ms of response latency is imperceptible in practice.

### Scouts bypass jitter

Scout frames (0x01) are already sent directly (not through the
`BatchAccumulator`) and have their own interval jitter (1-2x base). Adding
response jitter to scouts would slow peer discovery for negligible privacy
benefit. The privacy concern is data/Reticulum traffic revealing content access
patterns, not the existence of a peer.

### Auto-flush bypasses jitter

When the `BatchAccumulator`'s `push()` triggers an auto-flush (batch full at
1497 bytes), the full batch is sent immediately even during a jitter hold. A
full-MTU batch already contains enough traffic that timing correlation is
difficult — and we cannot hold an arbitrarily large backlog. This provides a
natural safety valve against unbounded buffering.

### Jitter not re-armed during hold

If additional inbound frames arrive while a jitter hold is already active,
the existing timer is not reset or extended. The `jitter_until.is_none()`
guard ensures that continuous inbound traffic cannot indefinitely suppress
outbound flushes. The hold always expires within the originally chosen
100-500ms window.

### Always-on, no configuration

Like frame batching, jitter is always active when rawlink is enabled. No UCI
knobs. One behavior, one code path. The 100-500ms range is a good default for
all deployment scenarios — tighter deployments where timing matters more can
override at the source level if needed in the future.

## Architecture

### Bridge loop integration

The change is a single `Option<Instant>` field in the bridge `run()` loop:

```
loop {
    poll_inbound()                          // existing
    had_inbound = process_inbound_frames()  // returns bool (was HashSet)

    if had_inbound && jitter_until.is_none():
        jitter_until = Some(now + rand(100..=500)ms)

    drain_zenoh_outbound()   → accumulator.push(DATA, payload)
                               if auto-flush → send_frame(batch)   // immediate
    drain_reticulum_outbound() → accumulator.push(RETICULUM, payload)
                                  if auto-flush → send_frame(batch) // immediate

    jitter_active = jitter_until is Some AND now < deadline
    if !jitter_active:
        accumulator.flush() → send_frame(batch) if non-empty
        jitter_until = None

    maybe_send_scout()       → send_frame() directly (unchanged)
}
```

### What changes

- `process_inbound_frames()` returns `(HashSet<u64>, bool)` — the bool tracks
  whether any L2 frames were received (set inside the `recv_frames` closure).
  This is more accurate than checking `!published_hashes.is_empty()` because
  it captures Scout and Reticulum inbound traffic, not just Data frames.
- `JitterHold` struct encapsulates the deadline state machine (testable
  independently of the bridge loop)
- One `gen_range(100..=500)` call per inbound trigger
- Explicit flush gated on jitter expiry

### What does NOT change

- `BatchAccumulator` struct and API — unchanged
- Outbound channel draining — unchanged (always drain to prevent backpressure)
- Auto-flush on `push()` — unchanged (sends immediately)
- Scout frames — unchanged (bypass accumulator, own jitter)
- Wire format — unchanged (no new frame types)
- UCI configuration — no new knobs
- `RawSocket` trait — no new methods

## File Changes

### zeblithic/harmony (implementation)

| File | Change |
|------|--------|
| `crates/harmony-rawlink/src/bridge.rs` | Add jitter hold logic to `run()` loop, gate explicit flush, 6 new tests |

### zeblithic/harmony-openwrt (docs)

| File | Change |
|------|--------|
| `docs/specs/2026-04-09-transmission-jitter-design.md` | This design spec |
| `docs/mesh-wifi-setup.md` | Note about jitter in "How it works" section |
| `README.md` | Mention jitter in L2 Transport section |

## Testing

### Unit tests (in `bridge.rs`)

1. **Jitter activates on inbound** — process inbound frames, verify explicit
   flush is suppressed for the hold duration. Use `MockSocket` to assert no
   `send_frame` calls during hold.

2. **No jitter without inbound** — push outbound frames with no inbound
   processing, verify flush happens every iteration as before.

3. **Jitter expires and flushes** — set up jitter, advance past deadline,
   verify accumulated batch is flushed.

4. **Auto-flush bypasses jitter** — during a jitter hold, push enough frames
   to fill the batch. Verify auto-flush sends immediately despite active
   jitter timer.

5. **Jitter not re-armed during hold** — inbound frames arriving while jitter
   is already active don't reset/extend the timer. Prevents indefinite hold.

6. **Jitter range** — statistical test: generate 1000 jitter values, verify
   all fall within 100-500ms and distribution isn't degenerate.

## What Is NOT Changed

- **UCI configuration** — no new knobs. Jitter is always-on.
- **Scout frame format or timing** — unchanged, own interval jitter.
- **BatchAccumulator** — no API changes. Jitter is in the bridge loop, not the
  accumulator.
- **Wire format** — no new frame types or headers.
- **Inbound frame handling** — unchanged. Jitter only affects outbound timing.
- **Auto-flush behavior** — unchanged. Full batches send immediately.
