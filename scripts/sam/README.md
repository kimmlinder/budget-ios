# SAM → Core ML conversion

Produces `LightroomCanon/Resources/SAMImageEncoder.mlpackage` and
`SAMMaskDecoder.mlpackage` from Meta's official
[segment-anything](https://github.com/facebookresearch/segment-anything)
ViT-B checkpoint. These two models back `SAMSegmentationService`.

## Regenerating the models

```
python3 -m venv venv && source venv/bin/activate
pip install torch torchvision --index-url https://download.pytorch.org/whl/cpu
pip install coremltools git+https://github.com/facebookresearch/segment-anything.git

mkdir -p checkpoints
curl -L -o checkpoints/sam_vit_b_01ec64.pth \
  https://dl.fbaipublicfiles.com/segment_anything/sam_vit_b_01ec64.pth

python3 convert.py
```

This writes `SAMImageEncoder.mlpackage` and `SAMMaskDecoder.mlpackage` into
the current directory — copy them into `LightroomCanon/Resources/`,
replacing the existing ones (both are Git LFS-tracked, see
`.gitattributes`).

Both models are exported at FLOAT16 precision (coremltools' `mlprogram`
default) — `SAMSegmentationService` reads/writes `Float16` buffers to match;
re-exporting at a different precision needs matching changes there too.

## Verifying a new export

`verify.py` compares the Core ML pipeline's output mask against the
reference PyTorch `SamPredictor` on `segment-anything`'s own demo image
(`truck.jpg` from its `notebooks/images/`) and prints the IoU between them —
it should be ~0.99. Needs `pillow`/`numpy` in the same venv, plus a
`test.jpg` (see the repo's `notebooks/images/truck.jpg`).
