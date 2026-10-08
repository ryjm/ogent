# Intent corpus method

This SDK adaptation normalizes 23 actual named boundary probes, each observed before and after changes, from the two independent scorers. It records the original batch argv, probe identifier, observed Lisp result/condition, and root classification; it does not claim a separate invented CLI or additional executions. Archived probe scripts and transcripts preserve the observations. No per-probe execution timestamp was available, so `ran_at` is null.

Subprocess status 0 means the collector completed: it caught Lisp conditions and serialized them. Each corpus row selects one observation from that batch, so do not replay it as a standalone ogent command or replace argv[0] with a product binary. Replay the archived script in the documented Emacs environment, with the appropriate historical source revision. Mutation probes use disposable fixtures.

Successful string aliases and literal leading-dash searches represent accepted intended arguments, not fuzzy destructive execution. Unknown configured tools teach a correction; pure unknown registry lookup continues to return nil and the stale wrapper retains its generic refusal. Those residual limitations remain visible in classifications and scores.
