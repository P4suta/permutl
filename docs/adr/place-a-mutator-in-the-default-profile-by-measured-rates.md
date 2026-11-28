---
status: accepted
date: 2026-11-26
---
# Place a mutator in the default profile by measured rates

## Context

A survivor should identify a test worth improving.
Equivalent code gives the developer nothing to distinguish.

## Decision

Require zero invalid mutants and zero unresolved calls.
Limit structural equivalence to 2% in each corpus and load failures to 10% across pinned distributions.
Probe up to four mutants per family per archive in fresh Perl processes after the original loads.

## Alternatives

Keeping every mutator enabled gives wider coverage at the cost of uninformative survivors.

## Consequences

Keep `comparison-boundary`, `call-swap`, `bitwise`, and `early-exit` in the extended profile.
Boundary changes matched 2/74 project originals and 0/62 dependency originals.
Call swaps matched 0/97 and 2/64 respectively.
One of eight bitwise changes matched because Perl removed a debugger branch in `namespace::clean`.
On Perl 5.44, 2/70 guarded exits matched inside version checks in `Module::Runtime` and `namespace::clean`.
Perl 5.10 can execute the guarded `eval` in `namespace::clean`.
The project enables `early-exit` for self-measurement.
All 25 boundary changes and 22 call swaps loaded.
Among default candidates, only statement removal failed a load probe, in 1/32 cases.

## Confirmation

Reevaluate the catalog with `mise run discover-mutants` and `mise run realworld` whenever the generator or corpus changes.
