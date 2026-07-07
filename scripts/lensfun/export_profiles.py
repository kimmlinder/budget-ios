#!/usr/bin/env python3
"""Extracts a curated subset of lens/camera calibration data from the real
Lensfun XML database (https://github.com/lensfun/lensfun) into
LightroomCanon/Resources/LensProfiles.json, bundled by this app for
Lensfun-derived lens correction when Apple's own CIRAWFilter has no profile
for the shot's lens (see LensProfileDatabase.swift/LensCorrectionKernel.swift).

Only the cameras/lenses actually used by this app's sample photos are
extracted here, not the whole database (~thousands of entries) — add more
(maker, camera model, lens model) tuples to PROFILES below and re-run to
extend it.

Usage:
    git clone --depth 1 https://github.com/lensfun/lensfun.git
    python3 export_profiles.py lensfun/data/db > ../../LightroomCanon/Resources/LensProfiles.json
"""
import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

# (camera model, lens model) pairs to extract. The lens model here is the
# lensfun XML <model> text (not necessarily identical to the EXIF LensModel
# string — LensProfileDatabase.swift does fuzzy/substring matching).
PROFILES = [
    ("Canon EOS M50m2", "Canon EF-M 15-45mm f/3.5-6.3 IS STM"),
    ("Canon EOS M50m2", "Canon EF-S 55-250mm f/4-5.6 IS II"),
    ("Canon EOS M", "Canon EF 50mm f/1.8 STM"),
]


def load_all(db_dir):
    cameras, lenses = {}, {}
    for xml_path in Path(db_dir).glob("*.xml"):
        root = ET.parse(xml_path).getroot()
        for cam in root.findall("camera"):
            model = cam.findtext("model")
            crop = cam.findtext("cropfactor")
            if model is not None and crop is not None:
                cameras.setdefault(model, float(crop))
        for lens in root.findall("lens"):
            model = lens.findtext("model")
            if model is None:
                continue
            lenses.setdefault(model, []).append(lens)
    return cameras, lenses


def extract_lens(lens_el):
    crop = float(lens_el.findtext("cropfactor", default="1.0"))
    aspect = float(lens_el.findtext("aspect-ratio", default="1.5"))
    distortion, vignetting = [], []
    calib = lens_el.find("calibration")
    if calib is None:
        return crop, aspect, distortion, vignetting
    for d in calib.findall("distortion"):
        if d.get("model") != "ptlens":
            continue  # only the ptlens model is ported in LensCorrectionKernel
        distortion.append({
            "focal": float(d.get("focal")),
            "a": float(d.get("a", 0)),
            "b": float(d.get("b", 0)),
            "c": float(d.get("c", 0)),
        })
    for v in calib.findall("vignetting"):
        if v.get("model") != "pa":
            continue
        vignetting.append({
            "focal": float(v.get("focal")),
            "aperture": float(v.get("aperture")),
            "distance": float(v.get("distance")),
            "k1": float(v.get("k1", 0)),
            "k2": float(v.get("k2", 0)),
            "k3": float(v.get("k3", 0)),
        })
    distortion.sort(key=lambda e: e["focal"])
    vignetting.sort(key=lambda e: (e["focal"], e["aperture"]))
    return crop, aspect, distortion, vignetting


def main():
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <lensfun/data/db directory>", file=sys.stderr)
        sys.exit(1)
    cameras, lenses = load_all(sys.argv[1])

    profiles = []
    for camera_model, lens_model in PROFILES:
        if camera_model not in cameras:
            print(f"warning: camera not found: {camera_model}", file=sys.stderr)
            continue
        candidates = lenses.get(lens_model, [])
        if not candidates:
            print(f"warning: lens not found: {lens_model}", file=sys.stderr)
            continue

        # A lens model can appear as multiple <lens> blocks calibrated at
        # different crop factors (e.g. Canon EF 50mm f/1.8 STM has a
        # full-frame block with distortion+vignetting, and an APS-C block
        # with vignetting only). Merge: prefer the block whose own crop
        # factor matches the camera's for vignetting (vignetting depends on
        # the sensor's image circle), but fall back to whichever block
        # actually has distortion data (it's a lens-intrinsic property,
        # valid regardless of which body it was measured on).
        camera_crop = cameras[camera_model]
        best_distortion, best_vignetting = [], []
        best_aspect = 1.5
        for lens_el in candidates:
            crop, aspect, distortion, vignetting = extract_lens(lens_el)
            if distortion and not best_distortion:
                best_distortion = distortion
                best_aspect = aspect
            if vignetting and (not best_vignetting or abs(crop - camera_crop) < 0.01):
                best_vignetting = vignetting

        if not best_distortion and not best_vignetting:
            print(f"warning: no ptlens/pa calibration data for {lens_model}", file=sys.stderr)
            continue

        profiles.append({
            "cameraModel": camera_model,
            "cameraCropFactor": camera_crop,
            "lensModel": lens_model,
            "aspectRatio": best_aspect,
            "distortion": best_distortion,
            "vignetting": best_vignetting,
        })

    json.dump({"profiles": profiles}, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
