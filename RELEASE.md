# Releasing Unsit

This is the maintainer runbook for publishing `ptudor/unsit`. Follow it for the
first `v1.0.0` release and for subsequent versions. A public release contains
Developer ID signed, notarized macOS apps and installers, matching command-line
tools, current source, SHA-256 checksums, update metadata, notarization receipts,
and GitHub provenance attestations. Development snapshots use ad hoc signing.

The existing `origin` is the project's primary Git repository. `github` is a
separate publication remote. Creating or pushing to GitHub does not require
changing `origin`. Publishing a version tag starts the release workflow.

## Prerequisites

- A clean checkout of the intended commit, with Xcode command-line tools,
  Python 3, Swift, and an authenticated GitHub CLI.
- Maintainer access to the public `ptudor/unsit` repository and its Actions.
- A valid **Developer ID Application** certificate **and its private key**.
  An Apple Development certificate or Developer ID Installer certificate does
  not serve this purpose. Check with `security find-identity -v -p codesigning`.
- Apple notarization credentials for the certificate's developer team.
- The release's native Apple silicon and Intel checks passing on GitHub.

Create or import the signing identity through Xcode's account/certificate tools
or the Apple developer account. Apple documents the required account role and
certificate setup in [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates).
Keep private keys, certificate exports, and passwords outside this repository.

## One-time GitHub setup

Check the account and existing repository before creating anything:

```sh
gh auth status
gh repo view ptudor/unsit
git remote -v
```

If the repository does not exist:

```sh
gh repo create ptudor/unsit --public \
  --description 'Recover classic StuffIt archives on macOS with a native app and CLI' \
  --disable-wiki
git remote add github https://github.com/ptudor/unsit.git
```

If `github` already exists, inspect its URL instead of adding it again. The
commands below use GitHub CLI's credential helper for this invocation only;
they do not change the authentication setup for other remotes:

```sh
git -c credential.helper= \
  -c 'credential.https://github.com.helper=!gh auth git-credential' \
  push github main
```

Enable Actions in the repository. The workflows pin their actions to commits.
Normal CI has read-only repository access; publication alone receives write and
attestation permissions. Keep private archive corpora and extraction output
outside the checkout. Review the current tree and scan Git history before its
first public push:

```sh
git status --short
git ls-files
gitleaks git --redact=100 --no-banner --log-opts=--all
```

The release source archive uses an explicit allowlist in `scripts/package.py`.
It includes this runbook and current licensing notices; it excludes private
inputs, build caches, credentials, Git metadata, and historical review files.
Git history retains the licensing provenance of earlier implementations.

## Configure Apple credentials

Signing and notarization use different credentials. The Developer ID certificate
and private key sign the app as its publisher. Notarization sends the signed app
to Apple's service for inspection and needs an Apple account login. Creating a
certificate in Xcode completes the signing setup; it does not automatically
create the command-line notarization profile described below.

### Choose where releases are signed

For this project's repeatable release workflow, the recommended choice is
**GitHub Actions with credentials in the `release` environment**. Both native
builds, signing, notarization, publication, and the live updater check can then
run from a version tag without depending on the maintainer's Mac being awake.

| Choice | Credential location | Work for each release |
| --- | --- | --- |
| GitHub Actions | A copy of the signing key and notary credentials is stored as encrypted environment secrets and loaded into a temporary runner keychain | Push the reviewed version tag and monitor the workflow |
| Local signing | The signing key and notary credentials stay in the release Mac's Keychain | Run signed packaging on that Mac and upload and verify its finished artifacts |

Public repository visitors cannot read environment secrets. The authorized
release jobs can use them, so control over those jobs also carries control over
the signing credentials. Keeping credentials local avoids granting that ability
to GitHub jobs. The choice changes the maintainer's release process; either can
produce a signed, notarized app with the same installation and update experience.
The automated workflow in this repository implements the GitHub Actions choice;
a local-only publication path needs separate artifact publication and provenance
handling. Do not upload a private signing key without the publisher's agreement.

### Local packaging

`unsit-notary` is a name chosen for a saved set of notarization credentials. It is
not another certificate, an App Store app registration, or a value to find in
Xcode. It is useful for local rehearsal; GitHub runners cannot read this Mac's
Keychain and need their own credentials in the next section.

