import torch
import torch.nn as nn
import coremltools as ct
from segment_anything import sam_model_registry

CKPT = "checkpoints/sam_vit_b_01ec64.pth"
IMG_SIZE = 1024
MAX_POINTS = 6

sam = sam_model_registry["vit_b"](checkpoint=CKPT)
sam.eval()


class ImageEncoderWrapper(nn.Module):
    def __init__(self, sam):
        super().__init__()
        self.image_encoder = sam.image_encoder
        self.register_buffer("pixel_mean", sam.pixel_mean.view(1, 3, 1, 1))
        self.register_buffer("pixel_std", sam.pixel_std.view(1, 3, 1, 1))

    def forward(self, x):
        # x: 1x3xIMG_SIZExIMG_SIZE, raw 0-255 float, already letterboxed
        x = (x - self.pixel_mean) / self.pixel_std
        return self.image_encoder(x)


class MaskDecoderWrapper(nn.Module):
    def __init__(self, sam):
        super().__init__()
        self.prompt_encoder = sam.prompt_encoder
        self.mask_decoder = sam.mask_decoder

    def forward(self, image_embeddings, point_coords, point_labels):
        sparse_embeddings, dense_embeddings = self.prompt_encoder(
            points=(point_coords, point_labels), boxes=None, masks=None
        )
        low_res_masks, iou_predictions = self.mask_decoder(
            image_embeddings=image_embeddings,
            image_pe=self.prompt_encoder.get_dense_pe(),
            sparse_prompt_embeddings=sparse_embeddings,
            dense_prompt_embeddings=dense_embeddings,
            multimask_output=True,
        )
        return low_res_masks, iou_predictions


print("Tracing image encoder...")
encoder_wrapper = ImageEncoderWrapper(sam).eval()
example_image = torch.rand(1, 3, IMG_SIZE, IMG_SIZE) * 255.0
with torch.no_grad():
    traced_encoder = torch.jit.trace(encoder_wrapper, example_image)

print("Converting image encoder to Core ML...")
encoder_mlmodel = ct.convert(
    traced_encoder,
    inputs=[ct.TensorType(name="image", shape=example_image.shape)],
    outputs=[ct.TensorType(name="image_embeddings")],
    minimum_deployment_target=ct.target.iOS17,
    compute_units=ct.ComputeUnit.CPU_AND_NE,
    convert_to="mlprogram",
)
encoder_mlmodel.save("SAMImageEncoder.mlpackage")
print("Saved SAMImageEncoder.mlpackage")

print("Tracing mask decoder...")
decoder_wrapper = MaskDecoderWrapper(sam).eval()
example_embeddings = torch.rand(1, 256, 64, 64)
example_coords = torch.rand(1, MAX_POINTS, 2) * IMG_SIZE
example_labels = torch.ones(1, MAX_POINTS, dtype=torch.float32)
with torch.no_grad():
    traced_decoder = torch.jit.trace(
        decoder_wrapper, (example_embeddings, example_coords, example_labels)
    )

print("Converting mask decoder to Core ML...")
decoder_mlmodel = ct.convert(
    traced_decoder,
    inputs=[
        ct.TensorType(name="image_embeddings", shape=example_embeddings.shape),
        ct.TensorType(name="point_coords", shape=example_coords.shape),
        ct.TensorType(name="point_labels", shape=example_labels.shape),
    ],
    outputs=[
        ct.TensorType(name="low_res_masks"),
        ct.TensorType(name="iou_predictions"),
    ],
    minimum_deployment_target=ct.target.iOS17,
    compute_units=ct.ComputeUnit.CPU_AND_NE,
    convert_to="mlprogram",
)
decoder_mlmodel.save("SAMMaskDecoder.mlpackage")
print("Saved SAMMaskDecoder.mlpackage")
print("MAX_POINTS =", MAX_POINTS)
