# Multi-Person Review Feature

## Overview

This feature allows users to review all detected people across all frames after pose detection completes, before proceeding to automatic tracking. Each person is displayed with a numbered badge above their head for easy identification.

## Workflow Changes

### New Flow:
1. **Select Video** → User selects a video for analysis
2. **Pose Detection** → System detects all people in all frames
3. **🆕 Review All People** → User can scrub through video to see all detected people with numbers
4. **Continue to Tracking** → User proceeds to automatic tracking when ready
5. **Person Selection** → (existing flow continues)
6. **Bar Marking** → (existing flow continues)
7. **Analysis** → (existing flow continues)

## Key Components

### PoseDetectionViewModel Changes

#### New Properties:
- `isReviewingAllPeople: Bool` - Tracks whether the user is in review mode
- `DetectionStatistics` struct - Provides summary statistics about detections

#### New Methods:
- `finishReviewingAllPeople()` - Exits review mode and runs auto-tracking
- `getDetectionStatistics()` - Returns statistics about detected people across frames

#### Modified Methods:
- `processVideo(url:session:)` - Now enters review mode instead of immediately running auto-tracking

### VideoAnalysisView Changes

#### New UI Components:
- **Review Mode Card** - Displays detection statistics and "Continue to Tracking" button
- Shows:
  - Detection coverage percentage
  - Multi-person frame count
  - Total frame count
  - Helpful description

#### Updated Components:
- **Skeleton Overlay** - Now checks for `isReviewingAllPeople` mode
- **Control Buttons** - Disabled during review mode
- **Workflow Hint** - Shows review card when in review mode

### MultiPersonOverlay.swift Changes

#### New Components:
- `AllPeopleReviewOverlay` - Read-only overlay showing all detected people with numbers
- `ReviewPersonBadge` - Numbered badge for each person (larger and more visible than selection badges)

## User Experience

### Review Mode Display:
- **Skeletons**: All detected people shown with distinct colors
  - Person 1: Cyan
  - Person 2: Yellow
  - Person 3: Pink
  - Person 4: Orange
  - Person 5: Purple
  - Person 6: Mint
  - (cycles through colors)
- **Number Badges**: Large numbered badges above each person's head
- **Read-only**: No interaction - just visual review

### Statistics Shown:
- **Detection Coverage**: Percentage of frames with at least one person detected
- **Multi-person Frames**: Count of frames with multiple people
- **Total Frames**: Total number of frames processed

### Review Process:
1. User scrubs through video using frame scrubber
2. Each frame shows all detected people with numbers
3. User can visually confirm:
   - Are all people being detected?
   - Are there frames where people are missing?
   - Is multi-person detection working correctly?
4. When satisfied, user taps "Continue to Tracking"

## Technical Details

### Detection Statistics Structure:
```swift
struct DetectionStatistics {
    let totalFrames: Int
    let framesWithNoPeople: Int
    let framesWithOnePerson: Int
    let framesWithMultiplePeople: Int
    let maxPeopleInFrame: Int
    
    var hasMultipleDetections: Bool
    var detectionCoveragePercent: Double
}
```

### State Flow:
```
processVideo() 
  ↓
storedObservations populated
  ↓
isReviewingAllPeople = true
  ↓
[User reviews]
  ↓
finishReviewingAllPeople()
  ↓
isReviewingAllPeople = false
  ↓
Auto-tracking runs
  ↓
[Normal workflow continues]
```

## Benefits

1. **Quality Assurance**: Users can verify detection quality before proceeding
2. **Transparency**: Clear visibility into what the system detected
3. **Confidence**: Users know if anyone is missing before tracking begins
4. **Multi-person Awareness**: Easy to spot frames with multiple people that may need attention

## Future Enhancements

Possible improvements for future versions:
- Jump to frames with missing detections
- Jump to frames with multiple people
- Export detection report
- Manual annotation during review (add missing people)
- Filter frames by detection count
