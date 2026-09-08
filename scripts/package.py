#!/usr/bin/env python3
"""Build the macOS app, installer, CLI, sources, and update/checksum manifests."""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import tarfile
import tempfile
import uuid

ROOT = Path(__file__).resolve().parent.parent
SOURCE_ITEMS = ["Sources", "Tests", "scripts", "packaging", "docs", ".github", "Package.swift", "README.md", "RELEASE.md", "LICENSE", "THIRD_PARTY_NOTICES.md", "VERSION", "CHANGELOG.md", "CONTRIBUTING.md", "SECURITY.md", ".gitignore", ".gitattributes", ".editorconfig", "Makefile"]

def run(*args, capture=False):
    if capture:
        return subprocess.check_output(args, cwd=ROOT, text=True).strip()
    subprocess.run(args, cwd=ROOT, check=True)

def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as contents:
        for chunk in iter(lambda: contents.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

def developer_identity(requested, listing):
    identities = re.findall(r'\d+\)\s+([A-Fa-f0-9]{40}) "(Developer ID Application: [^"\n]+ \(([A-Z0-9]{10})\))"', listing)
    matches = [item for item in identities if requested == item[1] or requested.upper() == item[0].upper()]
    if len(matches) != 1:
        raise ValueError("Select one valid Developer ID Application identity by its exact name or SHA-1 identifier")
    identity, name, team = matches[0]
    return identity, name, team

def accepted_submission(data):
    if not isinstance(data, dict) or data.get("status") != "Accepted":
        raise ValueError("Apple did not accept the notarization submission")
    try:
        submission_id = str(uuid.UUID(data["id"]))
    except (KeyError, TypeError, ValueError, AttributeError):
        raise ValueError("Apple returned an invalid notarization submission identifier") from None
    return {"id": submission_id, "status": "Accepted"}

def notarize(path, args):
    authentication = ["--keychain-profile", args.notary_profile]
    if args.keychain:
        authentication.extend(["--keychain", args.keychain])
    command = ["xcrun", "notarytool", "submit", str(path), *authentication,
               "--wait", "--timeout", "30m", "--output-format", "json"]
    print("Submitting " + path.name + " for Apple notarization", flush=True)
    result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
    log_dir = ROOT / ".build/notary-logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    log_path = log_dir / (path.name + "-" + str(uuid.uuid4()) + ".json")
    log_path.write_text(result.stdout + ("\n" + result.stderr if result.stderr else ""))
    try:
        if result.returncode:
            raise ValueError("Notarization failed or timed out")
        receipt = accepted_submission(json.loads(result.stdout))
    except (ValueError, json.JSONDecodeError) as error:
        raise SystemExit(str(error) + "; submission output: " + str(log_path)) from None
    print("Notarization accepted: " + receipt["id"], flush=True)
    return receipt

def sign(path, identity, keychain=None, executable=True):
    command = ["codesign", "--force", "--sign", identity]
    if identity != "-":
        command.append("--timestamp")
        if executable:
            command.extend(["--options", "runtime"])
        if keychain:
            command.extend(["--keychain", keychain])
    run(*command, str(path))

def zip_app(app, path):
    run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(path))

