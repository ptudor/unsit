# Method-13 wire format and implementation

The current Swift implementation uses a bounded bit cursor, canonical numeric
code ranges, and a single output buffer for LZ history. It replaces the earlier
decoder and prefix tree. It does not call or link an external decompression
library. Source is MIT; numeric format data and historical provenance are
described in [third-party notices](../THIRD_PARTY_NOTICES.md).

## Bit fields and codebooks

The first payload byte selects the codebooks. Its high nibble is zero for dynamic
tables or 1–5 for preset tables; larger values are invalid. In dynamic mode, bit
3 reuses the first literal/length codebook for the second context. Bits 0–2 plus
10 give the distance alphabet size. The stream then carries 321 lengths for the
first context, optionally 321 for the second, and the distance lengths.

Bits within each byte are consumed from low to high. A numeric field assigns the
first bit to its least significant position. A Huffman codeword is traversed in
its canonical high-to-low order using that sequence of consumed bits.

For canonical codes, symbols of a given positive width receive consecutive
integers in symbol order. Each width starts at twice the next available code
from the preceding width. Zero and -1 lengths omit a symbol. Widths above 32,
oversubscribed codebooks, duplicate codes, and prefix conflicts are rejected.

The fixed metacode uses explicit codewords, not canonical lengths alone. Its
symbols expand dynamic lengths as follows; the accumulator starts at zero:

| Symbol | Operation | Number of emitted lengths |
| --- | --- | --- |
| 0–30 | Set accumulator to symbol + 1 | 1 |
| 31 | Set accumulator to -1 | 1 |
| 32 | Increment accumulator | 1 |
| 33 | Decrement accumulator | 1 |
| 34 | Keep accumulator; read 1 extra bit | 1 + extra |
| 35 | Keep accumulator; read 3 extra bits | 3 + extra |
| 36 | Keep accumulator; read 6 extra bits | 11 + extra |

Every emitted value must remain within -1…32, and a run must fit in the remaining
table. Truncated fields and overlong runs are structural errors.

## Tokens and history

Use the first context at stream start and after a literal, and the second after
a match. Symbols 0–255 emit a literal byte. Symbols 256–317 encode match lengths
of symbol − 253. Symbol 318 adds a 10-bit field to 65; symbol 319 adds a 15-bit
field to 65. Symbol 320 ends the stream.

Each match reads a distance-category symbol. Category zero means distance 1.
For category `n > 0`, distance is `2^(n−1) + extra + 1`, where `extra` is an
`n−1`-bit field. The supported distance range is 1–65,536 bytes. Copying is
overlap-safe, and history before the first output byte reads as zero.

The archive header's uncompressed length bounds decoding. A final match may cross
that boundary; only the requested bytes are returned. No additional end marker
is required after that length. An end marker before the declared length, actual
compressed EOF, or an invalid code preserves the safe output prefix and reports
damage. CRC verification is a separate check.

These format facts were checked against the MIT-licensed
[compcol documentation and decoder](https://github.com/KarpelesLab/compcol/tree/1b67ebf73242feab6943d9a9fbfe43eb71971269/src/sit13)
and independent byte expectations. Unsit's zero-history, terminal-match, and
partial-output policies are verified separately; compatibility with damaged input
is not inferred from the other implementation's error policy.

## Numeric data and reproducible checks

`format/method13-codebooks.json` contains only fixed code lengths and explicit
metacode words. `scripts/generate-codebooks.py` emits the checked-in Swift data
representation and embeds its JSON SHA-256. A build never downloads these values.
Changing their representation does not change their recorded provenance.

`scripts/verify-method13.py` encodes deterministic test streams from the grammar
above. The five frozen probes cover every literal in both contexts, every match
length token in both contexts, maximum extended lengths, every preset distance
category and both endpoints of its extra bits, overlap, and initial zero history.
Each probe carries identical compressed data and resource forks. Expected lengths
and SHA-256 values are frozen in `Tests/unsitTests/Fixtures/codebooks.json`.

```sh
python3 scripts/generate-codebooks.py --check
python3 scripts/verify-method13.py --binary .build/debug/unsit
# Optional development-only differential check with an installed reference:
python3 scripts/verify-method13.py --binary .build/debug/unsit --reference /path/to/unar
```

The optional reference check passed for all five probes and both native forks
with `unar` 1.10.1. The reference executable and its implementation are not part
of source or binary release artifacts. The native suite also checks shared and
separate dynamic tables, omitted symbols, malformed tables, every byte truncation
of golden streams, and final-byte alignments.
