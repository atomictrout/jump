import SwiftUI

/// Bottom sheet for selecting which person is the athlete
struct PersonSelectionSheet: View {
    let detectedPeople: [PersonThumbnailGenerator.DetectedPerson]
    let reason: SmartTrackingEngine.DecisionPoint.Reason
    let onSelect: (PersonThumbnailGenerator.DetectedPerson?) -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    var reasonText: String {
        switch reason {
        case .initialSelection: return "Select the athlete to track"
        case .newPersonEntered: return "New person entered frame. Which is the athlete?"
        case .multipleOverlapping: return "People overlapping. Confirm athlete selection"
        case .lowTrackingConfidence: return "Tracking uncertain. Verify correct person"
        case .athleteLeftFrame: return "Athlete may have left. Is this person the athlete?"
        }
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: iconFor(reason))
                        .font(.title3)
                        .foregroundStyle(.blue)
                    Text(reasonText)
                        .font(.subheadline)
                    Spacer()
                }
                .padding()
                .background(Color.blue.opacity(0.1))
                
                if detectedPeople.isEmpty {
                    emptyState
                } else {
                    List {
                        // Helpful hint when only one person detected
                        if detectedPeople.count == 1 {
                            Section {
                                HStack(spacing: 8) {
                                    Image(systemName: "info.circle.fill")
                                        .foregroundStyle(.blue)
                                    Text("Only one person detected. If this isn't the athlete, select \"Athlete not detected\" below.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        
                        Section {
                            Text("Tap a person to select them as the athlete. Use \"Show Full Frame\" to see their position in context.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } header: {
                            Text("Select the Athlete (\(detectedPeople.count) detected)")
                        }
                        
                        Section {
                            ForEach(detectedPeople) { person in
                                PersonRow(person: person) {
                                    onSelect(person)
                                    dismiss()
                                }
                            }
                        }
                        
                        Section {
                            Button {
                                onSelect(nil)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "person.crop.circle.badge.xmark")
                                        .foregroundStyle(.orange)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Athlete not detected")
                                            .font(.body)
                                        Text("Skip this frame - athlete not visible")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.right")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                        } footer: {
                            if detectedPeople.count == 1 {
                                Text("💡 If this person is not the athlete, tap \"Athlete not detected\" to skip. The athlete may be mid-jump, off-camera, or pose detection missed them at this angle.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else if detectedPeople.isEmpty {
                                Text("💡 No people detected in this frame. The athlete may be off-camera, occluded, or pose detection failed. Tap \"Athlete not detected\" to skip.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Select Athlete")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.xmark")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            
            Text("No People Detected")
                .font(.headline)
            
            Text("Pose detection didn't find anyone in this frame. This can happen when the athlete is mid-jump, partially occluded, or at an unusual angle.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Button {
                onSelect(nil)
                dismiss()
            } label: {
                Label("Skip This Frame", systemImage: "arrow.right")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
    
    private func iconFor(_ reason: SmartTrackingEngine.DecisionPoint.Reason) -> String {
        switch reason {
        case .initialSelection: return "person.crop.circle"
        case .newPersonEntered: return "person.crop.circle.badge.plus"
        case .multipleOverlapping: return "person.2.fill"
        case .lowTrackingConfidence: return "exclamationmark.triangle"
        case .athleteLeftFrame: return "person.crop.circle.badge.questionmark"
        }
    }
}

struct PersonRow: View {
    let person: PersonThumbnailGenerator.DetectedPerson
    let onTap: () -> Void
    @State private var showFullPreview = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onTap) {
                HStack(spacing: 16) {
                    Image(uiImage: person.thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 80, height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Person")
                            .font(.headline)
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                            Text("Confidence: \(Int(person.confidence * 100))%")
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                        
                        Text(positionDescription)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.blue)
                }
            }
            .buttonStyle(.plain)
            
            // Full frame preview with highlight
            Button {
                showFullPreview.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showFullPreview ? "eye.slash" : "eye")
                        .font(.caption)
                    Text(showFullPreview ? "Hide Context" : "Show Full Frame")
                        .font(.caption.bold())
                }
                .foregroundStyle(.blue)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.blue.opacity(0.1))
                .clipShape(Capsule())
            }
            
            if showFullPreview {
                Image(uiImage: person.fullFrameWithHighlight)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.cyan, lineWidth: 2)
                    )
                    .padding(.top, 4)
            }
        }
        .padding(.vertical, 8)
    }
    
    private var positionDescription: String {
        let bbox = person.boundingBox
        let centerX = (bbox.minX + bbox.maxX) / 2
        
        let horizontal: String
        if centerX < 0.33 {
            horizontal = "Left"
        } else if centerX > 0.67 {
            horizontal = "Right"
        } else {
            horizontal = "Center"
        }
        
        return "\(horizontal) side of frame"
    }
}
// MARK: - Quick Person Selector (Thumbnail Carousel)

/// Compact thumbnail-based person selector
struct QuickPersonSelector: View {
    let detectedPeople: [PersonThumbnailGenerator.DetectedPerson]
    let onSelect: (PersonThumbnailGenerator.DetectedPerson?) -> Void
    
    @State private var selectedIndex: Int?
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 0) {
            // Quick instruction
            HStack {
                Image(systemName: "hand.tap.fill")
                    .foregroundStyle(.cyan)
                Text("Tap the athlete")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .font(.subheadline)
            }
            .padding()
            .background(.ultraThinMaterial)
            
            // Horizontal scrolling thumbnails (large, easy to distinguish)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    ForEach(detectedPeople.indices, id: \.self) { index in
                        PersonThumbnailCard(
                            person: detectedPeople[index],
                            number: index + 1,
                            isSelected: selectedIndex == index,
                            onTap: {
                                selectedIndex = index
                                onSelect(detectedPeople[index])
                                dismiss()
                            }
                        )
                    }
                    
                    // "None" option
                    NoAthleteCard(
                        isSelected: selectedIndex == nil,
                        onTap: {
                            selectedIndex = nil
                            onSelect(nil)
                            dismiss()
                        }
                    )
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
        }
        .presentationDetents([.height(280)])
        .presentationDragIndicator(.visible)
    }
}

