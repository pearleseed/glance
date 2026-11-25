#!/usr/bin/env python3
"""Offline unit tests for staged Core ML conversion and atomic promotion."""

from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

import convert_arcface as ca


def _write_package(package_dir: Path, sentinel_value: str) -> None:
    package_dir.mkdir(parents=True, exist_ok=True)
    (package_dir / "sentinel.txt").write_text(sentinel_value, encoding="utf-8")


def _assert_clean_output_dir(test: unittest.TestCase, output_dir: Path, expected_name: str) -> None:
    entries = sorted(p.name for p in output_dir.iterdir())
    test.assertEqual(entries, [expected_name])


class ConvertArcfacePublicationTests(unittest.TestCase):
    def test_verification_failure_preserves_existing_package(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_dir = Path(tmp)
            onnx_path = tmp_dir / "w600k_r50.onnx"
            onnx_path.write_bytes(b"fake-onnx")
            output_dir = tmp_dir / "models"
            output_path = output_dir / "ArcFace.mlpackage"
            _write_package(output_path, "old")

            def stub_converter(src_onnx: Path, staging_path: Path, *, variant: str, quantize: str) -> Path:
                self.assertEqual(src_onnx, onnx_path)
                _write_package(staging_path, "new")
                return staging_path

            def failing_verifier(package_path: Path, src_onnx: Path, *, min_cosine: float = 0.999) -> float:
                self.assertTrue((package_path / "sentinel.txt").is_file())
                raise ca.ConversionError("parity failed")

            with self.assertRaises(ca.ConversionError):
                ca.build_and_publish(
                    onnx_path,
                    output_path,
                    variant="w600k_r50",
                    quantize="int8",
                    skip_verify=False,
                    converter=stub_converter,
                    verifier=failing_verifier,
                )

            self.assertEqual((output_path / "sentinel.txt").read_text(encoding="utf-8"), "old")
            _assert_clean_output_dir(self, output_dir, "ArcFace.mlpackage")

    def test_promotion_failure_restores_existing_package(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_dir = Path(tmp)
            onnx_path = tmp_dir / "w600k_r50.onnx"
            onnx_path.write_bytes(b"fake-onnx")
            output_dir = tmp_dir / "models"
            output_path = output_dir / "ArcFace.mlpackage"
            _write_package(output_path, "old")

            def stub_converter(src_onnx: Path, staging_path: Path, *, variant: str, quantize: str) -> Path:
                _write_package(staging_path, "new")
                return staging_path

            def passing_verifier(package_path: Path, src_onnx: Path, *, min_cosine: float = 0.999) -> float:
                return 0.9999

            def flaky_rename(src: Path, dst: Path) -> None:
                src_path = Path(src)
                dst_path = Path(dst)
                if dst_path == output_path and "staging-" in src_path.name:
                    raise OSError("simulated promotion failure")
                os.rename(src, dst)

            with self.assertRaises(OSError):
                ca.build_and_publish(
                    onnx_path,
                    output_path,
                    variant="w600k_r50",
                    quantize="int8",
                    skip_verify=False,
                    converter=stub_converter,
                    verifier=passing_verifier,
                    promoter=lambda cand, dest: ca.promote_package(cand, dest, rename_fn=flaky_rename),
                )

            self.assertEqual((output_path / "sentinel.txt").read_text(encoding="utf-8"), "old")
            _assert_clean_output_dir(self, output_dir, "ArcFace.mlpackage")

    def test_successful_run_publishes_verified_package(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_dir = Path(tmp)
            onnx_path = tmp_dir / "w600k_r50.onnx"
            onnx_path.write_bytes(b"fake-onnx")
            output_dir = tmp_dir / "models"
            output_path = output_dir / "ArcFace.mlpackage"
            _write_package(output_path, "old")

            recorded: dict[str, Path] = {}

            def stub_converter(src_onnx: Path, staging_path: Path, *, variant: str, quantize: str) -> Path:
                recorded["staging"] = staging_path
                _write_package(staging_path, "verified-v2")
                return staging_path

            def checking_verifier(package_path: Path, src_onnx: Path, *, min_cosine: float = 0.999) -> float:
                self.assertEqual(package_path, recorded["staging"])
                self.assertNotEqual(package_path, output_path)
                self.assertEqual(src_onnx, onnx_path)
                self.assertEqual(min_cosine, 0.995)
                self.assertEqual((package_path / "sentinel.txt").read_text(encoding="utf-8"), "verified-v2")
                recorded["verified"] = package_path
                return 0.9998

            published = ca.build_and_publish(
                onnx_path,
                output_path,
                variant="w600k_r50",
                quantize="int8",
                skip_verify=False,
                converter=stub_converter,
                verifier=checking_verifier,
            )

            self.assertEqual(published, output_path)
            self.assertEqual(recorded.get("verified"), recorded.get("staging"))
            self.assertEqual((output_path / "sentinel.txt").read_text(encoding="utf-8"), "verified-v2")
            _assert_clean_output_dir(self, output_dir, "ArcFace.mlpackage")

    def test_skip_verify_promotes_without_calling_verifier(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_dir = Path(tmp)
            onnx_path = tmp_dir / "w600k_r50.onnx"
            onnx_path.write_bytes(b"fake-onnx")
            output_dir = tmp_dir / "models"
            output_path = output_dir / "ArcFace.mlpackage"
            _write_package(output_path, "old")

            verifier_calls = 0

            def stub_converter(src_onnx: Path, staging_path: Path, *, variant: str, quantize: str) -> Path:
                _write_package(staging_path, "skipped-verify")
                return staging_path

            def unexpected_verifier(package_path: Path, src_onnx: Path, *, min_cosine: float = 0.999) -> float:
                nonlocal verifier_calls
                verifier_calls += 1
                return 1.0

            ca.build_and_publish(
                onnx_path,
                output_path,
                variant="w600k_r50",
                quantize="none",
                skip_verify=True,
                converter=stub_converter,
                verifier=unexpected_verifier,
            )

            self.assertEqual(verifier_calls, 0)
            self.assertEqual((output_path / "sentinel.txt").read_text(encoding="utf-8"), "skipped-verify")
            _assert_clean_output_dir(self, output_dir, "ArcFace.mlpackage")

    def test_fresh_publish_when_destination_does_not_exist(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_dir = Path(tmp)
            onnx_path = tmp_dir / "w600k_r50.onnx"
            onnx_path.write_bytes(b"fake-onnx")
            output_dir = tmp_dir / "nested" / "models"
            output_path = output_dir / "ArcFace.mlpackage"

            def stub_converter(src_onnx: Path, staging_path: Path, *, variant: str, quantize: str) -> Path:
                _write_package(staging_path, "fresh-v1")
                return staging_path

            def passing_verifier(package_path: Path, src_onnx: Path, *, min_cosine: float = 0.999) -> float:
                self.assertEqual(min_cosine, 0.999)
                return 0.9999

            ca.build_and_publish(
                onnx_path,
                output_path,
                variant="w600k_r50",
                quantize="none",
                skip_verify=False,
                converter=stub_converter,
                verifier=passing_verifier,
            )

            self.assertEqual((output_path / "sentinel.txt").read_text(encoding="utf-8"), "fresh-v1")
            _assert_clean_output_dir(self, output_dir, "ArcFace.mlpackage")


if __name__ == "__main__":
    unittest.main()
