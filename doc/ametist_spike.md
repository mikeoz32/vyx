Ametist Spike — Buffer Actor

Status: spike branch `kozloffsky/vyx-54-ametist-spike`

Summary
-------
This spike implements a small per-buffer "actor" using Crystal fibers & channels as a stop-gap and testbed to validate actor-oriented Buffer semantics. The implementation lives in `src/vyx/buffer_actor.cr` and includes unit tests (`spec/buffer_actor_spec.cr`).

Why a spike
----------
- `Ametist` currently provides vector DB primitives but does not expose an actor runtime API (mailbox/supervision). Since you're the author, it's feasible to add minimal actor primitives to Ametist, which would be preferred for production.
- The spike provides a working actor facade that can be ported to Ametist when actor primitives are available.

Porting notes
-------------
- Replace `BufferActor` internals with an Ametist actor implementation that receives typed messages and supports supervision. The public BufferActor API (sync `text`, async `insert/delete`, `stop`) should be preserved.
- Use Ametist-provided request/response/future semantics if available; otherwise use an explicit reply channel in messages.
- Add tests for supervision/restart, and compare perf vs channel+fiber baseline.

Next steps
----------
- Create a small Ametist PR to add an actor mailbox primitive (typed `spawn` and `ask/tell` helpers) and supervision.
- After upstreaming or adding Ametist support locally, implement `src/vyx/ametist_buffer.cr` and add tests to prove equivalence.

Spike artifacts
---------------
- Branch: `kozloffsky/vyx-54-ametist-spike`
- Files: `src/vyx/buffer_actor.cr`, `spec/buffer_actor_spec.cr`

