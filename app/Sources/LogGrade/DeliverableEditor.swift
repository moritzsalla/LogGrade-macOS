import AppKit
import GradeKit
import SwiftUI

/// Editor for adding or modifying a custom deliverable.
struct DeliverableEditor: View {
    @Environment(\.dismiss) var dismiss
    @Binding var project: Project
    let existingDeliverable: Deliverable?

    @State private var name: String = ""
    @State private var aspectWidth: String = ""
    @State private var aspectHeight: String = ""
    @State private var centreOffset = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(existingDeliverable == nil ? "New shape" : "Edit shape")
                .font(.system(.headline, design: .default))

            Form {
                Section("Name") {
                    TextField("square, tall, wide, …", text: $name)
                        .monospacedDigit()
                        .font(Type.value)
                }

                Section("Aspect") {
                    HStack(spacing: 8) {
                        TextField("width", text: $aspectWidth)
                            .monospacedDigit()
                            .font(Type.value)
                            .frame(maxWidth: 60)
                        Text(":")
                            .font(Type.value)
                        TextField("height", text: $aspectHeight)
                            .monospacedDigit()
                            .font(Type.value)
                            .frame(maxWidth: 60)
                    }
                }

                Section("Crop") {
                    Toggle("Fixed centre", isOn: $centreOffset)
                        .font(Type.label)
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .font(Type.caption)
                            .foregroundColor(Palette.lamp)
                    }
                }
            }

            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.plate)
            }
            .padding(.top, 8)
        }
        .padding(Space.l)
        .frame(maxWidth: 280)
        .onAppear { loadExisting() }
    }

    private func loadExisting() {
        guard let existing = existingDeliverable else { return }
        name = existing.name
        aspectWidth = String(existing.aspectWidth)
        aspectHeight = String(existing.aspectHeight)
        centreOffset = existing.cropOffset == .centre
    }

    private func save() {
        errorMessage = nil

        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        var allDeliverables = project.delivery.targets
        if let existing = existingDeliverable {
            allDeliverables.removeAll { $0 == existing }
        }

        if let error = Deliverable.validateName(trimmedName, against: allDeliverables) {
            errorMessage = error.description
            return
        }

        guard let w = Int(aspectWidth), let h = Int(aspectHeight) else {
            errorMessage = "Aspect must be whole numbers."
            return
        }

        if let error = Deliverable.validateAspect(width: w, height: h) {
            errorMessage = error.description
            return
        }

        let offset: DeliverableCropOffset? = centreOffset ? .centre : nil
        let deliverable = Deliverable(name: trimmedName, aspectWidth: w, aspectHeight: h,
                                     cropOffset: offset)

        if existingDeliverable == nil {
            project.delivery.targets.append(deliverable)
        } else {
            if let index = project.delivery.targets.firstIndex(of: existingDeliverable!) {
                project.delivery.targets[index] = deliverable
            }
        }

        dismiss()
    }
}
