#!/usr/bin/env python3
"""Generate and verify a Sparkle 2 appcast.xml for Glance dual-arch GitHub Releases.

Signs both Apple Silicon (arm64) and Intel (x86_64) DMGs with Sparkle's EdDSA
`sign_update` tool, cross-checks the Keychain public key against `glance/Info.plist`
to prevent key mismatch mistakes, and emits a single Sparkle 2 appcast feed where:

- The `arm64` item is listed first with `<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>`,
  so Apple Silicon Macs select the native arm64 DMG while Intel Macs filter it out
  and select the `x86_64` DMG listed second.
- Builds older than `--key-migration-build` (default: 7, the first build carrying
  `pearleseed/glance`'s own EdDSA key) receive an informational update linking to
  the GitHub Release page instead of failing EdDSA signature verification.
"""

from __future__ import annotations

import argparse
import email.utils
import os
import plistlib
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Sequence

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DC_NS = "http://purl.org/dc/elements/1.1/"

DEFAULT_REPO = "pearleseed/glance"
DEFAULT_SPARKLE_ACCOUNT = "com.pearleseed.glance"
DEFAULT_MIN_SYSTEM_VERSION = "14.0"
DEFAULT_KEY_MIGRATION_BUILD = 7


@dataclass(frozen=True)
class SignedArchive:
    arch: str
    path: Path
    download_url: str
    length: int
    ed_signature: str
    hardware_requirements: str | None = None


def find_sparkle_tool(tool_name: str, explicit_path: str | None = None) -> Path:
    """Locate a Sparkle CLI binary (e.g. `sign_update`, `generate_keys`)."""
    candidates: list[Path] = []

    if explicit_path:
        p = Path(explicit_path).expanduser()
        if p.is_dir():
            p = p / tool_name
        if p.is_file() and os.access(p, os.X_OK):
            return p
        raise FileNotFoundError(f"Sparkle tool not found or not executable: {p}")

    env_bin = os.environ.get("SPARKLE_BIN")
    if env_bin:
        p = Path(env_bin).expanduser() / tool_name
        if p.is_file() and os.access(p, os.X_OK):
            return p

    on_path = shutil.which(tool_name)
    if on_path:
        return Path(on_path)

    # Search workspace build SourcePackages/DerivedData first, then Xcode's global DerivedData.
    rel_tool = Path("artifacts/sparkle/Sparkle/bin") / tool_name
    source_pkg_dirs = [
        Path.cwd() / "build" / "SourcePackages",
        Path.cwd() / "build" / "DerivedData" / "SourcePackages",
    ]
    global_dd = Path.home() / "Library" / "Developer" / "Xcode" / "DerivedData"
    if global_dd.is_dir():
        source_pkg_dirs.extend(
            p / "SourcePackages" for p in global_dd.iterdir() if p.is_dir() and p.name.startswith("glance-")
        )
        source_pkg_dirs.extend(
            p / "SourcePackages" for p in global_dd.iterdir() if p.is_dir() and not p.name.startswith("glance-")
        )

    for sp_dir in source_pkg_dirs:
        match = sp_dir / rel_tool
        if match.is_file() and os.access(match, os.X_OK):
            candidates.append(match)

    if not candidates:
        raise FileNotFoundError(
            f"Could not locate Sparkle `{tool_name}` binary. Build the project once in Xcode "
            f"(to resolve the Sparkle SwiftPM package) or pass --sign-update / set SPARKLE_BIN."
        )

    candidates.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    return candidates[0]


def verify_keychain_public_key_matches_plist(
    generate_keys_bin: Path,
    account: str,
    info_plist_path: Path,
) -> str:
    """Ensure the Keychain EdDSA public key matches `SUPublicEDKey` in Info.plist."""
    with info_plist_path.open("rb") as f:
        plist = plistlib.load(f)

    plist_pub_key = (plist.get("SUPublicEDKey") or "").strip()
    if not plist_pub_key:
        raise ValueError(f"SUPublicEDKey is missing or empty in {info_plist_path}")

    proc = subprocess.run(
        [str(generate_keys_bin), "--account", account, "-p"],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout).strip()
        raise RuntimeError(
            f"Failed to read Sparkle public key from Keychain for account `{account}`: {detail}"
        )

    keychain_pub_key = proc.stdout.strip().splitlines()[-1].strip()
    if keychain_pub_key != plist_pub_key:
        raise ValueError(
            f"Sparkle public key mismatch!\n"
            f"  Info.plist ({info_plist_path}): {plist_pub_key}\n"
            f"  Keychain (--account {account}): {keychain_pub_key}\n"
            f"Update SUPublicEDKey in Info.plist or pass the matching --account / --ed-key-file."
        )
    return plist_pub_key


