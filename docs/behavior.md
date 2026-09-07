# Extraction behavior

The app uses the same extractor and default limits as the CLI. It chooses a fresh
output folder for each archive; the CLI uses its requested destination directly.

Extraction preserves existing destinations: conflicting files or folders are
skipped with a warning and a nonzero result. Unrelated archive folders are never
merged. Unsafe empty, `.` and `..` member names are rejected; descendants of a
blocked folder are skipped until its closing marker. Output roots and their
path components must be ordinary directories, without symlinks. Member data,
resource forks, and metadata use the same opened descriptors. Displayed control
characters are escaped; safe Mac Roman names and `/` to `:` mapping are retained.

Resource limits apply before allocation/output: input 256 MiB, decoded fork
64 MiB, aggregate decoded output 512 MiB, 100,000 member records, nesting 128,
and 1 MiB of recovery scanning. Deliberately override individual limits with
`--max-input-bytes N`, `--max-fork-bytes N`, `--max-total-bytes N`,
`--max-members N`, `--max-depth N`, or `--max-recovery-bytes N` (nonnegative
integers, bytes where applicable). Input is read in bounded chunks; at most the
bounded input, a compressed fork copy, and the two bounded decoded forks are
retained. Reservations include damaged stored output and are not refunded for
failed members. List mode enforces input, member, nesting, and recovery limits.

Compressed EOF, invalid Huffman tables, contradictory fork lengths, and premature
end markers are structural errors even with `--no-verify`. Zero/zero fork lengths
mean an absent fork regardless of the unused method byte. Method 13 preserves the
reference's 64 KiB zero-initialized history and length-delimited completion,
including a terminal match spanning the declared boundary; no extra terminator
is required. Dynamic lengths -1 and zero denote omitted symbols.

Both archive signatures and the declared extent are validated. Bytes outside the
declared extent are diagnosed and not parsed. Incomplete headers/payloads,
resynchronization and unbalanced folders return nonzero in list and extraction
modes. Version-1 header counts are checked against root files plus root folders
(each complete folder counts once). Count enforcement for other classic header
versions is unverified and explicitly diagnosed with a nonzero result.

Recovery candidates require structural plausibility in addition to CRC. After a
lost header, hierarchy remains uncertain: independently identified files go to
`unsit-recovery-HEADER_OFFSET/NAME` under the output root. These directories use
exclusive creation; a collision is reported and skipped. List mode reports the
same intended recovery paths. Folder flags `0x10` (contains encrypted children)
and `0x80` are separated from `0x20`/`0x21` marker values in either method field;
encrypted nonempty file forks remain unsupported.

Each member is built as a unique `.unsit-tmp-UUID` sibling, then both native
forks are flushed, metadata is attempted independently, and close is checked
before exclusive atomic publication. A damaged fork or failed restoration uses
`NAME.partial-HEADER_OFFSET` with per-fork/operation warnings and a nonzero
result. Complete and partial members are counted separately. An independently
valid fork and safe decoder prefixes survive a failure in the other fork; a
failed fork is never described as an absent clean fork. CRC-damaged bytes remain
recoverable under this partial-name policy. Existing complete or partial output
is preserved even if publication collides.

Handled failures clean up their temporary pathname within the opened directory.
Abrupt termination can leave a clearly named `.unsit-tmp-UUID` orphan; it cannot
appear as a completed member. The tool does not automatically delete preexisting
orphans. File `fsync` and close are checked; atomic visibility is guaranteed for
publication, but crash/power-loss durability of the directory entry is not
promised. Resource forks use bounded positional `fsetxattr` on the member's
file descriptor, avoiding a second pathname-based resource open/close.

Folder dates come from the start marker and are restored after all child
publication at the matching end marker. Unclosed/uncertain folders are diagnosed
and are not assigned an invented completion date. Nonzero Mac dates are converted
with signed UTC arithmetic, including pre-1970 values; zero remains the missing
date sentinel. Actual destination failures are reported.

`--quiet` leaves successful extraction stdout empty; `--list --quiet` still emits
the requested listing. `--` makes all remaining tokens literal paths. An output
option consumes its next token even if it spells `--self-test`. Self-test mixed
with archive/extraction arguments and duplicate/conflicting output forms are
usage errors before extraction. Help and standalone self-test exit successfully.

## Recovery reports

When a fork or archive structure is damaged, the final warning explicitly credits
Unsit with the number of member files it recovered, split into complete and
partial publications. It calls the damage possible bitrot, without diagnosing its
cause. It separately counts files recovered beyond damaged records whose folder
placement is uncertain. Recovery directories use the visible
`unsit-recovery-HEADER_OFFSET` prefix so Finder users can reach their contents.

Unsupported compression, resource limits, disk/metadata failures, and unverified
version-specific counts do not by themselves count as damaged archive bytes.
Quiet mode retains the damage summary. A CRC mismatch in each of a member's two
forks counts as two damaged forks and one partial member.

`--json` writes one schema-version-1 JSON object to stdout after extraction;
warnings remain on stderr and ordinary progress is suppressed. It also works with
`--quiet` and rejects `--list`. Argument errors still return status 2 without JSON.
The report includes:

| Fields | Meaning |
| --- | --- |
| `status`, `problem`, `outputDirectory` | Exit status, optional fatal problem, and requested output location when established |
| `completeFiles`, `partialFiles`, `failedFiles` | Published complete members, published partial members, and identified files that were not saved; their total does not estimate unknown members inside unreadable regions |
| `damagedForks`, `unsupportedForks` | Affected forks, each counted once within its category |
| `recoveredAfterDamage` | Published files whose original hierarchy became uncertain after damaged records |
| `archiveStructureDamaged`, `damagedHeaderGaps`, `skippedArchiveBytes` | Structural damage and unreadable regions encountered during traversal |
| `archiveValidationIncomplete`, `forkChecksSkipped` | Unverified container count semantics or explicitly skipped fork CRC checks |
| `restorationFailures` | Member/folder operations affected by output, metadata, name, or resource-limit failures |

The recovered file total is `completeFiles + partialFiles`; damage is detected
when `damagedForks > 0` or `archiveStructureDamaged` is true. A complete member is
distinct from a complete archive. Early fatal errors retain the counts established
before failure; an interrupted process may not reach its final JSON report.
