---
status: proposed
date: 2026-11-28
---

# Check the release locally before publishing

## Context

The [previous release gate](require-complete-self-mutation-results.md) repeated the test suite across eight mutation shards.
A Perl module can read a file into a package variable while compiling.
Two shards can produce identical deparsed code and observe different values.

## Decision

Run the full release gate locally on a clean candidate.
Measure every mutant in one uncached run.
An earlier report may suggest a covering test to try first.
A missed detection restarts the normal test order.
Only the current run decides the verdict.

Record a successful local gate in the candidate's [GitHub commit status](https://docs.github.com/en/rest/commits/statuses).
GitHub Actions checks the status, builds and installs the archive on Linux and macOS, and verifies the archive selected for the Perl Authors Upload Server.

## Alternatives

Running the entire measurement on a dedicated hosted runner would require another machine.

## Consequences

A maintainer supplies the local compute time.
After a release proposal merges, its result transfers only when both commits identify the same [Git tree](https://docs.github.com/en/rest/git/commits).

## Confirmation

Reject a stale detector, a failed check, and a different tree.
Reconsider the decision if release preparation exceeds the local machine's capacity.
