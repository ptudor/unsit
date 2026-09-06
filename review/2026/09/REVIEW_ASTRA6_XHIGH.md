# Deep code review — unsit

Review date: 2026-09-06 (America/Los_Angeles). Source baseline: `de48bad3c1d3c7b29e11ae9bf834f977b3f70c14`, branch `main`. This is an analysis-only review: no source, package, or README changes are authorized or included. All locations refer to that baseline. IDs remain stable across review checkpoints.

## Scope and method

Read all 12 tracked files, 1,308 lines: `.gitignore`, `Package.swift`, `README.md`, and all nine Swift files in `Sources/unsit/`: `main.swift`, `SITArchive.swift`, `MacFileWriter.swift`, `StuffIt13.swift`, `StuffIt13Tables.swift`, `PrefixCode.swift`, `BitReaderLE.swift`, `CRC16.swift`, and `SelfTest.swift`. There are no other tracked targets, fixtures, dependencies, tests, CI workflows, or repository instruction files. The initial working tree was clean.

Traced command-line arguments → input bytes → archive/header recovery → folder state → fork slicing → Huffman/LZ decoding → length/CRC checks → data/resource fork writes → metadata → diagnostics and exit status. Reviewed list mode separately from extraction. The program is synchronous; concurrency exposure comes from other processes changing filesystem paths between pathname-based operations.

Validation used the unchanged executable and temporary, CRC-valid synthetic archives under `/tmp/unsit-ra6x-review/`. Fixtures touched only disposable output trees. Reproduction recipes and validation limits appear below. No unbounded allocation attack or real-user-file modification was performed.

Shared fix constraints: preserve successful ordinary CLI invocations and option spellings, supported method-0/method-13 bytes, Mac Roman/Finder name mapping for safe noncolliding names, native data/resource fork association, and the documented recovery of CRC-damaged bytes with explicit warnings. Do not alter the archive format or pretend to support other compression/encryption formats. There is no database or public library target. Internal helper contracts may be extended when all callers and tests are updated; each finding states the behavior that must remain compatible.

## Findings

### RA6X-001 — A parent-directory folder entry escapes the output root

- **ID:** RA6X-001
- **Severity:** High
- **Status:** Confirmed by executable reproduction.
- **Location:** `Sources/unsit/SITArchive.swift:82–91` (`decodeName`); `Sources/unsit/main.swift:114–124`; `Sources/unsit/MacFileWriter.swift:39–44`.
- **Problem:** Removing slashes and NULs does not make a name a safe path component. `..` survives and becomes an actual parent directory when concatenated to the extraction path. A crafted archive can overwrite accessible files outside the requested output directory and apply directory metadata there. Empty names and `.` also alias existing directories; NUL removal can manufacture any of these names.
- **Evidence:** A valid start-folder header named `..`, a stored file `escaped` containing `ESCAPE`, and an end-folder marker extract to the sibling of `out`, not inside `out`. The command exits 0 with no warning. `dirStack.append(root + "/..")` is the controlling data flow. Header CRC validation provides no protection because the archive author can calculate it.
- **Fix specification:** Validate the final decoded component before any filesystem operation. Reject or deterministically rename empty names, `.` and `..`, including names that become those values after normalization/NUL handling; diagnose the member and preserve folder traversal state without writing through its rejected path. Add a containment invariant for every output operation. Keep valid Mac Roman names and the intentional `/` → `:` Finder mapping. Do not interpret member names as relative paths or add support for archive symlinks. Coordinate descriptor-based confinement with RA6X-002.
- **Verification:** Extract nested `..`, `.`, empty, NUL-only, and `..\0` folder fixtures inside a disposable parent containing sentinel files. Assert no outside bytes, metadata, or directory entries change; all unsafe names are diagnosed; later safe siblings remain recoverable. Run with and without `--no-verify`.

### RA6X-002 — Existing directory symlinks redirect extraction outside the root

- **ID:** RA6X-002
- **Severity:** High
- **Status:** Confirmed for directory symlinks; pathname race exposure confirmed by source, race timing not exercised.
- **Location:** `Sources/unsit/main.swift:95–96, 114–124`; `Sources/unsit/MacFileWriter.swift:24–57, 76–87`.
- **Problem:** Valid-looking names are resolved through pre-existing directory symlinks. Each data, resource, and timestamp operation resolves a pathname again, allowing an external process to replace an ancestor between operations. Lexical name checks alone cannot confine writes. `XATTR_NOFOLLOW` protects only that specific xattr call's final component, not ancestor traversal or subsequent `open`/`utimes` calls.
- **Evidence:** Precreate `out/link` as a symlink to a disposable sibling directory. Extract a folder `link` containing file `escaped`. Its bytes appear in the sibling directory and the process exits 0. Control probes on this macOS showed that a final-component file symlink and a hard link were replaced by `createFile` without changing their original targets; this finding does not claim those two controls followed links.
- **Fix specification:** Establish an output-root directory descriptor and resolve/create each descendant relative to verified directory descriptors with no symlink following. Keep the descriptors through file creation, fork writes, and metadata restoration; use descriptor equivalents where available. Reject archive-member directory symlinks even when they already exist. Define root symlink handling explicitly: either reject it or resolve it once and anchor all writes to that opened directory. Do not rely on `realpath`/prefix checks followed by ordinary pathname writes. Preserve native macOS forks and successful extraction into ordinary directories.
- **Verification:** Repeat the directory-symlink fixture and assert the external sentinel and metadata are unchanged. Add a controlled ancestor-swap race between directory acquisition and file/fork writes, plus final-component symlink and hard-link controls. Verify safe extraction still works under an explicitly chosen ordinary root.

### RA6X-003 — Duplicate and colliding names silently destroy earlier output

- **ID:** RA6X-003
- **Severity:** High
- **Status:** Confirmed by executable reproduction on the current case-insensitive filesystem.
- **Location:** `Sources/unsit/SITArchive.swift:82–91`; `Sources/unsit/main.swift:124–141`; `Sources/unsit/MacFileWriter.swift:24–28`.
- **Problem:** Every file is created at its final name with replacement behavior. Existing user files and earlier archive members are overwritten without warning or an explicit overwrite option. Mac Roman decoding/NUL removal and destination case/Unicode equivalence add collisions even when archive names differ. Success counters count processed entries rather than surviving files, concealing loss.
- **Evidence:** Two entries named `f` with contents `FIRST` and `SECOND` produce one file containing `SECOND`, while stdout says “Extracted 2 file(s)” and exit status is 0. The same happens with `File`/`file` and `f`/`f\0`. An existing `out/f` containing `ORIGINAL` becomes `REPLACED` without warning.
- **Fix specification:** Default to preserving existing output. Resolve collisions before committing a member: either keep both using deterministic unique names and report the mapping, or skip with a nonzero result. Use filesystem-aware, race-safe exclusive creation rather than only a Swift string set. Detect file/file, file/directory, duplicate-folder, case, normalization, and sanitized-name collisions. Explicitly protect the input archive if the chosen output location overlaps it. If overwrite support is introduced, require an explicit option and combine it with RA6X-016's member transaction. Preserve names for noncolliding members and native fork association; never silently merge unrelated archive folders.
- **Verification:** Test existing files, duplicate members with both forks, case-equivalent names, NUL-collapsed names, Unicode-equivalent names where supported, and file/directory collisions. Assert original bytes and metadata survive the default policy, no reported-success member disappears, and the input archive cannot be replaced accidentally.

### RA6X-004 — Compressed EOF is replaced with infinite zero bits and can pass CRC

