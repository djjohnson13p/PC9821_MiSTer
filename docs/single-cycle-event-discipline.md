# Single-Cycle Event Discipline

A contribution guideline for every pulse, strobe, and one-shot event in this core.

**An event is data.** A single-cycle pulse is a piece of data with exactly one owner of its
consumption, and its next-state update is written exactly once per register per cycle. The
rules below apply to every new `always` block, handshake, and module boundary that carries
one.

## The rules

**R1 — One event, one consumer.** A 1-clk pulse may be *observed* (read for telemetry) from
many places but *consumed* (acted on / cleared / acknowledged) by exactly one sequential
handler. If two handlers must react, route the pulse to a single merge point that updates
shared state once (the PIC's folded `ir_latch` NBA and the PCM86's `D_DONE` count fold are
the in-tree exemplars). Multi-arm `if` chains over the same pulse inside one `always` block
are banned; use `else if` with a **stated** priority, or — better — eliminate the overlap.

**R2 — No source-order semantics.** "This assignment must be last" is a defect detector, not
a fix. Wherever a comment says *last*, *first*, *precede*, or *wins*, two writers reach one
register in one cycle: fold them into one next-state expression (`next = f(old, eventA,
eventB)`) so the resolution is a boolean, not a position. Lint rule: flag any reg with two
or more `<=` sites reachable in the same evaluation of one `always` block.

**R3 — Set vs. clear collisions need a named, local, asserted rule.** For edge latches where
a lost event is unrecoverable (interrupt requests, completions), the rule is **set-wins**:
`latch <= (latch & ~clear) | set`. If the protocol demands ack-consumes-even-the-just-
arrived event (clear-wins), the producer must be able to re-request and an assertion must
state the contract. Never let the two conventions coexist in one tree.

**R4 — Coincident dual events are merged, never arbitrated by luck.** accept+completion,
tick+reload, ack+set, service+pending: write the combined case explicitly —
`(old & ~clear) | set`, `count <= count - n + writes_this_cycle`,
`promote = queued ? ... : accepted_this_cycle ? ...`, or a `case ({eventA, eventB})` with a
named `2'b11` arm (the keyboard FIFO's `{enqueue_key, deliver_key}` is the exemplar). Each
such merge gets a comment naming both events and a test that fires them together.

**R5 — Never suppress an event to fix a coincidence; account for it.** `done && !accept`
deletes a completion. Either (a) attach a **taken/owner flag** set at accept and tested at
consume (the EGC's `req_acc`, the INTA bridge's `inta_responded`) so every completion is
delivered to the transaction that owns it, or (b) queue the completion. Assert
`!(waiter && done_suppressed)`.

**R6 — No level-bubble edge detection.** Never leave a wait state by observing a level drop
(`if (!cpu_valid)`). Use an unconditional one-cycle bubble (the tram bridge's and the GRCG's
`S_HOLD`/`G_HOLD` pattern), or tag transactions (sequence/ID counter, one-hot grant). If a
bubble is protocol, the *producer* must assert it (e.g.
`assert ($fell(cpu_valid) || !accept_seen)`).

**R7 — Deferred consumption, not lost consumption.** An event arriving while its consumer is
busy goes into a pending flag consumed at the boundary (the EGC's `shift_arm_pend`, the
SDRAM's `pnd_valid`, the PIT's `read_stat_pend`) — with R3's set-priority at the boundary.
Sticky pending flags may be cleared **only by their consumer**, never by a free-running timer
wrap: `assert (!(pending && wrap))`.

**R8 — Assertions are the contract.** Every module boundary that hands pulses across gets
the `pc9821_memory_subsystem` style: one `$fatal`/`$error` per invariant ("two routes ready
in one cycle", "queue underflow", "route overlap"), plus a directed test that fires the two
colliding events in the same cycle (the `tb_pc9821_pcm86_bufrst` pattern). A comment that
documents a race must name the assertion that pins it. The `pc9821_gvram_arb` invariant
block is the model: done-vs-accept masking, the in-flight owner latch, and the burst merge
reduction are each an assertion, not a paragraph.

## Quick audit checklist for any new pulse

1. **Who sets it?** List *all* set sites.
2. **Who consumes it?** Must be ≤ 1 sequential consumer.
3. **Can any other event write the same registers in the same cycle?** Write the merge.
4. **Can it coincide with its own accept/ack?** Fold or flag (R5).
5. **Is it edge- or level-derived?** If level-drop-derived, it is a level-bubble wedge
   class (S3) — redesign (R6).
6. **If it crosses a clock domain**, it needs a FIFO or toggle handshake, never a bare
   pulse (see `src/common/cdc_vector_handshake_continuous.sv`, the held handshake the audio
   crossings use).
7. **Name the assertion** (R8) and the bench that fires the two colliding events together.
