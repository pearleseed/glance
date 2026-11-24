#!/usr/bin/env python3
"""Offline unit and cryptographic signing tests for `tools/generate_appcast.py`."""

from __future__ import annotations

import base64
import os
import plistlib
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path
from unittest import mock

import generate_appcast as ga

SPARKLE = f"{{{ga.SPARKLE_NS}}}"
UPSTREAM_OLD_PUBKEY = "o9uQmlzKzh7NZvFtVktVh/wqw4Ie6WshX8K8NFDweWY="


class GenerateAppcastTests(unittest.TestCase):
    def test_repo_info_plist_migrated_to_pearleseed_and_valid_ed25519_key(self) -> None:
        repo_root = Path(__file__).resolve().parent.parent
        info_plist = repo_root / "glance" / "Info.plist"
        with info_plist.open("rb") as f:
            plist = plistlib.load(f)

        self.assertEqual(
            plist.get("SUFeedURL"),
            "https://github.com/pearleseed/glance/releases/latest/download/appcast.xml",
        )
        pub_key = plist.get("SUPublicEDKey", "")
        self.assertNotEqual(pub_key, UPSTREAM_OLD_PUBKEY)
        raw_key = base64.b64decode(pub_key, validate=True)
        self.assertEqual(len(raw_key), 32, "Ed25519 public key must decode to 32 bytes")

    def test_arm64_is_always_ordered_before_x86_64_and_has_hardware_requirement(self) -> None:
        # Intentionally pass x86_64 first to ensure canonical ordering is enforced.
        archives = [
            ga.SignedArchive(
                arch="x86_64",
                path=Path("Glance-2.1.1-x86_64.dmg"),
                download_url=ga.build_download_url(
                    "pearleseed/glance", "v2.1.1", "Glance-2.1.1-x86_64.dmg"
                ),
                length=42720433,
                ed_signature="SIG_X86_64",
                hardware_requirements=None,
            ),
            ga.SignedArchive(
                arch="arm64",
                path=Path("Glance-2.1.1-arm64.dmg"),
                download_url=ga.build_download_url(
                    "pearleseed/glance", "v2.1.1", "Glance-2.1.1-arm64.dmg"
                ),
                length=43328771,
                ed_signature="SIG_ARM64",
                hardware_requirements="arm64",
            ),
        ]

        xml_text = ga.build_appcast_xml(
            version="2.1.1",
            build="7",
            repo="pearleseed/glance",
            tag="v2.1.1",
            archives=archives,
            pub_date="Tue, 24 Nov 2026 08:30:00 +0000",
        )

        # Ensure zero upstream references leak into the generated feed.
        self.assertNotIn("jonnyoo", xml_text.lower())
        self.assertNotIn("tryglance", xml_text.lower())
        self.assertNotIn(UPSTREAM_OLD_PUBKEY, xml_text)

        root = ET.fromstring(xml_text)
        self.assertEqual(root.tag, "rss")
        self.assertEqual(root.attrib["version"], "2.0")

        channel = root.find("channel")
        self.assertIsNotNone(channel)
        assert channel is not None
        self.assertEqual(channel.findtext("link"), "https://github.com/pearleseed/glance")

        items = channel.findall("item")
        self.assertEqual(len(items), 2)

        # First item MUST be arm64 with hardwareRequirements=arm64.
        first_item, second_item = items
        self.assertEqual(first_item.findtext(f"{SPARKLE}hardwareRequirements"), "arm64")
        self.assertEqual(first_item.findtext(f"{SPARKLE}version"), "7")
        self.assertEqual(first_item.findtext(f"{SPARKLE}shortVersionString"), "2.1.1")
        self.assertEqual(first_item.findtext(f"{SPARKLE}minimumSystemVersion"), "14.0")
        self.assertEqual(
            first_item.findtext("link"),
            "https://github.com/pearleseed/glance/releases/tag/v2.1.1",
        )
        self.assertEqual(
            first_item.findtext(f"{SPARKLE}informationalUpdate/{SPARKLE}belowVersion"),
            "7",
        )
        first_enc = first_item.find("enclosure")
        assert first_enc is not None
        self.assertTrue(first_enc.attrib["url"].endswith("/Glance-2.1.1-arm64.dmg"))
        self.assertEqual(first_enc.attrib["length"], "43328771")
        self.assertEqual(first_enc.attrib[f"{SPARKLE}edSignature"], "SIG_ARM64")

        # Second item MUST be x86_64 with NO hardwareRequirements so Intel Macs pick it.
        self.assertIsNone(second_item.find(f"{SPARKLE}hardwareRequirements"))
        second_enc = second_item.find("enclosure")
        assert second_enc is not None
        self.assertTrue(second_enc.attrib["url"].endswith("/Glance-2.1.1-x86_64.dmg"))
        self.assertEqual(second_enc.attrib["length"], "42720433")
        self.assertEqual(second_enc.attrib[f"{SPARKLE}edSignature"], "SIG_X86_64")

    def test_key_migration_below_version_can_be_disabled(self) -> None:
        archives = [
            ga.SignedArchive(
                arch="arm64",
                path=Path("Glance-2.2.0-arm64.dmg"),
                download_url=ga.build_download_url(
                    "pearleseed/glance", "v2.2.0", "Glance-2.2.0-arm64.dmg"
                ),
                length=1234,
                ed_signature="SIG",
                hardware_requirements="arm64",
            )
        ]
        xml_text = ga.build_appcast_xml(
            version="2.2.0",
            build="8",
            repo="pearleseed/glance",
            tag="v2.2.0",
            archives=archives,
            key_migration_build=None,
        )
        root = ET.fromstring(xml_text)
        item = root.find("channel/item")
        assert item is not None
        self.assertIsNone(item.find(f"{SPARKLE}informationalUpdate"))

    def test_verify_keychain_public_key_matches_and_rejects_mismatch(self) -> None:
        expected_key = base64.b64encode(b"\x11" * 32).decode()
        with tempfile.TemporaryDirectory() as tmp:
            good_plist = Path(tmp) / "GoodInfo.plist"
            bad_plist = Path(tmp) / "BadInfo.plist"
            with good_plist.open("wb") as f:
                plistlib.dump({"SUPublicEDKey": expected_key}, f)
            with bad_plist.open("wb") as f:
                plistlib.dump({"SUPublicEDKey": UPSTREAM_OLD_PUBKEY}, f)

            fake_proc = subprocess.CompletedProcess(
                args=["generate_keys"], returncode=0, stdout=expected_key + "\n", stderr=""
            )
            with mock.patch.object(ga.subprocess, "run", return_value=fake_proc):
                matched = ga.verify_keychain_public_key_matches_plist(
                    generate_keys_bin=Path("/usr/bin/true"),
                    account=ga.DEFAULT_SPARKLE_ACCOUNT,
                    info_plist_path=good_plist,
                )
                self.assertEqual(matched, expected_key)

                with self.assertRaises(ValueError):
                    ga.verify_keychain_public_key_matches_plist(
                        generate_keys_bin=Path("/usr/bin/true"),
                        account=ga.DEFAULT_SPARKLE_ACCOUNT,
                        info_plist_path=bad_plist,
                    )

    def test_end_to_end_signing_and_tamper_detection_with_ephemeral_key(self) -> None:
        sign_update_bin = ga.find_sparkle_tool("sign_update")

        with tempfile.TemporaryDirectory() as tmp:
            tmp_dir = Path(tmp)
            ephemeral_key = tmp_dir / "ephemeral.key"
            ephemeral_key.write_text(
                base64.b64encode(os.urandom(32)).decode("ascii"), encoding="ascii"
            )
            arm_dmg = tmp_dir / "Glance-2.1.1-arm64.dmg"
            x86_dmg = tmp_dir / "Glance-2.1.1-x86_64.dmg"
            out_xml = tmp_dir / "appcast.xml"

            arm_dmg.write_bytes(b"fake-arm64-dmg-payload-v2.1.1")
            x86_dmg.write_bytes(b"fake-x86_64-dmg-payload-v2.1.1")

            exit_code = ga.main(
                [
                    "--version",
                    "2.1.1",
                    "--build",
                    "7",
                    "--arm64-dmg",
                    str(arm_dmg),
                    "--x86-64-dmg",
                    str(x86_dmg),
                    "--output",
                    str(out_xml),
                    "--ed-key-file",
                    str(ephemeral_key),
                    "--sign-update",
                    str(sign_update_bin),
                ]
            )
            self.assertEqual(exit_code, 0)
            self.assertTrue(out_xml.is_file())

            root = ET.fromstring(out_xml.read_text(encoding="utf-8"))
            items = root.findall("channel/item")
            self.assertEqual(len(items), 2)

            arm_sig = items[0].find("enclosure").attrib[f"{SPARKLE}edSignature"]  # type: ignore[union-attr]
            x86_sig = items[1].find("enclosure").attrib[f"{SPARKLE}edSignature"]  # type: ignore[union-attr]
            self.assertNotEqual(arm_sig, x86_sig)

            # Both signatures verify against the ephemeral key.
            for dmg, sig in [(arm_dmg, arm_sig), (x86_dmg, x86_sig)]:
                verify = subprocess.run(
                    [
                        str(sign_update_bin),
                        "--verify",
                        "--ed-key-file",
                        str(ephemeral_key),
                        str(dmg),
                        sig,
                    ],
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(verify.returncode, 0, msg=verify.stderr)

            # Tampering with 1 byte MUST cause verification to fail.
            arm_dmg.write_bytes(b"fake-arm64-dmg-payload-v2.1.2")
            tampered = subprocess.run(
                [
                    str(sign_update_bin),
                    "--verify",
                    "--ed-key-file",
                    str(ephemeral_key),
                    str(arm_dmg),
                    arm_sig,
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(tampered.returncode, 0)


if __name__ == "__main__":
    unittest.main()