def sign_archive(
    dmg_path: Path,
    sign_update_bin: Path,
    account: str,
    ed_key_file: str | None = None,
    ed_key_stdin: str | None = None,
) -> str:
    """Sign a DMG with Sparkle's `sign_update` and verify the resulting EdDSA signature."""
    if not dmg_path.is_file():
        raise FileNotFoundError(f"Archive not found: {dmg_path}")

    cmd = [str(sign_update_bin), "-p"]
    if ed_key_file:
        cmd.extend(["--ed-key-file", ed_key_file])
    else:
        cmd.extend(["--account", account])
    cmd.append(str(dmg_path))

    proc = subprocess.run(
        cmd,
        input=ed_key_stdin,
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout).strip()
        raise RuntimeError(f"sign_update failed for {dmg_path.name}: {detail}")

    signature = proc.stdout.strip().splitlines()[-1].strip()
    if not signature:
        raise RuntimeError(f"sign_update produced empty signature for {dmg_path.name}")

    # Cryptographically verify the generated signature immediately.
    verify_cmd = [str(sign_update_bin), "--verify"]
    if ed_key_file:
        verify_cmd.extend(["--ed-key-file", ed_key_file])
    else:
        verify_cmd.extend(["--account", account])
    verify_cmd.extend([str(dmg_path), signature])

    verify_proc = subprocess.run(
        verify_cmd,
        input=ed_key_stdin,
        capture_output=True,
        text=True,
        check=False,
    )
    if verify_proc.returncode != 0:
        detail = (verify_proc.stderr or verify_proc.stdout).strip()
        raise RuntimeError(f"sign_update --verify failed for {dmg_path.name}: {detail}")

    return signature


def build_appcast_xml(
    *,
    version: str,
    build: str,
    repo: str,
    tag: str,
    archives: Sequence[SignedArchive],
    min_system_version: str = DEFAULT_MIN_SYSTEM_VERSION,
    key_migration_build: int | None = DEFAULT_KEY_MIGRATION_BUILD,
    pub_date: str | None = None,
    release_notes_html: str | None = None,
) -> str:
    """Build a Sparkle 2 appcast XML document.

    IMPORTANT: When both `arm64` and `x86_64` archives share the same `build`,
    the `arm64` archive (with `hardware_requirements="arm64"`) MUST appear before
    the `x86_64` archive so Sparkle's `bestItemFromAppcastItems:` picks the native
    Apple Silicon build on arm64 Macs while Intel Macs filter it out and pick x86_64.
    """
    if not archives:
        raise ValueError("At least one signed archive is required to build appcast.xml")

    # Enforce canonical ordering: arm64-only items first, unrestricted/x86_64 items after.
    ordered_archives = sorted(
        archives,
        key=lambda a: (0 if a.hardware_requirements == "arm64" else 1, a.arch),
    )

    pub_date_str = pub_date or email.utils.format_datetime(datetime.now(timezone.utc))
    repo_url = f"https://github.com/{repo}"
    release_url = f"{repo_url}/releases/tag/{tag}"

    ET.register_namespace("sparkle", SPARKLE_NS)

    rss = ET.Element("rss", {"version": "2.0"})

    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Glance Updates"
    ET.SubElement(channel, "link").text = repo_url
    ET.SubElement(channel, "description").text = "Most recent changes with links to updates."
    ET.SubElement(channel, "language").text = "en"

    for archive in ordered_archives:
        item = ET.SubElement(channel, "item")
        ET.SubElement(item, "title").text = version
        ET.SubElement(item, "pubDate").text = pub_date_str
        ET.SubElement(item, "link").text = release_url
        ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = str(build)
        ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString").text = version
        ET.SubElement(item, f"{{{SPARKLE_NS}}}minimumSystemVersion").text = min_system_version
        if archive.hardware_requirements:
            ET.SubElement(
                item, f"{{{SPARKLE_NS}}}hardwareRequirements"
            ).text = archive.hardware_requirements
        ET.SubElement(item, f"{{{SPARKLE_NS}}}fullReleaseNotesLink").text = release_url

        if key_migration_build is not None and key_migration_build > 0:
            info_update = ET.SubElement(item, f"{{{SPARKLE_NS}}}informationalUpdate")
            ET.SubElement(info_update, f"{{{SPARKLE_NS}}}belowVersion").text = str(
                key_migration_build
            )

        if release_notes_html:
            ET.SubElement(item, "description").text = release_notes_html

        ET.SubElement(
            item,
            "enclosure",
            {
                "url": archive.download_url,
                "length": str(archive.length),
                "type": "application/octet-stream",
                f"{{{SPARKLE_NS}}}edSignature": archive.ed_signature,
            },
        )

    ET.indent(rss, space="  ")
    xml_bytes = ET.tostring(rss, encoding="utf-8", xml_declaration=True)
    return xml_bytes.decode("utf-8") + "\n"


