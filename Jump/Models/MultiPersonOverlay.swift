import SwiftUI

import SwiftUI

// MARK: - All People Review Overlay (Read-only, shows all detections)

/// Shows ALL detected people in the current frame with numbered labels
/// Used for reviewing detection quality before proceeding to tracking
/// The tracked athlete is highlighted in green, others in distinct colors
struct AllPeopleReviewOverlay: View {
    let allPoses: [BodyPose]
    let trackedPersonIndex: Int?  // Index of the athlete being tracked (nil if none)
    let viewSize: CGSize
    let offset: CGPoint
    var onSelectPerson: ((BodyPose) -> Void)? = nil  // Optional tap handler
    
    var body: some View {
        ZStack {
            ForEach(allPoses.indices, id: \.self) { index in
                let isTracked = index == trackedPersonIndex
                
                // Draw skeleton with distinct color
                SkeletonView(
                    pose: allPoses[index],
                    viewSize: viewSize,
                    offset: offset,
                    color: colorForPerson(index, isTracked: isTracked),
                    lineWidth: isTracked ? 3.5 : 2.5,
                    opacity: isTracked ? 1.0 : 0.7
                )
                
                // Number badge above head
                if let headPoint = allPoses[index].jointPoint(.nose) ?? allPoses[index].jointPoint(.neck) {
                    let viewPoint = CoordinateConverter.visionToView(
                        point: headPoint,
                        viewSize: viewSize,
                        offset: offset
                    )
                    
                    ReviewPersonBadge(
                        number: index + 1,
                        color: colorForPerson(index, isTracked: isTracked),
                        isTracked: isTracked
                    )
                    .frame(width: 60, height: 60) // Larger tap target
                    .contentShape(Rectangle()) // Make entire frame tappable
                    .onTapGesture {
                        print("🎯 Badge tapped for person \(index + 1)")
                        // Only handle taps if we have a handler
                        if let handler = onSelectPerson {
                            handler(allPoses[index])
                        }
                    }
                    .position(x: viewPoint.x, y: viewPoint.y - 40)
                }
            }
        }
        .allowsHitTesting(onSelectPerson != nil) // Allow taps only if handler is provided
    }
    
    private func colorForPerson(_ index: Int, isTracked: Bool) -> Color {
        if isTracked {
            return .green  // Tracked athlete is always green
        }
        
        let colors: [Color] = [.cyan, .yellow, .pink, .orange, .purple, .mint, .blue]
        return colors[index % colors.count]
    }
}

// MARK: - Review Person Badge

struct ReviewPersonBadge: View {
    let number: Int
    let color: Color
    let isTracked: Bool
    
    var body: some View {
        ZStack {
            // Outer pulse ring when tracked
            if isTracked {
                Circle()
                    .stroke(color, lineWidth: 3)
                    .frame(width: 40, height: 40)
                    .scaleEffect(1.5)
                    .opacity(0.6)
                    .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: isTracked)
            }
            
            // Main badge
            Text("\(number)")
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill(color)
                        .shadow(color: .black.opacity(0.4), radius: 5, x: 0, y: 2)
                )
                .overlay(
                    Circle()
                        .stroke(.white, lineWidth: isTracked ? 3 : 2.5)
                )
            
            // Checkmark overlay for tracked athlete
            if isTracked {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .background(Circle().fill(color).frame(width: 12, height: 12))
                    .offset(x: 12, y: -12)
            }
        }
        .animation(.spring(response: 0.3), value: isTracked)
        // Make sure frame is set in parent, not here
    }
}

// MARK: - Multi-Person Skeleton Overlay

/// Shows ALL detected skeletons with color-coding and tap-to-select
struct MultiPersonOverlay: View {
    let allPoses: [BodyPose]
    let trackedIndex: Int?
    let viewSize: CGSize
    let offset: CGPoint
    let onSelectPose: (Int) -> Void
    
    var body: some View {
        ZStack {
            ForEach(allPoses.indices, id: \.self) { index in
                let isTracked = index == trackedIndex
                
                // Draw skeleton
                SkeletonView(
                    pose: allPoses[index],
                    viewSize: viewSize,
                    offset: offset,
                    color: skeletonColor(for: index, isTracked: isTracked),
                    lineWidth: isTracked ? 3 : 2,
                    opacity: isTracked ? 1.0 : 0.5
                )
                
                // Number badge above head
                if let headPoint = allPoses[index].jointPoint(.nose) ?? allPoses[index].jointPoint(.neck) {
                    PersonBadge(
                        number: index + 1,
                        isSelected: isTracked,
                        color: skeletonColor(for: index, isTracked: isTracked)
                    )
                    .position(
                        CoordinateConverter.visionToView(
                            point: headPoint,
                            viewSize: viewSize,
                            offset: offset
                        )
                    )
                    .offset(y: -40) // Above head
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3)) {
                            onSelectPose(index)
                        }
                    }
                }
            }
        }
    }
    
    private func skeletonColor(for index: Int, isTracked: Bool) -> Color {
        if isTracked { return .cyan }
        
        let colors: [Color] = [.yellow, .pink, .orange, .purple, .mint]
        return colors[index % colors.count]
    }
}

// MARK: - Person Badge

