# 🚀 Quick Start Guide - New Person Selection Interface

## What Changed?

Your app now has a **much faster and more intuitive** person selection interface!

### Old Way (Slow) ❌
1. Tap "Person" button
2. Wait for modal sheet to appear
3. Scroll through list
4. Tap thumbnail
5. Sheet dismisses
6. Check if it worked

### New Way (Fast) ✅
1. Tap "Person" button
2. **All skeletons appear on video** with different colors
3. **Tap the athlete's skeleton** directly
4. Done! ⚡

---

## 🎮 How to Use

### Basic Selection (First Time)

1. **Import a video** with your high jump attempt
2. **Tap the "Person" button** (person icon in controls)
3. **See all skeletons** appear on the video with:
   - 🟦 **Cyan** = Currently tracked (or the one you select)
   - 🟡 **Yellow** = Other person #1
   - 🟣 **Pink** = Other person #2
   - 🟠 **Orange** = Other person #3
4. **Tap directly on the athlete's skeleton** (any bone or joint)
   - OR tap the **numbered badge** above their head
5. **Tap "Confirm"** in the bottom bar
6. **Done!** Tracking begins

### Quick Correction (While Watching)

If tracking switches to the wrong person:

1. **Tap "Person" button** (anytime, even while playing)
2. **All skeletons appear again**
3. **Tap the correct athlete's skeleton**
4. **No need to confirm** - just tap and move on!

### Using Thumbnails (For Close-Up Comparison)

If skeletons overlap or you want a clearer view:

1. While in selection mode, **tap "Thumbnails"** in bottom bar
2. **Horizontal carousel appears** with large images
3. **Tap the athlete's card**
4. Sheet closes automatically

### Marking "No Athlete"

When athlete is off-camera:

1. **Tap "Thumbnails"** in selection mode
2. **Tap the orange "Not Here" card**
3. Frame is marked as athlete absent

---

## 🎯 Visual Guide

### Selection Mode (All Skeletons Visible)

```
┌─────────────────────────────────────┐
│                    [🟢 Locked]  [?] │ ← Confidence HUD
│                                     │
│   ①🟡        ②🟦         ③🟠       │ ← Tap any skeleton
│   ╱▏         ╱▏          ╱▏        │   or number badge
│  ╱ ▏        ╱ ▏         ╱ ▏        │
│ Coach     ATHLETE     Official     │
│                                     │
├─────────────────────────────────────┤
│ 👆 Tap a skeleton     [Thumbnails] │ ← Bottom bar
│    1 mark              [✓ Confirm] │
└─────────────────────────────────────┘
```

### Thumbnail Mode (Carousel View)

```
┌─────────────────────────────────────┐
│ 👆 Tap the athlete         Cancel   │
├─────────────────────────────────────┤
│                                     │
│  ┌─────┐  ┌─────┐  ┌─────┐  ┌────┐│
│  │  ①  │  │  ②  │  │  ③  │  │ ⊗  ││ ← Scroll horizontal
│  │ 👤  │  │ 👤  │  │ 👤  │  │Not ││   Tap to select
│  │     │  │  ✓  │  │     │  │Here││
│  └─────┘  └─────┘  └─────┘  └────┘│
│   Left    Center   Right    None  │
└─────────────────────────────────────┘
```

### Tracking with Confidence HUD

```
┌─────────────────────────────────────┐
│                    [🟡 Tracking]    │ ← Real-time feedback
│                    [2 people]       │   Green/Yellow/Orange/Red
│                                     │
│        🟦 Athlete skeleton          │
│        ╱▏                           │
│       ╱ ▏                           │
│                                     │
│                                     │
│ Frame 142 / 245          Flight    │
└─────────────────────────────────────┘
```

---

## 🎨 Color Guide

### Skeleton Colors
- 🟦 **Cyan** - The athlete you're tracking (bright, thick lines)
- 🟡 **Yellow** - Other person #1 (dimmed, thinner lines)
- 🟣 **Pink** - Other person #2 (dimmed, thinner lines)
- 🟠 **Orange** - Other person #3 (dimmed, thinner lines)
- 🟣 **Purple** - Other person #4 (dimmed, thinner lines)

### Confidence Indicator
- 🟢 **Green "Locked"** (90-100%) - Perfect tracking
- 🟡 **Yellow "Tracking"** (70-89%) - Good tracking
- 🟠 **Orange "Uncertain"** (50-69%) - May need review
- 🔴 **Red "Lost"** (<50%) - Tracking failed, please correct

---

## 💡 Pro Tips

### Tip 1: Speed Selection
**Don't wait for thumbnails!** Just tap the skeleton directly. It's way faster.

### Tip 2: Use Number Badges
If skeletons overlap, tap the **number badge above the head** instead of the skeleton itself.

### Tip 3: Watch the Confidence HUD
Keep an eye on the top-right corner. If it turns orange or red:
- Scrub to that frame
- Tap "Person" button
- Tap the correct skeleton