def build_download_url(repo: str, tag: str, filename: str) -> str:
    return f"https://github.com/{repo}/releases/download/{tag}/{filename}"


def parse_args(argv: Iterable[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Sign Glance release DMGs and generate a Sparkle 2 appcast.xml."
    )
    parser.add_argument("--version", required=True, help="Marketing version (e.g. 2.1.1)")
    parser.add_argument("--build", required=True, help="CFBundleVersion build number (e.g. 7)")
    parser.add_argument("--arm64-dmg", required=True, type=Path, help="Path to arm64 DMG")
    parser.add_argument("--x86-64-dmg", required=True, type=Path, help="Path to x86_64 DMG")
    parser.add_argument("--output", required=True, type=Path, help="Output path for appcast.xml")
    parser.add_argument("--repo", default=DEFAULT_REPO, help=f"GitHub repo (default: {DEFAULT_REPO})")
    parser.add_argument("--tag", default=None, help="GitHub Release tag (default: v<version>)")
    parser.add_argument(
        "--min-system-version",
        default=DEFAULT_MIN_SYSTEM_VERSION,
        help=f"Minimum macOS version (default: {DEFAULT_MIN_SYSTEM_VERSION})",
    )
    parser.add_argument(
        "--key-migration-build",
        type=int,
        default=DEFAULT_KEY_MIGRATION_BUILD,
        help=(
            "Builds strictly below this build number get an informational update linking to "
            "GitHub Releases (default: 7; pass 0 to disable)."
        ),
    )
    parser.add_argument(
        "--account",
        default=DEFAULT_SPARKLE_ACCOUNT,
        help=f"Keychain account for Sparkle EdDSA key (default: {DEFAULT_SPARKLE_ACCOUNT})",
    )
    parser.add_argument(
        "--ed-key-file",
        default=None,
        help="Optional EdDSA private key file path (or '-' for stdin, useful in CI).",
    )
    parser.add_argument(
        "--sign-update",
        default=None,
        help="Explicit path to Sparkle's sign_update binary (or its parent bin directory).",
    )
    parser.add_argument(
        "--info-plist",
        type=Path,
        default=Path("glance/Info.plist"),
        help="Path to Info.plist for SUPublicEDKey verification (default: glance/Info.plist).",
    )
    parser.add_argument(
        "--skip-plist-check",
        action="store_true",
        help="Skip verifying Keychain public key against Info.plist.",
    )
    parser.add_argument(
        "--release-notes",
        default=None,
        help="Optional inline release notes HTML string (or @path/to/notes.html).",
    )
    parser.add_argument("--pub-date", default=None, help="Optional RFC 2822 pubDate override.")
    return parser.parse_args(list(argv) if argv is not None else None)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    tag = args.tag or f"v{args.version}"

    sign_update_bin = find_sparkle_tool("sign_update", args.sign_update)

    ed_key_stdin: str | None = None
    if args.ed_key_file == "-":
        ed_key_stdin = sys.stdin.read()
    elif not args.ed_key_file and not args.skip_plist_check and args.info_plist.is_file():
        generate_keys_bin = find_sparkle_tool("generate_keys", str(sign_update_bin.parent))
        verify_keychain_public_key_matches_plist(
            generate_keys_bin=generate_keys_bin,
            account=args.account,
            info_plist_path=args.info_plist,
        )

    release_notes_html: str | None = None
    if args.release_notes:
        if args.release_notes.startswith("@"):
            release_notes_html = Path(args.release_notes[1:]).read_text(encoding="utf-8")
        else:
            release_notes_html = args.release_notes

    archives: list[SignedArchive] = []
    for arch, dmg_path, hw_req in [
        ("arm64", args.arm64_dmg, "arm64"),
        ("x86_64", args.x86_64_dmg, None),
    ]:
        sig = sign_archive(
            dmg_path=dmg_path,
            sign_update_bin=sign_update_bin,
            account=args.account,
            ed_key_file=args.ed_key_file,
            ed_key_stdin=ed_key_stdin,
        )
        archives.append(
            SignedArchive(
                arch=arch,
                path=dmg_path,
                download_url=build_download_url(args.repo, tag, dmg_path.name),
                length=dmg_path.stat().st_size,
                ed_signature=sig,
                hardware_requirements=hw_req,
            )
        )

    xml_text = build_appcast_xml(
        version=args.version,
        build=args.build,
        repo=args.repo,
        tag=tag,
        archives=archives,
        min_system_version=args.min_system_version,
        key_migration_build=args.key_migration_build if args.key_migration_build > 0 else None,
        pub_date=args.pub_date,
        release_notes_html=release_notes_html,
    )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(xml_text, encoding="utf-8")
    print(f"Generated verified Sparkle appcast: {args.output}")
    for archive in archives:
        print(f"  - {archive.arch}: {archive.path.name} ({archive.length} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
