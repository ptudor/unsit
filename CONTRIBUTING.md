# Contributing

Describe a reproducible extraction or app problem, the version or commit, macOS
version and architecture, expected behavior, and actual results. Redact private
filenames and archive contents. Only contribute archives you have permission to
redistribute; synthetic fixtures are preferred. Use [private reporting](SECURITY.md)
for vulnerabilities.

Use Swift 5.7 or later with the Xcode command-line tools:

```sh
swift test
make check
make app
```

The app consists of `UnsitApp` and the testable `UnsitDesktop` subprocess helper.
It bundles the `unsit` executable. Preserve that shared behavior when changing
either interface. Run tests against the packaged helper for a release:

```sh
UNSIT_TEST_BINARY="$PWD/dist/Unsit.app/Contents/MacOS/unsit" swift test --filter RegressionTests
```

For decoder changes, update [the wire-format notes](docs/method-13.md), retain
explicit expected bytes or hashes, and check both native forks. Numeric codebooks
live in JSON; regenerate Swift with `python3 scripts/generate-codebooks.py` and
review any change to their values and provenance. The optional `unar` differential
check is a development tool and is never a shipped dependency.

For release changes, run `python3 scripts/package.py --arch universal`, validate
workflows with actionlint 1.7.12, and follow [the release guide](docs/releases.md).
Update both `VERSION` and `Sources/unsit/Version.swift` when changing versions.

Contributions to current source use the [MIT license](LICENSE). Preserve
third-party notices and the historical provenance of format data. Do not copy a
copyleft implementation into the production targets.
