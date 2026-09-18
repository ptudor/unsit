#!/usr/bin/env python3
"""Prepare an immutable draft release from verified signed CI artifacts."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import time


def gh(*args):
    return subprocess.check_output(["gh", *args], text=True)


def find_release(repository, tag):
    # The by-tag endpoint returns published releases only. List releases with
    # push access to discover drafts, including those left by a failed run.
    pages = json.loads(gh("api", "repos/" + repository + "/releases?per_page=100", "--paginate", "--slurp"))
    matches = [release for page in pages for release in page if release["tag_name"] == tag]
    if len(matches) > 1:
        raise SystemExit("Multiple releases have this tag; inspect the drafts before retrying")
    return matches[0] if matches else None


def prepare_draft(repository, tag, directory, hashes):
    release = find_release(repository, tag)
    if release is None:
        command = ["release", "create", tag, "--repo", repository, "--draft", "--verify-tag",
                   "--title", "Unsit " + tag, "--notes-file", "docs/release-notes/" + tag + ".md"]
        if "-" in tag:
            command.append("--prerelease")
        gh(*command)
        # The releases list can lag a few seconds behind a create; the v1.2.0 run
        # gave up on its first look while the draft was already there.
        for attempt in range(6):
            if attempt:
                time.sleep(5)
            release = find_release(repository, tag)
            if release is not None:
                break
        else:
            raise SystemExit("Created draft could not be found; inspect it before retrying")
    if not release["draft"] or release["tag_name"] != tag:
        raise SystemExit("This version is already published; do not replace it")
    existing = {}
    for asset in release["assets"]:
        name = asset["name"]
        if name not in hashes or asset.get("digest") != "sha256:" + hashes[name]:
            raise SystemExit("Existing draft asset differs: " + name + "; inspect the failed run before retrying")
        existing[name] = asset
    for name in sorted(hashes.keys() - existing.keys()):
        gh("release", "upload", tag, str(directory / name), "--repo", repository)
    endpoint = "repos/" + repository + "/releases/" + str(release["id"])
    final = json.loads(gh("api", endpoint))
    if not final["draft"] or final["tag_name"] != tag:
        raise SystemExit("Release changed while preparing the draft; inspect it before continuing")
    if {asset["name"]: asset.get("digest") for asset in final["assets"]} != {name: "sha256:" + digest for name, digest in hashes.items()}:
        raise SystemExit("Uploaded draft assets do not match the verified bytes")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--directory", type=Path, default=Path("dist"))
    args = parser.parse_args()
    if not re.fullmatch(r"v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?", args.tag):
        raise SystemExit("Invalid release tag")
    repository = os.environ.get("GH_REPO", "")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise SystemExit("Set GH_REPO to the intended repository")
    version = args.tag[1:]
    spec = importlib.util.spec_from_file_location("verify_release", Path(__file__).with_name("verify-release.py"))
    verify = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(verify)
    hashes = {}
    for arch in ("arm64", "x86_64"):
        verify.verify(args.directory, version, arch, notarized=True)
        entries = verify.verify_checksums(args.directory, args.directory / ("checksums-macos-" + arch + ".txt"))
        for name, digest in entries.items():
            if name in hashes and hashes[name] != digest:
                raise SystemExit("Architecture builds disagree about " + name)
            hashes[name] = digest
    manifest = args.directory / "checksums.txt"
    manifest.write_text("".join(hashes[name] + "  " + name + "\n" for name in sorted(hashes)))
    hashes[manifest.name] = verify.sha256(manifest)
    prepare_draft(repository, args.tag, args.directory, hashes)
    print("Draft assets verified; ready for provenance attestation and publication")


if __name__ == "__main__":
    main()
