# Jump - High Jump Analysis App: Product Spec

## Overview

**Platform:** iOS 16.0+ (iPhone and iPad)
**Language:** Swift / SwiftUI
**Architecture:** MVVM
**Pose Detection:** MediaPipe BlazePose (33 landmarks)
**Connectivity:** Fully offline — no network required

An iOS app that uses computer vision to analyze high jump technique. Athletes or coaches import or record a video, select the athlete, mark the bar, and receive automated biomechanical analysis with coaching recommendations.

**Device requirements:** iPhone or iPad with A12 chip or later (iPhone XS / iPad Air 3rd gen / 2018+). Processing time scales with frame count — a 10-second 120fps video (~1200 frames) processes in ~30s; 240fps doubles the frame count and processing time.

**iPad considerations:** The larger screen is ideal for the video frame viewer — more room for skeleton overlays, angle badges, and the phase timeline. On iPad, the Takeoff Instant View and Results Display use a two-column layout (video frame on the left, metrics on the right) instead of stacking vertically. All touch interactions (loupe, skeleton tap, scrubbing) work identically. The app supports Split View and Slide Over multitasking.

---

## Onboarding (First Launch)

On first launch, show a 4-card walkthrough introducing the workflow. Each card is a single screen with an illustration and short text. Swipe or tap to advance. Skip button always visible.

1. **Record your jump** — "Film a high jump from the side, perpendicular to the bar. 120fps or higher recommended."
2. **Select & mark** — "Tap the athlete to track them. Mark the bar endpoints for height calibration."
3. **Automatic analysis** — "We detect every phase of the jump and measure 30+ biomechanical metrics."
4. **Instant coaching** — "See what's working, what to fix, and specific drills to improve."

After dismissal, the walkthrough is not shown again. Accessible from Settings → "Show Walkthrough" if the user wants to revisit.

---

## Data Persistence

Each analysis session is saved as a **JumpSession** object, persisted to local storage via SwiftData (iOS 17+) or Core Data (iOS 16 fallback).