- **ID:** RA6X-004
- **Severity:** High
- **Status:** Confirmed by executable reproduction.
- **Location:** `Sources/unsit/BitReaderLE.swift:23–29`; `Sources/unsit/PrefixCode.swift:74–81`; `Sources/unsit/StuffIt13.swift:119–160`; `Sources/unsit/main.swift:135–138, 161–175`.
- **Problem:** Running out of compressed bytes is not surfaced as an error or recovery event. The reader supplies zeros indefinitely, and the decoder can fabricate the entire declared output from them. Fork CRC verification does not reliably expose this: CRC-16/ARC of any number of zero bytes is zero. This differs from the intentional zero-initialized LZ history window, which must not be removed indiscriminately.
- **Evidence:** A method-13 fork containing only selector byte `10` (hex), declared uncompressed length 4,096, and data CRC 0 produces 4,096 zero bytes, exits 0, and emits no warning. No encoded symbol exists after the selector. `fill` explicitly selects `0` whenever `bytePos >= data.count` and keeps incrementing the position.
- **Fix specification:** Track the actual compressed bit boundary and distinguish available bits from any bounded decoder lookahead padding. Consuming bits beyond the available stream must create a persistent truncation/recovery condition propagated to the fork and command result even when CRC matches or `--no-verify` is set. If preserving best-effort output, bound synthetic padding, mark it explicitly, and apply RA6X-015's resource budget. Keep correct LSB-first reading, valid byte-end padding, preset/dynamic decoding, and documented 64 KiB zero-initialized LZ history semantics.
- **Verification:** Reproduce selector-only input, every byte truncation of valid streams, and truncated dynamic tables/match extras. Assert no malformed stream is reported fully verified. Include CRC-0 all-zero expected output and `--no-verify`, plus valid streams ending at all eight bit alignments.

### RA6X-005 — Fork length mismatches are accepted as successful extraction

- **ID:** RA6X-005
- **Severity:** High
- **Status:** Confirmed for stored forks and early method-13 end markers.
- **Location:** `Sources/unsit/SITArchive.swift:158–168`; `Sources/unsit/StuffIt13.swift:108–110, 139–140, 153–164`; `Sources/unsit/main.swift:161–175`.
- **Problem:** There is no invariant that a decoded fork contains its advertised number of bytes. Stored data ignores the uncompressed length; the method-13 end marker returns a short buffer; a final match is silently clipped. CRC checks are independent of length and are skipped altogether when the declared uncompressed length is zero. Truncated or contradictory files therefore appear complete.
- **Evidence:** A stored fork containing `A`, declared length 20, and CRC of `A` writes one byte and exits 0. A stored fork with five bytes, declared length 0, and deliberately wrong CRC also exits 0. Method-13 bytes `10 16` encode an immediate preset-1 end marker; declaring length 20 with CRC 0 writes an empty file and exits 0.
- **Fix specification:** Validate stored compressed/uncompressed length equality and require the actual decoded length to equal the declared length for a clean result. Classify premature end markers and contradictory zero-length declarations as structural damage independently of optional CRC checks. Record whether the expected-length boundary is reached in the middle of a match and validate the format's allowed terminal behavior before changing valid stream handling. Keep recoverable bytes under the explicit partial-output policy; do not silently pad, truncate, or rewrite header lengths to make verification pass. Do not require an additional terminator if the valid format allows length-delimited completion.
- **Verification:** Cover shorter/longer stored forks, zero/nonzero length contradictions, early end markers, exact output, final matches crossing the declared boundary, and both CRC modes. All length mismatches must be diagnosed and return nonzero even when the CRC of the returned bytes matches.

### RA6X-006 — Archive boundaries and incomplete traversal are not validated

- **ID:** RA6X-006
- **Severity:** High
- **Status:** Confirmed by executable reproduction.
- **Location:** `Sources/unsit/SITArchive.swift:61–68, 130–152`; `Sources/unsit/main.swift:109–111, 153–157, 178–204`.
- **Problem:** The parser checks only `SIT!`, ignores `rLau` and archive length, stores but never uses the declared count, and silently stops on a partial final header or failed resynchronization. List mode never validates payload extents. Successfully resynchronized damage is omitted from extraction's final error condition, and list mode always returns 0 after warnings. Scripts cannot distinguish an intact archive from missing members or unexplained trailing data.
- **Evidence:** A 22-byte header declaring one missing entry, a 60-byte partial entry, and a final header with bad CRC each list zero files and exit 0 without warning. `SIT!` with `NOPE` instead of `rLau` is accepted. List mode reports a member whose compressed length exceeds EOF without error. A second valid entry appended beyond the header's declared archive length is extracted. A 17-byte resync gap emits warnings but returns 0. `onResync` is never called when no later header is found.
- **Fix specification:** Parse and validate both signatures and the declared archive extent, distinguish expected EOF from incomplete headers/payloads, and return a traversal report containing corruption, terminal gaps, and incomplete-member information to both CLI modes. Bound ordinary parsing to the declared archive extent; any deliberate salvage beyond it must be explicit and diagnosed. Verify the format/version meaning of `numFiles` (including folder counting) before enforcing it, then report applicable discrepancies rather than silently ignoring them. Preserve continuing past recoverable damaged members, but return nonzero whenever bytes/members are lost or completeness is uncertain. `--no-verify` must affect fork CRC only.
- **Verification:** Test every header/payload truncation boundary, missing final members, unrecoverable tail CRC damage, valid empty archives, wrong secondary signature, declared lengths shorter/longer than the physical file, count semantics for nested folders, appended valid-looking entries, and successful resync. Check diagnostics and exit codes in list, extraction, quiet, and no-verify modes.
- **Needs investigation:** Establish precisely what archive-header `numFiles` counts for each supported classic version, especially nested folders. Check actual versioned archives or a format specification before comparing it with the CLI's recursive file count. The signature, length, EOF, and exit-status defects above are independently confirmed and do not depend on that answer.

### RA6X-007 — Resynchronization trusts a 16-bit CRC without structural plausibility

- **ID:** RA6X-007
- **Severity:** High
- **Status:** Confirmed by executable reproduction.
- **Location:** `Sources/unsit/SITArchive.swift:75–79, 94–102, 133–150`.
- **Problem:** Any 112-byte block whose first 110 bytes match the last two is accepted as a member header. A CRC match in damaged/compressed data is not enough to establish a boundary. Bogus lengths are then used to jump over genuine later entries; empty names, impossible name lengths, and contradictory folder markers are accepted. This undermines the repository's central promise of recovering members after damage.
- **Evidence:** A block of 112 zero bytes is accepted as an empty-name file because its CRC is zero. A 17-byte gap followed by a CRC-valid header with name length 255, method 255, and compressed length 10,000 is selected as the recovered member; a genuine `good` entry after it is never visited. List mode exits 0. No name, kind, or payload-bound check participates in `isValidHeader`.
- **Fix specification:** Separate checksum checking from a structural candidate validator. During recovery require a plausible name field, coherent marker/flag interpretation, and checked payload bounds within the selected archive extent; reject impossible candidates and keep scanning. Use next-boundary/folder consistency as corroborating evidence where available, and explicitly report ambiguous recovery rather than declaring it trustworthy. Do not filter out every unsupported compression method: a real unsupported member still has to be identified, diagnosed, and skipped by its validated extent so later supported members remain reachable. Preserve valid empty end-marker names if the format permits them.
- **Verification:** Place zero-filled blocks and CRC-valid but impossible headers before real members. Assert the real members are recovered, false candidates do not control offsets or paths, unsupported real members are still reported, and valid folder markers remain recognized. Include malformed lengths near EOF and random damaged spans with deterministic seeds.

### RA6X-008 — Recovery retains an untrustworthy folder stack and misplaces files

- **ID:** RA6X-008
- **Severity:** High
- **Status:** Confirmed by executable reproduction.
- **Location:** `Sources/unsit/main.swift:102–124, 178–195`; `Sources/unsit/SITArchive.swift:130–152`.
- **Problem:** A damaged folder start/end marker can disappear during resync, but the caller keeps using its old stack as though hierarchy were intact. Missing end markers put later root files inside an earlier folder; missing starts flatten children. Extra end markers are silently clamped at root and unclosed folders are never diagnosed. This corrupts the recovered directory layout and can combine with name collisions to lose bytes.
- **Evidence:** Start `dir`, file `inside`, an end `dir` header with one CRC bit flipped, then root file `root_file`. Extraction skips the bad end marker and writes `out/dir/root_file`, exits 0, and issues only a skipped-bytes warning. An unclosed folder and an extra root-level end marker also complete without a structure warning. List mode mirrors the wrong hierarchy.
- **Fix specification:** Make hierarchy state and uncertainty explicit across parser and extraction/list consumers. Detect unmatched starts/ends. After a resync that could omit structural records, do not assign later files to the prior path without corroboration; use validated parent information if supported, otherwise place uncertain recoveries in a clearly reported collision-safe recovery directory keyed by offsets. Keep intact archive hierarchy and continue recovering independently identifiable files. Do not “fix” this merely by resetting depth to zero: that guesses a different potentially wrong path. Integrate with RA6X-003, RA6X-006, and RA6X-007.
- **Verification:** Damage a start, an end, and multiple nested markers independently; include identically named members in different folders. Verify no uncertain member is silently attached to a trusted directory, no outputs overwrite one another, unbalanced archives return nonzero, and list/extraction agree on recovery status and paths.

