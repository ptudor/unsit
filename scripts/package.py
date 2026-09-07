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

ROOT = Path(__file__).resolve().parent.parent
SOURCE_ITEMS = ["Sources", "Tests", "scripts", "packaging", "docs", ".github", "Package.swift", "README.md", "LICENSE", "THIRD_PARTY_NOTICES.md", "VERSION", "CHANGELOG.md", "CONTRIBUTING.md", "SECURITY.md", ".gitignore", ".gitattributes", ".editorconfig", "Makefile"]

def run(*args, capture=False):
    if capture:
        return subprocess.check_output(args, cwd=ROOT, text=True).strip()
    subprocess.run(args, cwd=ROOT, check=True)

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
    source_archive(output / source_name, version, epoch)
    with tempfile.TemporaryDirectory(prefix="unsit-package-") as tmp:
        stage = Path(tmp).resolve()
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
                    "source_sha256": hashlib.sha256((output / source_name).read_bytes()).hexdigest(),
                    "signing": "ad-hoc", "notarized": False, "update_repository": args.repository}
        (resources / "build-info.json").write_text(json.dumps(metadata, indent=2) + "\n")
        maker = stage / "make-icon"
        run("swiftc", str(ROOT / "scripts/make-icon.swift"), "-o", str(maker))
        iconset = stage / "AppIcon.iconset"
        run(str(maker), str(iconset))
        run("iconutil", "-c", "icns", str(iconset), "-o", str(resources / "AppIcon.icns"))
        run("codesign", "--force", "--sign", "-", str(executables / "unsit"))
        run("codesign", "--force", "--sign", "-", str(app))
        run("codesign", "--verify", "--deep", "--strict", str(app))
        run(str(executables / "unsit"), "--self-test")
        run("python3", "scripts/verify-method13.py", "--binary", str(executables / "unsit"))
        zip_name = "Unsit-" + version + "-macos-" + arch + ".zip"
        run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(output / zip_name))
        disk = stage / "disk-image"
        disk.mkdir()
        shutil.copytree(app, disk / "Unsit.app")
        (disk / "Applications").symlink_to("/Applications", target_is_directory=True)
        dmg_name = "Unsit-" + version + "-macos-" + arch + ".dmg"
        run("hdiutil", "create", "-volname", "Unsit " + version, "-srcfolder", str(disk), "-format", "UDZO", "-fs", "HFS+", "-ov", str(output / dmg_name))
        run("hdiutil", "verify", str(output / dmg_name))
        update_name = "Unsit-" + version + "-macos-" + arch + ".update.json"
        minimum_os = info["LSMinimumSystemVersion"].split(".")
        minimum_os += ["0"] * (3 - len(minimum_os))
        update = {"schemaVersion": 1, "version": version, "bundleIdentifier": info["CFBundleIdentifier"],
                  "minimumSystemVersion": ".".join(minimum_os), "assetName": dmg_name}
        (output / update_name).write_text(json.dumps(update, indent=2) + "\n")
        cli = stage / ("unsit-" + version + "-macos-" + arch)
        cli.mkdir()
        shutil.copy2(executables / "unsit", cli / "unsit")
        for name in ["LICENSE", "THIRD_PARTY_NOTICES.md", "README.md"]:
            shutil.copy2(ROOT / name, cli / name)
        shutil.copy2(resources / "build-info.json", cli / "build-info.json")
        cli_name = cli.name + ".tar.gz"
        with tarfile.open(output / cli_name, "w:gz") as archive:
            archive.add(cli, arcname=cli.name)
        installed = output / "Unsit.app"
        if installed.exists():
            existing = plistlib.loads((installed / "Contents/Info.plist").read_bytes())
            if existing.get("CFBundleIdentifier") != "net.ptudor.Unsit":
                raise SystemExit("Refusing to replace an unrelated app in the output directory")
            shutil.rmtree(installed)
        shutil.copytree(app, installed)
        names = [zip_name, dmg_name, update_name, cli_name, source_name]
        checksums = ''.join(hashlib.sha256((output / name).read_bytes()).hexdigest() + "  " + name + "\n" for name in sorted(names))
        (output / ("checksums-macos-" + arch + ".txt")).write_text(checksums)
    print("Packaged " + str(output / "Unsit.app"))
    print("Development signing only: these artifacts are not Developer ID signed or notarized.")

if __name__ == "__main__":
    main()
