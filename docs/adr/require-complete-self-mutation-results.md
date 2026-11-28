---
status: proposed
date: 2026-11-26
---
# Require complete self-mutation results

## Context

Timeouts and missing files can leave a perfect score.
A four-CPU Linux run exceeded seven hours before reaching half its inventory, beyond the [hosted job limit](https://docs.github.com/en/actions/reference/limits).

## Decision

Measure the complete project without cached verdicts.
The original manual workflow merged eight uncached shards and checked whether their inventory matched the checkout.
The [local release check](check-the-release-locally-before-publishing.md) measures the entire inventory in one run.
Require 100 percent, a completed verdict for every eligible mutant, and named suppressions with reasons.
Measure the shim on Perl 5.10, 5.14, and 5.18.
Require both statement coverage and branch coverage to meet their recorded floors.

## Alternatives

A threshold alone accepts an incomplete report.
One hosted job can expire before it produces a report.

## Consequences

Running eight shards repeated the original tests eight times.
Thirteen release cases exercise eight distributions.
Named runs preserve two verdicts across changes to the default profile and shard membership.

## Confirmation

`t/unit/self-measurement.t` rejects incomplete inventories, interrupted runs, and fabricated suppressions.
`t/unit/library-coverage.t` rejects regressions in either coverage fraction.
Review the accepted verdicts when the public API adds a status.
