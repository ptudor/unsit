# Third-party notices

Unsit's current implementation is distributed under the [MIT license](LICENSE).
It has no third-party package dependencies. The app bundles the Unsit CLI; neither
XADMaster nor `unar` is linked, bundled, or invoked by the shipped products.

## Method-13 format references

The replacement Swift decoder was written using documented wire-format behavior,
synthetic byte expectations, and black-box compatibility checks. Its bit cursor,
canonical range decoder, dynamic-length parser, and output-history expansion
replace the earlier implementation. This is not a claim of a clean-room process:
upstream source was consulted during the project's development.

The MIT-licensed **compcol** method-13 documentation and decoder were consulted
for format facts, including selector fields, length tokens, and distance coding.
Reference revision:
[`1b67ebf73242feab6943d9a9fbfe43eb71971269`](https://github.com/KarpelesLab/compcol/tree/1b67ebf73242feab6943d9a9fbfe43eb71971269/src/sit13).
Its notice is retained below.

### Numeric interoperability data

The fixed code lengths and metacode words in
`docs/format/method13-codebooks.json` are the numeric data needed to interpret
existing method-13 streams. Their values were initially transcribed from
[XADMaster's published tables](https://github.com/MacPaw/XADMaster/blob/137728c1d7e1ae8cd45234c4a8e5e540051bb6db/XADStuffIt13Handle.m),
then compared with other published codebooks and verified using synthetic
archives covering every preset symbol and distance category. The generated Swift
representation does not change that provenance.

These are retained as functional format data, separate from decoder source.
The earlier decoder's LGPL-derived provenance remains documented in historical
revisions; the new MIT grant does not retroactively relicense those revisions.
See [the format and verification notes](docs/method-13.md).

## compcol notice

MIT License

Copyright (c) 2026 Karpeles Lab Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
