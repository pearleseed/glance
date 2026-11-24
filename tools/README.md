# Converting ArcFace to Core ML

`convert_arcface.py` turns InsightFace's official ArcFace weights (ONNX) into
`glance/Models/ArcFace.mlpackage`, ready for `ArcFaceEmbedder.swift` to load.
By default it converts **`w600k_r50`** (ResNet50 backbone from `buffalo_l`, ~166 MB ONNX)
with **W8A16 int8 weight quantization** (`--variant w600k_r50 --quantize int8`),
producing a ~42 MB Core ML `.mlpackage` (`modelIdentifier = arcface-w600k_r50-v1`).

Run this yourself if you want to regenerate or switch model variants — it downloads
~2 GB of Python tooling (`torch`, `coremltools`) and the InsightFace weights from
InsightFace's own hosting.

## Run it

```bash
cd /path/to/glance
python3 -m venv .venv
source .venv/bin/activate
pip install -r tools/requirements.txt
python tools/convert_arcface.py --variant w600k_r50 --quantize int8
```

First run downloads the InsightFace `buffalo_l` model pack to
`~/.insightface/models/` (cached for next time). The script then:

1. Converts ONNX → torch → Core ML FP16 MLProgram (`macOS 14+`), baking
   preprocessing (RGB, `(px-127.5)/127.5`) into the model so Swift only ever
   hands over a raw 112×112 image, then applies per-channel symmetric W8A16
   weight quantization (`--quantize int8`; pass `--quantize none` for FP16).
2. **Verifies numerical parity**: runs the same random input through the
   original ONNX graph and the converted Core ML model and checks the
   outputs agree (cosine similarity `>= 0.995` for W8A16 int8, `>= 0.999` for FP16).
   This is the real check — a channel-order or scale mistake would silently produce
   a broken model that loads fine and returns plausible-looking garbage. If this
   check fails, the script exits with an error and **the model is not usable** —
   do not wire it in.
3. Saves `glance/Models/ArcFace.mlpackage`.

Expect it to take a few minutes, mostly the one-time package installs.

## After it succeeds

Add `glance/Models/ArcFace.mlpackage` to the Xcode project if it doesn't
show up automatically (the `glance/` folder is a file-system-synchronized
group, so it should auto-appear — if not, drag it into Xcode and make sure
"Copy items if needed" + the `glance` target are checked).

The model is committed to git (see the repo's `.gitignore` — only the
*compiled* `.mlmodelc` is excluded, since that's derived from the
`.mlpackage` at build time).

## If auto-download fails

InsightFace's model hosting occasionally moves. If `FaceAnalysis(...).prepare()`
fails, download `w600k_r50.onnx` yourself from the InsightFace model zoo and
run:

```bash
python tools/convert_arcface.py --variant w600k_r50 --quantize int8 --onnx-path /path/to/w600k_r50.onnx
```

## Model contract (what Swift expects)

| | |
|---|---|
| Input | `input_image`, 112×112 RGB image (`CVPixelBuffer`/`CGImage`) |
| Output | `embedding`, 512 floats, **not** L2-normalized — Swift normalizes it |
| Preprocessing | Baked in: `(pixel - 127.5) / 127.5`, RGB channel order |

If you ever swap in a different ArcFace variant (e.g. the smaller MobileFaceNet
`--variant w600k_mbf`), this contract stays the same — only the file size,
accuracy, latency, and `ArcFaceEmbedder.modelIdentifier` change.
