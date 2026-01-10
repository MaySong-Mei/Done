//
//  SubtaskEditView.swift
//  Done
//
//  Created by Codex on 12/10/25.
//

import SwiftUI

struct SubtaskEditView: View {
    private struct ScheduleRange: Identifiable {
        let id = UUID()
        var startDate: Date?
        var endDate: Date?
        var frequencyDays: String
    }

    @Environment(\.dismiss) private var dismiss
    let template: ActivityTemplate
    let onSave: (String) -> Void
    @State private var title: String = ""
    @State private var scheduleRanges: [ScheduleRange] = []
    @State private var dueDate: Date?
    @State private var tags: [String] = []
    @State private var showTagPrompt = false
    @State private var newTagName = ""
    @State private var priorityLevel = 1
    @State private var descriptionText = ""

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Subtask Title", text: $title)
                .font(.system(size: 22, weight: .semibold))
                .textInputAutocapitalization(.sentences)
                .disableAutocorrection(true)
                
            Rectangle()
                .fill(Color(.systemGray4))
                .frame(height: 1)

            HStack {
                Text("Schedule (Optional)")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.black)

                Spacer()

                Button {
                    scheduleRanges.append(ScheduleRange(frequencyDays: ""))
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            ForEach($scheduleRanges) { $range in
                HStack(spacing: 0) {
                    Text("Every ")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.black)

                    TextField("N", text: Binding(
                        get: { range.frequencyDays },
                        set: { newValue in
                            range.frequencyDays = sanitizePositiveInt(newValue)
                        }
                    ))
                    .frame(width: 12)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(frequencyColor(range.frequencyDays))

                    Text(" day ")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.black)
                    
                    Text("from ")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.black)

                    Text(range.startDate.map { formattedDate($0) } ?? "Start Date")
                        .foregroundColor(range.startDate == nil ? .secondary : (isRangeInvalid(range) ? .red : .primary))
                        .overlay(
                            DatePicker(
                                "",
                                selection: Binding(
                                    get: { range.startDate ?? Date() },
                                    set: { newValue in
                                        range.startDate = newValue
                                    }
                                ),
                                displayedComponents: .date
                            )
                            .labelsHidden()
                            .datePickerStyle(.compact)
                            .opacity(0.02)
                            .contentShape(Rectangle())
                        )
                        .font(.system(size: 16, weight: .medium))

                    Text(" to ")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.black)

                    Text(range.endDate.map { formattedDate($0) } ?? "End Date")
                        .foregroundColor(range.endDate == nil ? .secondary : (isRangeInvalid(range) ? .red : .primary))
                        .overlay(
                            DatePicker(
                                "",
                                selection: Binding(
                                    get: { range.endDate ?? Date() },
                                    set: { newValue in
                                        range.endDate = newValue
                                    }
                                ),
                                displayedComponents: .date
                            )
                            .labelsHidden()
                            .datePickerStyle(.compact)
                            .opacity(0.02)
                            .contentShape(Rectangle())
                        )
                        .font(.system(size: 16, weight: .medium))

                    Spacer()

                    Button {
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isRangeValid(range))

                    Button {
                        scheduleRanges.removeAll { $0.id == range.id }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .environment(\.locale, Locale(identifier: "en_US_POSIX"))
            }

            HStack(spacing: 0) {
                Text("Due")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.black)

                Spacer()
                
                Text(dueDate.map { formattedDate($0) } ?? "Due Date")
                    .foregroundColor(dueDate == nil ? .secondary : .primary)
                    .overlay(
                        DatePicker(
                            "",
                            selection: Binding(
                                get: { dueDate ?? Date() },
                                set: { newValue in
                                    dueDate = newValue
                                }
                            ),
                            displayedComponents: .date
                        )
                        .labelsHidden()
                        .datePickerStyle(.compact)
                        .opacity(0.02)
                        .contentShape(Rectangle())
                    )
                    .font(.system(size: 16, weight: .medium))
            }

            HStack {
                Text("Tag")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.black)

                Spacer()

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(tags, id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Color(.systemGray6))
                                )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }

                Spacer()

                Button {
                    newTagName = ""
                    showTagPrompt = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                
            }

            HStack {
                Text("Priority")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.black)

                Spacer()

                HStack(spacing: 8) {
                    Button {
                        priorityLevel = max(1, priorityLevel - 1)
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(priorityLevel == 1)

                    Text(String(repeating: "!", count: priorityLevel))
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.red)
                        .frame(width: 30, alignment: .center)

                    Button {
                        priorityLevel = min(5, priorityLevel + 1)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(priorityLevel == 5)
                }
            }

            Text("Description")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.black)

            Rectangle()
                .fill(Color(.systemGray4))
                .frame(height: 1)

            ZStack(alignment: .topLeading) {
                if descriptionText.isEmpty {
                    Text("description")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.top, 8)
                        .padding(.leading, 4)
                }

                TextEditor(text: $descriptionText)
                    .font(.system(size: 16, weight: .medium))
                    .frame(minHeight: 80)
                    .textInputAutocapitalization(.sentences)
                    .disableAutocorrection(true)
            }
                
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .alert("New Tag", isPresented: $showTagPrompt) {
            TextField("Tag", text: $newTagName)
            Button("Cancel", role: .cancel) {}
            Button("Add") {
                let trimmed = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    tags.append(trimmed)
                }
            }
        }
        .navigationTitle("New Subtask")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    onSave(title.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .fontWeight(.semibold)
            }
        }
    }

    private func formattedDate(_ date: Date) -> String {
        Self.dateFormatter.string(from: date)
    }

    private func isRangeValid(_ range: ScheduleRange) -> Bool {
        guard let startDate = range.startDate else {
            return false
        }
        if let endDate = range.endDate, endDate < startDate {
            return false
        }
        return true
    }

    private func isRangeInvalid(_ range: ScheduleRange) -> Bool {
        guard let startDate = range.startDate, let endDate = range.endDate else {
            return false
        }
        return endDate < startDate
    }

    private func sanitizePositiveInt(_ value: String) -> String {
        let digits = value.filter { $0.isNumber }
        if digits.isEmpty {
            return ""
        }
        let trimmed = digits.drop { $0 == "0" }
        if trimmed.isEmpty {
            return ""
        }
        return String(trimmed)
    }

    private func isPositiveInt(_ value: String) -> Bool {
        guard let number = Int(value) else {
            return false
        }
        return number > 0
    }

    private func frequencyColor(_ value: String) -> Color {
        if value.isEmpty {
            return .secondary
        }
        return isPositiveInt(value) ? .primary : .red
    }
}
