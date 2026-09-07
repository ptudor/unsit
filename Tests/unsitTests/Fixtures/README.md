These redistributable synthetic archives were generated for RA6X-025 from the
bit recipes in review/2026/09/REVIEW_ASTRA6_XHIGH.md. They contain no private data.
The five preset and two shared/separate dynamic context fixtures must decode
to seven ASCII A bytes followed by B. No private archive or network is needed.

Private archives remain a separate corpus gate; the anonymized local comparison
is recorded in docs/verification.md. Their bytes and hashes are not distributed
and are not inputs to this suite. Preserve source SHA-256, member paths, both fork
SHA-256 values, lengths, metadata, and CRC outcomes in local manifests when
repeating that check. Minimum-platform and toolchain checks are separate gates;
local tests record the actual host/toolchain.

`valid_extended_window_wrap.sit` decodes to 66,753 ASCII A bytes followed by B;
`valid_omitted_symbols.sit` decodes to A. `SHA256SUMS` pins every golden archive.
The five `codebooks_preset_*.sit` probes exercise every literal and match-length
symbol in both contexts, every preset distance category and extra-bit endpoint,
maximum extended lengths, overlap, and initial zero history. Both forks were
verified against independently generated expected bytes with `unar` 1.10.1.
Expected lengths and hashes are in `codebooks.json`; the generator and optional
oracle check are `scripts/verify-method13.py`. All probe contents are synthetic.
The suite also rebuilds independent synthetic containers and metacode streams to
exercise contradictory declarations, bit alignments, repeat boundaries, flagged
folders, and recovery. `fault-interposer.c` is loaded only into isolated test
subprocesses; `resource-driver.c` applies CPU/file-size limits plus a resident-memory watchdog and reports RSS
for the maximum-declaration test. Both compile with the installed macOS clang.
