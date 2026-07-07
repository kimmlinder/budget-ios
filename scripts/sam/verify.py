import numpy as np
import torch
import coremltools as ct
from PIL import Image
from segment_anything import sam_model_registry, SamPredictor
from segment_anything.utils.transforms import ResizeLongestSide

IMG_SIZE = 1024
MAX_POINTS = 6

image = np.array(Image.open("test.jpg").convert("RGB"))
orig_h, orig_w = image.shape[:2]
point = np.array([[500, 375]])
label = np.array([1])

# --- Reference: PyTorch SamPredictor ---
sam = sam_model_registry["vit_b"](checkpoint="checkpoints/sam_vit_b_01ec64.pth")
sam.eval()
predictor = SamPredictor(sam)
predictor.set_image(image)
ref_masks, ref_scores, _ = predictor.predict(
    point_coords=point, point_labels=label, multimask_output=True
)
ref_mask = ref_masks[np.argmax(ref_scores)]
print("Reference (PyTorch) best score:", ref_scores.max())

# --- Core ML path ---
transform = ResizeLongestSide(IMG_SIZE)
resized = transform.apply_image(image)
rh, rw = resized.shape[:2]
padded = np.zeros((IMG_SIZE, IMG_SIZE, 3), dtype=np.float32)
padded[:rh, :rw, :] = resized.astype(np.float32)
input_tensor = padded.transpose(2, 0, 1)[None, ...]  # 1x3x1024x1024

encoder = ct.models.MLModel("SAMImageEncoder.mlpackage")
decoder = ct.models.MLModel("SAMMaskDecoder.mlpackage")

enc_out = encoder.predict({"image": input_tensor})
image_embeddings = enc_out["image_embeddings"]
print("image_embeddings shape:", image_embeddings.shape)

coords_resized = transform.apply_coords(point.astype(np.float32), (orig_h, orig_w))
padded_coords = np.full((1, MAX_POINTS, 2), 0.0, dtype=np.float32)
padded_labels = np.full((1, MAX_POINTS), -1.0, dtype=np.float32)
padded_coords[0, : len(point)] = coords_resized
padded_labels[0, : len(point)] = label

dec_out = decoder.predict(
    {
        "image_embeddings": image_embeddings.astype(np.float32),
        "point_coords": padded_coords,
        "point_labels": padded_labels,
    }
)
low_res_masks = dec_out["low_res_masks"]  # 1x3x256x256
iou_predictions = dec_out["iou_predictions"]  # 1x3
print("iou_predictions:", iou_predictions)

best_idx = int(np.argmax(iou_predictions[0]))
low_res_mask = torch.from_numpy(low_res_masks[0, best_idx : best_idx + 1][None, ...])

# Upscale exactly like Sam.postprocess_masks: interpolate to img_size, crop to
# resized (pre-pad) dims, then interpolate to original size.
upscaled = torch.nn.functional.interpolate(
    low_res_mask, size=(IMG_SIZE, IMG_SIZE), mode="bilinear", align_corners=False
)
upscaled = upscaled[..., :rh, :rw]
upscaled = torch.nn.functional.interpolate(
    upscaled, size=(orig_h, orig_w), mode="bilinear", align_corners=False
)
coreml_mask = (upscaled[0, 0] > 0.0).numpy()

intersection = np.logical_and(ref_mask, coreml_mask).sum()
union = np.logical_or(ref_mask, coreml_mask).sum()
iou = intersection / union
print("IoU between PyTorch and Core ML masks:", iou)
print("ref_mask coverage:", ref_mask.mean(), "coreml_mask coverage:", coreml_mask.mean())
