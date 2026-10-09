---
name: emacs-performance
description: Measure and repair native Emacs latency, redisplay, streaming and lifecycle costs using reproducible local fixtures.
---

# Emacs performance

Read the native UI design contract and repository specs. Start with a user-visible symptom and a representative workload: large Org transcript, streaming deltas, hundreds of records, repeated refresh, hidden buffers, or window resizing. Use owned local fixtures and actual runtime dependencies; provider authentication and inference are unnecessary.

Measure before changing code. Record source fingerprint, Emacs/Org/package versions, native compilation state, terminal/GUI, fixture size, GC settings, repetitions and raw observations. Use `benchmark-run` for synchronous paths, `profiler-start`/`profiler-report` for CPU or memory attribution, and elapsed timestamps for asynchronous completion. Report median and tail latency with GC counts; distinguish rendering, process/network waiting, parsing and storage. A batch microbenchmark does not prove interactive responsiveness.

Inspect `post-command-hook`, timers, process filters and sentinels, fontification, overlays, Org scans and synchronous file I/O. Avoid rescanning an entire transcript per delta. Cache only when invalidation is explicit. Coalesce work without losing final output, statuses, pending tool calls or immutable context. Hidden buffers must not create pointless recurring presentation work. Finish, abort, error and kill-buffer must release owned processes, timers and overlays.

Repair measured costs, then rerun the same workload and verify real keyboard input remains responsive during streaming. Check focus, point, viewport and data integrity separately. Do not add brittle time-limit unit tests or tune global GC/font-lock settings. Preserve raw evidence and explain measurement limits; if no bottleneck is demonstrated, report that result instead of inventing an optimization.
