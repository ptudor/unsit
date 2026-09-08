#!/usr/bin/env python3
"""Prepare an immutable draft release from verified signed CI artifacts."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess


def gh(*args):
    return subprocess.check_output(["gh", *args], text=True)


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
    endpoint = "repos/" + repository + "/releases/tags/" + args.tag
    result = subprocess.run(["gh", "api", endpoint], text=True, capture_output=True)
    if result.returncode:
        if "HTTP 404" not in result.stderr:
            raise SystemExit("Cannot inspect the existing release: " + result.stderr)
        command = ["release", "create", args.tag, "--repo", repository, "--draft", "--verify-tag",
                   "--title", "Unsit " + args.tag, "--notes-file", "docs/release-notes/" + args.tag + ".md"]
        if "-" in version:
            command.append("--prerelease")
        gh(*command)
        release = json.loads(gh("api", endpoint))
    else:
        release = json.loads(result.stdout)
    if not release["draft"] or release["tag_name"] != args.tag:
        raise SystemExit("This version is already published; do not replace it")
    existing = {}
    for asset in release["assets"]:
        name = asset["name"]
        if name not in hashes or asset.get("digest") != "sha256:" + hashes[name]:
            raise SystemExit("Existing draft asset differs: " + name + "; inspect the failed run before retrying")
        existing[name] = asset
    for name in sorted(hashes.keys() - existing.keys()):
        gh("release", "upload", args.tag, str(args.directory / name), "--repo", repository)
    final = json.loads(gh("api", endpoint))
    if {asset["name"]: asset.get("digest") for asset in final["assets"]} != {name: "sha256:" + digest for name, digest in hashes.items()}:
        raise SystemExit("Uploaded draft assets do not match the verified bytes")
    print("Draft assets verified; ready for provenance attestation and publication")


if __name__ == "__main__":
    main()
