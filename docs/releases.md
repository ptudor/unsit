# Builds and releases

Maintainers should follow [RELEASE.md](../RELEASE.md) for the complete repeatable
procedure: repository setup, Apple credentials, native CI, signing, notarization,
publication, download verification, and the live updater check.

`scripts/package.py` builds the macOS app and its bundled CLI using SwiftPM. It
produces an installer DMG, app ZIP, CLI tarball, source tarball, update metadata, and per-architecture SHA-256
manifest. The app includes an original icon, classic StuffIt document registration,
offline help, an updater, licenses, and build metadata. No third-party archive executable is
required or shipped.

## Local rehearsal

```sh
swift test
make check
python3 scripts/package.py --arch universal
open dist/Unsit.app
```

`--arch native` is the default. `arm64`, `x86_64`, and `universal` are also accepted.
The universal package contains both slices; its local smoke test runs on the host
architecture. Native Intel execution is checked separately in CI. `--output DIR`
changes the artifact directory. Rebuilding replaces generated Unsit artifacts in
that directory; keep unrelated files elsewhere.

Snapshot names include the base version, source commit, and dirty-worktree status.
The app and CLI's base version is recorded in `VERSION` and
`Sources/unsit/Version.swift`. Each binary package includes `build-info.json` with
the full package version, commit, architectures, toolchain, source archive name,
and source SHA-256. Source archives include current source and build inputs;
private corpora, extraction output, build caches, and historical review files are
excluded. Historical licensing provenance remains in the notices.

The packaging script checks architecture slices, code signatures, the bundled
CLI self-test, and all five exhaustive preset probes through both native forks.
Exact reproducibility across different Xcode, Swift, and signing tools is not
claimed. Source archive headers use the source commit date and omit local owners.

## App installation and signing

Open the DMG and drag **Unsit.app** to its Applications shortcut, or expand the
app ZIP in Finder and move the app into Applications. The app
requires macOS 12 or later. CLI archives target macOS 11 or later; extract the
tarball and place its `unsit` executable in a directory on your PATH.

Local snapshots use ad hoc signatures by default. Public release packaging
requires a Developer ID Application identity and a validated notarization profile.
It signs the helper and app with Hardened Runtime and secure timestamps, requires
Apple to accept both the app and DMG, staples and verifies both tickets, and
checks Gatekeeper acceptance before publishing finished packages. There is no
unsigned fallback for `--release`.

The publisher configures Apple credentials in the GitHub `release` environment
or uses a local Keychain profile for rehearsal. Credentials are excluded from
sources and packages. Final asset hashes and accepted submission IDs are recorded
in each architecture's `.notarization.json` receipt. See the
[credential setup and signed rehearsal](../RELEASE.md#configure-apple-credentials).

## GitHub automation

| Trigger | Checks and artifacts |
| --- | --- |
| Push to `main`, pull request, or manual CI | Workflow and fixture validation; native tests and app/CLI packaging on Apple silicon and Intel macOS; downloadable snapshot artifacts |
| Weekly or source changes | Redacted secret scan of Git history; Dependabot updates for pinned actions |
| Push a version tag | Required CI and secret scan; native signed/notarized packages; draft, provenance attestation, publication, and live stable updater check |

Actions are pinned to commits, checkout does not retain credentials, and only
the release job has publishing permissions. Signed packages are built from the
checked tag, verified with their final signatures, and tested natively before
being uploaded. The publishing job consumes those exact artifacts. macOS runner labels and the actual
toolchain are recorded in logs; they do not establish minimum-platform coverage.
The runner choices follow [GitHub's runner documentation](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).

The release begins as a draft. If attestation fails, it stays a draft. Investigate
the failed run before publishing manually. Correct a published artifact using a
new version; do not overwrite an existing public version tag.

## Prepare and publish a version

1. Update `VERSION`, the CLI version, `CHANGELOG.md`, and
   `docs/release-notes/vMAJOR.MINOR.PATCH.md`. Review licenses, current verification
   results, and signing limitations.
2. Commit the complete release changes and run the local rehearsal. Configure a
   GitHub repository and an HTTPS remote if this checkout does not have one. Verify
   its identity in `build-info.json` and the app's update configuration.
3. Push the reviewed source and let both native CI jobs and the security check
   pass on the intended commit. Confirm the app opens archives through Finder
   and drag-and-drop, and that packaged licenses and source match that commit.
   Keep the DMG and matching `.update.json` assets in the release; the
   [updater](updates.md) verifies GitHub's asset digests before opening an installer.
4. When publication is authorized, create and push an annotated version tag:

```sh
git tag -a v1.0.0 -m 'Release 1.0.0'
git push github v1.0.0
```

The tag is the publication trigger. `v1.0.0-rc.1` creates a prerelease if matching
release notes exist. Tagged packaging requires a clean checkout and a tag pointing
to HEAD, and rejects a version whose base differs from `VERSION`.

On a clean tagged checkout, rehearse that exact version with:

```sh
python3 scripts/package.py --version 1.0.0 --release \
  --sign-identity 'Developer ID Application: YOUR NAME (TEAMID)' \
  --notary-profile unsit-notary --output dist/release-1.0.0
```

## Verify a download

Download an asset and `checksums.txt` from the same release. Compute its SHA-256
and compare it with the manifest:

```sh
shasum -a 256 Unsit-1.0.0-macos-arm64.zip
```

When every listed asset is present, `shasum -a 256 -c checksums.txt` checks the
whole manifest. A checksum detects changed bytes; provenance requires verifying
the attestation and its expected source commit. With a recent GitHub CLI:

```sh
gh attestation verify Unsit-1.0.0-macos-arm64.zip --repo ptudor/unsit --signer-workflow ptudor/unsit/.github/workflows/release.yml
```

Inspect the verified repository, workflow, tag, and commit. Development snapshots
are not release-attested. GitHub attestations establish build provenance and do
not substitute for Apple code signing or notarization. See
[GitHub's attestation documentation](https://github.com/actions/attest).