### RA6X-009 — An absent compressed fork prevents recovery of the present fork

- **ID:** RA6X-009
- **Severity:** Medium
- **Status:** Confirmed by executable reproduction; comparison with the reference parser corroborates ignoring absent forks.
- **Location:** `Sources/unsit/main.swift:126–133`; `Sources/unsit/SITArchive.swift:158–170`; `Sources/unsit/StuffIt13.swift:24–25`.
- **Problem:** Both fork decompressors are invoked unconditionally, even when a fork has zero compressed and uncompressed lengths. A zero-byte absent resource fork with method 13 throws `emptyInput`, so a perfectly good stored data fork is discarded. A method byte has no encoded stream to select in this case.
- **Evidence:** A file with resource method 13, resource compressed/uncompressed lengths 0, and stored data `GOOD` produces no file and exits 1 with `emptyInput`. The [reference container parser](https://github.com/MacPaw/XADMaster/blob/137728c1d7e1ae8cd45234c4a8e5e540051bb6db/XADStuffItParser.m) processes resource and data forks conditionally on their uncompressed lengths.
- **Fix specification:** After validating the fork range and consistency, treat compressed length 0 plus uncompressed length 0 as an absent fork and return an empty successful result without initializing a decoder. Handle resource-only, data-only, and entirely empty files. Do not extend this shortcut to zero/nonzero length contradictions or to encrypted/unsupported nonempty content; RA6X-005 must diagnose those cases. Keep unsupported nonempty compression methods as explicit errors.
- **Verification:** Extract data-only and resource-only files with method 13 on the absent side, both absent sides, and absent unsupported-method fields. Assert present fork bytes and metadata are preserved; contradictory lengths still fail independently of `--no-verify`.

### RA6X-010 — One damaged fork discards the other recoverable fork

- **ID:** RA6X-010
- **Severity:** Medium
- **Status:** Confirmed by executable reproduction.
- **Location:** `Sources/unsit/main.swift:125–145`; `Sources/unsit/StuffIt13.swift:108–164`.
- **Problem:** Resource decompression, data decompression, verification, and writing share one `do/catch`. A thrown error on either side discards the entire member, even if the other fork is valid. If a decoder throws after producing a prefix, its local output is also inaccessible. This is inconsistent with the documented best-effort recovery of damaged archives.
- **Evidence:** Resource bytes `60` (illegal method-13 selector), resource method 13, and stored data `GOOD` yield no output. Swapping the valid and invalid forks has the same result. The resource error prevents data decompression entirely; a later data error discards the already decoded resource buffer.
- **Fix specification:** Track a separate outcome for each fork, including complete bytes, safe partial bytes, absence, and diagnostics. Attempt independently addressable forks even if one fails. Preserve the intact fork and any safely recovered partial output under a clearly identified partial-member policy, with a nonzero result and per-fork diagnostics; never present an omitted failed fork as a clean empty fork. Coordinate final publication with RA6X-016 so an incomplete member does not replace an existing complete file. Preserve unsupported-method errors and the existing behavior of retaining CRC-mismatched bytes with warnings.
- **Verification:** Test valid data/bad resource, valid resource/bad data, both bad, absent/valid, and a method-13 error after several valid literals. Assert all independently recoverable bytes survive, partial members are unambiguous, originals are preserved, later members are still extracted, and the exit status remains nonzero.

### RA6X-011 — Flagged folder markers are misclassified as files

- **ID:** RA6X-011
- **Severity:** Medium
- **Status:** Confirmed by source comparison and executable reproduction.
- **Location:** `Sources/unsit/SITArchive.swift:94–100`; `Sources/unsit/main.swift:113–145`; `README.md:103–105`.
- **Problem:** Folder recognition compares whole method bytes to `0x20`/`0x21`. The format carries folder flags in those bytes, so a folder marked as containing encrypted children (`0x30`/`0x31`) is treated as a file with an unsupported compression method. Its unencrypted children are then extracted at the wrong hierarchy level. Unsupported encryption does not justify flattening otherwise recoverable content.
- **Evidence:** Start `dir` with method bytes `0x30`, stored child `inside`, end `dir` with `0x31`, then root file `root_file`. The program warns about unsupported methods 48 and 49 and writes `out/inside` instead of `out/dir/inside`. The [reference parser's folder mask](https://github.com/MacPaw/XADMaster/blob/137728c1d7e1ae8cd45234c4a8e5e540051bb6db/XADStuffItParser.m) excludes both the encrypted bit `0x80` and contains-encrypted bit `0x10` before recognizing markers.
- **Fix specification:** Interpret marker and flag bits separately for both fork method fields; recognize flagged folders and preserve their traversal structure. Keep flags available for diagnostics. Reject contradictory start/end combinations through RA6X-007. Do not simply mask encryption off ordinary file methods and feed ciphertext to the decoder; encrypted nonempty forks must remain explicitly unsupported unless separately implemented. Update the format note to describe recognized marker flags.
- **Verification:** Cover both method-field positions, flagged starts/ends, nested folders with a mixture of encrypted and plain children, and contradictory markers. Plain children must retain the correct paths; encrypted content must not be reported decoded successfully.

### RA6X-012 — A single directory creation failure aborts unrelated later members

- **ID:** RA6X-012
- **Severity:** Medium
- **Status:** Confirmed by executable reproduction.
- **Location:** `Sources/unsit/main.swift:114–117, 142–150`.
- **Problem:** File failures are caught per member, but a folder creation error escapes to the outer catch and terminates traversal. An existing file where a directory belongs, an inaccessible subtree, or a path-length failure prevents recovery of later independent root members.
- **Evidence:** Precreate `out/blocked` as an ordinary file. An archive with folder `blocked`, its child, its end marker, and a later root file exits immediately at the folder error; `later` is not extracted. The original sentinel remains intact, but the archive recovery stops.
- **Fix specification:** Separate logical folder nesting from whether its destination directory could be created. Catch/report a folder failure locally, mark its subtree as blocked or explicitly rerouted by the collision policy, and continue consuming nested markers until safe siblings can be recovered. Do not leave the stack unchanged and extract failed-folder children into the parent. Preserve a nonzero final status and report affected members. Coordinate with RA6X-003 and RA6X-008.
- **Verification:** Test existing-file collisions, permission failures, nested blocked folders, and a too-long component/path in a disposable tree. The blocked subtree must not escape or flatten, later safe siblings must survive, and all failures must contribute to the result.

### RA6X-013 — Huffman insertion silently replaces an existing leaf

- **ID:** RA6X-013
- **Severity:** Medium
- **Status:** Confirmed with a Swift harness linked to unchanged source and a malformed dynamic-stream fixture.
- **Location:** `Sources/unsit/PrefixCode.swift:30–44, 50–64`; `Sources/unsit/SelfTest.swift:35–45`.
- **Problem:** `insert` rejects internal prefix conflicts but never checks whether the final node already has a symbol. Duplicate bit patterns overwrite the previous symbol. Canonical code assignment also lacks an oversubscription check, so an overflowing assignment wraps onto an existing code path. Malformed tables are decoded with silently changed symbols, and the self-test's claim that it catches over-full trees is false for this case.
- **Evidence:** `PrefixCode.canonical(lengths: [1, 1, 1], count: 3)` succeeds; a zero bit decodes as symbol 2 because it replaced symbol 0. Two explicit insertions of code 0/length 1 with values 42 and 99 decode as 99. A dynamic method-13 stream defining 321 length-1 symbols is accepted and produces an immediate end marker rather than rejecting the table. The [reference prefix insertion](https://github.com/MacPaw/XADMaster/blob/137728c1d7e1ae8cd45234c4a8e5e540051bb6db/XADPrefixCode.m) requires the final node to be empty.
- **Fix specification:** Reject an occupied destination leaf as well as prefix/internal-node conflicts. Validate canonical capacity before assigning each code and avoid relying on `&+=` overflow or truncated high bits. Enforce the supported code width and safe count bounds. Preserve incomplete but valid tables and valid single-symbol codes; do not require every alphabet to fill the full binary tree. Keep all preset symbol assignments and bit ordering unchanged.
- **Verification:** Add direct duplicate-insert and oversubscribed `[1,1,1]` tests, prefix conflicts in both insertion orders, boundary code widths, valid incomplete/single-symbol alphabets, and an archive-level malformed dynamic table. All existing preset/dynamic golden vectors must retain their bytes.

### RA6X-014 — Dynamic Huffman table parsing clips run overruns and accepts invalid lengths

- **ID:** RA6X-014
- **Severity:** Medium
- **Status:** Confirmed by executable reproduction.
- **Location:** `Sources/unsit/StuffIt13.swift:67–93`; `Sources/unsit/PrefixCode.swift:31, 50–64`.
- **Problem:** The local `put` helper drops out-of-range writes instead of rejecting an invalid repeat run. Table parsing then continues at the next table despite having accepted an impossible symbol count. Increment/decrement metacodes can also generate lengths outside the supported range; negative values are silently omitted and lengths beyond the UInt32 representation are accepted. These malformed states are not equivalent to the valid absent-symbol sentinel.
- **Evidence:** Define length 9 once, four maximum metacode-36 runs (74 positions each), then a 25-position run: `1 + 4*74 + 25 = 322` values are claimed for 321 symbols. The final value is silently dropped; a following valid literal `A` extracts with exit 0 and no warning. A dynamic table with lengths `[31,32] + [33]*319` also extracts `A` successfully. The [method-13 reference construction](https://github.com/MacPaw/XADMaster/blob/137728c1d7e1ae8cd45234c4a8e5e540051bb6db/XADStuffIt13Handle.m) uses a maximum code width of 32; permissiveness in old reference parsing is not a reason to silently accept an overrun here.
- **Fix specification:** Calculate each run's total emitted positions, including the common final assignment, before modifying the index. Reject any run crossing the table size; retain exact-boundary runs. Validate each resulting length against the supported range and the format's omitted-symbol semantics before canonical construction; distinguish `-1` from values below the sentinel and establish whether zero is a permitted omitted state with compatibility fixtures. Reject positive lengths over 32. Reuse RA6X-004's actual EOF tracking and RA6X-013's code validation. Keep selector bit 3's table reuse and the existing valid metacode repeat counts unchanged.
- **Verification:** Exercise metacodes 31–36, each repeat's minimum/maximum length, exact final-slot fills, one-slot and larger overruns, decrements past omission, increments through 32, and truncation during repeat extras. Valid dynamic tables with shared and separate contexts must still decode identically; invalid tables must never produce a clean result.
- **Needs investigation:** Determine whether a generated length of exactly zero is a legitimate omitted-symbol encoding in the target corpus, in addition to the explicit `-1` sentinel. Check streams using increment after `-1` and decrement from 1; do not reject zero based only on the positive-width rule. The run-overrun and width-33 reproductions remain confirmed regardless.

### RA6X-015 — Archive-controlled sizes can exhaust memory, disk, and work budgets

- **ID:** RA6X-015
- **Severity:** High
- **Status:** Confirmed unbounded expansion and allocation path; intentionally not tested at destructive maximum sizes.
- **Location:** `Sources/unsit/main.swift:73–80, 126–141, 185–189`; `Sources/unsit/SITArchive.swift:71–73, 115–118, 162`; `Sources/unsit/StuffIt13.swift:108–119`; `Sources/unsit/MacFileWriter.swift:26`.
- **Problem:** The entire input is loaded and copied to an array, compressed forks are copied again, both decompressed forks are held at once, and `reserveCapacity` trusts a UInt32 size from the archive. There are no per-fork/aggregate output limits, expansion limits, member limits, or nesting/work limits. A very small archive can request roughly 4 GiB per fork before validation and repeated members can fill disk. List mode also constructs depth-proportional indentation for arbitrarily deep nesting.
- **Evidence:** A bounded test with a 135-byte archive and selector-only fork produced 16,777,216 output bytes, returned 0, and reached 56,770,560 bytes maximum RSS. Changing the declared UInt32 length increases the unconditional reservation and decode loop bound; no policy check intervenes. This is an independently needed resource policy even after RA6X-004, because valid highly compressed streams can also expand substantially.
- **Fix specification:** Introduce explicit, documented limits for input size, individual and aggregate decoded bytes, members, nesting, and recovery work, checked before allocation or output growth with overflow-safe arithmetic. Give large legitimate recovery jobs a deliberate override rather than silently accepting unlimited resource use. Bound peak memory by streaming/mapping input and emitting fork data incrementally with incremental CRC where practical; enforce the same totals for partial/synthetic output. Preserve valid 64 KiB LZ history semantics and byte-identical output within the configured budget. Do not disguise allocation failure as a CRC mismatch.
- **Verification:** Use small configurable limits to test each boundary and one-byte-over rejection, two forks individually below but collectively above budget, repeated members, valid high-ratio streams, and deep list-only archives. Assert bounded RSS/work and no uncontrolled disk growth; use a subprocess limit for maximum-size headers rather than allocating GiB in a test.

### RA6X-016 — Publishing the data fork before the rest of the member causes destructive partial writes

- **ID:** RA6X-016
- **Severity:** High
- **Status:** Confirmed with targeted resource-open and write fault injection against the unchanged executable.
- **Location:** `Sources/unsit/MacFileWriter.swift:24–36, 48–60`; `Sources/unsit/main.swift:138–145`.
- **Problem:** The final destination is created/replaced before its resource fork and metadata are written. Failure after data publication leaves a partial member at the normal final path and destroys any previous complete file. A nonzero exit cannot restore those lost bytes. Even if Foundation makes the individual data write atomic, the complete native Mac file is not an atomic transaction.
- **Evidence:** Start with data `ORIGINAL` and resource `OLD_RESOURCE`. Inject `ENOTSUP` only when opening the new named resource fork: extraction reports zero successful files, but the destination contains `NEW_DATA` and the old resource is gone. Inject a one-byte successful resource write followed by `ENOSPC`: the final file contains `NEW_DATA` plus resource byte `R`, with the original both forks lost. No rollback or cleanup exists.
- **Fix specification:** Build a member in a unique sibling temporary file inside RA6X-002's confined directory, write both forks, check I/O completion, and apply/report metadata before atomically publishing according to RA6X-003's collision policy. On failure retain any pre-existing destination unchanged. Either clean up temporary output or publish recoverable partial bytes under an explicitly distinct partial name with diagnostics, as specified by RA6X-010. Define durability requirements and handle any required flush/close failures before publication. Never remove the old destination as a preliminary step to rename.
- **Verification:** Inject failures at data creation, resource open, after a short resource write, close/flush, metadata, and final rename, and interrupt the process between stages. Assert a previously complete file remains unchanged unless a whole replacement commits, partial files cannot masquerade as completed members, and orphan cleanup stays within the confined tree.

### RA6X-017 — Resource-fork I/O mishandles interrupted writes, large requests, and close errors

- **ID:** RA6X-017
- **Severity:** Medium
- **Status:** Interrupted-write and close handling confirmed by fault injection; oversized-write limit confirmed from the installed macOS SDK manual, not exercised with a GiB allocation.
- **Location:** `Sources/unsit/MacFileWriter.swift:48–60`; `Sources/unsit/MacFileWriter.swift:11–19`.
- **Problem:** Any nonpositive `write` result aborts, including a recoverable `EINTR`; one call requests the entire remaining fork rather than a supported bounded chunk; and `close` is discarded in `defer`. Close can report a delayed write error, so a fork can be counted successful despite failed persistence. For a zero-byte write the code also reports an unrelated/stale `errno`, while the dedicated `shortWrite` case is unused.
- **Evidence:** Inject a single `EINTR` on the first resource write and allow subsequent writes to work: extraction aborts and leaves an empty resource fork. Inject `close` returning `-1/EIO`: extraction exits 0 with no warning. Apple's [write manual](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/write.2.html) documents interrupted writes; its [close manual](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/close.2.html) documents delayed write errors. The installed SDK's `usr/share/man/man2/write.2` additionally states that requests exceeding `INT_MAX` fail without a partial write; UInt32 fork sizes can exceed that limit.
- **Fix specification:** Retry `write` after `EINTR`, continue after positive short writes, cap request size to a safe platform-supported chunk, and treat zero progress as an explicit short-write error. Capture errno immediately on a negative return. Check the final close/required flush result and propagate it to the member transaction and command status while ensuring cleanup closes descriptors once. Do not blindly retry `close` on a possibly reused descriptor; follow the platform's close semantics. Preserve normal resource fork bytes and empty-fork handling.
- **Verification:** Inject `EINTR` followed by success, repeated short writes, zero progress, `ENOSPC`, and close `EIO`. Verify exact bytes for recoverable conditions and nonzero status for permanent failures. Test the request-size cap with an I/O stub and counters, avoiding a real multi-GiB fixture.

### RA6X-018 — Finder metadata and timestamp failures are silently reported as success

- **ID:** RA6X-018
- **Severity:** Medium
- **Status:** Confirmed by fault injection against the unchanged executable.
- **Location:** `Sources/unsit/MacFileWriter.swift:35–44, 65–87`; `Sources/unsit/main.swift:138–141, 157`.
- **Problem:** Both metadata helpers discard syscall return values and cannot report failure. A filesystem that rejects FinderInfo or timestamps yields files lacking the type/creator, flags, or date the tool promises to restore. Classic files may depend on type/creator association, so successful data bytes alone do not establish successful restoration.
- **Evidence:** Inject `setxattr(..., "com.apple.FinderInfo", ...) = -1/ENOTSUP`: the xattr is absent, but extraction exits 0 without warning. Inject `utimes = -1/EPERM`: the file keeps its newly created timestamp, again with exit 0 and no warning. Both calls are explicitly assigned to `_`. Apple's [setxattr](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/setxattr.2.html) and [utimes](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/utimes.2.html) contracts expose failure through return values and errno.
- **Fix specification:** Return structured metadata outcomes or throw errors carrying the path, operation, and captured errno. Attempt independent metadata fields even if one fails, preserve recoverable bytes, warn in quiet mode, and return a nonzero incomplete-restoration result. Integrate transaction publication with RA6X-016 without silently deleting useful recovered bytes. If unsupported destinations require a fallback representation, make it explicit and preserve the original metadata values rather than declaring them restored. Keep the 32-byte FinderInfo layout, type/creator endian order, and intended Finder flags.
- **Verification:** Inject unsupported-xattr, permission, and timestamp failures separately and for directories. Assert missing fields are identified, successful independent fields remain restored, failures affect the summary/status, and ordinary native-destination metadata exactly matches the archive.

### RA6X-019 — Directory modification dates are set before children change them

- **ID:** RA6X-019
- **Severity:** Medium
- **Status:** Confirmed by executable reproduction.
- **Location:** `Sources/unsit/MacFileWriter.swift:39–45`; `Sources/unsit/main.swift:114–121`.
- **Problem:** Folder timestamps are restored at the start marker, then creating children changes the directory's mtime. The end marker only pops the stack, so nonempty folders retain extraction time rather than the archived date. Deferred temporary-file publication would also update these dates unless finalization order is corrected.
- **Evidence:** A folder with Mac modification date 3,000,000,000 should have Unix mtime 917,155,200. After extracting one child, its actual mtime was the current extraction time, while the child file's archived mtime was restored correctly. The end branch performs only `removeLast()`.
- **Fix specification:** Retain each folder-start entry's metadata in a folder frame and finalize directory timestamps after all child writes/publications, on the matching end marker and in postorder. Treat incomplete/recovered/blocked folder state according to RA6X-008 and RA6X-012, and report metadata failures through RA6X-018. Preserve the recorded start-entry metadata rather than assuming end-marker metadata is authoritative. Do not change descendant file timestamps while finalizing a directory.
- **Verification:** Check exact timestamps for empty, nonempty, and multi-level folders, with resource-bearing children and temporary-file publication. Test recoverable child failure and missing end markers; intact completed folders must retain archived dates and incomplete ones must receive explicit status.

### RA6X-020 — Valid nonzero Mac dates at or before the Unix epoch are discarded

- **ID:** RA6X-020
- **Severity:** Low
- **Status:** Confirmed by executable reproduction.
- **Location:** `Sources/unsit/MacFileWriter.swift:81–87`.
- **Problem:** The `unix > 0` guard treats all nonzero Mac dates at/before 1970-01-01 as missing, even though they have a valid signed Unix representation. Old document dates and historically mis-set classic Mac clocks are replaced by the current extraction date without a diagnostic. The existing Mac-date-zero sentinel is a separate case.
- **Evidence:** Mac date 2,000,000,000 converts to Unix time -82,844,800. The extracted stored file instead retains its creation-time mtime and exits 0. Mac date 2,082,844,800 (Unix epoch exactly) is discarded by the same guard.
- **Fix specification:** Preserve the documented zero sentinel, but convert and attempt every other representable Mac date using signed time values, including zero/negative Unix times. Report actual destination/platform rejection via RA6X-018 instead of silently rejecting the whole range. Keep the 2,082,844,800-second epoch offset and UTC arithmetic; do not introduce local timezone shifts.
- **Verification:** Test Mac values 0, 1, 2,000,000,000, 2,082,844,800, an ordinary 1990s timestamp, and UInt32 maximum on a supporting filesystem. Check exact seconds or explicit errors for unsupported dates, with no silent substitution of “now.”

### RA6X-021 — Archive names and type bytes can inject terminal control sequences

- **ID:** RA6X-021
- **Severity:** Medium
- **Status:** Confirmed by captured CLI output; no harmful terminal operation was executed.
- **Location:** `Sources/unsit/SITArchive.swift:82–91`; `Sources/unsit/main.swift:59–64, 118, 141–143, 165–171, 193–195`.
- **Problem:** Untrusted names and four-byte file types are printed directly. NUL removal leaves ESC, carriage returns, newlines, and other control bytes intact. Listing an archive or receiving an extraction warning can clear/rewrite terminal content, spoof additional entries or warnings, and make the review of an untrusted archive misleading. Quiet mode still prints raw names in warnings.
- **Evidence:** A Mac Roman name with bytes `1b 5b 32 4a` followed by `hidden\nFAKE` is emitted as raw `ESC[2Jhidden\nFAKE` by `--list`, rather than escaped text. The control sequence was captured into a pipe, not displayed to a terminal. File type bytes have a separate unescaped print path.
- **Fix specification:** Add a display-only escaping function for names, paths, type codes, and any other input-derived diagnostic text. Escape control bytes and line breaks consistently before terminal/log output; keep ordinary printable Unicode readable. Do not alter the actual stored filename to solve a display problem, and keep raw bytes/offsets available in an unambiguous escaped diagnostic form. Apply the function to both stdout and stderr, including error interpolation.
- **Verification:** Capture listing, normal extraction, CRC errors, and unsupported-method errors for ESC/OSC/CR/LF/tab/NUL-containing fields. Assert no raw terminal controls escape the chosen output format and each member occupies an unambiguous record. Verify ordinary Mac Roman names retain their filesystem mapping.

### RA6X-022 — Resync diagnostics report the old offset as the recovered offset

- **ID:** RA6X-022
- **Severity:** Low
- **Status:** Confirmed by executable reproduction and offset calculation.
- **Location:** `Sources/unsit/SITArchive.swift:139–141`; `Sources/unsit/main.swift:109–110, 182–183`.
- **Problem:** The callback receives the original invalid position, but both consumers describe it as where resynchronization happened. Engineers investigating damaged archives are directed to the bad bytes instead of the accepted header. Accurate offsets are especially important when deciding whether a recovery candidate is real.
- **Evidence:** After a first entry ending at offset 137, insert 17 junk bytes and a valid second header at 154. The warning reads `resynced at offset 137, skipped 17 ...`. `onResync(pos, scan - pos)` runs before `pos = scan`.
- **Fix specification:** Define the callback contract with explicit invalid-start, recovered-header, and skipped-length fields, or preserve its existing start/length semantics and calculate `start + skipped` in both messages. Avoid silently changing semantics for one consumer only. Keep existing skipped-byte totals correct; RA6X-006's terminal gaps should also identify their real start/end offsets.
- **Verification:** Assert exact messages/fields for the 137 → 154 fixture, multiple resyncs, and a terminal failed resync in list and extraction modes. Cross-check every reported recovered offset against the header validator.

### RA6X-023 — Quiet extraction still writes the success summary

- **ID:** RA6X-023
- **Severity:** Low
- **Status:** Confirmed by executable reproduction.
- **Location:** `Sources/unsit/main.swift:22, 153`; `README.md:28`.
- **Problem:** `--quiet` promises only warnings and errors, but the final success summary always uses `quiet: false`. This breaks callers that use quiet extraction to keep stdout empty. List mode needs its listing output, but ordinary extraction's summary is incidental progress output.
- **Evidence:** A valid stored one-file archive with `--quiet` returns 0 and still writes a blank line followed by `Extracted 1 file(s) into ...` to stdout.
- **Fix specification:** Honor `opts.quiet` for the extraction summary while keeping warnings/errors on stderr. Define and preserve list mode's primary listing semantics explicitly; do not indiscriminately suppress the requested listing. Keep normal nonquiet summary/count behavior, subject to corrected completion accounting from other findings.
- **Verification:** Assert empty stdout for successful quiet extraction, retained stderr diagnostics for damaged quiet extraction, unchanged normal output, and documented `--list --quiet` behavior.

### RA6X-024 — Command parsing silently changes requested actions and output destinations

- **ID:** RA6X-024
- **Severity:** Low
- **Status:** Confirmed by executable reproduction.
- **Location:** `Sources/unsit/main.swift:33–56, 67–70`; `Sources/unsit/main.swift:11–30`.
- **Problem:** `--self-test` is detected by searching all raw arguments before parsing, so it overrides extraction even when the token is the value of `--output`. Separately, a positional output directory unconditionally overrides an explicit `-o` destination without warning. There is no `--` end-of-options handling, making literal dash-prefixed names awkward to pass and preventing a reliable distinction between paths and flags.
- **Evidence:** `unsit --output --self-test archive.sit` prints `self-test: OK`, returns 0, and extracts nothing. `unsit -o chosen archive.sit positional` creates `positional/f`, leaving `chosen` unused. `unsit -- -archive.sit dashout` exits 2. A mixed `--self-test archive.sit mixed` also skips extraction, while `--help` exits 2 and omits self-test from the displayed options. The raw `contains` precheck and unconditional assignment at line 54 explain these outcomes.
- **Fix specification:** Parse all supported options, including self-test, through one state machine that distinguishes option values from flags and honors `--`. Reject conflicting self-test/extraction requests and conflicting output destination forms with a clear diagnostic, or adopt an explicitly documented precedence that cannot silently defeat the explicit destination. Keep current unambiguous invocations, the executable name, and supported option spellings. Separate successful help/self-test outcomes from usage errors and include self-test in help.
- **Verification:** Test `--output --self-test archive.sit`, `-o chosen archive.sit positional`, standalone self-test, mixed self-test/extraction, `--` with dash-prefixed archive/output names, missing option values, help, and ordinary positional/flag forms. Assert the selected action/path or clear error before any output file is created.

### RA6X-025 — The shipped self-test provides no executable regression coverage of extraction

- **ID:** RA6X-025
- **Severity:** Medium
- **Status:** Confirmed by repository inventory and native test command.
- **Location:** `Package.swift:7–12`; `Sources/unsit/SelfTest.swift:14–56`; `README.md:66–77`.
- **Problem:** The only checks cover a CRC vector, bit reversal, array shapes, and whether code trees construct. No test decodes even one complete member, checks filesystem confinement or fork bytes, exercises recovery, or asserts exit status. The three archives and differential comparison evidence mentioned in the README are not in the repository. A self-test pass therefore coexists with all of the confirmed corruption/security failures above and cannot protect subsequent fixes.
- **Evidence:** `swift test --scratch-path .build/ra6x-review` builds the target and then reports `error: no tests found; create a target in the 'Tests' directory`. `unsit --self-test` reports OK. Its over-full-tree assumption is specifically disproved by RA6X-013. All 12 source-baseline files were inventoried; there is no fixture, test target, or CI configuration.
- **Fix specification:** Add a native automated test target and a reproducible macOS command/CI check covering the regressions in this ledger. Include redistributable synthetic fixtures with independently stated expected bytes for both forks, all preset selectors, dynamic tables (shared/separate), literal/match context transitions, extended lengths, window wrap/overlap, and malformed input. Add filesystem/fault-injection tests in isolated directories and explicit CLI output/status assertions. Keep the fast public `--self-test` command; do not replace meaningful assertions with implementation-mirroring snapshots. If the historical private archives cannot be redistributed, retain reproducible hashes/manifests and describe the separate corpus gate without claiming those samples were rerun here.
- **Verification:** A clean checkout must run `swift test` successfully and fail when a representative known bug is reintroduced. Run the suite on the declared minimum supported macOS/toolchain where available, retain deterministic fixture bytes and expected results, and make no fixture depend on private absolute paths or network access.

## Verification record and limits

Environment: macOS 26.6.2 (25G83), arm64, Apple Swift 6.3.3 (`swiftlang-6.3.3.1.3`), current local filesystem supports native resource forks and is case-insensitive. The package declares macOS 11 and Swift tools 5.7; those older runtime/toolchain combinations were not executed.

| Check | Actual result |
|---|---|
| `swift build -c release --scratch-path .build/ra6x-review` | PASS; production executable built without source edits. |
| `.build/ra6x-review/release/unsit --self-test` | PASS, `self-test: OK`; limited coverage is RA6X-025. |
| `swift test --scratch-path .build/ra6x-review` | Build passed, command failed because no tests exist. Initial sandbox attempt was blocked at the toolchain module cache; the approved retry reached the real `no tests found` result. |
| Stored native-file control | PASS: data `GOOD`, resource `RSRC`, FinderInfo `TEXT`/`ttxt`, and Unix mtime 917155200 restored. |
| Five preset method-13 selectors | PASS: each encoded literal/match/match/literal fixture decoded to seven `A` bytes followed by `B`, with matching CRC. |
| Dynamic contexts | PASS for shared 9-bit contexts and separate 9-/10-bit contexts; both decoded the same eight expected bytes. |
| Dynamic omitted symbols | PASS: an alphabet omitting all but literal `A` and end marker decoded `A`. |
| Extended matches/window wrap | PASS: preset-1 literal `A`, two 32,832-byte matches, a 1,088-byte match, then `B` produced exactly 66,754 expected bytes across the 64 KiB window boundary. |
| Constant tables | All 18 arrays / 3,349 integers match [XADMaster's method-13 source at `137728c1d7e1ae8cd45234c4a8e5e540051bb6db`](https://github.com/MacPaw/XADMaster/blob/137728c1d7e1ae8cd45234c4a8e5e540051bb6db/XADStuffIt13Handle.m). Downloaded source SHA-256: `9c82ffaee932b6bed4ae23fbad7e7b1a67cfbfcacca74176d16d0b7ebf5b54d5`. |
| Path/collision controls | Confirmed parent-component and directory-symlink escapes plus duplicate/case/NUL/existing-file overwrites. Final-file-symlink and hard-link target contents stayed unchanged on this OS. |
| Container/decoder adversarial fixtures | Confirmed missing/truncated header acceptance, out-of-range listing, extra physical entries, unsafe resync/hierarchy, fabricated EOF output, short output, oversubscribed codes, repeat overrun, and width-33 acceptance. |
| Native writer fault injection | Confirmed destructive partial output, failure on a recoverable `EINTR`, and silent resource-close, FinderInfo, and timestamp errors. Injected errors are explicitly synthetic; no real disk-full or failing volume was required. |
| Bounded expansion measurement | 135-byte input → 16 MiB output, exit 0, 56,770,560-byte max RSS, approximately 0.22 s. An initial timing wrapper hit a sandbox-only statistics error; its approved retry produced these measurements. No 4 GiB reservation was attempted. |
| CLI edge cases | Confirmed quiet summary leakage, raw control output captured in a pipe, incorrect resync offset, self-test dispatch override, conflicting destination override, absent `--`, and help exit 2. |
| Source preservation | `git diff de48bad -- .gitignore Package.swift README.md Sources` is empty. Only this report is staged/committed; build products are ignored and probe sources/results live in temporary storage. |

The absence of a reported bug in `CRC16.swift` or the constant tables is supported by the check vector, CRC-valid fixtures, comparison, and positive decode controls above. The intentional circular LZ window, unsupported nonempty compression methods, and retention of CRC-mismatched bytes are compatibility behavior, not findings by themselves. `SITEntry.creationDate` and `rawName` are parsed but not currently consumed; the README promises modification-date restoration, so this report does not mislabel creation-date restoration as an already supported behavior. `shortWrite`'s unused branch matters to the missing zero-progress error handling in RA6X-017.

Not verified: the three private archives named in the README (absent from this checkout), a live `unar` differential run (`unar`/`lsar` not installed on PATH), minimum-macOS behavior, a race scheduler that swaps directories at precise syscall boundaries, real network/removable filesystem failures, and maximum-size/resource-exhaustion inputs. The two format ambiguities needing investigation are called out in RA6X-006 and RA6X-014. These limits do not turn the reproduced findings into guesses; they delimit the additional acceptance tests needed for fixes.

## Reproduction appendix

### Minimal CRC-valid archive builder

Run from the repository root after the release-build command above. This Python 3 helper writes only a newly created temporary directory and captures untrusted output using `repr`. It intentionally allows contradictory fields so the findings can be reproduced; it is not a format validator. Set `count` explicitly for count-semantics tests; the baseline parser does not use it. Temporary paths from the review run are supporting evidence, not a dependency of the recipes.

```python
from pathlib import Path
import struct, subprocess, tempfile

binary = Path(".build/ra6x-review/release/unsit").resolve()
scratch = Path(tempfile.mkdtemp(prefix="unsit-ra6x-repro-"))

def crc(bs):
    value = 0
    for b in bs:
        value ^= b
        for _ in range(8):
            value = (value >> 1) ^ (0xA001 if value & 1 else 0)
    return value

def member(name=b"f", *, data=b"", rsrc=b"", rm=0, dm=0,
           du=None, ru=None, dc=None, rc=None, data_crc=None,
           rsrc_crc=None, mod=3_000_000_000, nl=None):
    if isinstance(name, str):
        name = name.encode("mac_roman")
    h = bytearray(112)
    h[:3] = bytes((rm, dm, len(name) if nl is None else nl))
    h[3:3 + min(len(name), 31)] = name[:31]
    h[66:74] = b"TEXTttxt"
    struct.pack_into(">II", h, 76, mod, mod)
    struct.pack_into(">IIIIHH", h, 84,
        len(rsrc) if ru is None else ru,
        len(data) if du is None else du,
        len(rsrc) if rc is None else rc,
        len(data) if dc is None else dc,
        crc(rsrc) if rsrc_crc is None else rsrc_crc,
        crc(data) if data_crc is None else data_crc)
    struct.pack_into(">H", h, 110, crc(h[:110]))
    return bytes(h) + rsrc + data

def sit(parts, *, count=1, total=None, signature=b"rLau"):
    body = b"".join(parts)
    return (b"SIT!" + struct.pack(">HI", count,
        22 + len(body) if total is None else total) + signature
        + b"\x01" + bytes(7) + body)

def probe(label, payload, flags=(), setup=None):
    case = scratch / label
    case.mkdir()
    out = case / "out"
    out.mkdir()
    archive = case / "input.sit"
    archive.write_bytes(payload)
    if setup:
        setup(case, out)
    result = subprocess.run([str(binary), *flags, str(archive), str(out)],
                            capture_output=True, timeout=20)
    print(label, result.returncode, repr(result.stdout), repr(result.stderr))
    return case, out

# These complete examples should both diagnose corruption after the fixes.
probe("eof", sit([member(data=b"\x10", dm=13, du=4096, data_crc=0)]))
probe("early_end", sit([member(data=b"\x10\x16", dm=13, du=20, data_crc=0)]))
print("Inspect outputs under", scratch)
```

The following `parts` expressions can be passed to `sit(parts)` and then `probe`. All named data is ASCII unless given as bytes. Inspect data with `Path.read_bytes()`, resource bytes with `Path(str(file) + "/..namedfork/rsrc").read_bytes()`, metadata with `xattr -px com.apple.FinderInfo FILE`, and timestamps with `Path.stat().st_mtime`. Capture terminal-control cases in a pipe as the helper does.

| Finding(s) | Fixture or procedure |
|---|---|
| RA6X-001 | `[member("..", rm=32, dm=32), member("escaped", data=b"ESCAPE"), member("..", rm=33, dm=33)]`; observe `case/escaped`. |
| RA6X-002 | Use start/end `link` around `escaped`; in `setup`, create `case/outside` and symlink `out/link` to it. Observe `case/outside/escaped`. |
| RA6X-003 | `[member(data=b"FIRST"), member(data=b"SECOND")]`; variants use `File`/`file`, `b"f"`/`b"f\0"`, or precreate `out/f` with sentinel bytes. |
| RA6X-004, RA6X-015 | Selector-only complete example above; for the bounded size probe replace 4096 with `16*1024*1024`. Do not use the maximum UInt32 value without a subprocess allocation limit. |
| RA6X-005 | `[member(data=b"A", du=20)]`, `[member(data=b"EXTRA", du=0, data_crc=65535)]`, or the early-end example above. |
| RA6X-006 | `sit([], count=1, total=134)`; `sit([member(data=b"A")[:60]], total=135)`; `sit([], signature=b"NOPE")`; `[member(data=b"A", dc=200, du=200)]` with `flags=("--list",)`; append an extra member while retaining the first member's total length. |
| RA6X-007 | `[bytes(112)]` in list mode; or `[b"?"*17, member("bogus", dm=255, nl=255, dc=10000), member("good", data=b"GOOD")]`. |
| RA6X-008 | Start `dir`, stored `inside`, end `dir` with byte 110 XORed by 1, then `root_file`; observe `root_file` wrongly nested. Also remove the end marker or insert an unmatched end marker. |
| RA6X-009 | `[member(data=b"GOOD", rm=13)]`. Resource lengths both default to zero. |
| RA6X-010 | `[member(data=b"GOOD", rsrc=b"\x60", rm=13)]` and `[member(data=b"\x60", rsrc=b"GOOD", dm=13)]`. |
| RA6X-011 | Start/end `dir` with both method bytes 48/49 and a stored child between them. |
| RA6X-012 | Start/end `blocked` around a child, then a root `later`; precreate `out/blocked` as a file. |
| RA6X-013, RA6X-014 | See exact table/bit construction below. |
| RA6X-016–RA6X-018 | Use a two-fork member and the syscall fault procedure below; start with an existing two-fork sentinel for transaction tests. |
| RA6X-019 | Start/end `dir` around one child; expected folder mtime is `3_000_000_000 - 2_082_844_800`. |
| RA6X-020 | `[member(data=b"A", mod=2_000_000_000)]`; expected mtime is `-82_844_800`. |
| RA6X-021 | `[member(b"\x1b[2Jhidden\nFAKE", data=b"A")]` with list mode and captured output. |
| RA6X-022 | `[member("first", data=b"ONE"), b"?"*17, member("second", data=b"TWO")]`; the second header begins at 154, not 137. |
| RA6X-023 | Any valid stored member with `flags=("--quiet",)`; inspect stdout. |
| RA6X-024 | The exact argument sequences and observed paths/statuses are in the finding. Run each in a separate temporary working directory containing the valid fixture. |
| RA6X-025 | Run the two native validation commands and inspect the package targets and self-test body. |

### Exact malformed Huffman recipes and positive controls

For a direct RA6X-013 unit reproduction, compile `BitReaderLE.swift` and `PrefixCode.swift` with a temporary Swift `@main` harness; construct `canonical(lengths: [1,1,1], count: 3)`, read a zero bit, and observe symbol 2. A second insertion of the identical `hbf: 0, length: 1` code also overwrites the first value. These calls should throw after the fix. `canonical(lengths: [33], count: 1)` currently accepts a width beyond the representation limit.

For archive-level tests, emit the selector byte, then concatenate bits with bit 0 of each emitted group consumed first. Define `T(v)` as the low `metaCodeLengths[v]` bits of `metaCodes[v]`, in LSB-first order. `L(n, k)` means the low `k` bits of integer `n`, also LSB-first. Pack consecutive bits into bytes from low to high bit, padding the last byte only. Huffman body symbols use the canonical high-to-low code path specified by their lengths.

- **Oversubscribed:** Selector `0x08` (shared contexts, ten offset symbols), `T(0)` repeated 321 times, `T(0)` repeated ten times for offsets, then one zero body bit. Declare one output byte and CRC 0. The baseline incorrectly accepts 321 one-bit codes, decodes symbol 320, writes no bytes, and returns 0.
- **Run overrun:** Selector `0x08`; first table `T(8) + 4*(T(36)+L(63,6)) + T(36)+L(14,6)`; offsets `T(3)` repeated ten times; body the canonical nine-bit code for literal 65 (`A`). The run sequence claims 322 entries; the baseline clips one, emits `A`, and returns 0 with the correct one-byte CRC.
- **Width 33:** Selector `0x08`; first table `T(30)+T(32)+T(32)+318*(T(34)+L(0,1))`; offsets `T(3)` repeated ten times; body the canonical code for literal 65 in lengths `[31,32]+[33]*319`. The baseline accepts and emits `A`. Compute canonical values using the same standard symbol-order assignment, without truncating the independently generated bit path.
- **Valid shared/separate controls:** Use 321 length-9 symbols for the first alphabet, ten length-4 offset symbols, and selector `0x08` to reuse the first alphabet. For separate contexts use selector `0x00` and a second 321-symbol alphabet of length 10. Encode literal `A`, match symbol 256 (length 3)/offset symbol 0 (distance 1), match symbol 256/offset symbol 1 (distance 2), literal `B`, choosing the alphabet by the preceding symbol. Expected output is `AAAAAAAB`. All five preset selectors passed the same logical sequence.
- **Valid extended/window control:** Preset 1; literal `A`, match symbol 319 with extra value 32767/15 bits and offset symbol 0, another such match using the second context, match symbol 318 with extra value 1023/10 bits and offset symbol 1, then literal `B`. Expected output is 66,753 `A` bytes followed by `B`.

### Syscall fault procedure

Use a test I/O adapter after refactoring, or a temporary macOS `DYLD_INSERT_LIBRARIES` interposer against the unchanged executable (the latter was used here). Interpose only the relevant operations, keep ordinary Foundation/data writes and stdout/stderr unmodified, and restrict all fixture paths to a disposable directory. An `open` interposer identifies `"/..namedfork/rsrc"` and records that returned descriptor so resource `write`/`close` can be targeted precisely. Preserve other calls and vararg file-creation modes.

| Injected outcome | Observed baseline behavior |
|---|---|
| Resource `open` returns `-1`, errno `ENOTSUP` | Exit 1; new data fork already replaced the old file, old resource is gone. |
| First resource `write` really writes one byte, second returns `-1/ENOSPC` | Exit 1; normal final filename contains full new data plus one resource byte. |
| First resource `write` returns `-1/EINTR` once; subsequent calls would succeed | Exit 1; no retry, empty resource fork. |
| Resource `close` calls the real close, then reports `-1/EIO` | Exit 0; no warning. This proves error suppression, not actual injected media damage. |
| Only FinderInfo `setxattr` returns `-1/ENOTSUP` | Exit 0; FinderInfo missing, no warning; other content/date restored. |
| `utimes` returns `-1/EPERM` | Exit 0; current timestamp remains, no warning; forks/FinderInfo restored. |

Use `NEW_DATA` plus resource `RSRC` as the new member and `ORIGINAL` plus `OLD_RESOURCE` as the existing destination. Verify both forks and metadata after each failure, independently of the CLI's count. For the oversized-write subcase use a stub recording requested lengths: assert no request exceeds the chosen safe chunk size without actually allocating a GiB buffer.

## Summary by severity and dependency-aware fix order

| Severity | Count | Findings |
|---|---:|---|
| Critical | 0 | None |
| High | 10 | RA6X-001–RA6X-008, RA6X-015, RA6X-016 |
| Medium | 11 | RA6X-009–RA6X-014, RA6X-017–RA6X-019, RA6X-021, RA6X-025 |
| Low | 4 | RA6X-020, RA6X-022–RA6X-024 |
| **Total** | **25** | |

| ID | Severity | Finding | Fix dependencies |
|---|---|---|---|
| RA6X-001 | High | Parent-directory member escapes output root | Pair with RA6X-002 |
| RA6X-002 | High | Directory symlinks and pathname races defeat confinement | Foundation for RA6X-003, RA6X-016 |
| RA6X-003 | High | Existing/colliding output is silently overwritten | RA6X-001, RA6X-002 |
| RA6X-004 | High | Compressed EOF fabricates zero bits without failure | Pair with RA6X-015 |
| RA6X-005 | High | Fork lengths are not verified | RA6X-004, RA6X-013, RA6X-014 |
| RA6X-006 | High | Archive extent/completeness and recovery status ignored | Foundation for traversal fixes; resolve count ambiguity before count enforcement |
| RA6X-007 | High | CRC-only resync accepts impossible headers | RA6X-006, RA6X-011 marker interpretation |
| RA6X-008 | High | Lost folder markers corrupt recovered hierarchy | RA6X-003, RA6X-006, RA6X-007, RA6X-011 |
| RA6X-015 | High | Unbounded archive-controlled resource consumption | Can start immediately; coordinate all output paths |
| RA6X-016 | High | Partial member publication destroys complete originals | RA6X-002, RA6X-003, RA6X-017, RA6X-018 |
| RA6X-009 | Medium | Absent method-13 fork blocks present fork | RA6X-005's consistency rules |
| RA6X-010 | Medium | One failed fork discards independent recoverable bytes | RA6X-009, RA6X-016 and structured decoder outcomes |
| RA6X-011 | Medium | Flagged folders are flattened as unsupported files | Implement alongside RA6X-006 before candidate validation |
| RA6X-012 | Medium | Folder failure aborts later independent members | RA6X-003, RA6X-008 |
| RA6X-013 | Medium | Duplicate/oversubscribed Huffman codes overwrite symbols | Add regression harness first |
| RA6X-014 | Medium | Dynamic table overruns/invalid widths accepted | RA6X-004, RA6X-013 |
| RA6X-017 | Medium | Resource write/close completion mishandled | Foundation for RA6X-016 |
| RA6X-018 | Medium | Metadata failure reported as success | Foundation for RA6X-016 and timestamp fixes |
| RA6X-019 | Medium | Child creation overwrites restored directory mtime | RA6X-008, RA6X-012, RA6X-016, RA6X-018 |
| RA6X-021 | Medium | Untrusted output injects terminal controls | Can proceed independently; preserve filesystem names |
| RA6X-025 | Medium | No automated extraction regression suite | Start first and extend with each fix |
| RA6X-020 | Low | Pre-/at-Unix-epoch dates discarded | RA6X-018 |
| RA6X-022 | Low | Resync message identifies wrong offset | RA6X-006's recovery outcome contract |
| RA6X-023 | Low | Quiet extraction emits success summary | Independent; keep corrected summary accounting |
| RA6X-024 | Low | CLI silently overrides action/destination | Independent; preserve ordinary invocations |

Suggested implementation sequence:

1. Establish minimal native regression/fault-injection infrastructure (RA6X-025), adding each reproduction before its fix. This is an enabling step, not a reason to defer the high-severity corrections until an elaborate test framework is finished.
2. Confine filesystem writes and preserve originals/collisions (RA6X-001, RA6X-002, RA6X-003). Add bounded resource policies immediately (RA6X-015). Terminal escaping (RA6X-021) can proceed independently as a small security correction.
3. Repair decoder trust boundaries: actual EOF (RA6X-004), prefix capacity/leaf checks (RA6X-013), dynamic table runs/widths (RA6X-014), then exact fork lengths and absent-fork handling (RA6X-005, RA6X-009). Keep the passing valid-stream controls throughout.
4. Establish archive bounds and traversal results (RA6X-006), correct folder flags (RA6X-011), validate resync candidates (RA6X-007), then handle uncertain/blocked hierarchy (RA6X-008, RA6X-012). Update resync diagnostics with that contract (RA6X-022).
5. Check resource I/O and metadata outcomes (RA6X-017, RA6X-018), then publish complete members transactionally (RA6X-016) and retain independently recoverable forks/partial bytes safely (RA6X-010). These changes can be developed alongside the decoder/parser work after confinement is available.
6. Finalize folder timestamps after child publication (RA6X-019), preserve representable historical dates (RA6X-020), and complete quiet/argument semantics (RA6X-023, RA6X-024). Finish the regression suite and run the separately identified historical-corpus/minimum-platform checks when those environments are available.