**What is saved per session:**
- Video reference (URL to the original video in the user's photo library or app sandbox)
- All cached pose detection results (per-frame, per-person landmark arrays)
- Person selection state (anchor frame, all frame assignments, user corrections)
- Bar endpoints, bar height, scale calibration
- Takeoff leg selection
- Phase classification results
- All computed metrics and error detections
- Session metadata: date, bar height, estimated athlete height, jump outcome (cleared/knocked)

**Auto-save behavior:**
- Sessions are saved automatically after each major step completes (pose detection, person selection, bar marking, analysis)
- If the user closes the app mid-session, they return to where they left off
- No explicit "Save" button needed — the session is always current

**Home screen:**
- Shows a list of saved sessions, most recent first
- Each session card shows: video thumbnail, date, bar height, outcome badge (CLEARED/KNOCKED), key metric summary (e.g., "Takeoff angle: 44°, Peak clearance: +5cm")
- Tap a session to reopen it at the Results Display (or at the last incomplete step if analysis wasn't finished)
- Swipe to delete a session (with confirmation)
- "New Jump" button (prominent, top of screen) to start a new session
- **Empty state**: on first launch (after onboarding), Home shows a single card: "Record or import your first jump" with camera and library icons

**Storage considerations:**
- Pose detection cache is the largest data per session (~2-5 MB for a typical jump). Video is referenced, not duplicated.
- Sessions are stored locally only (no cloud sync in V1)
- Provide a "Clear All Data" option in Settings for storage management
- **Orphaned sessions**: if the source video is deleted from the photo library, the session's pose data and analysis results are still valid (they're cached independently). Show a "Video unavailable" badge on the session card. The user can still view all metrics and results, but cannot scrub the video or return to the frame viewer. Offer: "Re-link video" to associate a new copy, or "Delete session" to clean up.

---

## Navigation Structure

The app uses a **NavigationStack** with a clear hierarchy:

```
Home (session list)
  ├── New Jump
  │     ├── Video Import (record or library)
  │     ├── Video Trim (optional)
  │     └── Video Analysis View (primary workspace)
  │           ├── Pose Detection (automatic, progress overlay)
  │           ├── Person Selection mode
  │           ├── Bar Marking mode
  │           ├── Bar Height Input (sheet)
  │           ├── Analysis (progress overlay)
  │           └── Results
  │                 ├── Approach Summary (swipeable)
  │                 ├── Takeoff Instant View (hero, swipeable)
  │                 ├── Peak Instant View (swipeable)
  │                 ├── Results Display (full metrics, errors, coaching)
  │                 └── Frame Viewer (zoom, scrub, inspect any frame)
  ├── Existing Session → Results (or resume at last step)
  └── Settings
```

**Key navigation patterns:**
- The **Video Analysis View** is a single persistent screen with mode switches (person selection mode, bar marking mode, review mode). It does NOT push new screens — the user stays in the same frame viewer context throughout.
- Results screens (Takeoff Instant View → Peak Instant View → Results Display) are **horizontally swipeable** within a paged container, not pushed onto the navigation stack.
- Tapping "Go to Frame X" from any results screen returns to the Video Analysis View at that frame, with the relevant joint/metric highlighted.
- A persistent **back arrow** in the top-left returns to Home from any depth. Changes are auto-saved.
- The bar height input appears as a **bottom sheet**, not a full-screen push.

---

## User Flow

```
Home → Import Video (record or library) → Video Analysis View
  1. Pose Detection (automatic)
  2. Select Person (tap skeleton overlay) — required before step 5
  3. Mark Bar (pinch-zoom, tap endpoints) — required before step 5
  4. Enter Bar Height (read from caption and/or have customer confirm) — required
  5. Analyze — requires steps 2, 3, and 4 complete; grayed out until ready
  6. Review Results:
     - Takeoff Instant View (hero screen — shown first, see Section 12)
     - Phase timeline (color-coded, tappable) with quick-jump to Takeoff / Peak / Landing
     - Phase-specific metrics (tap phase to see its metrics card)
     - Errors with severity and "Go to Frame" links
     - Coaching questions answered from this jump's data
     - Prioritized recommendations with drills
```

**Step gating:** Steps 2 (Select Person) and 3 (Mark Bar) are **independent** — the user can do them in either order. Both are required before step 5 (Analyze). Visual indicators show which steps are complete (checkmark), current (highlighted), and locked (grayed out). The user can go back and redo any step — redoing person selection or bar marking invalidates the analysis and requires re-running step 5.

**Typical session: 3-5 minutes from video to actionable feedback.**

---

## Features

### 1. Video Import & Recording

- Record directly via native camera interface
- Import from photo library
- Metadata extraction (frame rate, duration, resolution)
- Auto-parse bar height from video caption (if present)
- Camera positioning tips shown before recording

**Video quality guidance (shown before recording and on import):**
- **Recommended: 120fps or 240fps** — takeoff ground contact is ~0.17s, so 30fps gives only ~5 frames of the entire takeoff. 120fps gives ~20 frames, enough to identify plant vs toe-off precisely.
- **Minimum usable: 60fps** — below this, key frames (exact plant, exact toe-off) may fall between captured frames
- **30fps warning**: if imported video is 30fps, show a yellow banner: "Low frame rate — takeoff measurements may be approximate. For best results, record at 120fps or higher."
- **Camera angle**: side view perpendicular to the bar gives the best 2D analysis. Angled views reduce angle measurement accuracy.
- **Distance**: far enough to capture the full approach curve + bar + landing mat in frame. Too close cuts off the approach.

**Video trimming (optional, post-import):**
- After import, show a trim interface with start/end handles on a frame-strip timeline
- Drag handles to trim the video to just the jump (removes warm-up, standing around, etc.)
- Preview shows first and last frames of the trimmed selection
- "Use Full Video" button to skip trimming
- Trimming happens before pose detection — trimming reduces the number of frames to process, saving time
- Trim is non-destructive (original video is not modified)

### 2. Pose Detection

**Engine: MediaPipe BlazePose (33 landmarks per person)**

BlazePose is the sole pose detection engine. It provides 33 landmarks including heel and foot_index on each foot — critical for ankle angle, ground contact detection, toe-off timing, and step length measurement. Apple Vision (19 landmarks) was evaluated but lacks heel, toe, and spine landmarks needed for core analysis metrics.

- Detects **all people** in **every frame** on initial processing
- **33 body landmarks per person:**

| # | Landmark | # | Landmark | # | Landmark |
|---|----------|---|----------|---|----------|
| 0 | nose | 11 | left shoulder | 23 | left hip |
| 1 | left eye (inner) | 12 | right shoulder | 24 | right hip |
| 2 | left eye | 13 | left elbow | 25 | left knee |
| 3 | left eye (outer) | 14 | right elbow | 26 | right knee |
| 4 | right eye (inner) | 15 | left wrist | 27 | **left ankle** |
| 5 | right eye | 16 | right wrist | 28 | **right ankle** |
| 6 | right eye (outer) | 17 | left pinky | 29 | **left heel** |
| 7 | left ear | 18 | right pinky | 30 | **right heel** |
| 8 | right ear | 19 | left index | 31 | **left foot_index** |
| 9 | mouth (left) | 20 | right index | 32 | **right foot_index** |
| 10 | mouth (right) | 21 | left thumb | | |
| | | 22 | right thumb | | |

**Skeleton bone connections (for drawing overlay):**
```
nose(0)─left eye inner(1)─left eye(2)─left eye outer(3)
nose(0)─right eye inner(4)─right eye(5)─right eye outer(6)
left eye outer(3)─left ear(7)       right eye outer(6)─right ear(8)
mouth left(9)─mouth right(10)
left shoulder(11)─right shoulder(12)
left shoulder(11)─left elbow(13)─left wrist(15)
right shoulder(12)─right elbow(14)─right wrist(16)
left shoulder(11)─left hip(23)      right shoulder(12)─right hip(24)
left hip(23)─right hip(24)
left hip(23)─left knee(25)─left ankle(27)─left heel(29)
left ankle(27)─left foot_index(31)
right hip(24)─right knee(26)─right ankle(28)─right heel(30)
right ankle(28)─right foot_index(32)
left heel(29)─left foot_index(31)   right heel(30)─right foot_index(32)
```
For the skeleton overlay, draw only the major bones (shoulder-elbow-wrist, shoulder-hip-knee-ankle-heel/toe, shoulder-shoulder, hip-hip). Omit face connections — they add visual clutter and aren't needed for analysis.

**Bold landmarks** are critical additions over Apple Vision's 19-joint set. Heel + foot_index enable: ankle angle at plant (knee→ankle→foot_index, elite target 121°), precise ground contact detection (heel Y-minimum for heel-strike, foot_index Y for toe-off), accurate step length (heel-to-heel), and foot contact type classification (heel-strike vs forefoot).

- All observations cached so retracking is instant (no re-processing video)
- Confidence threshold: 0.1 minimum per joint
- 3-frame moving average smoothing to reduce jitter
- Requires `pose_landmarker_heavy.task` model file (~30MB, bundled with app)

**Multi-person detection:**

The MediaPipe `PoseLandmarker` API supports a `num_poses` parameter (set to 5) that detects multiple people in a single inference pass. This is critical — the user needs to see all people in the frame to select the correct athlete.

```swift
let options = PoseLandmarkerOptions()
options.numPoses = 5          // detect up to 5 people per frame
options.minPoseDetectionConfidence = 0.5
options.minPosePresenceConfidence = 0.5
options.minTrackingConfidence = 0.5
```

**Known limitations of `num_poses > 1`:**
- **Landmark switching**: detected skeletons can swap identity between frames. This is handled by our Person Tracking system (Section 4), which uses spatial matching across frames rather than relying on MediaPipe's ordering.
- **Proximity issues**: when two people are within ~50cm of each other, one detection may drop. In high jump, this rarely occurs — the athlete is typically separated from bystanders/officials.
- **Hallucinated landmarks on occlusion**: when people overlap, occluded joints may get incorrect positions rather than low confidence scores. The confidence threshold + our tracking system mitigates this.

**Fallback for dense scenes (>5 people or persistent detection failures):**
If `num_poses` fails to detect the athlete in too many frames (>30% flagged as gaps), offer a fallback pipeline:
1. Run a person detector (e.g., Apple's `VNDetectHumanRectanglesRequest`) to get bounding boxes
2. Crop each bounding box and run BlazePose with `num_poses = 1` on each crop
3. Map per-crop landmarks back to full-frame coordinates
This is slower (~3x) but more reliable in crowded scenes. Triggered automatically or via "Retry with enhanced detection" button.

**Processing feedback UI:**
- Progress bar shown during detection: "Detecting poses…"
- Frame counter: "Processing frame 142 / 380"
- Estimated time remaining (based on average processing speed per frame)
- Cancel button to abort processing (discards partial results)
- Note: 240fps video = 4x the frames of 60fps = proportionally longer processing. A 10-second 240fps clip has ~2400 frames vs ~600 at 60fps.

### 3. Video Frame Viewer & Scrubbing

The video frame viewer is the primary workspace throughout the entire session — used for person selection, bar marking, review, and analysis. It must support precise inspection of any frame.

**Scrubbing:**
- Frame scrubber bar at bottom: drag to scrub through all frames
- Tap-and-hold scrubber for fine-grained single-frame stepping
- Frame counter shown: "Frame 142 / 380" with timestamp
- Playback controls: play/pause, frame-forward, frame-backward
- Playback speed: 1x, 0.5x, 0.25x, frame-by-frame step

**Zoom & Pan (available at all times, not just bar marking):**
- Pinch-to-zoom on the video frame (up to 4x zoom)
- Pan with one finger when zoomed in
- Double-tap to toggle between fit-to-screen and 2x zoom centered on tap point
- Zoom level persists while scrubbing (so you can zoom into the takeoff foot and scrub frame-by-frame to watch the plant)
- Skeleton overlay scales with zoom — joints and angle badges remain legible at any zoom level
- When zoomed, a mini-map thumbnail in the corner shows the full frame with a viewport rectangle

**Skeleton overlay (always visible when athlete is tracked):**
- Joints drawn as circles, bones as lines
- Angle badges shown at key joints (knee, hip, ankle, shoulder) — togglable
- Confidence-based opacity: low-confidence joints are semi-transparent
- Tap any joint to see its exact coordinates and confidence score

### 4. Person Selection & Tracking

This is the most critical user interaction. The goal: for every frame of the video, determine whether the athlete is present and which detected skeleton (if any) belongs to them. The system does an initial automatic pass, then the user reviews and corrects.

#### Step 1: Initial Selection

After pose detection completes, the user scrubs to a frame where the athlete is clearly visible (typically mid-approach or takeoff). All detected skeletons are shown:

- **Multi-skeleton overlay** on video: all detected people shown with color-coded skeletons
  - Unassigned people: yellow, pink, orange, purple (dimmed)
  - Numbered badges above each person's head
  - Tap any skeleton or badge to select it as the athlete
- **Thumbnail carousel** (bottom strip): cropped thumbnails of each detected person with confidence scores
  - Tap a thumbnail to select that person as the athlete
  - Includes a **"No Athlete in Frame"** thumbnail option (silhouette with X)

The user taps the correct skeleton. It turns bright cyan. This is the **anchor frame** — the starting point for automatic propagation.

#### Step 2: Automatic Propagation (All Frames)

Once the athlete is selected at the anchor frame, the system automatically assigns the athlete across **every other frame** in the video. For each frame, the result is one of:

| Frame Assignment | Meaning | Visual |
|-----------------|---------|--------|
| **Athlete matched** | A detected skeleton was matched to the athlete with high confidence | Cyan skeleton shown |
| **Athlete matched (uncertain)** | A skeleton was matched but confidence is below threshold | Cyan skeleton shown with orange outline; orange dot on timeline |
| **No athlete (no skeletons)** | No poses detected in this frame at all | Gray frame marker on timeline |
| **No athlete (unmatched)** | Skeletons detected but none match the athlete | Gray frame marker; other skeletons shown dimmed |
| **No pose detected (gap)** | Athlete should be present based on surrounding frames but no skeleton was found (occlusion, detection failure) | Red dot on timeline; frame flagged for review |

**Propagation algorithm:**
- Works bidirectionally from the anchor frame (forward and backward)
- Uses bounding box IoU + joint-level spatial matching between consecutive frames
- Velocity-based prediction to handle movement between frames
- Motion consistency scoring (moving person preferred over stationary bystanders)
- Appearance consistency (body proportions, relative joint positions)
- If confidence drops below threshold, marks frame as uncertain rather than guessing wrong
- Stops assigning athlete when no reasonable match exists (athlete left frame)

**After propagation completes:**
- Timeline updates to show frame-by-frame assignment: cyan (matched), orange (uncertain), gray (no athlete), red (gap/missing pose)
- Summary shown: "Athlete tracked in X of Y frames. Z frames need review."

#### Step 3: User Review & Correction

The user can review and correct any frame. The system makes this fast by surfacing problems first.

**Review mode (optional but encouraged):**
- "Review Flagged Frames" button jumps through only uncertain (orange) and gap (red) frames
- At each flagged frame the user can:

**Correction actions available on any frame:**

| Action | When to use | What happens |
|--------|-------------|--------------|
| **Tap a different skeleton** | Wrong person was matched as athlete | Reassigns this frame to the tapped skeleton; re-propagates from this frame outward to neighboring uncertain frames |
| **Tap "No Athlete"** | A bystander was matched but athlete isn't actually in frame | Clears athlete assignment for this frame; marks as no-athlete; re-propagates to neighbors |
| **Tap "Athlete Here" + tap skeleton** | Frame was marked no-athlete but athlete IS present | Assigns the tapped skeleton as athlete; re-propagates outward |
| **Tap "Athlete Here, No Pose"** | Athlete is visible in the video but no skeleton was detected | Marks frame as athlete-present-but-undetected; these frames are excluded from biomechanical analysis but included in phase timeline (interpolated) |
| **Long-press + drag** | Select a range of frames to bulk-apply a correction | Applies the same correction to all frames in the range |

**Re-propagation on correction:**
- When the user corrects a frame, the system re-runs matching outward from that correction point
- Only affects frames between the correction and the nearest other user-confirmed frame (doesn't override other manual corrections)
- This means each manual correction improves surrounding frames automatically

**Correction confidence:**
- User-confirmed frames are marked with a small checkmark on the timeline
- These act as hard anchors — propagation never overrides them
- The more anchors the user sets, the more accurate the overall assignment

#### Frame Assignment States (Summary)

Each frame in the video has exactly one of these states:

```
┌─────────────────────────────────────────────────────────────┐
│ Frame State           │ Source      │ Editable │ Timeline   │
├───────────────────────┼─────────────┼──────────┼────────────┤
│ Athlete (confirmed)   │ User tap    │ Yes      │ Cyan + ✓   │
│ Athlete (auto)        │ Propagation │ Yes      │ Cyan       │
│ Athlete (uncertain)   │ Propagation │ Yes      │ Cyan + ⚠   │
│ No athlete (confirmed)│ User tap    │ Yes      │ Gray + ✓   │
│ No athlete (auto)     │ Propagation │ Yes      │ Gray       │
│ Athlete, no pose      │ User tap    │ Yes      │ Red + ✓    │
│ Unreviewed gap        │ Detection   │ Yes      │ Red        │
└─────────────────────────────────────────────────────────────┘
```

#### Tracking Confidence HUD

Shown in top-right corner of the video frame view:
- **Locked** (90-100%, green) — high-confidence match
- **Tracking** (70-89%, yellow) — good match, minor variation
- **Uncertain** (50-69%, orange) — may be wrong person
- **Lost** (<50%, red) — no confident match; needs user input
- Shows person count when multiple detected (e.g., "3 people • Tracking")

#### Edge Cases

| Scenario | System behavior |
|----------|----------------|
| Athlete enters frame mid-video (approach starts off-camera) | Early frames auto-marked "no athlete"; first matched frame becomes approach start |
| Athlete leaves frame after landing | Post-landing frames auto-marked "no athlete" |
| Two people cross paths / occlude each other | Confidence drops; frames marked uncertain; user resolves |
| Athlete's pose only partially detected (e.g., legs occluded by mat) | Partial skeleton still matched if enough joints present (≥6); low-confidence joints excluded from metrics |
| Camera shake or zoom change | Matching adapts via relative joint positions (not absolute coordinates) |
| Only one person in entire video | Auto-assigned as athlete for all frames where detected; no selection step needed |
| Person detection finds a "ghost" skeleton (false positive on equipment/crowd) | Motion consistency filter suppresses stationary detections; user can mark as not-athlete |
| Official or coach walks through frame during approach | Transient person appears for a few frames; motion direction (perpendicular to athlete) helps disambiguate; if wrongly matched, user corrects those frames |
| Athlete wears same color as another person | Spatial/skeletal matching (not color) is primary; appearance matching is supplementary only |
| Video starts with athlete already mid-approach | No "no athlete" lead-in; first frame starts in approach phase |
| Very low frame rate (30fps) causes large position jumps between frames | Relax IoU threshold; rely more on velocity prediction; warn user about low frame rate |
| Athlete is partially out of frame (e.g., feet cut off at bottom) | Partial skeleton matched if ≥6 joints visible; out-of-frame joints marked as missing, not low-confidence |

### 5. Bar Detection, Height Calibration & Scale

#### Bar Marking UX (Precision Interaction)

Marking bar endpoints requires pixel-level precision, but the user's finger is ~44pt wide and occludes the exact point they're trying to tap. We use the **loupe pattern** (same as iOS text cursor selection) to solve this:

**Marking flow:**
1. System prompts: "Mark the bar — tap near one end of the bar to begin"
2. User navigates to a frame where the bar is clearly visible (before the jump). System suggests first frame or auto-detects a good candidate.
3. User taps approximately near one end of the bar
4. **Loupe appears**: a magnified circular callout (3-4x zoom) appears **above** the user's finger, showing the area under the fingertip with a crosshair at center
5. User drags to fine-tune position — the loupe tracks the finger, the crosshair shows the exact pixel being selected
6. User lifts finger to place the first endpoint (shown as a colored dot with a short handle)
7. Repeat for the second endpoint
8. A line is drawn connecting the two endpoints, overlaid on the video frame
9. User confirms or adjusts: drag either endpoint to reposition (loupe reappears on touch)

**Loupe details:**
- Circular, ~120pt diameter, positioned above and slightly offset from the touch point (never occluded by finger)
- 3x magnification by default; 4x if the video resolution is low
- Crosshair at center of loupe indicates exact selection point
- Semi-transparent background outside the loupe dims slightly to focus attention
- Loupe disappears on finger lift; reappears on drag of any endpoint

**Auto-detect assist (optional):**
- After the user places the first endpoint, the system can suggest the second endpoint by detecting the horizontal bar edge (Hough line detection or edge tracking from the first point)
- Shown as a pulsing dot at the suggested position — user taps to accept or places manually
- If both endpoints are auto-detected with high confidence, show both as suggestions and let the user confirm with a single tap

**Visual confirmation:**
- Bar line shown in bright green overlaid on video
- "Bar marked" badge with the pixel length shown
- "Redo" button to clear and start over

#### Bar Height Input

- Prompt: "What height is the bar set to?" shown immediately after marking
- Input supports: feet + inches (e.g., 5'10"), meters (e.g., 1.78m), centimeters (e.g., 178cm)
- Auto-parse from video caption/filename if present (e.g., "178cm" in filename)
- Segmented picker for unit selection (ft/in, m, cm)
- Validation range: 0.5m - 2.6m
- This establishes the **pixels-to-meters scale factor** for all subsequent measurements

#### Bar Tracking Across Frames

The bar is marked on one frame, but the analysis needs bar position on every frame (especially during flight/clearance).

**Stationary camera (most common case):**
- Bar pixel position is constant across all frames — mark once, done
- Validate by checking: do the bar endpoint neighborhoods look the same in other frames? (template matching)

**Camera movement detected:**
- If global motion is detected between frames (optical flow on background features), apply homography correction to map bar endpoints to each frame
- Show user: "Camera movement detected — bar position adjusted automatically" with option to verify on any frame

**Bar knock detection:**
- Track the bar region across frames during the flight/landing phase using template matching or optical flow on the bar endpoints
- **Bar stays up**: bar endpoints remain in consistent position across all frames → "CLEARED"
- **Bar knocked**: bar endpoints shift significantly (one or both drop) between consecutive frames → "KNOCKED"
  - Detect which frame the knock begins (sudden displacement of bar region)
  - Detect which body part was nearest the bar at the knock frame (compare skeleton joint positions to bar line)
  - Report: "Bar knocked at frame 287 — left shin closest to bar at contact"
- **Ambiguous**: if displacement is small or bar vibrates but settles back → "Bar disturbed but stayed up" (still counts as cleared per competition rules if bar is resting on supports when jumper leaves mat)

#### Ground Plane Detection & Athlete Height Estimation

Knowing the bar height in real-world units and its pixel length gives us a scale factor. Combined with ground plane detection, we can estimate the athlete's full standing height and convert all spatial measurements to real-world units.

**Scale calibration from bar:**
- The bar is horizontal, but from a side-view camera perpendicular to the bar plane, horizontal and vertical pixel scales are equivalent (no perspective distortion in either axis).
- Therefore: bar pixel length (from the two marked endpoints) and the known real-world bar length (~3.98-4.00m for competition) give us **pixels-per-meter** for both axes.
- However, the bar's *height from the ground* (the adjustable height, e.g., 1.78m) is the vertical dimension we need. Combined with the ground plane Y-coordinate (see below), we get: `pixels_per_meter = (bar_Y - ground_Y) / bar_height_meters`. This converts any pixel distance to real-world meters.

**Ground plane detection:**
- **Primary method**: the athlete's lowest foot position across all standing/approach frames defines ground level. During approach, the foot contact points trace the ground plane.
- **Secondary method**: if the mat/runway surface has a visible edge or line, detect it via edge detection
- **Fallback**: user taps a point on the ground in the same frame as the bar marking, giving us: ground Y (pixels), bar Y (pixels), and bar height (meters) → pixels-per-meter for vertical measurements

**Athlete height estimation:**
- From the approach phase (athlete standing upright, mid-stride): measure pixel distance from foot (ground contact) to top of head
- Apply the vertical pixels-per-meter scale factor derived from bar height + ground plane
- Report estimated athlete height: e.g., "Estimated athlete height: ~1.83m (6'0")"
- User can confirm or override with actual height for more precise measurements

**Why athlete height matters:**
- COM height at takeoff (H1) is typically 55-65% of standing height — knowing the actual height makes this more accurate
- Clearance efficiency metrics depend on knowing whether the athlete is "tall for their jump" or "jumping well above their height"
- Takeoff distance from bar is more meaningful when expressed relative to athlete height

**What the scale factor enables:**
- All spatial metrics convert from pixels to meters: takeoff distance, COM height, clearance, step lengths
- Velocity estimates (pixels/frame → m/s) become real-world speeds
- Angle measurements are scale-independent (they work without calibration), but distance and speed require it

**Body-to-bar comparison (clearance analysis):**
- At each frame during flight, compute the minimum distance from each body part to the bar line
- At bar crossing: for each joint, record its clearance (distance above/below bar) at the frame where it passes the bar's horizontal position
- Visualize as a "clearance profile": a diagram showing each body part's clearance as it crosses the bar (head: +8cm, shoulders: +5cm, hips: +3cm, knees: -2cm knocked, etc.)
- Identify the body part with minimum clearance (the "limiter") — this is what the athlete should focus on improving
- If a body part's clearance is negative, that's where the bar was (or would be) contacted

### 6. Camera Angle Estimation & Metric Confidence

Most high jump videos are NOT filmed from a perfectly perpendicular side view. The camera angle affects measurement accuracy differently for different metric types. This section defines how the app handles non-ideal camera angles.

#### Camera Angle Estimation

When the user marks the bar endpoints, the app estimates the camera's horizontal viewing angle relative to perpendicular:

**Auto-estimation from bar geometry:**
- The high jump bar is always ~4.00m (World Athletics standard). From a perfect side view, the bar appears at its maximum pixel length. From an angled view, it appears foreshortened.
- If the bar's apparent pixel length is much shorter than expected relative to the frame width, or if the two endpoints cluster together horizontally, the camera is angled.
- The bar's apparent tilt in the image (endpoints at different Y positions) also indicates camera angle — from side view, the bar should appear horizontal.

**User-assisted calibration (shown after bar marking):**
- "Where was the camera?" — show a bird's-eye diagram of the jump area (bar, runway, mat) and let the user tap approximately where the camera was positioned
- Or a simpler 4-option picker: "Side view" / "Slightly angled (~15-30°)" / "Moderately angled (~30-45°)" / "Behind the bar (>45°)"
- Default: if user skips, assume "slightly angled" (the most common non-ideal case)

#### Metric Confidence Tiers

Every metric is classified by its sensitivity to camera angle:

**Tier 1 — Robust (always shown, no correction needed):**
Joint angles measured in the sagittal plane, timing metrics, and vertical-only measurements are reliable from any reasonable viewing angle.
- All joint angles: knee, hip, ankle, drive knee, takeoff angle, back tilt
- Ground contact time, flight time (frame-count based)
- Vertical velocity at takeoff
- Peak COM height, COM rise, clearance over bar (vertical measurements)
- Bar knock detection
- H1, H2, H3 decomposition

**Tier 2 — Correctable (shown with correction applied when calibration available):**
Horizontal distances and speeds can be corrected using the estimated camera angle. Show a "~" badge and "(corrected)" label.
- Approach speed → multiply by `1/cos(θ)`
- Takeoff distance from bar → multiply by `1/cos(θ)`
- Step lengths → multiply by `1/cos(θ)`
- CM-to-foot distance at plant

**Tier 3 — Approximate (shown with warning when angle > 30°):**
Metrics that require seeing the ground-plane trajectory are inherently approximate from any single 2D view, and degrade further with angle.
- Approach angle to bar → label as "estimated" with "~" badge
- J-curve radius → label as "estimated from 2D projection"
- Inward body lean during curve

**Tier 4 — Unreliable (hidden or grayed out when angle > 45°):**
- Approach angle to bar
- J-curve radius
- Hip-shoulder separation (rotation partly in depth axis)

#### Metric Confidence Display

Each metric in the results UI shows a confidence badge:
- **(no badge)** — Tier 1, reliable from any angle
- **~** — Tier 2/3, approximate or corrected; tap for explanation
- **?** — Tier 4, unreliable from this camera angle; grayed out with explanation

When a metric is corrected, tapping the "~" badge shows: "This measurement has been adjusted for your camera angle (~25° from perpendicular). For best accuracy, film from directly to the side of the bar."

### 7. Takeoff Leg Identification

Before analysis, the system must know which leg is the takeoff leg (the leg that plants for the jump).

**Auto-detection:**
- At the detected takeoff frame, the foot closest to the ground with downward velocity transitioning to upward = takeoff leg
- Validated by checking: the opposite leg (trail/drive leg) should show knee-drive motion upward
- For Fosbury Flop: a left-footed jumper approaches from the right side of the bar; right-footed from the left. The approach direction can confirm.

**User confirmation:**
- After auto-detection, show: "Takeoff leg: Left" (or Right) with the takeoff foot highlighted on the skeleton
- User taps to confirm or toggle to the other leg
- This is a one-time setting per jump (doesn't change frame-to-frame)

**Why this matters:**
- All takeoff metrics (plant leg knee angle, trail leg knee drive, shin angle) depend on knowing which leg is which
- Getting it wrong inverts every takeoff measurement
- The penultimate step detection also depends on knowing which foot contacts when

### 8. Frame Marking & Phase Classification

Every frame in the video is classified into one of the following categories. This enables scrubbing, quick-jump navigation, and phase-specific metric display.

**Frame Categories:**

| Category | Color | Description | Detection Method |
|----------|-------|-------------|-----------------|
| No Athlete | Gray | Athlete not in frame (approach outside camera view) | No tracked skeleton detected, or user-marked "No Athlete in Frame" |
| Approach | Blue | J-curve run-up through penultimate step | Tracked skeleton present, horizontal velocity dominant, before penultimate |
| Penultimate | Cyan | Second-to-last ground contact (COM lowering). _Biomechanically part of the approach, but broken out as a separate phase because it's a critical coaching checkpoint (COM lowering, shin angle, loading)._ | Ankle minima of takeoff leg, deepest COM position, shin angle near vertical |
| Takeoff | Green | Plant foot contact through toe-off | Velocity transition from horizontal to vertical, full body extension at toe-off |
| Peak / Flight | Yellow | Airborne phase, apex over bar | No ground contact, root Y increasing then at maximum |
| Landing | Orange | Descent and contact with mat | Significant Y-drop after peak, mat contact |

**Phase Timeline Bar:**
- Color-coded bar below the video frame showing the full jump segmented by phase
- Each phase section is tappable to jump directly to that phase's start frame
- Current frame indicator (playhead) on the timeline
- Gray sections for frames with no athlete visible
- Phase boundary markers (vertical lines) at transition points

**Quick-Jump Navigation:**
- Dedicated buttons to jump directly to: Takeoff frame, Peak frame, Landing frame
- Swipe left/right within a phase to stay within that phase's frames
- Double-tap a phase on the timeline to auto-play just that phase in slow motion
- Keyboard/gesture shortcuts: previous phase / next phase

**Key Frame Detection:**
- **First athlete frame**: first frame where tracked skeleton appears
- **Penultimate contact**: ankle minima of takeoff leg, shin angle ≥90°
- **Takeoff (plant)**: last frame with heel ground contact before launch (heel Y-minimum)
- **Toe-off**: frame where foot_index leaves ground, full extension (ankles, knees, hips, arms)
- **Peak height**: maximum root Y during flight (highest COM position)
- **Bar crossing**: frame(s) where body passes over bar plane
- **Landing**: first frame of mat contact (significant Y-drop)

### 9. Biomechanical Analysis

**Phase-Specific Metrics:**

Metrics are organized by phase so coaches can quickly evaluate each part of the jump. Tapping a phase on the timeline shows that phase's metrics card.

#### Approach Phase Metrics

| Category | Metric | Ideal / Notes |
|----------|--------|---------------|
| Speed | Approach speed (horizontal CM velocity) | 7.5-8.0 m/s for elite men; higher = better conversion potential |
| Speed | Speed progression (accelerating through approach) | Stride frequency should increase toward bar |
| Geometry | Approach angle to bar | ~30-40° (ideal ~35°); <20° = flattening the curve; >55° = cutting the curve |
| Geometry | Curve radius | Tighter radius = more inward lean = more rotational momentum |
| Rhythm | Step count | Typically 8-12 steps; should be consistent between attempts |
| Rhythm | Step length pattern (heel-to-heel) | Penultimate step longer, final step shorter |
| Rhythm | Flight-time-to-contact-time ratio (FT:CT) | Higher ratio in final steps correlates with success (~0.31 for elite) |
| Contact | Foot contact type per step (heel-strike vs forefoot) | Detected from heel/foot_index Y positions; forefoot striking preferred in final steps |
| Lean | Inward body lean during curve | 10-20° from vertical; generates rotation for bar clearance |

#### Penultimate Step Metrics

| Category | Metric | Ideal / Notes |
|----------|--------|---------------|
| Position | COM height at penultimate contact | Lowest point; sets up vertical conversion |
| Angles | Shin angle at penultimate contact | ≥90° (acute angle indicates over-reaching) |
| Angles | Takeoff leg knee angle | Slight flexion to load; ~162° at subsequent touchdown |
| Temporal | Step duration | Longer than surrounding steps |
| Spatial | Step length (heel-to-heel) | Longest step in the approach |

#### Takeoff Phase Metrics

| Category | Metric | Ideal / Notes |
|----------|--------|---------------|
| Angles | Takeoff leg knee at plant | 160-175° (near full extension) |
| Angles | Takeoff leg knee at toe-off | ~170° (full extension) |
| Angles | Drive knee angle at takeoff | 70-90° (tight = fast rotation) |
| Angles | Takeoff leg ankle at plant (knee→ankle→foot_index) | ~121° (elite successful jumps) |
| Angles | Trail leg knee angle at touchdown | ~100° for successful; >110° correlates with failure |
| Angles | Takeoff angle (CM trajectory) | 40-48° from horizontal |
| Lean | Whole-body backward lean at plant | Slight lean away from bar; hips must pass over takeoff foot |
| Separation | Hip-shoulder separation at touchdown | ~40° (creates torque for rotation) |
| Separation | Hip-shoulder separation at toe-off | ~12° (unwinding through takeoff) |
| Velocity | Vertical CM velocity at toe-off | 4.5-4.6 m/s for elite |
| Velocity | Horizontal CM velocity at toe-off | ~4.3 m/s (roughly 43% reduction from approach) |
| Angles | Ankle plantarflexion at toe-off (knee→ankle→foot_index) | Full plantarflexion at toe-off; indicates complete push-off |
| Temporal | Ground contact time | 0.16-0.17s for successful; longer = less efficient |
| Spatial | Takeoff distance from bar | ~1.0-1.2m; too close = hits bar on way up; too far = peaks before bar |
| Spatial | CM-to-foot distance at plant | ~0.77m; shorter = less backward lean = better |
| Position | CM height at toe-off (H2) | Depends on athlete height; maximize through full extension |
| Drive | Trail leg thigh peak velocity | ~5.8 m/s; excessive velocity (>6.3) may indicate compensation |

#### Peak / Flight Phase Metrics

| Category | Metric | Ideal / Notes |
|----------|--------|---------------|
| Height | Peak CM height (H3) | Maximum root Y during flight |
| Height | CM raise (toe-off to peak) | Difference between H2 and H3; ~0.97m for elite successful |
| Height | Clearance over bar | Distance between peak CM and bar; closer = more efficient |
| Position | Peak CM distance from bar | Should be ~0 (directly over bar); negative = peaked before bar |
| Arch | Back tilt angle at peak (neck-to-hip line vs horizontal) | Approximation without spine landmarks; >160° = too flat (hammock); check hip elevation. True back arch requires RTMPose 133pt spine landmarks (see Future Considerations). |
| Rotation | Hip elevation over bar | Hips should be highest body part at bar crossing |
| Timing | Head drop timing | Head should not drop before hips pass bar (early head drop error) |
| Limbs | Hands position | Should be at hips (shortens body, accelerates rotation) |
| Limbs | Knee bend in flight | Bent knees shorten rotation radius |

#### Landing Phase Metrics

| Category | Metric | Ideal / Notes |
|----------|--------|---------------|
| Position | Landing zone | Should be center of mat, shoulders/upper back first |
| Timing | Flight time (toe-off to landing) | Total airborne duration |
| Safety | Leg clearance | Legs should clear bar; late leg lift is common knock cause |
| Bar | Bar contact detection | Which body part (if any) contacted bar; at what frame |

Real-world values (meters) computed when bar height is provided.

#### H1 + H2 + H3 Decomposition

The bar height cleared in a high jump can be decomposed into three additive components:

```
Bar Height = H1 + H2 + H3

H1 = COM height at the instant of toe-off (takeoff)
     Typically 55-65% of athlete standing height.
     Determined by: athlete height, body position, and extension at takeoff.

H2 = COM rise during flight (toe-off to peak)
     Calculated from vertical velocity at toe-off: H2 = Vz² / (2g)
     Elite range: ~0.90-1.00m. This is the "jump" component.

H3 = Bar height minus peak COM height
     Can be NEGATIVE for efficient Fosbury Flop technique (COM passes below bar).
     H3 < 0 means the athlete clears the bar without their COM ever reaching bar height.
     Elite: H3 ranges from -0.05m to +0.10m.
```

This decomposition tells the coach WHERE improvement potential lies:
- Low H1 → work on full extension at takeoff (ankle, knee, hip, arm drive)
- Low H2 → increase vertical velocity (stronger/faster plant, better speed conversion)
- High H3 → improve clearance technique (back arch, timing, head/arm position)

#### Center of Mass (COM) Calculation

Many metrics reference COM position and velocity. COM is computed per-frame using the **segmental method** with **de Leva (1996)** body segment parameters — validated specifically for high jump analysis (Virmavirta et al. 2022 showed de Leva matches reaction board ground truth for female high jumpers, while the older Dempster model overestimates).

**Method:** Divide the body into 14 segments. Each segment's COM is located along its length using published proportions. Whole-body COM is the mass-weighted average.

```
COM = Σ (segment_mass_fraction × segment_COM_position)  for all 14 segments

segment_COM = proximal_joint + com_fraction × (distal_joint − proximal_joint)
```

**14-Segment Model (de Leva 1996, male values shown):**

| Segment | Proximal Landmark(s) | Distal Landmark(s) | Mass % | COM % from Proximal |
|---------|---------------------|--------------------|---------|--------------------|
| Head+Neck | midpoint(11,12) | 0 (nose) | 6.94% | 50.0% |
| Trunk | midpoint(11,12) | midpoint(23,24) | 43.46% | 51.4% |
| L Upper Arm | 11 (L shoulder) | 13 (L elbow) | 2.71% | 57.7% |
| R Upper Arm | 12 (R shoulder) | 14 (R elbow) | 2.71% | 57.7% |
| L Forearm | 13 (L elbow) | 15 (L wrist) | 1.62% | 45.7% |
| R Forearm | 14 (R elbow) | 16 (R wrist) | 1.62% | 45.7% |
| L Hand | 15 (L wrist) | midpoint(17,19) | 0.61% | 79.0% |
| R Hand | 16 (R wrist) | midpoint(18,20) | 0.61% | 79.0% |
| L Thigh | 23 (L hip) | 25 (L knee) | 14.16% | 41.0% |
| R Thigh | 24 (R hip) | 26 (R knee) | 14.16% | 41.0% |
| L Shank | 25 (L knee) | 27 (L ankle) | 4.33% | 44.0% |
| R Shank | 26 (R knee) | 28 (R ankle) | 4.33% | 44.0% |
| L Foot | 29 (L heel) | 31 (L foot_index) | 1.37% | 44.2% |
| R Foot | 30 (R heel) | 32 (R foot_index) | 1.37% | 44.2% |

**Notes:**
- Trunk + thighs = 71.8% of body mass — these two segment types dominate COM position. Getting them right is the priority.
- Female parameters differ slightly (e.g., trunk 42.57%, thighs 14.78% each). Default to male; allow user to select sex in settings for slightly more accurate COM.
- Head segment: BlazePose has no vertex landmark. Using nose (landmark 0) as distal end introduces ~2mm whole-body COM error (head = 6.9% of mass).
- Computational cost: trivial — one weighted average of 14 points per frame. No performance concern.
- This COM is used for: H1 (COM at takeoff), H2 (COM rise), COM velocity, COM trajectory during flight, COM-to-bar clearance.

#### Measurement Precision Notes

All measurements are computed from 2D video projections. Accuracy depends on camera setup and frame rate.

| Measurement | Precision | Notes |
|-------------|-----------|-------|
| Ground contact time | ±8-16ms at 120fps | One frame = 8.3ms at 120fps. True contact start/end may fall between frames. |
| Joint angles | ±2-3° | Depends on joint detection confidence and smoothing. |
| Distances (with bar calibration) | ±5cm | Assumes camera perpendicular to bar; perspective distortion adds error. |
| Velocities | ±0.2 m/s | Derived from position differences across frames; noise amplified by differentiation. |
| Back tilt angle | Approximate only | Computed from neck-to-hip line, not true spinal curvature. Underestimates actual arch. |

**Camera angle assumption:** all spatial measurements assume a side-view camera perpendicular to the bar. Angled views cause foreshortening that affects distance measurements but not angles in the plane of view.

### 10. Error Detection & Coaching

**Detected Errors (with severity: minor/moderate/major):**

_Approach errors:_
1. Flattening the Curve (approach angle <20°) — major
2. Cutting the Curve (approach angle >55°) — major
3. Stepping Out of Curve (lateral deviation from J-curve path) — moderate
4. Decelerating on Approach (speed drops in final 3 steps) — moderate
5. Inconsistent Step Count (varies between attempts) — minor
6. Insufficient Inward Lean (lean <10° during curve) — moderate

_Penultimate/Takeoff errors:_
7. Over-reaching Penultimate (shin angle <90° at penultimate contact) — moderate
8. Extended Body Position (drive knee >120°) — major
9. Improper Takeoff Angle (lean <5° or >30°, plant leg <155°) — major
10. Takeoff Foot Misalignment (takeoff foot X-position too far from bar midpoint at plant; proxy for "jumping into the bar") — moderate _(Note: true lateral alignment requires a front or overhead view. This 2D proxy detects gross misalignment only. Tier 3 confidence — see Section 6.)_
11. Incomplete Knee Drive (trail leg not driven to ≤100°) — moderate
12. Too Close to Bar (takeoff distance <0.8m) — moderate
13. Too Far from Bar (takeoff distance >1.4m) — moderate
14. Long Ground Contact (contact time >0.19s) — minor

_Flight/clearance errors:_
15. Hammock Position (back tilt angle >160°, too flat) — major
16. Hip Collapse (hip angle <140° during flight) — major
17. Insufficient Rotation — moderate
18. Early Head Drop (nose drops faster than hips before bar crossing) — major
19. Late Leg Lift (legs trail and knock bar) — moderate
20. Arms Not Tucked (hands not at hips during clearance) — minor

_General:_
21. Bar Knock (body part crosses bar plane) — detected with body-part identification

**Coaching Recommendations:**
- Top 5 issues prioritized by severity
- Specific drills and cues for each error (positive cues — tell athletes what TO do, not what NOT to do)
- Frame references to jump to problem areas (links to exact phase/frame)
- Phase-specific focus: recommendation indicates which phase to review
- Positive feedback when no major errors detected
- Drill suggestions tied to specific errors (e.g., curve running drills for approach errors, penultimate pop-ups for takeoff errors)

### 11. Common Coaching Questions (Built-In Analysis)

The app proactively answers the questions coaches and athletes most frequently ask, surfaced contextually based on the jump data:

| Question | How We Answer It | Phase |
|----------|-----------------|-------|
| "Am I fast enough on approach?" | Compare approach speed to ideal ranges; show speed progression graph across final steps | Approach |
| "Is my curve the right shape?" | Overlay detected curve path on aerial view; measure radius and approach angle | Approach |
| "Am I leaning enough into the curve?" | Measure inward body lean angle during curve phase | Approach |
| "Where exactly should I take off?" | Show takeoff distance from bar; overlay optimal zone on video | Takeoff |
| "Is my takeoff leg straight enough?" | Measure knee angle at plant and toe-off; compare to 160-175° ideal | Takeoff |
| "Am I driving my knee hard enough?" | Measure drive knee angle and trail leg thigh velocity | Takeoff |
| "Why do I keep falling on the bar?" | Analyze curve quality — falling on bar is almost always a curve problem, not a takeoff distance problem | Takeoff/Approach |
| "Am I getting full extension?" | Check full-body extension at toe-off (ankles, knees, hips, arms) | Takeoff |
| "Is my arch good enough?" | Measure back tilt angle at peak (approximation — see measurement notes); compare hip elevation to bar height | Flight |
| "Why do my legs knock the bar?" | Detect late leg lift; check head drop timing (early head drop pulls legs into bar) | Flight |
| "Am I peaking at the right spot?" | Show peak CM position relative to bar; should be directly over | Flight |
| "How much am I clearing by?" | Clearance profile showing each body part's distance from bar at crossing; identify the limiter | Flight |
| "What's knocking the bar off?" | If knocked: identify body part, frame, and root cause (early head drop → legs drop, insufficient arch → hips sag, late leg lift) | Flight |
| "How tall am I jumping relative to my height?" | Compare bar height to estimated athlete height; show H1+H2+H3 decomposition | All |
| "Is my approach consistent?" | Compare step count, timing, and curve across multiple jumps (when available) | Approach |
| "What should I work on most?" | Prioritized error list with biggest performance-impact items first | All |

### 12. Takeoff Instant View (Hero Screen)

This is the **first thing shown after analysis completes**. The takeoff is where the jump is won or lost — coaches and biomechanics research agree that 90% of coaching value is in the ground phases. This screen gives instant, visual answers to the most important questions.

**Layout:**

```
┌─────────────────────────────────────────────────┐
│  ┌──────────────┐   ┌──────────────┐            │
│  │  Plant Frame  │   │  Toe-off Frame│           │
│  │  (skeleton +  │   │  (skeleton +  │           │
│  │   angles)     │   │   angles)     │           │
│  └──────────────┘   └──────────────┘            │
│                                                  │
│  Takeoff Leg: LEFT ✓        Ground Contact: 0.17s│
│                                                  │
│  ┌────────────────────────────────────────────┐  │
│  │ Key Angles          Value    Ideal   Status │  │
│  │ Plant knee          168°    160-175°   ✓    │  │
│  │ Toe-off knee        172°     ~170°     ✓    │  │
│  │ Drive knee           85°    70-90°     ✓    │  │
│  │ Trail leg at TD     103°     ~100°     ✓    │  │
│  │ Takeoff angle        44°    40-48°     ✓    │  │
│  │ Hip-shoulder sep     38°     ~40°      ~    │  │
│  └────────────────────────────────────────────┘  │
│                                                  │
│  Takeoff distance from bar: 1.1m                 │
│  Vertical velocity: 4.5 m/s                      │
│  Speed conversion: 7.6 → 4.3 m/s (43% retained) │
│                                                  │
│  [View Full Phase Timeline]  [View All Errors]   │
└─────────────────────────────────────────────────┘
```

**Interactions on this screen:**
- Tap either frame thumbnail to expand it full-screen with zoom + skeleton overlay
- Scrub between the plant and toe-off frames with a mini-scrubber between the two thumbnails (shows the full takeoff sequence)
- Tap any metric row to jump to the frame where it was measured, with the relevant joint highlighted and zoomed
- Swipe left to see Peak Instant View (Section 14 — same layout concept but for flight phase)
- Swipe right to see Approach Summary (Section 13 — speed graph, step rhythm, curve quality)

**Why this is the hero screen:**
- Coaches overwhelmingly report takeoff is what they review first and most often
- The plant-to-toe-off comparison is the single most informative visual in high jump coaching
- Surfacing the 6-8 most important metrics immediately (no drilling into menus) makes the app feel instant and expert

### 13. Approach Summary View

Accessed by swiping right from the Takeoff Instant View. Shows the approach phase with an emphasis on rhythm, speed, and curve quality.

**Layout:**
- **Speed progression graph**: horizontal bar chart or line graph showing approach speed at each of the final 5-8 steps. Ideal pattern: accelerating into the takeoff. Color-coded: green = accelerating, yellow = steady, red = decelerating.
- **Step rhythm strip**: visual strip showing step count, step length (heel-to-heel), and ground contact time per step. Highlights the penultimate step (longest) and final step (shortest).
- **Key metrics table:**
  - Approach speed (final 3 steps average)
  - Step count
  - Approach angle to bar (with confidence badge per Section 6)
  - Inward body lean
  - Penultimate step length vs final step length
  - FT:CT ratio (final steps)
- **Curve quality indicator**: simple "Good / Needs work / Poor" rating based on approach angle + lean + speed progression
- Tap any step in the rhythm strip to jump to that frame in the Video Frame Viewer
- Swipe left to return to Takeoff Instant View

### 14. Peak Instant View

Accessed by swiping left from the Takeoff Instant View. Shows the peak/flight phase with the same instant-feedback layout.

**Layout:**
- **Peak frame** with skeleton overlay + bar line overlay, zoomed to the athlete
- **Clearance profile diagram**: body silhouette showing each body part's clearance as it crosses the bar (head: +8cm, shoulders: +5cm, hips: +3cm, etc.). Color-coded: green = safe, yellow = close, red = contact/negative.
- **Key metrics table:**
  - Peak COM height (H3) with value and ideal
  - COM raise from takeoff (H2)
  - Back tilt angle at peak
  - Hip elevation over bar
  - Clearance over bar (minimum)
  - Limiter body part (part with least clearance)
  - Head/hand position
- **Bar status**: "CLEARED" (green) or "KNOCKED by [body part] at frame [N]" (red)
- Tap peak frame to expand full-screen with zoom + skeleton
- Swipe left to see Landing summary; swipe right to return to Takeoff Instant View

### 15. Results Display

- Jump outcome banner: "CLEARED" (green) or "KNOCKED" (red)
  - If knocked: "Bar knocked by left shin at frame 287" with tap-to-jump
- **Athlete summary**: "Estimated height: ~1.83m (6'0") — Bar: 1.78m" (confirm/edit)
- **Phase timeline bar** (color-coded by phase, tappable to jump to any phase)
  - Gray = no athlete | Blue = approach | Cyan = penultimate | Green = takeoff | Yellow = peak/flight | Orange = landing
  - Quick-jump buttons: "Takeoff" / "Peak" / "Landing" for instant navigation
- **Phase metric cards**: tap a phase on the timeline to see that phase's specific metrics
  - Each metric shows: value, ideal range, status indicator (good/marginal/poor)
  - Metrics grouped by category (angles, speed, position, timing)
- **Clearance profile diagram**: visual showing each body part's clearance as it crosses the bar
  - Body silhouette with color-coded clearance values (green = safe margin, yellow = close, red = contact/negative)
  - Identifies the "limiter" — the body part with least clearance
  - Tap any body part in the diagram to jump to the frame where it crosses the bar
- Error cards with severity badge, description, and "Go to Frame X" links
- Prioritized recommendations section with phase tags
- Coaching questions section: contextually answered based on this jump's data

### 16. Re-analysis & Undo

**Re-analysis triggers:**
- If the user changes person selection after analysis, a banner appears: "Tracking changed — results may be outdated. [Re-analyze]"
- If the user changes bar position or bar height, same banner
- Re-analysis re-runs only the affected computations (not pose detection, which is cached)
- Phase classification and all metrics recompute; results view updates in place

**Undo:**
- Undo stack for all user actions: person selection corrections, bar placement, bar height entry, takeoff leg toggle
- Standard iOS undo gesture (three-finger swipe left or shake)
- Undo banner appears at top: "Undid: Mark as No Athlete" with [Redo] button
- Undo does NOT affect pose detection (which is read-only cached data)

### 17. Error States & Empty States

| Scenario | Message | Action |
|----------|---------|--------|
| Zero people detected in any frame | "No people detected. Make sure the athlete is visible and well-lit." | Offer: re-import video, adjust and retry |
| Video too short (<1 second) | "Video is too short for analysis. Record at least 3-5 seconds covering the approach through landing." | Return to import |
| Video too long (>60 seconds) | "Long video detected. Trim to just the jump to speed up processing." | Show trim interface |
| Analysis fails (insufficient data) | "Could not complete analysis. Ensure the athlete is tracked in the takeoff and flight phases." | Highlight which phases are missing tracked frames |
| Bar not visible in video | "The bar must be visible in at least one frame. Try zooming out or using a different video." | Return to import; bar marking is required |
| Only partial jump captured | "Only [approach/takeoff/flight] phases detected. Some metrics require the full jump." | Show available metrics only; gray out unavailable ones |
| Pose detection lost during critical phase | "Athlete tracking lost during [takeoff]. Try a video with better visibility." | Show which frames lost tracking on timeline |
| Low-confidence analysis | "Some measurements have low confidence due to [partial visibility / low frame rate / camera angle]." | Show confidence indicators per metric |
| Source video deleted | "The original video is no longer available. Analysis results are preserved." | Show metrics/results read-only; disable frame viewer; offer "Re-link video" or "Delete session" |

### 18. Accessibility

- **VoiceOver**: all controls, buttons, phase timeline segments, and metric values are VoiceOver-accessible with descriptive labels
- **Dynamic Type**: all text scales with the user's preferred text size setting; metric cards and tables reflow for larger sizes
- **Color accessibility**: phase timeline colors are supplemented with pattern fills and text labels so phase identification does not rely on color alone (colorblind-safe)
- **Haptic feedback**: subtle haptic taps when scrubbing across phase boundaries; distinct haptic for phase transitions during playback
- **Reduced Motion**: if the user has Reduce Motion enabled, skip animations on phase transitions and timeline scrolling
- **Minimum touch targets**: all tappable elements are at least 44x44pt

---

## Architecture

### Data Flow

```
User Action → ViewModel → Service → Model → ViewModel → View Update
```

### Key Components

| Layer | Components |
|-------|-----------|
| Views | HomeView, SessionListView, OnboardingView, VideoImportView, VideoTrimView, CameraRecorderView, VideoAnalysisView, VideoFrameViewer (zoom/pan/scrub), AnalysisResultsView, SkeletonOverlayView, FrameScrubberView, AngleBadgeView, PhaseTimelineView, PhaseMetricCardView, ApproachSummaryView, TakeoffInstantView, PeakInstantView, ClearanceProfileView, CoachingQuestionsView, PersonSelectionOverlay, TrackingReviewView, CameraCalibrationView, ErrorStateView |
| ViewModels | PoseDetectionViewModel, VideoPlayerViewModel, VideoImportViewModel, AnalysisViewModel, TrackingViewModel |
| Services | PoseDetectionService, PersonTracker, AnalysisEngine, PhaseClassifier, TakeoffLegDetector, COMCalculator, VideoFrameExtractor, ThumbnailGenerator, BarDetectionService, BarTracker, GroundPlaneDetector, ScaleCalibrator, CameraAngleEstimator, UndoManager |
| Models | JumpSession, BodyPose, JumpPhase, FrameCategory, FrameAssignment, AnalysisResult, BarDetectionResult, BarKnockResult, ClearanceProfile, PhaseMetrics, CoachingInsight, ScaleCalibration, CameraCalibration, MetricConfidence |
| Persistence | JumpSessionStore (SwiftData/CoreData), SessionMigrator |
| Utilities | AngleCalculator, CoordinateConverter, HomographyCorrector, LoupeView, DeLeva1996Parameters, CGPoint+Extensions, Color+Theme, BarHeightParser |

### Coordinate Systems

- **MediaPipe BlazePose**: normalized 0-1, origin top-left (pose data)
- **View**: pixel-based, origin top-left (SwiftUI)
- **CoordinateConverter** handles all transformations including aspect ratio and letterboxing

### Concurrency

- Async/await for video processing
- Task.detached for CPU-intensive pose detection
- @MainActor for UI updates
- NSLock for thread-safe parallel frame collection

---

## Settings

- **Measurement units**: metric (meters, m/s) or imperial (feet/inches, mph) — affects all displayed values
- **Athlete sex**: male / female / not specified (default: not specified → uses male de Leva parameters for COM). Affects body segment mass fractions for COM calculation.
- **Skeleton overlay**: toggle on/off (default: on)
- **Angle badges**: toggle on/off (default: on) — show angle values at key joints during scrubbing
- **Show walkthrough**: replay the onboarding walkthrough
- **Clear all data**: delete all saved sessions and cached pose data
- Persisted via UserDefaults

---

## Dependencies

| Framework | Purpose |
|-----------|---------|
| SwiftUI | UI |
| AVFoundation | Video playback, metadata, frame extraction |
| CoreGraphics | Drawing, geometry |
| PhotosUI | Photo library picker |
| UIKit | Camera interface (UIViewControllerRepresentable) |
| MediaPipeTasksVision | Pose detection — BlazePose 33-landmark model (Swift Package or CocoaPods) |

---

## Known Limitations

- **BlazePose multi-person has known reliability issues**: `num_poses > 1` is supported but can exhibit landmark switching between frames, proximity-based detection drops (~50cm), and hallucinated landmarks on occlusion. The Person Tracking system (Section 4) mitigates switching; a fallback pipeline (Section 2) handles persistent failures.
- **Back tilt angle is an approximation**: computed from neck-to-hip line, not true spinal curvature. Underestimates actual arch. True back arch measurement requires spine landmarks (RTMPose 133pt — see Future Considerations).
- **All measurements are 2D projections**: camera angle affects accuracy. Side-view perpendicular to the bar is assumed. Angled views cause foreshortening in distance measurements.
- **Hip-shoulder separation has reduced accuracy from pure side-view**: rotation between hips and shoulders occurs partly in the depth axis (toward/away from camera), which a single side-view camera cannot capture.
- Real-world distance measurements require user-provided bar height for scale calibration.
- Best results from side-view (perpendicular to bar) at a distance that captures full approach + bar + mat.
- Occlusion from mat, equipment, or officials can interrupt tracking.
- Lighting/contrast affects joint detection quality.
- 240fps video produces 4x the frames of 60fps — processing time scales linearly with frame count.

---

## Competitive Landscape

| App | Strengths | Gaps (vs Jump) |
|-----|-----------|----------------|
| **Dartfish** | Industry standard; SimulCam overlay, Stromotion, multi-view sync; used by Olympic coaches | General-purpose (not high-jump-specific); expensive licensing; no automatic phase detection or coaching recommendations; manual annotation only |
| **Onform** | 240fps recording, 5 capture modes, voice-over annotations, coach-athlete messaging, side-by-side comparison | General video analysis — no pose detection, no automatic measurements, no high-jump-specific metrics or error detection |
| **Athletics 3D** | Interactive 3D animations for all events, technique tips and common faults with corrections, compare own video against 3D model | Educational reference tool; no automatic video analysis, no pose detection, no measurement extraction |
| **My Jump Lab** | Scientifically validated (>500 citations), AI real-time jump detection, 30+ test types, force-velocity profiling, offline-first | Focused on vertical jump testing (CMJ, SJ, DJ), not Fosbury Flop technique analysis; no approach/curve analysis; no bar clearance metrics; no coaching recommendations |
| **VueMotion** | AI-powered movement profiling, normative data comparison, 80,000+ athletes tested | Broad sports platform; no high-jump-specific phase detection or error identification; not focused on Fosbury Flop mechanics |
| **Athlete Analyzer** | Training plan integration, frame-by-frame review, team management | General coaching platform; no automatic pose detection or biomechanical measurement |
| **TrackBoss** | Results integration with video, overlay comparisons | Event management focused; video analysis is supplementary feature |
| **Quintic Sports** | Biomechanics research-grade, COM analysis | Desktop software; expensive; academic-oriented; no mobile experience |

**Jump's differentiators:**
- Only app that automatically detects high jump phases (approach → penultimate → takeoff → peak → landing)
- Automatic pose detection with per-frame skeleton tracking
- Phase-specific biomechanical metrics with ideal-range comparison
- Automated error detection with severity ranking and coaching cues
- Frame marking and quick-jump navigation to key moments
- Contextual coaching questions answered from the data
- Mobile-first, single-session workflow (video to feedback in 3-5 minutes)

---

## Future Considerations

_Use this section to track planned features, improvements, or ideas._

- [ ] Export & share: screenshot of Takeoff Instant View with metrics, PDF report (full analysis summary), video clip with skeleton overlay, share sheet integration
- [ ] Comparison between jumps (side-by-side or overlay with SimulCam-style sync)
- [ ] Cloud sync / sharing
- [ ] Coach/athlete collaboration features (annotated video sharing, voice-over feedback)
- [ ] Additional sport support
- [ ] Improvement tracking over time (trend charts across sessions)
- [ ] Approach speed graph overlay (speed curve across final steps)
- [ ] Curve path visualization (bird's-eye overlay of detected J-curve)
- [ ] Normative data comparison (compare metrics to age/level benchmarks)
- [ ] Multi-angle sync (front + side camera alignment)
- [ ] Force-velocity profiling integration
- [ ] **RTMPose / RTMW 133-keypoint model**: adds thorax, spine, and detailed foot landmarks for true back arch measurement and more precise body mechanics. ~75% AP accuracy vs ~65% for BlazePose. Requires ONNX → CoreML conversion engineering. Would replace BlazePose as the primary engine.
