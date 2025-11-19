import os
import cv2
import torch
import argparse
import numpy as np
from PIL import Image
from tqdm import tqdm
from torchvision import transforms
from cubediff.pipelines.pipeline import CubeDiffPipeline


class CubeDiffRunner:
    def __init__(self, checkpoint="hlicai/cubediff-512-imgonly"):
        self.device = "cuda" if torch.cuda.is_available() else "cpu"

        print(f"[INFO] Loading CubeDiff model: {checkpoint}")
        self.pipe = CubeDiffPipeline.from_pretrained(checkpoint).to(self.device)
        print(f"[INFO] Model loaded on {self.device}")

        self.image_size = self.pipe.vae.config.sample_size

        self.transform = transforms.Compose([
            transforms.Resize((self.image_size, self.image_size)),
            transforms.ToTensor(),
            transforms.Normalize([0.5, 0.5, 0.5], [0.5, 0.5, 0.5]),
        ])

    # ---------------------------------------------------------
    # PANORAMA → MULTI-VIEW OUTWARD PERSPECTIVES (100 views)
    # ---------------------------------------------------------
    def panorama_to_views(self, pano_path, frames_dir, num_views=100, fov=90, pitch=0):
        """
        Convert a 2048×1024 equirectangular panorama into outward-facing
        perspective frames for 3D Gaussian Splatting.
        """

        os.makedirs(frames_dir, exist_ok=True)
        list_file = os.path.join(os.path.dirname(frames_dir), "outward.txt")

        pano = cv2.imread(pano_path, cv2.IMREAD_COLOR)
        if pano is None:
            raise ValueError(f"Could not read pano: {pano_path}")

        H, W, _ = pano.shape
        frame_h, frame_w = 512, 512

        # normalized camera rays for 90° FOV
        x = np.linspace(-1, 1, frame_w)
        y = np.linspace(-1, 1, frame_h)
        xv, yv = np.meshgrid(x, y)
        zv = np.ones_like(xv)
        dirs = np.stack([xv, -yv, zv], axis=-1)
        dirs /= np.linalg.norm(dirs, axis=-1, keepdims=True)

        pitch_rad = np.deg2rad(pitch)

        print(f"[INFO] Extracting {num_views} outward views...")

        with open(list_file, "w") as f:
            for i in tqdm(range(num_views), desc="Generating outward frames", unit="frame"):

                yaw = np.deg2rad(i * 360 / num_views)

                Ry = np.array([
                    [np.cos(yaw), 0, np.sin(yaw)],
                    [0, 1, 0],
                    [-np.sin(yaw), 0, np.cos(yaw)]
                ])

                Rp = np.array([
                    [1, 0, 0],
                    [0, np.cos(pitch_rad), -np.sin(pitch_rad)],
                    [0, np.sin(pitch_rad), np.cos(pitch_rad)]
                ])

                R = Rp @ Ry
                dirs_rot = dirs @ R.T

                lon = np.arctan2(dirs_rot[..., 0], dirs_rot[..., 2])
                lat = np.arcsin(dirs_rot[..., 1])

                u = (lon / (2 * np.pi) + 0.5) * W
                v = (0.5 - lat / np.pi) * H

                frame = cv2.remap(
                    pano,
                    u.astype(np.float32),
                    v.astype(np.float32),
                    interpolation=cv2.INTER_LINEAR,
                    borderMode=cv2.BORDER_WRAP
                )

                fname = f"{i:05d}.png"
                f.write(fname + "\n")
                cv2.imwrite(os.path.join(frames_dir, fname), frame)

        print(f"[INFO] Saved {num_views} frames to: {frames_dir}")
        print(f"[INFO] Saved outward.txt to: {list_file}")

    # ---------------------------------------------------------
    # PIPELINE ENTRYPOINT
    # ---------------------------------------------------------
    def run(self, input_path, output_dir):
        print(f"[INFO] Reading: {input_path}")
        img = Image.open(input_path).convert("RGB")
        conditioning = self.transform(img).unsqueeze(0).to(self.device)

        print("[INFO] Running CubeDiff inference...")
        out = self.pipe(
            prompts="",
            conditioning_image=conditioning,
            num_inference_steps=50,
            cfg_scale=3.5,
        )
        
        base = os.path.splitext(os.path.basename(input_path))[0]
        base_folder = os.path.join(output_dir, base)
        os.makedirs(base_folder, exist_ok=True)

        # Save the generated panorama
        pano_path = os.path.join(base_folder, "output_pano.png")
        Image.fromarray(out.equirectangular).save(pano_path)
        print(f"[INFO] Saved panorama: {pano_path}")

        # Make views directory inside this folder
        frames_dir = os.path.join(base_folder, "images")

        # Generate perspective views
        self.panorama_to_views(pano_path, frames_dir, num_views=100, fov=90)

        return pano_path


def parse_args():
    parser = argparse.ArgumentParser(description="CubeDiff Equirectangular Generator")
    parser.add_argument("-i", "--input", required=True, help="Input image path")
    parser.add_argument("-o", "--output", required=True, help="Output directory")
    return parser.parse_args()


if __name__ == "__main__":
    args = parse_args()

    runner = CubeDiffRunner()
    runner.run(args.input, args.output)
