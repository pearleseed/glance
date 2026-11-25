#!/usr/bin/env python3
"""
Converts InsightFace's ArcFace recognition model (`w600k_r50` ResNet50 or `w600k_mbf`
MobileFaceNet backbone trained with ArcFace loss) into a Core ML `.mlpackage`
that Glance's Swift code can load directly.

Pipeline: ONNX (InsightFace's official weights) -> torch (via onnx2torch)
-> traced TorchScript -> Core ML FP16 MLProgram (+ optional W8A16 weight
quantization), with preprocessing baked into the model so Swift only ever hands
over a raw RGB 112x112 image.

Usage:
    python3 -m venv .venv && source .venv/bin/activate
    pip install -r tools/requirements.txt
    python tools/convert_arcface.py --variant w600k_r50 --quantize int8

Output:
    glance/Models/ArcFace.mlpackage
        input:  "input_image", 112x112 RGB CVPixelBuffer/CGImage
        output: "embedding", 512 floats (NOT yet L2-normalized — Swift does that)

This script does not modify the Xcode project or any Swift source. It only
produces the model file; wiring it in is a separate, reviewable step.
"""

from __future__ import annotations

import argparse
import os
import shutil
import sys
from pathlib import Path
from typing import Callable
from uuid import uuid4

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = REPO_ROOT / "glance" / "Models" / "ArcFace.mlpackage"

VARIANT_ONNX_NAMES = {
    "w600k_mbf": "w600k_mbf.onnx",   # buffalo_s pack, ~13MB, MobileFaceNet backbone
    "w600k_r50": "w600k_r50.onnx",   # buffalo_l pack, ~166MB, ResNet50 backbone
}
VARIANT_PACK = {
    "w600k_mbf": "buffalo_s",
    "w600k_r50": "buffalo_l",
}


def fail(message: str) -> None:
    print(f"\nERROR: {message}\n", file=sys.stderr)
    sys.exit(1)


def locate_or_download_onnx(variant: str, explicit_path: str | None) -> Path:
    """Returns a local path to the recognition-model .onnx file.

    Prefers an explicit --onnx-path if given (for when auto-download fails
    or the user already has the weights). Otherwise downloads the official
    InsightFace model pack via the `insightface` package's own model zoo,
    which is the actively-maintained source for these weights — more
    resilient than us hardcoding a URL that could move.
    """
    if explicit_path:
        path = Path(explicit_path).expanduser().resolve()
        if not path.is_file():
            fail(f"--onnx-path does not exist: {path}")
        return path

    try:
        from insightface.app import FaceAnalysis
    except ImportError:
        onnx_name = VARIANT_ONNX_NAMES[variant]
        fail(
            "The 'insightface' package is required to auto-download weights.\n"
            "Install it with: pip install insightface onnxruntime opencv-python\n"
            f"Or download {onnx_name} yourself and pass --onnx-path."
        )

    pack_name = VARIANT_PACK[variant]
    print(f"Downloading InsightFace '{pack_name}' model pack (first run only)...")
    # .prepare() triggers the download+unzip into ~/.insightface/models/<pack>/
    # and validates every model in the pack loads correctly.
    app = FaceAnalysis(name=pack_name, providers=["CPUExecutionProvider"])
    app.prepare(ctx_id=-1)

    model_dir = Path.home() / ".insightface" / "models" / pack_name
    onnx_name = VARIANT_ONNX_NAMES[variant]
    matches = list(model_dir.glob(f"*{onnx_name}"))
    if not matches:
        fail(
            f"Downloaded pack '{pack_name}' but couldn't find {onnx_name} in {model_dir}. "
            f"Contents: {list(model_dir.iterdir()) if model_dir.exists() else 'directory missing'}"
        )
    return matches[0]


class ConversionError(RuntimeError):
    """Raised when Core ML conversion or parity verification fails."""


def _remove_path(path: Path) -> None:
    if not os.path.lexists(path):
        return
    if path.is_symlink() or not path.is_dir():
        path.unlink(missing_ok=True)
    else:
        shutil.rmtree(path)


def convert_to_coreml(onnx_path: Path, output_path: Path, *, variant: str, quantize: str) -> Path:
    import coremltools as ct
    from onnx2torch import convert
    import onnx
    import torch

    print(f"Loading ONNX model from {onnx_path} ({onnx_path.stat().st_size / 1e6:.1f} MB)...")
    onnx_model = onnx.load(str(onnx_path))
    onnx.checker.check_model(onnx_model)

    print("Converting ONNX -> torch (via onnx2torch)...")
    torch_model = convert(onnx_model)
    torch_model.eval()

    dummy_input = torch.randn(1, 3, 112, 112)
    with torch.no_grad():
        traced = torch.jit.trace(torch_model, dummy_input)

    print("Converting torch -> Core ML FP16 (preprocessing baked in: RGB, (px-127.5)/127.5)...")
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.ImageType(
                name="input_image",
                shape=(1, 3, 112, 112),
                scale=1.0 / 127.5,
                bias=[-1.0, -1.0, -1.0],
                color_layout=ct.colorlayout.RGB,
            )
        ],
        outputs=[ct.TensorType(name="embedding")],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.ALL,
    )

    if quantize == "int8":
        import coremltools.optimize.coreml as cto

        print("Applying W8A16 weight quantization (linear_symmetric, int8, per_channel)...")
        quant_config = cto.OptimizationConfig(
            global_config=cto.OpLinearQuantizerConfig(
                mode="linear_symmetric",
                dtype="int8",
                granularity="per_channel",
            )
        )
        mlmodel = cto.linear_quantize_weights(mlmodel, config=quant_config)

    precision_label = "W8A16" if quantize == "int8" else "FP16"
    mlmodel.short_description = (
        f"ArcFace ({variant}, {precision_label}) face embedding — 512-d, on-device"
    )
    mlmodel.input_description["input_image"] = "112x112 RGB aligned face crop"
    mlmodel.output_description["embedding"] = "512-float embedding (not L2-normalized)"

    output_path.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(output_path))
    print(f"Saved {output_path}")
    return output_path


