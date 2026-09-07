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
| RA6X-004 | Bit consumption now throws at actual compressed EOF and latches truncation; no synthetic padding. Decoder errors retain safe prefixes for the forthcoming partial-member publication step. | `BitReaderLE.swift`, `PrefixCode.swift`, `StuffIt13.swift`, `DecoderTests.swift` | PASS: selector-only CRC-0 in both CRC modes, every byte truncation of all preset/shared/separate/extended golden streams, valid endings at all eight bit alignments. |
| RA6X-013 | Reject occupied leaves, both prefix conflicts, capacity oversubscription, unsupported widths/counts; use UInt64 canonical capacity arithmetic. | `PrefixCode.swift`, `DecoderTests.swift` | PASS: duplicate insertion, `[1,1,1]`, both prefix orders, count bounds, widths 1/31/32/33, incomplete/single-symbol tables and all golden vectors. |
| RA6X-014 | Compute repeat emission counts before table writes; reject crossing runs and lengths outside -1...32; retain zero and -1 omission and shared contexts. | `StuffIt13.swift`, `DecoderTests.swift`, `Support.swift` | PASS: metacodes 31–36, minimum/maximum repeats, exact fills/overruns, underflow/width-33, truncated extras, and compatible zero generated via increment(-1)/decrement(1). Reference canonical construction only assigns positive widths; compatibility fixtures decode expected A. |
| RA6X-005 | Enforce stored/decoded lengths and zero/nonzero consistency independently of CRC; retain damaged bytes in structured errors. Record unused terminal-match bytes without changing reference length-delimited completion. | `SITArchive.swift`, `StuffIt13.swift`, `DecoderTests.swift` | PASS: shorter/longer/zero stored forks, early end, exact output and crossing terminal match in both CRC modes. Partial-byte publication is integrated in RA6X-010 below. |
| RA6X-009 | Validated 0/0 forks succeed without decoder construction, including absent unsupported method fields; nonempty unsupported forks still fail. | `SITArchive.swift`, `DecoderTests.swift` | PASS: data-only/resource-only/entirely empty files with absent method 13/99/128; contradictory lengths still fail. |

Decoder compatibility evidence: XADMaster commit `137728c1d7e1ae8cd45234c4a8e5e540051bb6db`,
[`XADPrefixCode.m`](https://github.com/MacPaw/XADMaster/blob/137728c1d7e1ae8cd45234c4a8e5e540051bb6db/XADPrefixCode.m)
assigns lengths 1...32; [`CSStreamHandle.m`](https://github.com/MacPaw/XADMaster/blob/137728c1d7e1ae8cd45234c4a8e5e540051bb6db/CSStreamHandle.m)
limits reads to the declared stream length while `XADLZSSHandle.m` retains pending
match bytes. Thus a terminal match crossing that boundary is allowed by the
reference contract; a premature end marker or actual EOF remains damage.
Six decoder tests pass; all preexisting test groups also passed in the preceding
full run (its new alignment test needed an odd-width literal and was corrected).
