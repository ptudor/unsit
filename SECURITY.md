# Security

Report suspected vulnerabilities through the repository's **Security → Report a
vulnerability** page when enabled. Otherwise email **ptudor@ptudor.net** with
“Unsit security” in the subject. Include the affected version, platform, impact,
and a minimal reproduction; keep private archives and exploit details out of
public issues.

Security fixes target the current release and default branch. There is no
guaranteed response time or backport schedule.

Unsit treats archive names and lengths as untrusted, confines output with opened
directory descriptors, preserves existing destinations, and limits allocations
and recovery work. Tests include malformed archives, path collisions, native
syscall faults, and interrupted publication. These checks do not establish a
security certification or guarantee that every malformed archive is harmless.

Release automation scans Git history for secrets, pins third-party actions, and
limits publishing permissions to the release job. Assets include checksums and
build provenance attestations. App signing is currently ad hoc, without Developer
ID signing or notarization; see [release verification](docs/releases.md).