def verify_parity(package_path: Path, onnx_path: Path, *, min_cosine: float = 0.999) -> float:
    """The real correctness check: reload the saved Core ML package from disk,
    feed identical random pixels through both the original ONNX graph and the
    reloaded Core ML model, and confirm they agree. Shape-only checks would miss
    a channel-order or scale bug — exactly the kind of mistake that silently
    wrecks ArcFace accuracy without ever throwing an error.
    """
    import coremltools as ct
    import numpy as np
    import onnxruntime as ort
    from PIL import Image

    print(f"\nVerifying ONNX <-> Core ML numerical parity on saved package {package_path}...")
    try:
        mlmodel = ct.models.MLModel(str(package_path))
    except Exception as exc:
        raise ConversionError(f"Failed to load saved Core ML package {package_path}: {exc}") from exc

    rng = np.random.default_rng(0)
    pixels = rng.integers(0, 256, size=(112, 112, 3), dtype=np.uint8)

    sess = ort.InferenceSession(str(onnx_path), providers=["CPUExecutionProvider"])
    onnx_input_name = sess.get_inputs()[0].name
    chw = pixels.astype(np.float32).transpose(2, 0, 1)[None]
    normalized = (chw - 127.5) / 127.5
    onnx_out = sess.run(None, {onnx_input_name: normalized})[0].flatten()

    pil_image = Image.fromarray(pixels, mode="RGB")
    prediction = mlmodel.predict({"input_image": pil_image})
    coreml_out = np.array(prediction["embedding"]).flatten()

    if onnx_out.shape != (512,) or coreml_out.shape != (512,):
        raise ConversionError(
            f"Unexpected output shape: onnx={onnx_out.shape}, coreml={coreml_out.shape} (expected (512,))"
        )

    norm_product = float(np.linalg.norm(onnx_out) * np.linalg.norm(coreml_out))
    if norm_product == 0.0:
        raise ConversionError("Parity check failed — model produced a zero-norm embedding.")

    cosine = float(np.dot(onnx_out, coreml_out) / norm_product)
    print(f"ONNX vs Core ML cosine similarity: {cosine:.6f}  (expect >= {min_cosine:.3f})")
    if not (cosine >= min_cosine):
        raise ConversionError(
            "Parity check failed — the converted model disagrees with the original. "
            "Most likely cause: preprocessing mismatch (channel order RGB vs BGR, or "
            "scale/bias). Do not use this model until this passes."
        )
    print("Parity check passed. The conversion is numerically correct.")
    return cosine


def promote_package(
    candidate_path: Path,
    destination_path: Path,
    *,
    rename_fn: Callable[[Path, Path], object] = os.rename,
) -> None:
    """Atomically promote a verified staging package to destination_path with rollback."""
    destination_path.parent.mkdir(parents=True, exist_ok=True)
    backup_path: Path | None = None
    if os.path.lexists(destination_path):
        backup_path = destination_path.parent / f".{destination_path.name}.backup-{uuid4().hex}"
        rename_fn(destination_path, backup_path)

    try:
        rename_fn(candidate_path, destination_path)
    except Exception:
        if (
            backup_path is not None
            and os.path.lexists(backup_path)
            and not os.path.lexists(destination_path)
        ):
            rename_fn(backup_path, destination_path)
        raise

    if backup_path is not None:
        _remove_path(backup_path)


def build_and_publish(
    onnx_path: Path,
    output_path: Path,
    *,
    variant: str,
    quantize: str,
    skip_verify: bool,
    converter: Callable[..., object] = convert_to_coreml,
    verifier: Callable[..., float] = verify_parity,
    promoter: Callable[[Path, Path], None] = promote_package,
) -> Path:
    """Convert into a sibling staging path, verify on disk, and atomically publish."""
    output_path = Path(output_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    staging_path = output_path.parent / f".{output_path.name}.staging-{uuid4().hex}.mlpackage"
    try:
        converter(onnx_path, staging_path, variant=variant, quantize=quantize)
        if not skip_verify:
            min_cosine = 0.995 if quantize == "int8" else 0.999
            verifier(staging_path, onnx_path, min_cosine=min_cosine)
        promoter(staging_path, output_path)
    finally:
        _remove_path(staging_path)
    return output_path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--variant", choices=sorted(VARIANT_ONNX_NAMES), default="w600k_r50")
    parser.add_argument(
        "--quantize",
        choices=["none", "int8"],
        default="int8",
        help="Weight quantization mode: int8 (W8A16, default) or none (FP16).",
    )
    parser.add_argument("--onnx-path", default=None, help="Skip auto-download; use this local .onnx file instead.")
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT), help="Output .mlpackage path.")
    parser.add_argument("--skip-verify", action="store_true", help="Skip the ONNX/Core ML parity check.")
    args = parser.parse_args()

    onnx_path = locate_or_download_onnx(args.variant, args.onnx_path)
    output_path = Path(args.output)
    try:
        build_and_publish(
            onnx_path,
            output_path,
            variant=args.variant,
            quantize=args.quantize,
            skip_verify=args.skip_verify,
        )
    except ConversionError as exc:
        fail(str(exc))

    print(f"\nDone. Model ready at: {output_path}")
    print("Next: add this file to the Xcode project (glance/Models/ArcFace.mlpackage) if not auto-picked-up,")
    print("then build — ArcFaceEmbedder.swift will load it from the app bundle at runtime.")


if __name__ == "__main__":
    main()
