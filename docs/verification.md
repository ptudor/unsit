# Verification

## Compatibility comparison, 2026-09-07

A private corpus was extracted into fresh, isolated directories using the initial
`de48bad` implementation, the recent `a84d6e4` revision, and the replacement
decoder with the folder-summary fix. A saved original extraction and a fresh
`unar` 1.10.1 run provided additional comparisons. Source archive bytes and all
saved extracted files' bytes and metadata were verified unchanged. Private filenames, hashes, and contents are not
included in the repository or release artifacts.

| Measure | Original extraction | Updated extraction |
| --- | ---: | ---: |
| File members retained | 290 | 1,095 |
| Members with both forks validated and publication complete | 270 | 1,039 |
| Members with damaged forks, now named explicitly as partial | 20 | 56 |
| Combined data and resource fork bytes | 12,555,872 | 38,464,034 |

The additional 805 members comprise 769 complete member publications and 36
partial recoveries. All 290 earlier members have matching data and resource
SHA-256 pairs, lengths, modification dates, and FinderInfo in the updated output.
Every member reached by the reference also has a matching fork pair. Recovery
directory names and partial suffixes differ by design; byte comparisons account
for those path changes and duplicate content.

The new decoder produces the same fork bytes as the recent implementation on all
1,095 retained members. Increased recovery comes from traversal and error-handling
changes, rather than claiming that a decoder rewrite repairs source damage.
Folder metadata also improved: 22 of the 34 directories shared with the saved
extraction now have modification dates matching their archive start markers;
four already matched. Eight folders interrupted by structural damage remain
incomplete and are not assigned a completion date.

The corpus exposed a regression in the recent validator: folder markers can
contain nonzero aggregate lengths. Those values do not describe inline fork
payloads. Rejecting them caused unnecessary resynchronization and loss of trusted
folder placement. The fix accepts those markers, and a synthetic nested-folder
regression checks paths, both forks, listing, and restored dates.

All corpus runs still return nonzero. Damaged forks remain partial, hierarchy
after genuine gaps remains uncertain, and these version-2 containers trigger the
explicit unverified-count diagnostic. No version-2 root-count semantics were
guessed. Member completeness is distinct from complete archive restoration.

The packaged extractor was run again with JSON recovery reporting: 1,039 complete
files, 56 partial files, and 57 damaged forks. It identified five damaged header
gaps, skipped 257,337 bytes, and published 938 files after the hierarchy became
uncertain. These files now live in visible recovery folders. All 1,095 fork pairs
and file metadata still match the recent output. This confirms recovery of files,
not reconstruction of missing bytes or certainty about their original locations.

## Public automated checks

`swift test` runs 56 native tests without private inputs or network access. They
cover decoder bounds and codebooks, archive traversal, path confinement, output
collisions, metadata, syscall faults, interrupted publication, limits, CLI
semantics, and the app helper's extraction, collision, failure, and cancellation
workflow. Recovery report tests distinguish corruption from unsupported methods,
limits, and skipped validation. Updater tests cover version ordering, compatible
assets, metadata identity, SHA-256, byte limits, quarantine, cancellation,
collision avoidance, rollback detection, failed-check backoff, and newer-OS
advisories using simulated local responses. Scratch builds locate their own CLI
beside the test bundle.

Fourteen frozen synthetic archives have SHA-256 checksums. The five exhaustive
preset probes were independently decoded with `unar` 1.10.1; both native forks
match explicit expected bytes. See [method-13 verification](method-13.md).

Local runtime verification uses macOS 26.6.2, Swift 6.3.3, and Apple silicon on
APFS. CI is configured to run natively on Apple silicon and Intel macOS runners,
build app and CLI packages, and test the bundled helper. Those remote jobs must
pass on the published commit before a release is called verified.

The universal app was opened locally through Finder with multiple synthetic
archives, and a native file drag recovered a deliberately damaged synthetic
archive. The result showed two complete files, one partial file, and credit for
two files found beyond a damaged record. Both outputs and visible recovery paths
were checked. Disk-image packaging and checksums passed. The updater's first live
public upgrade remains a publication check.

Window restoration was checked in a separate app instance: three close/reopen
cycles through **Window → Show Unsit**, reopening with **⌘0**, and restoration
from a minimized window. The restore command remains enabled without a window.

Minimum macOS 11 CLI / macOS 12 app and Swift 5.7 runtime checks remain separate
platform gates. A cross-build alone does not establish native Intel runtime
behavior. Real failing volumes and power-loss durability are not tested; native
syscall faults and interrupted processes are covered.

## Repeating a private comparison

Keep archives and previous output outside the source tree. Build each revision
with the same toolchain into separate scratch directories, extract into fresh
destinations with verification enabled, and retain command status and diagnostics.
Record archive SHA-256 and a manifest containing relative paths, lengths and
SHA-256 for both forks, modification dates, and FinderInfo. Compare fork pairs
with multiplicity, accounting for explicit partial and recovery names. Separately
check expected folder dates and trustworthy paths against archive start markers.

Keep the full manifests private and publish only aggregate findings. The private
gate supplements the redistributable tests; it is not a dependency of CI.
