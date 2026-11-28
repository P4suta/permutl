---
status: proposed
date: 2026-11-27
---

# Conclude shard observations in inventory order

## Context

The [existing merge](merge-shard-reports-only-as-one-complete-run.md) checks inventory.
Splitting Fold duplicates lowers its score from 75.0% to 66.7%.
Different compile-time data can initialize package variables with identical deparsed code.

## Decision

Store test observations and compiler comparisons per mutant.
Fingerprint sources, tests, execution settings, interpreter, and dependencies.
Verify copied inputs and key cached observations to them.
Require identified compiler inputs and compare shared inputs by content.
Match the driver's `PPI`, `PPIx::QuoteLike`, and `PPIx::Regexp` versions when reusing cached observations or merging shards.
Require a known compiler input protocol when merging or refreshing saved verdicts.
Exclude unchanged published reports from isolated copies at their recorded paths.
Fingerprint reports visible in place or through links.
Reuse detections when covering tests through the first failure match.
Interleave shards in verified inventory order.
Keep each source's first undetected mutant per compiled digest.

## Alternatives

File-based shards can overload one worker.
Recompilation requires the original environment.

## Consequences

Merge verified reports offline.
Older reports remain readable.
Use an unsplit run when compiler inputs remain unknown.

## Confirmation

Compare Fold verdicts, reasons, scores, and exits across modes.
Reject reordered mutants and incompatible inputs.
Revisit the inputs when the launcher gains a dependency.
