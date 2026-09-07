# Classic StuffIt container

Unsit accepts the paired `SIT!` and `rLau` signatures in a 22-byte archive header.
It parses only the declared archive extent and diagnoses a physical-length mismatch.

Per-entry header (112 bytes, big-endian), offsets that were confirmed by
validating the stored header CRC:

| Offset | Size | Field                          |
|-------:|-----:|--------------------------------|
| 0      | 1    | resource-fork compression method |
| 1      | 1    | data-fork compression method     |
| 2      | 1    | filename length (≤ 31)           |
| 3      | 31   | filename (Mac Roman)             |
| 66     | 4    | file type (OSType)               |
| 70     | 4    | creator (OSType)                 |
| 74     | 2    | Finder flags                     |
| 76     | 4    | creation date (Mac 1904 epoch)   |
| 80     | 4    | modification date                |
| 84     | 4    | resource fork uncompressed length|
| 88     | 4    | data fork uncompressed length    |
| 92     | 4    | resource fork compressed length  |
| 96     | 4    | data fork compressed length      |
| 100    | 2    | resource fork CRC-16/ARC         |
| 102    | 2    | data fork CRC-16/ARC             |
| 110    | 2    | header CRC-16/ARC (over bytes 0–109) |

Folder marker values are `0x20` (start) and `0x21` (end) in either method byte,
with `0x10` and `0x80` flags separated before classification. Folder length fields
can contain nonzero summary values; markers still occupy exactly 112 bytes and
have no inline fork payload. For a file, the compressed resource fork immediately
follows the header, then the compressed data fork.

Only version-1 root-item count semantics are enforced. Other classic header
versions report unverified count validation with a nonzero status; member and
fork checks still run. See [extraction behavior](behavior.md) and the
[method-13 wire grammar](method-13.md).