def source_archive(path, version, epoch):
    with path.open("wb") as output, gzip.GzipFile(filename="", fileobj=output, mode="wb", mtime=0) as zipped, tarfile.open(fileobj=zipped, mode="w") as tar:
        for item in SOURCE_ITEMS:
            source = ROOT / item
            if not source.exists():
                raise SystemExit("Missing release source: " + item)
            paths = sorted(source.rglob("*")) if source.is_dir() else [source]
            for file in paths:
                if not file.is_file() or file.name == ".DS_Store" or "__pycache__" in file.parts or file.suffix == ".pyc":
                    continue
                name = "unsit-" + version + "/" + file.relative_to(ROOT).as_posix()
                info = tar.gettarinfo(str(file), arcname=name)
                info.uid = info.gid = 0
                info.uname = info.gname = ""
                info.mtime = epoch
                with file.open("rb") as contents:
                    tar.addfile(info, contents)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", choices=["native", "arm64", "x86_64", "universal"], default="native")
    parser.add_argument("--output", type=Path, default=ROOT / "dist")
    parser.add_argument("--version", help="Release version; defaults to a development snapshot")
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", "ptudor/unsit"), help="GitHub owner/repository for update checks")
    parser.add_argument("--release", action="store_true", help="Require a clean tree and matching local version tag")
    parser.add_argument("--sign-identity", help="Developer ID Application identity name or SHA-1 identifier")
    parser.add_argument("--notary-profile", help="Validated notarytool Keychain profile")
    parser.add_argument("--keychain", help="Keychain containing both the identity and notary profile")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_-][A-Za-z0-9_.-]*/[A-Za-z0-9_-][A-Za-z0-9_.-]*", args.repository):
        raise SystemExit("Expected a GitHub owner/repository")
    if platform.system() != "Darwin":
        raise SystemExit("App packaging requires macOS and Xcode command-line tools")
    base = (ROOT / "VERSION").read_text().strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+", base):
        raise SystemExit("VERSION must contain MAJOR.MINOR.PATCH")
    if '"' + base + '"' not in (ROOT / "Sources/unsit/Version.swift").read_text():
        raise SystemExit("VERSION and the CLI version differ")
    commit = run("git", "rev-parse", "HEAD", capture=True)
    dirty = bool(run("git", "status", "--porcelain", capture=True))
    version = args.version or base + "-dev." + commit[:7] + (".dirty" if dirty else "")
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?", version) or version.split("-", 1)[0] != base:
        raise SystemExit("Invalid version or version differs from VERSION")
    if args.release:
        if dirty or args.version is None:
            raise SystemExit("Release packaging requires a clean tree and explicit --version")
        if run("git", "rev-parse", "refs/tags/v" + version + "^{}", capture=True) != commit:
            raise SystemExit("The release tag must identify HEAD")
        if not args.sign_identity or not args.notary_profile:
            raise SystemExit("Release packaging requires --sign-identity and --notary-profile; see RELEASE.md")
    if (args.notary_profile or args.keychain) and not args.sign_identity:
        raise SystemExit("--notary-profile and --keychain require --sign-identity")
    identity, identity_name, team = "-", None, None
    if args.sign_identity:
        command = ["security", "find-identity", "-v", "-p", "codesigning"]
        if args.keychain:
            command.append(args.keychain)
        try:
            identity, identity_name, team = developer_identity(args.sign_identity, run(*command, capture=True))
        except ValueError as error:
            raise SystemExit(str(error)) from None
    arch = platform.machine() if args.arch == "native" else args.arch
    arches = ["arm64", "x86_64"] if arch == "universal" else [arch]
    build = ["swift", "build", "-c", "release", "--scratch-path", str(ROOT / ".build" / ("package-" + arch))]
    for target in arches:
        build.extend(["--arch", target])
    run("python3", "scripts/generate-codebooks.py", "--check")
    run(*build)
    binary_dir = Path(run(*build, "--show-bin-path", capture=True))
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    epoch = int(run("git", "show", "-s", "--format=%ct", "HEAD", capture=True))
    source_name = "unsit-" + version + "-source.tar.gz"
    with tempfile.TemporaryDirectory(prefix=".unsit-package-", dir=output) as tmp:
        stage = Path(tmp).resolve()
        artifacts = stage / "artifacts"
        artifacts.mkdir()
        source_archive(artifacts / source_name, version, epoch)
        app = stage / "Unsit.app"
        executables = app / "Contents/MacOS"
        resources = app / "Contents/Resources"
        executables.mkdir(parents=True)
        resources.mkdir()
        info = plistlib.loads((ROOT / "packaging/Info.plist").read_bytes())
        info.update(CFBundleShortVersionString=base, CFBundleVersion=base)
        info.update(UnsitReleaseRepository=args.repository, UnsitAutomaticUpdatesDefault=args.release and "-" not in version)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        for name in ["unsit", "UnsitApp"]:
            shutil.copy2(binary_dir / name, executables / name)
            actual = set(run("lipo", "-archs", str(executables / name), capture=True).split())
            if actual != set(arches):
                raise SystemExit(name + " has unexpected architectures: " + str(actual))
        for name in ["LICENSE", "THIRD_PARTY_NOTICES.md"]:
            shutil.copy2(ROOT / name, resources / name)
        shutil.copy2(ROOT / "packaging/Help.html", resources / "Help.html")
        metadata = {"version": version, "commit": commit, "dirty": dirty, "architectures": arches,
                    "swift": run("swift", "--version", capture=True), "source_archive": source_name,
                    "source_sha256": sha256(artifacts / source_name),
                    "signing": "developer-id" if args.sign_identity else "ad-hoc",
                    "signing_identity": identity_name, "team_identifier": team,
                    "hardened_runtime": bool(args.sign_identity),
                    "notarized": bool(args.notary_profile), "update_repository": args.repository}
        # The signed metadata cannot change after Apple's submission. A claimed
        # notarized build stays in private staging until both submissions pass.
        (resources / "build-info.json").write_text(json.dumps(metadata, indent=2) + "\n")
        maker = stage / "make-icon"
        run("swiftc", str(ROOT / "scripts/make-icon.swift"), "-o", str(maker))
        iconset = stage / "AppIcon.iconset"
        run(str(maker), str(iconset))
        run("iconutil", "-c", "icns", str(iconset), "-o", str(resources / "AppIcon.icns"))
        sign(executables / "unsit", identity, args.keychain)
        sign(app, identity, args.keychain)
        run("codesign", "--verify", "--deep", "--strict", str(app))
        run(str(executables / "unsit"), "--self-test")
        run("python3", "scripts/verify-method13.py", "--binary", str(executables / "unsit"))
        app_receipt = None
        if args.notary_profile:
            submission_zip = stage / "Unsit-notary.zip"
            zip_app(app, submission_zip)
            app_receipt = notarize(submission_zip, args)
            run("xcrun", "stapler", "staple", str(app))
            run("xcrun", "stapler", "validate", str(app))
            run("spctl", "--assess", "--type", "execute", "--verbose=2", str(app))
        zip_name = "Unsit-" + version + "-macos-" + arch + ".zip"
        zip_app(app, artifacts / zip_name)
        disk = stage / "disk-image"
        disk.mkdir()
        run("ditto", str(app), str(disk / "Unsit.app"))
        (disk / "Applications").symlink_to("/Applications", target_is_directory=True)
        dmg_name = "Unsit-" + version + "-macos-" + arch + ".dmg"
        dmg_path = artifacts / dmg_name
        run("hdiutil", "create", "-volname", "Unsit " + version, "-srcfolder", str(disk), "-format", "UDZO", "-fs", "HFS+", "-ov", str(dmg_path))
        if args.sign_identity:
            sign(dmg_path, identity, args.keychain, executable=False)
        dmg_receipt = None
        if args.notary_profile:
            dmg_receipt = notarize(dmg_path, args)
            run("xcrun", "stapler", "staple", str(dmg_path))
            run("xcrun", "stapler", "validate", str(dmg_path))
            run("spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=2", str(dmg_path))
        run("hdiutil", "verify", str(dmg_path))
        update_name = "Unsit-" + version + "-macos-" + arch + ".update.json"
        minimum_os = info["LSMinimumSystemVersion"].split(".")
        minimum_os += ["0"] * (3 - len(minimum_os))
        update = {"schemaVersion": 1, "version": version, "bundleIdentifier": info["CFBundleIdentifier"],
                  "minimumSystemVersion": ".".join(minimum_os), "assetName": dmg_name}
        (artifacts / update_name).write_text(json.dumps(update, indent=2) + "\n")
        cli = stage / ("unsit-" + version + "-macos-" + arch)
        cli.mkdir()
        shutil.copy2(executables / "unsit", cli / "unsit")
        for name in ["LICENSE", "THIRD_PARTY_NOTICES.md", "README.md"]:
            shutil.copy2(ROOT / name, cli / name)
        shutil.copy2(resources / "build-info.json", cli / "build-info.json")
        cli_name = cli.name + ".tar.gz"
        with tarfile.open(artifacts / cli_name, "w:gz") as archive:
            archive.add(cli, arcname=cli.name)
        names = [zip_name, dmg_name, update_name, cli_name, source_name]
        if args.notary_profile:
            receipt_name = "Unsit-" + version + "-macos-" + arch + ".notarization.json"
            receipt = {"schemaVersion": 1, "version": version, "commit": commit,
                       "architecture": arch, "teamIdentifier": team,
                       "app": app_receipt, "dmg": dmg_receipt,
                       "sha256": {name: sha256(artifacts / name) for name in [zip_name, dmg_name, cli_name]}}
            (artifacts / receipt_name).write_text(json.dumps(receipt, indent=2) + "\n")
            names.append(receipt_name)
        checksums = ''.join(sha256(artifacts / name) + "  " + name + "\n" for name in sorted(names))
        checksum_name = "checksums-macos-" + arch + ".txt"
        (artifacts / checksum_name).write_text(checksums)
        run("python3", "scripts/verify-release.py", "--directory", str(artifacts),
            "--version", version, "--arch", arch, "--macos",
            *(["--require-notarized"] if args.notary_profile else []))
        # Release destinations are immutable. Failed Apple submissions never
        # replace a previous finished package or leave a publishable manifest.
        if args.release and any((output / name).exists() for name in names):
            raise SystemExit("Release assets already exist; use a fresh --output directory")
        installed = output / "Unsit.app"
        if installed.exists():
            existing = plistlib.loads((installed / "Contents/Info.plist").read_bytes())
            if existing.get("CFBundleIdentifier") != "net.ptudor.Unsit":
                raise SystemExit("Refusing to replace an unrelated app in the output directory")
            shutil.rmtree(installed)
        run("ditto", str(app), str(installed))
        for name in names + [checksum_name]:
            os.replace(artifacts / name, output / name)
    print("Packaged " + str(output / "Unsit.app"))
    print("Developer ID signed and notarized." if args.notary_profile else
          "Development snapshot: not notarized for public distribution.")

if __name__ == "__main__":
    main()
