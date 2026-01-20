VYX-32: Marker mismatch (seed=1)

Summary
-------
A deterministic failing sequence was discovered for markers using seed=1. The failure reproduces locally and is tracked under VYX-32. This test has been added as a guarded spec so it does not run by default in CI.

How to reproduce locally
------------------------
- Fast deterministic repro (already available):
  - `VYX_DEBUG=1 ./bin/find_marker_failure` (compiled binary finds seed quickly)
  - or run the exact replay script: `VYX_DEBUG=1 crystal run tools/replay_seed1_exact.cr`

Guarded regression test
-----------------------
- `spec/marker_seed1_spec.cr` added. The test is skipped by default; to run it locally set:

  RUN_MARKER_REPRO=1 crystal spec spec/marker_seed1_spec.cr

Notes & context
----------------
- Tools useful for debugging:
  - `tools/replay_seed1_exact.cr`  — deterministic op replay for seed=1
  - `tools/step_repro_seed1.cr`    — step-by-step run with a TARGET_OP dump
  - `bin/find_marker_failure`      — compiled finder that locates failing seeds quickly
- Debugging flags:
  - Set `VYX_DEBUG=1` to enable invariant checks and verbose remap diagnostics

Next steps
----------
- Reproduce step-by-step with `tools/step_repro_seed1.cr` + `VYX_DEBUG=1` to pinpoint the mutation that causes marker migration divergence.
- Add a minimal fix ensuring node-level lists and global `@markers` registry remain consistent through splits/merges/deletes.
- Remove guarded skip once regression is fixed and add the test to CI.