struct PersonBadge: View {
    let number: Int
    let isSelected: Bool
    let color: Color
    
    var body: some View {
        ZStack {
            // Outer pulse ring when selected
            if isSelected {
                Circle()
                    .stroke(color, lineWidth: 2)
                    .frame(width: 36, height: 36)
                    .scaleEffect(1.5)
                    .opacity(0.5)
            }
            
            // Main badge
            Text("\(number)")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(color)
                        .shadow(color: .black.opacity(0.3), radius: 4)
                )
                .overlay(
                    Circle()
                        .stroke(.white, lineWidth: isSelected ? 2 : 0)
                )
        }
        .animation(.spring(response: 0.3), value: isSelected)
    }
}

// MARK: - Skeleton View (Individual Skeleton Drawing)

struct SkeletonView: View {
    let pose: BodyPose
    let viewSize: CGSize
    let offset: CGPoint
    let color: Color
    let lineWidth: CGFloat
    let opacity: Double
    
    var body: some View {
        Canvas { context, size in
            // Draw bones
            for connection in BodyPose.boneConnections {
                guard let startJoint = pose.joints[connection.from],
                      let endJoint = pose.joints[connection.to],
                      startJoint.confidence > 0.3,
                      endJoint.confidence > 0.3 else { continue }
                
                let start = CoordinateConverter.visionToView(
                    point: startJoint.point,
                    viewSize: viewSize,
                    offset: offset
                )
                let end = CoordinateConverter.visionToView(
                    point: endJoint.point,
                    viewSize: viewSize,
                    offset: offset
                )
                
                var path = Path()
                path.move(to: start)
                path.addLine(to: end)
                
                context.stroke(
                    path,
                    with: .color(color.opacity(opacity)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
            }
            
            // Draw joints
            for joint in pose.joints.values where joint.confidence > 0.3 {
                let point = CoordinateConverter.visionToView(
                    point: joint.point,
                    viewSize: viewSize,
                    offset: offset
                )
                
                let circleRect = CGRect(
                    x: point.x - 4,
                    y: point.y - 4,
                    width: 8,
                    height: 8
                )
                
                context.fill(
                    Circle().path(in: circleRect),
                    with: .color(color.opacity(opacity))
                )
            }
        }
    }
}

// MARK: - Tracking Confidence HUD

struct TrackingConfidenceHUD: View {
    let confidence: Double
    let detectedCount: Int
    let isTracking: Bool
    
    var confidenceColor: Color {
        switch confidence {
        case 0.9...1.0: return .green
        case 0.7..<0.9: return .yellow
        case 0.5..<0.7: return .orange
        default: return .red
        }
    }
    
    var confidenceText: String {
        switch confidence {
        case 0.9...1.0: return "Locked"
        case 0.7..<0.9: return "Tracking"
        case 0.5..<0.7: return "Uncertain"
        default: return "Lost"
        }
    }
    
    var body: some View {
        VStack {
            HStack {
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    // Main confidence indicator
                    HStack(spacing: 6) {
                        Circle()
                            .fill(confidenceColor)
                            .frame(width: 8, height: 8)
                            .shadow(color: confidenceColor, radius: 4)
                        
                        Text(confidenceText)
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    
                    // People count (if multiple)
                    if detectedCount > 1 {
                        HStack(spacing: 4) {
                            Image(systemName: "person.2.fill")
                                .font(.caption2)
                            Text("\(detectedCount)")
                                .font(.caption2.bold())
                        }
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.6))
                        .clipShape(Capsule())
                    }
                }
                .padding(.trailing, 16)
                .padding(.top, 16)
            }
            Spacer()
        }
    }
}

// MARK: - Enhanced Selection Confirmation Bar with 3 Annotation Types

struct SelectionConfirmationBar: View {
    let selectedCount: Int
    let hasDetections: Bool
    let onConfirm: () -> Void
    let onShowThumbnails: () -> Void
    let onNoAthlete: () -> Void  // NEW: Mark frame as "no athlete"
    let onCancel: () -> Void
    
    var body: some View {
        VStack(spacing: 8) {
            // Instruction text
            HStack(spacing: 8) {
                Image(systemName: "hand.tap.fill")
                    .foregroundStyle(.cyan)
                
                if selectedCount > 0 {
                    Text("\(selectedCount) annotation\(selectedCount == 1 ? "" : "s")")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Select athlete")
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                        Text(hasDetections ? "Tap skeleton OR tap background if no skeleton" : "No poses detected")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                
                Spacer()
            }
            
            // Action buttons
            HStack(spacing: 8) {
                // "No Athlete" button - marks frame as athlete not present
                Button {
                    onNoAthlete()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "person.slash")
                            .font(.caption)
                        Text("No Athlete")
                            .font(.caption.bold())
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.8))
                    .clipShape(Capsule())
                }
                
                if selectedCount > 0 {
                    // Show thumbnails
                    Button("Thumbnails") {
                        onShowThumbnails()
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    
                    Spacer()
                    
                    // Confirm
                    Button {
                        onConfirm()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Confirm")
                                .font(.subheadline.bold())
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.green)
                        .clipShape(Capsule())
                    }
                } else {
                    Spacer()
                    
                    // Cancel
                    Button("Cancel") {
                        onCancel()
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
    }
}
