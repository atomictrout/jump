# Fine-Tuning a Pose Model for High Jump: Labeling Options

## Why Fine-Tune?

All current pose models (BlazePose, Apple Vision, YOLO-Pose, RTMPose) are trained on COCO — mostly upright humans. They fail during the Fosbury Flop arch. Research shows fine-tuning on just 300-500 domain-specific frames can reduce joint error from 214mm to ~65mm.

## Best Model to Fine-Tune: YOLO11-pose

- **Official CoreML export**: `model.export(format="coreml")`
- **Official Swift package** via SPM: github.com/ultralytics/yolo-ios-app
- **60+ FPS** on iPhone Neural Engine (nano model), 30+ FPS (medium)
- **Single-stage**: detects bounding boxes AND keypoints in one pass
- ⚠️ **License**: AGPL-3.0 — must open-source app OR buy Ultralytics Enterprise License

### Alternative: RTMPose (Apache 2.0 — free for commercial use)
- Export to CoreML via ONNX
- Fine-tune via MMPose framework
- Similar accuracy and speed

## What to Label

- **300-500 frames** of high jumpers (especially the arch/flight phase)
- **17 COCO keypoints**: nose, eyes, ears, shoulders, elbows, wrists, hips, knees, ankles
- **Focus**: ~200+ arch-phase frames (the hardest cases), ~100-200 approach/landing

## Labeling Options: Cost Comparison

| Option | Est. Cost (500 images) | Your Effort | Quality |
|---|---|---|---|
| **DIY with pre-labeling (CVAT)** | **$0** (4-8 hrs of your time) | High | High (you control it) |
| **Offshore BPO team** | $25-$75 | Low | Medium-High |
| **College student + pre-labels** | $50-$120 | Medium | High |
| **MTurk (single annotation)** | $60-$180 | Medium (setup) | Medium |
| **Fiverr freelancer** | $75-$250 | Low | Variable |
| **Toloka crowdsourcing** | $50-$150 | Medium (setup) | Medium |
| **Upwork freelancer (offshore)** | $65-$200 | Low | Medium-High |
| **Roboflow outsourced labeling** | ~$425 | Very Low | High |
| **Scale AI** | $100-$500 | Very Low | High |

---

## Option 1: DIY with Pre-Labeling (FREE — Recommended)

**Best for**: You want control and don't mind spending a few hours.

### Workflow
1. Extract 300-500 frames from high jump videos (YouTube competitions)
2. Run an existing pose model (YOLO-Pose, ViTPose) to generate initial keypoint predictions
3. Import predictions into **CVAT** (free, open-source)
4. Manually correct only the errors (~30-60 seconds per image)
5. Export in COCO keypoint format

### Tools (all free)
- **CVAT** (cvat.ai) — self-hosted or cloud, native skeleton/keypoint support, auto-annotation
- **Label Studio** (labelstud.io) — supports keypoints, COCO export
- **COCO Annotator** (github.com/jsbroks/coco-annotator) — purpose-built for COCO format

### Time Estimate
- Pre-labeling is ~50-70% accurate on upright frames, ~20-40% on arch frames
- Correction: ~4-8 hours total for 500 images

---

## Option 2: Fiverr / Upwork Freelancer ($75-$250)

**Best for**: You want it done without doing it yourself.

- Fiverr keypoint annotation gigs start at $5/batch
- Negotiate custom order for 500 images × 17 keypoints
- Provide the pre-labeled data (from running YOLO-Pose) so they only correct errors
- **Fiverr sellers**: search "keypoint annotation" — Ukhan4910, Annotatorr, Annotationbd
- **Upwork**: offshore annotators at $5-15/hr, ~1-3 min per image

---

## Option 3: Amazon Mechanical Turk ($60-$180)

**Best for**: Cheapest outsourced option, but requires setup.

- You set the per-HIT reward ($0.10-$0.30 per image)
- Amazon charges 20% fee on top
- Open-source MTurk keypoint UI: github.com/Vinno97/improved-mturk-keypoints-ui
- 3x redundancy for quality: $180-$540
- COCO dataset was originally annotated this way

---

## Option 4: Cheapest "Have Someone Else Do It" ($25-$120)

### Offshore BPO ($25-$75)
- Philippines-based annotation shops, 40-60% savings
- $0.05-$0.15 per image
- Companies like Digital Minds BPO advertise keypoint services

### College Student ($50-$120)
- Post on university CS job board or r/forhire
- $12-$15/hr, 4-8 hours with pre-labeled data
- They only correct errors, not label from scratch

---

## Option 5: Roboflow Outsourced ($425)

**Best for**: Hands-off, integrated with training pipeline.

- $0.05 per keypoint annotation × 17 keypoints = $0.85/image
- Integrated with Roboflow training/export pipeline
- Free tier: 10,000 images, 3 projects (for the platform, not labeling)
- Auto-annotate feature reduces manual work

---

## Training Workflow (after labeling)

```python
from ultralytics import YOLO

# Load pretrained pose model
model = YOLO("yolo11m-pose.pt")

# Fine-tune on your dataset
model.train(
    data="highjump_keypoints.yaml",
    epochs=100,
    imgsz=640,
    batch=16
)

# Export for iOS
model.export(format="coreml", int8=True, imgsz=[640, 384])
```

- **Training time**: ~1-2 hours on GPU (Google Colab free tier works)
- **Output**: `.mlpackage` file → drop into Xcode project

## Recommendation

Start with **Option 1 (DIY pre-label + CVAT)** — it's free and gives you the highest quality since you understand the domain. If you'd rather not spend the time, a **Fiverr freelancer ($75-$150)** with pre-labeled data is the cheapest outsourced path.
