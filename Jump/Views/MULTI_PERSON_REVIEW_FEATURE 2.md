# Multi-Person Detection Display - Simplified

## Overview

After selecting a video for analysis, all detected people across all frames are automatically displayed with numbered badges above their heads. This provides immediate visibility into the pose detection results without any additional user interaction required.

## Implementation

### Workflow:
1. **Select Video** → User selects a video for analysis
2. **Auto-Detection** → Pose detection runs automatically and detects all people in all frames
3. **Display All People** → ALL detected skeletons shown with numbers in every frame
4. **Scrub to Review** → User can scrub through video to verify detection quality

### Key Features:
- **Automatic**: Pose detection starts immediately when video loads
- **All People Shown**: Every detected person is displayed with distinct colors and numbers
- **Minimal UI**: Only video player and scrubber - no buttons or controls
- **Numbered Badges**: Large, visible numbers above each person's head for easy identification

## Implementation Details

### VideoAnalysisView

**Simplified Structure:**
- Video display (70% of screen height)
- Frame scrubber only
- No control buttons
- No workflow hints
- No interaction/gestures

**Auto-detection:**
```swift
.task {
    await playerVM.loadVideo(url: session.videoURL, session: session)
    // Auto-start pose detection
    await poseVM.processVideo(url: session.videoURL, session: session)
}
```

**Always Show All People:**
```swift
.overlay {
    let allPoses = poseVM.getAllPosesAtFrame(playerVM.currentFrameIndex)
    if !allPoses.isEmpty && poseVM.hasDetected {
        AllPeopleReviewOverlay(
            allPoses: allPoses,
            viewSize: fittedVideoSize(in: geo.size),
            offset: fittedVideoOffset(in: geo.size)
        )
    }
}
```

### AllPeopleReviewOverlay

**Read-only overlay showing all detected people:**
- Distinct colors for each person (cycles through: cyan, yellow, pink, orange, purple, mint, green, blue)
- Numbered badge above each person's head
- No tap handling - purely visual
- Semi-transparent skeletons (85% opacity)

### PoseDetectionViewModel

**No Changes Required:**
- Uses existing `getAllPosesAtFrame()` method
- `storedObservations` contains all raw detections
- No special review mode state needed

## User Experience

### What The User Sees:
1. Select video from library
2. Processing overlay appears ("Detecting poses...")
3. Once complete, video shows with ALL people visible
4. Each person has:
   - Colored skeleton overlay
   - Large numbered badge above their head
5. User scrubs through video to review
6. Can verify:
   - Are all people being detected?
   - Are there frames where detection fails?
   - How many people are in each frame?

### Visual Design:
- **Person 1**: Cyan skeleton + badge #1
- **Person 2**: Yellow skeleton + badge #2  
- **Person 3**: Pink skeleton + badge #3
- **Person 4**: Orange skeleton + badge #4
- (continues cycling through 8 colors)

### Badge Design:
- White number on colored circle
- Large (32x32 pt)
- Bold rounded font
- White stroke for contrast
- Drop shadow for visibility
- Positioned 40pt above person's head

## Benefits

1. **Immediate Feedback**: User sees detection results instantly
2. **Quality Verification**: Easy to spot missing or incorrect detections
3. **Multi-Person Awareness**: Clear visibility when multiple people are in frame
4. **Simplicity**: No complex workflows or button presses needed
5. **Transparency**: Complete visibility into what the system detected

## Code Removed

The following features were removed to simplify:
- Person selection workflow
- Bar marking
- Analysis controls
- Workflow hints
- Control buttons (Person/Bar/Analyze)
- Frame info bar
- Gesture handling (zoom/pan/tap)
- Review mode state management
- Decision points
- Uncertain frame navigation
- Thumbnail sheets
- Bar height input
- All interaction overlays and banners

## File Changes

### Modified Files:
1. **VideoAnalysisView.swift** - Simplified to minimal view with auto-detection
2. **MultiPersonOverlay.swift** - Added `AllPeopleReviewOverlay` component

### Unchanged Files:
- **PoseDetectionViewModel.swift** - Uses existing methods, no changes needed
- **BodyPose.swift** - No changes
- **SkeletonOverlayView.swift** - Not used anymore but could be removed

## Total Lines of Code

**Before**: ~1000+ lines  
**After**: ~130 lines

Over 85% reduction in code complexity while maintaining core functionality of showing all detected people.
