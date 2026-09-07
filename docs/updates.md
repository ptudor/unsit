# App updates

Choose **Unsit → Check for Updates** to check immediately and change automatic
checks. Stable tagged builds default to daily checks, with six-hour and weekly
options. Snapshots and prereleases default to automatic checks off; an existing
user preference always wins. Failed checks wait at least 15 minutes before another
automatic attempt. Manual checks can retry immediately.

The flow follows TudorGPS's scheduled check, verified download, and installer
handoff. Unsit uses the configured public GitHub repository instead of requiring
a catalog service. The packaged default is `ptudor/unsit`; CI uses
`GITHUB_REPOSITORY`, and `scripts/package.py --repository OWNER/REPO` configures
another distribution. No release published yet is shown explicitly, never as
"up to date". The first public release must exist before a live upgrade is possible.

Only newer stable `vMAJOR.MINOR.PATCH` releases qualify. Each release includes a
small `.update.json` asset naming its version, bundle identifier, minimum macOS
version, and installer. The app chooses its architecture's assets or a universal
fallback. It validates these fields, requires an exact repository/tag/asset URL,
and keeps the highest accepted version to reject a subsequent rollback response.
A newer release requiring a newer macOS version is an advisory, not an offer to
install and not a claim that the installed version is current.

The app checks exact byte lengths and SHA-256 digests from GitHub's release API
for both the metadata and DMG. Missing digests, altered data, oversized transfers,
unsafe redirects, and invalid metadata fail closed. The API response is limited
to 1 MiB, metadata to 16 KiB, and an installer to 256 MiB. Downloads are streamed,
cancelable, and placed in unique cache directories; unsuccessful transfers remove
their partial files. Verified installers retain macOS quarantine metadata.
The digest field and stable release endpoint are documented in
[GitHub's releases API](https://docs.github.com/en/rest/releases/releases) and
[release assets API](https://docs.github.com/en/rest/releases/assets).

This trust model uses HTTPS to GitHub and the publisher's GitHub release access.
The hash detects changed downloads; it is not an independent publisher signature,
an in-app verification of GitHub's provenance attestation, or Apple notarization.
Unlike TudorGPS's signed catalog, no separate manifest signing key or freshness
renewal service is used. The app can reject versions it has already seen superseded,
but cannot independently detect a frozen, otherwise valid first response.
Release provenance can be checked separately as described in [releases](releases.md).

**Download Update** opens the verified disk image. Finish extracting, quit Unsit,
and drag the new app into Applications. Unsit does not replace a running app or
install silently. Extraction and the CLI work offline; update requests contain no
archive paths, contents, or extraction reports. GitHub receives ordinary network
request information, including the connecting IP address.

The updater and its failure paths are tested with local simulated responses. A
live public upgrade and Developer ID/notarization remain release checks; local
ad hoc packaging does not establish them.
