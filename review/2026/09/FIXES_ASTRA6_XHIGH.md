# ASTRA6 XHIGH remediation

Review: `REVIEW_ASTRA6_XHIGH.md`, baseline `953a454`. Only listed findings are in scope.
Policy choices and verification limits are recorded with each finding. PASS means
the named local checks passed, not that unavailable historical/platform gates ran.

| Finding | Change | Files touched | Verification result |
|---|---|---|---|
| RA6X-025 (enabling step) | Added native XCTest target, isolated CLI/filesystem harness and frozen synthetic preset/dynamic fixtures with explicit expected fork bytes; retaining public self-test. Suite will grow in review order. | `Package.swift`, `Tests/unsitTests/*`, this ledger | PASS: `swift test`, 2 tests, macOS 26.6.2 / Swift 6.3.3. Historical corpus and macOS 11 / Swift 5.7 are unavailable; final coverage follows below. |
| RA6X-001 | Validate final names; reject empty/dot/parent components and block their logical subtree. Every member operation uses a single validated component and parent descriptor. | `MacFileWriter.swift`, `main.swift`, `ConfinementTests.swift`, `README.md` | PASS: unsafe names including NUL collapse in both CRC modes; sentinels unchanged and later siblings recovered. |
| RA6X-002 | Anchor root/descendants to no-follow directory descriptors; reject symlinks throughout root path and member directories; use `fsetxattr` for native resource forks and descriptor metadata. | `MacFileWriter.swift`, `main.swift`, `ConfinementTests.swift`, `README.md` | PASS: external directory sentinel/mtime, acquired-ancestor swap before both fork writes, final symlink/hard-link controls, ordinary roots. |
| RA6X-003 | Exclusive creation preserves all existing output, skips collisions with nonzero status, and blocks duplicate folders instead of merging them. Input archives overlapping output cannot be replaced. | `MacFileWriter.swift`, `main.swift`, `ConfinementTests.swift`, `README.md` | PASS: existing file/directory, both-fork duplicates, case/NUL/Unicode equivalence on this filesystem, duplicate folders, and overlapping input. |
| RA6X-015 | Add documented configurable input/fork/aggregate/member/depth/recovery limits, checked before allocations and output. Bounded input reads retain one Data buffer; both forks and damaged stored bytes reserve aggregate budget first. | `Limits.swift`, `SITArchive.swift`, `main.swift`, `LimitsAndDisplayTests.swift`, `README.md` | PASS: exact/over boundaries, combined forks, repeated members, deep listing, recovery work, UInt32-max declaration rejected before allocation, valid 66,754-byte high-ratio stream. Streaming decoded forks remains impractical in this bounded in-memory decoder; peak retained buffers are explicitly limited/documented. |
| RA6X-021 | Escape controls/backslashes in terminal records, warnings, errors and listed type fields without changing filesystem names. | `Display.swift`, `main.swift`, `LimitsAndDisplayTests.swift`, `README.md` | PASS: captured ESC/OSC/BEL/CR/LF/tab names in normal/list/quiet/no-verify modes; ordinary names retain mapping. |

Batch verification: `swift test` — 10 tests passed. Before confinement, the three
new confinement tests produced 49 assertions failing against the old executable;
before display escaping, its control-output regression also failed as expected.