### Tip 4: Multiple Corrections
You don't need to confirm after every tap! When in selection mode:
1. Scrub to frame 50, tap athlete
2. Scrub to frame 100, tap athlete again
3. Scrub to frame 150, tap athlete again
4. **Then** tap "Confirm" once

The system will use all your annotations to improve tracking across the whole video.

### Tip 5: Bar Crossing Issues
During bar crossing, the athlete's body orientation changes dramatically. If tracking gets confused:
1. Scrub to a frame right before the bar
2. Add an annotation (tap athlete skeleton)
3. Scrub to a frame right after the bar
4. Add another annotation
5. This helps tracking "bridge" the occlusion

### Tip 6: Landing Mat Crowds
When the athlete lands and multiple people surround the mat:
1. Mark the last frame where you clearly see the athlete
2. For frames after that, either:
   - Use "Thumbnails" → "Not Here" (if athlete off-camera)
   - Or tap the correct skeleton if athlete is still visible but surrounded

---

## 🐛 Troubleshooting

### Problem: "No skeletons appear when I tap Person button"

**Solution:**
- Make sure pose detection has completed (wait for progress bar)
- Scrub to a frame where people are clearly visible
- Try a different frame if the current one has no detections

### Problem: "All skeletons are the same color"

**Solution:**
- You're not in selection mode
- Tap the "Person" button to enter selection mode
- Skeletons should become colored (cyan, yellow, pink, etc.)

### Problem: "I can't tap the skeleton - it's too small"

**Solution:**
- Tap the **number badge above the person's head** instead
- Or tap "Thumbnails" to see large side-by-side cards

### Problem: "Tracking keeps switching back to wrong person"

**Solution:**
- Add more annotations throughout the video:
  1. Enter selection mode
  2. Scrub through video, tap athlete on 5-10 different frames
  3. Include frames at beginning, middle, and end
  4. Confirm when done
- The more annotations, the better the tracking!

### Problem: "Confidence HUD always shows red"

**Solution:**
- Some frames may genuinely have poor detection (mid-jump, blur, etc.)
- Mark those frames as "No Athlete" if the athlete isn't clearly visible
- The system will interpolate across short gaps

---

## 📊 When to Use Each Method

### Use **Tap Skeleton** (Fastest) When:
✅ Multiple people clearly visible  
✅ Skeletons don't overlap much  
✅ You can see which one is the athlete  
✅ Making quick corrections during playback

### Use **Thumbnails** (Most Detailed) When:
✅ Skeletons heavily overlap  
✅ You want side-by-side comparison  
✅ First time selecting on a crowded frame  
✅ Need to see full body position for context

### Use **"Not Here"** When:
✅ Athlete is off-camera  
✅ Athlete is fully occluded (behind mat, behind officials)  
✅ Pre-jump setup frames (athlete not in approach yet)  
✅ Post-landing frames (athlete already walked away)

---

## 🎬 Example Workflow: Full High Jump Analysis

1. **Import video** of high jump attempt (30 seconds, 900 frames)

2. **Initial selection:**
   - Scrub to frame 100 (clear view during approach)
   - Tap "Person" button
   - See 3 skeletons (athlete + 2 officials)
   - Tap athlete's cyan skeleton
   - Tap "Confirm"

3. **Watch auto-tracking:**
   - Confidence HUD shows green "Locked"
   - Scrub through video to check tracking
   - Notice at frame 450 (bar crossing) it switches to official

4. **Correct the error:**
   - Scrub to frame 450
   - Tap "Person" button
   - All 3 skeletons appear again
   - Tap the correct athlete skeleton
   - Don't need to confirm, just move on

5. **Add more annotations:**
   - Scrub to frame 250 (mid-approach) - tap athlete
   - Scrub to frame 400 (pre-takeoff) - tap athlete
   - Scrub to frame 500 (in-flight) - tap athlete
   - Scrub to frame 600 (landing) - tap athlete
   - Tap "Confirm"

6. **Mark bar:**
   - Tap "Bar" button
   - Pinch to zoom
   - Tap both ends of bar
   - Confirm
   - Enter bar height

7. **Analyze:**
   - Tap "Analyze" button
   - Get technique feedback!

**Total time: ~2 minutes** (vs 5-10 minutes with old interface!)

---

## ✅ Key Takeaways

1. **Tap skeletons directly** - Don't default to thumbnails, they're slower
2. **Watch the confidence HUD** - It tells you when to intervene
3. **Add multiple annotations** - 5-10 taps across the video = rock-solid tracking
4. **Use colors to distinguish** - Cyan = athlete, Yellow/Pink = others
5. **No need to confirm every time** - Batch your selections, then confirm once

**You now have one of the fastest and most intuitive sports analysis interfaces available!** 🚀

Enjoy analyzing those high jumps! 🏃‍♂️🔝
