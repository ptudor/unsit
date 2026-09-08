#!/usr/bin/env python3
"""Create or remove the release job's isolated Apple signing credentials."""
import argparse
import base64
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess


def run(label, *arguments):
    # Some arguments contain passwords. Never print the command, its output, or
    # a CalledProcessError that would repeat those arguments into Actions logs.
    result = subprocess.run(arguments, capture_output=True, text=True)
    if result.returncode:
        raise SystemExit("Apple credential setup failed while " + label + "; check the release environment secrets")
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["setup", "cleanup"])
    args = parser.parse_args()
    if os.environ.get("GITHUB_ACTIONS") != "true" or not os.environ.get("RUNNER_TEMP"):
        raise SystemExit("This helper is only for GitHub Actions; use a Keychain profile locally")
    directory = Path(os.environ["RUNNER_TEMP"]).resolve() / "unsit-signing"
    keychain = directory / "release.keychain-db"
    if args.action == "cleanup":
        if keychain.exists():
            result = subprocess.run(["security", "delete-keychain", str(keychain)], capture_output=True)
            if result.returncode:
                raise SystemExit("Could not remove the temporary release keychain")
        if directory.exists():
            shutil.rmtree(directory)
        return
    required = ["DEVELOPER_ID_P12_BASE64", "DEVELOPER_ID_P12_PASSWORD", "APPLE_TEAM_ID",
                "NOTARY_APPLE_ID", "NOTARY_APP_PASSWORD"]
    missing = [name for name in required if not os.environ.get(name)]
    if missing:
        raise SystemExit("Missing release environment secrets: " + ", ".join(missing) + "; see RELEASE.md")
    team = os.environ["APPLE_TEAM_ID"]
    if not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise SystemExit("APPLE_TEAM_ID must contain the certificate's 10-character team identifier")
    directory.mkdir(mode=0o700)
    export = directory / "identity.p12"
    try:
        export.write_bytes(base64.b64decode("".join(os.environ["DEVELOPER_ID_P12_BASE64"].split()), validate=True))
    except ValueError:
        raise SystemExit("DEVELOPER_ID_P12_BASE64 is not valid base64") from None
    export.chmod(0o600)
    password = secrets.token_urlsafe(48)
    run("creating the temporary keychain", "security", "create-keychain", "-p", password, str(keychain))
    run("setting keychain timeout", "security", "set-keychain-settings", "-lut", "7200", str(keychain))
    run("unlocking the temporary keychain", "security", "unlock-keychain", "-p", password, str(keychain))
    run("importing Developer ID", "security", "import", str(export), "-k", str(keychain),
        "-P", os.environ["DEVELOPER_ID_P12_PASSWORD"], "-T", "/usr/bin/codesign", "-T", "/usr/bin/security")
    export.unlink()
    run("granting signing-tool access", "security", "set-key-partition-list", "-S", "apple-tool:,apple:",
        "-s", "-k", password, str(keychain))
    listing = run("checking Developer ID", "security", "find-identity", "-v", "-p", "codesigning", str(keychain))
    matches = re.findall(r'\d+\)\s+([A-Fa-f0-9]{40}) "Developer ID Application: [^"\n]+ \(' + re.escape(team) + r'\)"', listing)
    if len(matches) != 1:
        raise SystemExit("The export must contain one usable Developer ID Application identity for APPLE_TEAM_ID")
    profile = "unsit-release"
    run("validating notarization credentials", "xcrun", "notarytool", "store-credentials", profile,
        "--keychain", str(keychain), "--apple-id", os.environ["NOTARY_APPLE_ID"],
        "--team-id", team, "--password", os.environ["NOTARY_APP_PASSWORD"])
    with Path(os.environ["GITHUB_ENV"]).open("a") as output:
        for key, value in {"UNSIT_SIGN_IDENTITY": matches[0], "UNSIT_SIGN_KEYCHAIN": str(keychain),
                           "UNSIT_NOTARY_PROFILE": profile}.items():
            output.write(key + "=" + value + "\n")
    print("Developer ID and notarization credentials are ready in the temporary keychain")


if __name__ == "__main__":
    main()
