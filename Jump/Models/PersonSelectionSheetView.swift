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
                        Section("Select the Athlete") {
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
                                    Text("No athlete in this frame")
                                    Spacer()
                                }
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
            Button("Mark as No Athlete") {
                onSelect(nil)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    
    var body: some View {
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
                }
                Spacer()
                Image(systemName: "checkmark.circle")
                    .font(.title3)
                    .foregroundStyle(.blue)
            }
        }
        .buttonStyle(.plain)
    }
}