1. Sign in to [your Apple account](https://account.apple.com/) using the account
   that belongs to the signing team.
2. Open **Sign-In and Security → App-Specific Passwords**, generate a password,
   and give it a recognizable label such as `Unsit notarization`. Apple requires
   two-factor authentication for this feature. See
   [Apple's password instructions](https://support.apple.com/en-us/102654).
3. Run the following command in Terminal, replacing the example email with that
   Apple account's email. `55QT38683G` is the current Unsit signing team; another
   publisher must use their own team identifier.

```sh
xcrun notarytool store-credentials unsit-notary \
  --apple-id 'YOUR-APPLE-ACCOUNT-EMAIL' \
  --team-id 55QT38683G
```

4. At the secure password prompt, paste the generated app-specific password and
   press Return. Terminal may show no characters while it is entered. Use the
   generated password here, not the normal Apple account password. Omitting the
   password from the command keeps it out of shell history.
5. The tool checks the login with Apple and saves it to Keychain. This step does
   not upload an app or publish a release. Confirm that the saved profile works:

```sh
xcrun notarytool history --keychain-profile unsit-notary
security find-identity -v -p codesigning
```

An empty submission history is normal before the first notarization. An
authentication error needs correction before packaging can submit an app.
App-specific passwords can be revoked individually in the Apple account; changing
the primary Apple account password also revokes existing app-specific passwords.

Use the exact Developer ID Application identity name or SHA-1 identifier from
the last command. `--keychain PATH` selects an explicit keychain for both signing
and notarization when they are stored together outside the normal search list.
Never pass passwords in the release command or commit them in configuration.

### GitHub Actions

Create the `release` environment in repository settings. Permit deployment from
version tags (`v*`). Store these **environment secrets** there:

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | Base64 of a password-protected export of the Developer ID Application certificate and its private key |
| `DEVELOPER_ID_P12_PASSWORD` | Password protecting that export |
| `APPLE_TEAM_ID` | Team identifier belonging to that certificate |
| `NOTARY_APPLE_ID` | Apple account authorized to notarize for that team |
| `NOTARY_APP_PASSWORD` | App-specific password for that account |

Enter secrets through GitHub's secure settings interface or `gh secret set`'s
prompt/stdin. Do not put their values in command arguments, workflow YAML, logs,
or chat. Verify names, without retrieving values:

```sh
gh secret list --repo ptudor/unsit --env release
```

`scripts/ci-signing.py` imports the certificate into an isolated temporary
keychain, selects a Developer ID identity for the specified team, and stores a
validated notarization profile there. An `always()` cleanup step deletes that
keychain and temporary credential files. Secrets are used only in the release
packaging jobs, after ordinary CI and the history scan pass. Missing credentials
stop the release; there is no fallback to an ad hoc public installer. See
[GitHub's macOS signing guidance](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications).

## Prepare a version

1. Update `VERSION` and `Sources/unsit/Version.swift` to the same
   `MAJOR.MINOR.PATCH` value. Update `CHANGELOG.md` and create
   `docs/release-notes/vMAJOR.MINOR.PATCH.md`.
2. Describe measured behavior, supported formats, recovery warnings, and known
   limits. Publish aggregate compatibility results without private filenames or
   archive contents. Retain `LICENSE` and `THIRD_PARTY_NOTICES.md`.
3. Confirm `packaging/Info.plist` has the intended minimum macOS version and
   bundle identifier (`net.ptudor.Unsit`). The updater repository must be
   `ptudor/unsit`; packaging records it in the app and `build-info.json`.
4. Run the local checks and app rehearsal:

```sh
swift test
make check
python3 scripts/test-release.py
python3 scripts/package.py --arch universal
open dist/Unsit.app
```

Open synthetic archives through Finder, File → Open Archives, and drag-and-drop.
Check complete and damaged recovery reports, both forks, output collisions,
cancellation, and Finder's output action. Close the main window and restore it
using Window → Show Unsit, Command-0, and the Dock. Use a separate app instance
when testing lifecycle behavior so an older running copy cannot receive events.

The full native test suite includes deliberate fault injection into development
binaries. Production signatures enable Hardened Runtime without debug or library
validation exceptions. Production-helper smoke tests therefore use ordinary
extraction fixtures; do not weaken a release signature to enable fault injection.

Commit the complete release source and push `main` to `github`. Inspect the CI and
Security checks runs on that exact commit:

```sh
gh run list --repo ptudor/unsit --branch main --limit 10
gh run view RUN_ID --repo ptudor/unsit
gh run view RUN_ID --repo ptudor/unsit --log-failed
```

Both `Test and package (arm64)` and `Test and package (x86_64)` must pass. An Intel
cross-build on Apple silicon is not evidence of native Intel execution. Current
runners also do not establish behavior on the minimum supported macOS versions;
record minimum-platform testing separately in `docs/verification.md`.

## Tag and publish

Check the clean tree, version, signing secret names, and intended commit before
tagging. Confirm that the tag does not already exist locally or on GitHub. Never
move a published version tag or overwrite its assets.

For the first release:

```sh
git status --short
git rev-parse HEAD
git tag --list v1.0.0
gh release view v1.0.0 --repo ptudor/unsit
git tag -a v1.0.0 -m 'Release 1.0.0'
git -c credential.helper= \
  -c 'credential.https://github.com.helper=!gh auth git-credential' \
  push github v1.0.0
gh run list --repo ptudor/unsit --workflow release.yml --limit 5
```

The absence of a release is expected before first publication. If the tag or
release already exists, inspect it and resume its run rather than recreating it.
A prerelease such as `v1.0.0-rc.1` requires matching release notes and stays outside
the app's stable update feed.

The release workflow performs these steps in order:

1. Validate the version tag and required release files.
2. Run ordinary CI on both native architectures and scan full Git history.
3. Build each architecture from the checked tag in the `release` environment.
   Sign the helper first and the enclosing app second using Developer ID,
   Hardened Runtime, and secure timestamps.
4. Submit the app ZIP to Apple with `notarytool`; require `Accepted`. Staple and
   validate the app's ticket, and assess it with Gatekeeper.
5. Create the downloadable app ZIP from the stapled app. Create and sign a DMG
   containing that same app and an Applications shortcut. Notarize the DMG,
   require `Accepted`, then staple and validate its ticket.
6. Run the final signed helper's self-test and native integration checks. Verify
   the ZIP and DMG, receipt, update metadata, source identity, and signatures.
7. Compute hashes only after all signing and stapling. Upload the finished
   packages, merge and verify the architecture checksum manifests, create a
   draft release, and generate GitHub attestations for the exact uploaded bytes.
8. Publish the draft only after those checks and attestations succeed. Run the
   live updater verification against the now-public release.

Apple describes the submit/staple sequence in
[Customizing the notarization workflow](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution/customizing-the-notarization-workflow).
Signing changes bytes, and stapling can change container bytes: checksums and
GitHub asset digests must identify the final downloadable files.

## Local signed rehearsal

On the clean tagged checkout, use a fresh output directory:

```sh
python3 scripts/package.py --arch universal --version 1.0.0 --release \
  --sign-identity 'Developer ID Application: YOUR NAME (TEAMID)' \
  --notary-profile unsit-notary --output dist/release-1.0.0
python3 scripts/verify-release.py --directory dist/release-1.0.0 \
  --version 1.0.0 --arch universal --require-notarized --macos
```

This submits the app and DMG to Apple. It does not publish to GitHub. Local
packages are useful for rehearsal but do not carry the release workflow's build
attestation. Publish the artifacts produced and checked by the release workflow.

The CLI binary is signed and is included in the notarized app submission. Apple
does not support stapling a bare command-line executable or a tarball; its notary
record can be consulted online. The app and DMG carry stapled tickets.

## Verify the public release

Download to an empty directory and retain the verification output:

```sh
gh release view v1.0.0 --repo ptudor/unsit
gh release download v1.0.0 --repo ptudor/unsit --dir dist/download-1.0.0
python3 scripts/verify-release.py --directory dist/download-1.0.0 \
  --version 1.0.0 --arch arm64 --require-notarized --macos
gh attestation verify dist/download-1.0.0/Unsit-1.0.0-macos-arm64.dmg \
  --repo ptudor/unsit \
  --signer-workflow ptudor/unsit/.github/workflows/release.yml
```

Repeat verification for `x86_64` on an Intel Mac. Check the attestation's source
commit and workflow, the app's version/bundle ID/update repository, the Developer
ID team, and the accepted stapled tickets. Run a quarantined download through
Finder and extract a synthetic archive. Do not disable Gatekeeper or strip
quarantine to make a release test pass.

### Exercise the actual updater

Compile the probe with the app's real update client; no alternate downloader or
weakened validation is used:

```sh
swiftc -parse-as-library Sources/UnsitDesktop/AppUpdate.swift \
  scripts/check-updater.swift -o dist/check-updater
dist/check-updater --version 1.0.0 --arch arm64 --directory dist/update-check
dist/check-updater --version 1.0.0 --arch x86_64 --directory dist/update-check
```

For a first release, the probe supplies `0.0.0` as the previous version to the
same client code; it does not alter the shipped app's version. It checks the
stable endpoint, manifest identity, asset selection, exact byte count, SHA-256,
and quarantine, and downloads the DMG. It then checks that a client already on
the published version receives no newer update. A future release should also be
tested from the previous installed public app, through Download Update, opening
the installer, quitting the old app, and copying the new app into Applications.

The installed release should report its current version through Unsit → Check
for Updates and retain the configured automatic-check preference. Checks must
not send archive contents or recovery reports. An unpublished release, failed
download, or invalid manifest must never be reported as a successful upgrade.

## Failures and reruns

- **CI failure:** inspect the failed job, fix the source, commit, and rerun on
  the new commit before choosing a release tag.
- **Missing signing credentials:** configure the `release` environment; keep
  the release unpublished. Never substitute Apple Development or ad hoc signing.
- **Notary rejection or timeout:** use the recorded submission ID with
  `xcrun notarytool info` and `log`. A timeout does not cancel Apple's processing.
  Local logs remain under `.build/notary-logs`; do not publish raw account logs.
  No finished package is promoted from staging on a notary failure.
- **Attestation failure:** the release remains a draft. Rerun the failed jobs
  for the same immutable tag; verify existing asset hashes before reusing a
  draft. Do not manually publish unverified files.
- **Failure after publication:** inspect the public assets and updater error.
  For changed code or bytes, issue a new version. The updater rejects downgrades
  it has already seen; it cannot make missing assets or an invalid feed safe.
- **Credential compromise:** rotate the affected Apple or GitHub credentials
  and follow the provider's revocation process. Do not silently replace files
  under an existing version.

Record each execution using the tag, commit, CI and release run URLs, native
platform results, notary submission receipts, asset checksums, and live updater
result. GitHub retains the published receipts and attestations alongside the
release; keep a separate backup of credentials and release evidence.
