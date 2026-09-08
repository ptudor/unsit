#!/usr/bin/env python3
"""Verify an Unsit release's final bytes, metadata, and optional macOS tickets."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import subprocess
import tarfile
import tempfile
import uuid
import zipfile


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as contents:
        for chunk in iter(lambda: contents.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_checksums(directory, manifest):
    entries = {}
    for line in manifest.read_text().splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._-]*)", line)
        require(match is not None, "Invalid or unsafe checksum manifest entry")
        digest, name = match.groups()
        require(name not in entries, "Duplicate checksum entry: " + name)
        path = directory / name
        require(path.is_file() and not path.is_symlink(), "Missing or symlinked asset: " + name)
        require(sha256(path) == digest, "Checksum mismatch: " + name)
        entries[name] = digest
    require(bool(entries), "Empty checksum manifest")
    return entries


def read_zip(archive, name):
    entry = archive.getinfo(name)
    require(entry.file_size <= 1_048_576, "Oversized bundle metadata")
    return archive.read(entry)


def check_zip_paths(archive):
    entries = archive.infolist()
    require(len(entries) <= 10_000 and sum(x.file_size for x in entries) <= 256 * 1024 * 1024,
            "Oversized app ZIP")
    names = set()
    for entry in entries:
        path = PurePosixPath(entry.filename)
        require(not path.is_absolute() and ".." not in path.parts and "\\" not in entry.filename,
                "Unsafe app ZIP path")
        require(path.parts and path.parts[0] in ("Unsit.app", "__MACOSX"), "Unexpected app ZIP entry")
        require(entry.filename not in names, "Duplicate app ZIP entry")
        require(not stat.S_ISLNK(entry.external_attr >> 16), "Unexpected app ZIP symlink")
        names.add(entry.filename)


def command(*args):
    result = subprocess.run(args, check=True, capture_output=True)
    return result.stdout


def assess_app(app, metadata, notarized):
    command("codesign", "--verify", "--deep", "--strict", str(app))
    for path in (app, app / "Contents/MacOS/unsit"):
        command("codesign", "--verify", "--strict", str(path))
        if notarized:
            result = subprocess.run(["codesign", "-d", "--verbose=4", str(path)],
                                    check=True, capture_output=True, text=True)
            details = result.stderr + result.stdout
            require("Authority=Developer ID Application:" in details, "Missing Developer ID signature")
            require("TeamIdentifier=" + metadata["team_identifier"] + "\n" in details,
                    "Code signature team does not match build metadata")
            require("runtime" in details and "Timestamp=" in details,
                    "Missing Hardened Runtime or secure timestamp")
    if notarized:
        command("xcrun", "stapler", "validate", str(app))
        command("spctl", "--assess", "--type", "execute", "--verbose=2", str(app))


def verify_macos(directory, prefix, metadata, notarized):
    with tempfile.TemporaryDirectory(prefix="unsit-release-verify-") as tmp:
        extracted = Path(tmp)
        command("ditto", "-x", "-k", str(directory / (prefix + ".zip")), str(extracted))
        app = extracted / "Unsit.app"
        assess_app(app, metadata, notarized)
        helper = app / "Contents/MacOS/unsit"
        command(str(helper), "--self-test")
        dmg = directory / (prefix + ".dmg")
        command("hdiutil", "verify", str(dmg))
        if notarized:
            command("codesign", "--verify", "--strict", str(dmg))
            command("xcrun", "stapler", "validate", str(dmg))
            command("spctl", "--assess", "--type", "open", "--context", "context:primary-signature",
                    "--verbose=2", str(dmg))
        mounted = plistlib.loads(command("hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen", "-plist", str(dmg)))
        entities = mounted["system-entities"]
        device = next(x["dev-entry"] for x in entities if "dev-entry" in x)
        try:
            volume = Path(next(x["mount-point"] for x in entities if "mount-point" in x))
            disk_app = volume / "Unsit.app"
            require((volume / "Applications").is_symlink()
                    and (volume / "Applications").readlink() == Path("/Applications"),
                    "Missing Applications shortcut")
            assess_app(disk_app, metadata, notarized)
            require(json.loads((disk_app / "Contents/Resources/build-info.json").read_bytes()) == metadata,
                    "DMG and ZIP build metadata differ")
            for binary in ("unsit", "UnsitApp"):
                require(sha256(disk_app / "Contents/MacOS" / binary) == sha256(app / "Contents/MacOS" / binary),
                        "DMG and ZIP binaries differ")
        finally:
            command("hdiutil", "detach", device)


def verify(directory, version, arch, notarized=False, macos=False, team=None):
    require(re.fullmatch(r"\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?", version), "Invalid release version")
    prefix = "Unsit-" + version + "-macos-" + arch
    cli_name = "unsit-" + version + "-macos-" + arch + ".tar.gz"
    source_name = "unsit-" + version + "-source.tar.gz"
    manifest = directory / "checksums.txt"
    if not manifest.exists():
        manifest = directory / ("checksums-macos-" + arch + ".txt")
    hashes = verify_checksums(directory, manifest)
    required = [prefix + suffix for suffix in (".zip", ".dmg", ".update.json")] + [cli_name, source_name]
    if notarized:
        required.append(prefix + ".notarization.json")
    require(set(required) <= hashes.keys(), "Release is missing required assets/checksums")
    update = json.loads((directory / (prefix + ".update.json")).read_text())
    require(type(update["schemaVersion"]) is int and update["schemaVersion"] == 1
            and update["version"] == version and update["bundleIdentifier"] == "net.ptudor.Unsit"
            and update["assetName"] == prefix + ".dmg", "Invalid updater metadata")
    require(re.fullmatch(r"\d+\.\d+\.\d+", update["minimumSystemVersion"]), "Invalid minimum macOS version")
    with zipfile.ZipFile(directory / (prefix + ".zip")) as archive:
        check_zip_paths(archive)
        metadata = json.loads(read_zip(archive, "Unsit.app/Contents/Resources/build-info.json"))
        info = plistlib.loads(read_zip(archive, "Unsit.app/Contents/Info.plist"))
        for name in ("LICENSE", "THIRD_PARTY_NOTICES.md", "Help.html"):
            require(bool(read_zip(archive, "Unsit.app/Contents/Resources/" + name)), "Missing bundled notices/help")
    require(metadata["version"] == version and metadata["architectures"] ==
            (["arm64", "x86_64"] if arch == "universal" else [arch]), "Incorrect build version or architecture")
    require(re.fullmatch(r"[0-9a-f]{40}", metadata["commit"]), "Missing source commit")
    require(metadata["source_archive"] == source_name and metadata["source_sha256"] == hashes[source_name],
            "Source archive differs from the signed build metadata")
    require(info["CFBundleIdentifier"] == "net.ptudor.Unsit"
            and info["CFBundleShortVersionString"] == version.split("-", 1)[0]
            and info["UnsitReleaseRepository"] == metadata["update_repository"], "Incorrect bundle identity/version/feed")
    minimum = info["LSMinimumSystemVersion"].split(".")
    require(".".join(minimum + ["0"] * (3 - len(minimum))) == update["minimumSystemVersion"],
            "Bundle and updater minimum macOS versions differ")
    with tarfile.open(directory / cli_name) as archive:
        raw = archive.extractfile(cli_name[:-7] + "/build-info.json")
        require(raw is not None and json.load(raw) == metadata, "CLI and app build metadata differ")
    with tarfile.open(directory / source_name) as archive:
        names = set(archive.getnames())
        source_prefix = "unsit-" + version + "/"
        require({source_prefix + name for name in ("RELEASE.md", "LICENSE", "THIRD_PARTY_NOTICES.md", "Package.swift")} <= names,
                "Source archive is missing release instructions or notices")
    if notarized:
        require(metadata["signing"] == "developer-id" and metadata["notarized"] is True
                and metadata["hardened_runtime"] is True and metadata["dirty"] is False,
                "Release is not a clean Developer ID/notarized build")
        require(re.fullmatch(r"[A-Z0-9]{10}", metadata["team_identifier"] or ""), "Invalid signing team")
        if team:
            require(metadata["team_identifier"] == team, "Unexpected signing team")
        receipt = json.loads((directory / (prefix + ".notarization.json")).read_text())
        require(receipt["schemaVersion"] == 1 and receipt["version"] == version
                and receipt["commit"] == metadata["commit"] and receipt["architecture"] == arch
                and receipt["teamIdentifier"] == metadata["team_identifier"], "Notarization receipt identity mismatch")
        for kind in ("app", "dmg"):
            require(receipt[kind]["status"] == "Accepted", "Apple did not accept the " + kind)
            uuid.UUID(receipt[kind]["id"])
        receipt_names = {prefix + ".zip", prefix + ".dmg", cli_name}
        require(set(receipt["sha256"]) == receipt_names, "Notarization receipt is missing final asset hashes")
        require(all(receipt["sha256"][name] == hashes[name] for name in receipt_names),
                "Final assets differ from their notarization receipt")
    if macos:
        verify_macos(directory, prefix, metadata, notarized)
    print("Verified " + version + " " + arch + (" with Developer ID and notarization" if notarized else " development snapshot"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--arch", choices=["arm64", "x86_64", "universal"], required=True)
    parser.add_argument("--require-notarized", action="store_true")
    parser.add_argument("--macos", action="store_true", help="Also check installed signatures, tickets, and the mounted DMG")
    parser.add_argument("--team-id", help="Require a particular Developer ID team")
    args = parser.parse_args()
    try:
        verify(args.directory.resolve(), args.version, args.arch, args.require_notarized, args.macos, args.team_id)
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit("Release verification failed: " + str(error)) from None


if __name__ == "__main__":
    main()