struct PersonThumbnailCard: View {
    let person: PersonThumbnailGenerator.DetectedPerson
    let number: Int
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 12) {
                // Large thumbnail with skeleton overlay
                ZStack(alignment: .topLeading) {
                    Image(uiImage: person.thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 140, height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(isSelected ? Color.cyan : Color.white.opacity(0.3), 
                                       lineWidth: isSelected ? 4 : 2)
                        )
                        .shadow(color: isSelected ? .cyan.opacity(0.5) : .black.opacity(0.2), 
                               radius: isSelected ? 12 : 6)
                    
                    // Number badge
                    Text("\(number)")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(
                            Circle()
                                .fill(isSelected ? Color.cyan : Color.gray)
                        )
                        .offset(x: 10, y: 10)
                    
                    // Checkmark when selected
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.cyan)
                            .background(
                                Circle()
                                    .fill(.white)
                                    .frame(width: 28, height: 28)
                            )
                            .offset(x: 100, y: 10)
                    }
                }
                
                // Position hint
                Text(positionDescription)
                    .font(.caption.bold())
                    .foregroundStyle(isSelected ? .cyan : .secondary)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isSelected ? 1.05 : 1.0)
        .animation(.spring(response: 0.3), value: isSelected)
    }
    
    private var positionDescription: String {
        let bbox = person.boundingBox
        let centerX = (bbox.minX + bbox.maxX) / 2
        
        if centerX < 0.33 { return "Left side" }
        else if centerX > 0.67 { return "Right side" }
        else { return "Center" }
    }
}

struct NoAthleteCard: View {
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.orange.opacity(0.2))
                        .frame(width: 140, height: 180)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(isSelected ? Color.orange : Color.white.opacity(0.3), 
                                       lineWidth: isSelected ? 4 : 2)
                        )
                    
                    VStack(spacing: 8) {
                        Image(systemName: "person.crop.circle.badge.xmark")
                            .font(.system(size: 48))
                            .foregroundStyle(.orange)
                        
                        Text("Not Here")
                            .font(.headline)
                            .foregroundStyle(.orange)
                    }
                }
                
                Text("Athlete not visible")
                    .font(.caption.bold())
                    .foregroundStyle(isSelected ? .orange : .secondary)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isSelected ? 1.05 : 1.0)
        .animation(.spring(response: 0.3), value: isSelected)
    }
}

