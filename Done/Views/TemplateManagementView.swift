//
//  TemplateManagementView.swift
//  Done
//
//  Created by Yifan Mei on 12/10/25.
//

import SwiftUI
import UIKit

// Generate Dot UIImage
func colorDotImage(_ color: UIColor, diameter: CGFloat = 16) -> UIImage {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: diameter, height: diameter))
    return renderer.image { ctx in
        let rect = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        ctx.cgContext.setFillColor(color.cgColor)
        ctx.cgContext.fillEllipse(in: rect)
    }
}

struct TemplateManagementView: View {
    @StateObject private var dataManager = DataManager.shared
    @State private var showingAddTemplate = false
    @State private var selectedTemplate: ActivityTemplate?
    @State private var detailTemplate: ActivityTemplate?

    var body: some View {
        NavigationStack {
            List {
                if let active = dataManager.ongoingEntry {
                    ActiveTimerCardRow(entry: active)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(
                            top: dataManager.wordlessMode ? 40 : 6,
                            leading: 16,
                            bottom: 6,
                            trailing: 16
                        ))
                        .listRowBackground(Color.clear)
                }

                ForEach(dataManager.templates) { template in
                    Button {
                        startActivity(template: template)
                        detailTemplate = template
                    } label: {
                        TemplateCardRow(template: template)
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            dataManager.deleteTemplate(template)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }

                        Button {
                            selectedTemplate = template
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                }
                .onMove(perform: moveTemplates)

                Button {
                    showingAddTemplate = true
                } label: {
                    AddTemplateCardRow()
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowBackground(Color.clear)
            
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(
                ZStack {
                    // 有光场的白色背景
                    LinearGradient(
                        colors: [
                            Color(red: 0.98, green: 0.98, blue: 0.99),
                            Color(red: 0.95, green: 0.96, blue: 0.98)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .ignoresSafeArea()
                }
            )
            .navigationTitle(dataManager.wordlessMode ? "" : "Activity Templates")
            .navigationDestination(item: $selectedTemplate) { template in
                TemplateEditView(template: template)
            }
            .navigationDestination(item: $detailTemplate) { template in
                TemplateDetailView(template: template)
            }
            .sheet(isPresented: $showingAddTemplate) {
                NavigationStack {
                    TemplateEditView(template: nil)
                }
            }
        }
    }

    private func deleteTemplates(at offsets: IndexSet) {
        for index in offsets {
            dataManager.deleteTemplate(dataManager.templates[index])
        }
    }

    private func moveTemplates(from source: IndexSet, to destination: Int) {
        dataManager.reorderTemplates(from: source, to: destination)
    }

    private func startActivity(template: ActivityTemplate) {
        dataManager.startOngoingEntry(template: template)
    }
}

// MARK: - Template Card View
struct TemplateCardRow: View {
    let template: ActivityTemplate
    @ObservedObject var dataManager = DataManager.shared

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: template.icon)
                .font(.system(size: dataManager.wordlessMode ? 22 : 18, weight: .semibold))
                .foregroundColor(dataManager.wordlessMode ? template.color : .white)
                .if(dataManager.wordlessMode) { view in
                    view.shadow(color: .white.opacity(0.6), radius: 0, x: 0, y: 1)
                        .shadow(color: .black.opacity(0.12), radius: 2, x: 0, y: 1)
                }
                .frame(width: 44, height: 44)
                .background(dataManager.wordlessMode ? Color.clear : template.color)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            if !dataManager.wordlessMode {
                Text(template.name)
                    .font(.system(size: 18, weight: .semibold, design: .default).monospacedDigit())
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .if(dataManager.wordlessMode) { view in
            view.cleanGlassCard(tint: template.color)
        }
        .if(!dataManager.wordlessMode) { view in
            view.background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.systemBackground))
                    .shadow(color: .black.opacity(0.06), radius: 12, x: 0, y: 6)
            )
        }
    }
}


// MARK: - View Extension for Conditional Modifiers
extension View {
    @ViewBuilder
    func `if`<Transform: View>(_ condition: Bool, transform: (Self) -> Transform) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

struct AddTemplateCardRow: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 44, height: 44)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.06), radius: 12, x: 0, y: 6)
        )
    }
}

private struct ActiveTimerCardRow: View {
    let entry: TimeEntry
    @State private var elapsed: TimeInterval = 0
    @State private var timer: Timer?
    @ObservedObject var dataManager = DataManager.shared

    private var entryColor: Color {
        Color(hex: entry.colorHex) ?? .blue
    }

    var body: some View {
        HStack(spacing: 10) {
            if dataManager.wordlessMode {
                Image(systemName: "livephoto.play")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(entryColor)
                    .shadow(color: .white.opacity(0.6), radius: 0, x: 0, y: 1)
                    .shadow(color: .black.opacity(0.12), radius: 2, x: 0, y: 1)
                    .frame(width: 44, height: 44)
                    .background(Color.clear)

                Text(elapsed.formatAsTimer())
                    .font(.system(size: 18, weight: .semibold, design: .default).monospacedDigit())
                    .foregroundColor(entryColor)
            } else {
                Image(systemName: "livephoto.play")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
                    .background(entryColor)

                Text(elapsed.formatAsTimer())
                    .font(.system(size: 18, weight: .semibold, design: .default).monospacedDigit())
                    .foregroundColor(.white)
            }

            Spacer()

            Button {
                endEntry()
            } label: {
                if dataManager.wordlessMode {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(entryColor)
                        .frame(width: 28, height: 28)
                } else {
                    Text("End")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 0)
        .if(dataManager.wordlessMode) { view in
            view.cleanGlassCard(tint: entryColor, cornerRadius: 6)
        }
        .if(!dataManager.wordlessMode) { view in
            view.background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(entryColor)
                    .shadow(color: .black.opacity(0.06), radius: 12, x: 0, y: 6)
            )
        }
        .onAppear {
            sync()
            startTimer()
        }
        .onDisappear {
            timer?.invalidate()
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            sync()
        }
    }

    private func sync() {
        elapsed = Date().timeIntervalSince(entry.startTime)
    }

    private func endEntry() {
        dataManager.finishOngoingEntry(matching: entry.id)
    }
}

struct TemplateEditView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var dataManager = DataManager.shared

    let template: ActivityTemplate?

    @State private var name: String
    @State private var selectedColorHex: String
    @State private var selectedIcon: String

    private let availableColors: [(name: String, hex: String, color: Color)] = [
        ("Tomato", "#D50000", Color(hex: "#D50000")!),
        ("Tangerine", "#F4511E", Color(hex: "#F4511E")!),
        ("Banana", "#F6BF26", Color(hex: "#F6BF26")!),
        ("Basil", "#0B8043", Color(hex: "#0B8043")!),
        ("Sage", "#33B679", Color(hex: "#33B679")!),
        ("Peacock", "#039BE5", Color(hex: "#039BE5")!),
        ("Blueberry", "#3F51B5", Color(hex: "#3F51B5")!),
        ("Lavender", "#7986CB", Color(hex: "#7986CB")!),
        ("Grape", "#8E24AA", Color(hex: "#8E24AA")!),
        ("Flamingo", "#E67C73", Color(hex: "#E67C73")!),
        ("Graphite", "#616161", Color(hex: "#616161")!)
    ]

    private let availableIcons: [(name: String, systemName: String)] = [
        ("Laptop", "laptopcomputer"),
        ("People", "person.3.fill"),
        ("Running", "figure.run"),
        ("Book", "book.fill"),
        ("Coffee", "cup.and.saucer.fill"),
        ("Car", "car.fill"),
        ("Dining", "fork.knife"),
        ("Music", "music.note"),
        ("Art", "paintbrush.fill"),
        ("Gaming", "gamecontroller.fill"),
        ("TV", "tv.fill"),
        ("Phone", "phone.fill"),
        ("Message", "message.fill"),
        ("Email", "envelope.fill"),
        ("Home", "house.fill"),
        ("Shopping", "cart.fill")
    ]

    private var selectedColor: Color {
        Color(hex: selectedColorHex) ?? .blue
    }

    init(template: ActivityTemplate?) {
        self.template = template
        _name = State(initialValue: template?.name ?? "")
        _selectedColorHex = State(initialValue: template?.colorHex ?? "#3F51B5")
        _selectedIcon = State(initialValue: template?.icon ?? "laptopcomputer")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if dataManager.wordlessMode {
                    HStack(spacing: 12) {
                        Image(systemName: selectedIcon)
                            .font(.title3)
                            .foregroundColor(selectedColor)
                            .frame(width: 44, height: 44)
                            .background(Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .if(dataManager.wordlessMode) { view in
                        view.cleanGlassCard(tint: selectedColor)
                    }
                } else {
                    HStack(spacing: 12) {
                        Image(systemName: selectedIcon)
                            .font(.title3)
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(selectedColor)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                        TextField("Template Name", text: $name)
                            .font(.system(size: 18, weight: .semibold, design: .default).monospacedDigit())
                            .foregroundColor(name.isEmpty ? .secondary : .primary)
                            .textInputAutocapitalization(.words)
                            .disableAutocorrection(true)

                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .if(!dataManager.wordlessMode) { view in
                        view.background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color(.systemBackground))
                                .shadow(color: .black.opacity(0.06), radius: 12, x: 0, y: 6)
                        )
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(availableColors, id: \.hex) { colorItem in
                                Button {
                                    selectedColorHex = colorItem.hex
                                } label: {
                                    ZStack {
                                        Circle()
                                            .fill(colorItem.color)
                                            .frame(width: 26, height: 26)

                                        if selectedColorHex == colorItem.hex {
                                            Circle()
                                                .strokeBorder(colorItem.color, lineWidth: 3)
                                                .frame(width: 34, height: 34)

                                            // checkmark
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 12, weight: .bold))
                                                .foregroundColor(.white)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(availableIcons, id: \.systemName) { iconItem in
                                Button {
                                    selectedIcon = iconItem.systemName
                                } label: {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .fill(Color(.systemGray6))
                                            .frame(width: 44, height: 44)

                                        Image(systemName: iconItem.systemName)
                                            .font(.system(size: 20, weight: .semibold))
                                            .foregroundColor(.primary)

                                        if selectedIcon == iconItem.systemName {
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .strokeBorder(selectedColor, lineWidth: 3)
                                                .frame(width: 44, height: 44)

                                            // checkmark overlay
                                            Circle()
                                                .fill(selectedColor)
                                                .frame(width: 18, height: 18)
                                                .overlay(
                                                    Image(systemName: "checkmark")
                                                        .font(.system(size: 10, weight: .bold))
                                                        .foregroundColor(.white)
                                                )
                                                .offset(x: 13, y: -13)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .navigationTitle(dataManager.wordlessMode ? "" : (template == nil ? "New Template" : "Edit Template"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            if template == nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        if dataManager.wordlessMode {
                            Image(systemName: "xmark")
                        } else {
                            Text("Cancel")
                        }
                    }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    saveTemplate()
                    dismiss()
                } label: {
                    if dataManager.wordlessMode {
                        Image(systemName: "checkmark")
                    } else {
                        Text("Save")
                    }
                }
                .disabled(!dataManager.wordlessMode && name.isEmpty)
                .fontWeight(.semibold)
            }
        }
    }

    private func saveTemplate() {
        let selectedKey = CategoryColorKey.from(hex: selectedColorHex)

        let finalName = name

        if let template = template {
            var updated = template
            updated.name = finalName
            updated.colorKey = selectedKey
            updated.colorHex = selectedKey.hexValue
            updated.icon = selectedIcon
            dataManager.updateTemplate(updated)
        } else {
            let newTemplate = ActivityTemplate(
                name: finalName,
                colorKey: selectedKey,
                icon: selectedIcon,
                order: dataManager.templates.count
            )
            dataManager.addTemplate(newTemplate)
        }
    }
}

// MARK: - Clean Glass Card Modifier
struct CleanGlassCard: ViewModifier {
    let tint: Color
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        content
            .background {
                ZStack {
                    shape.fill(tint.opacity(0.16))
                    shape.strokeBorder(tint.opacity(0.35), lineWidth: 1.0)
                    shape.strokeBorder(.white.opacity(0.75), lineWidth: 0.8)
                    shape.strokeBorder(.black.opacity(0.06), lineWidth: 0.6)

                    shape.fill(Color.clear)
                        .shadow(color: .black.opacity(0.12), radius: 3, x: 0, y: 2)

                    shape.fill(Color.clear)
                        .shadow(color: .black.opacity(0.05), radius: 14, x: 0, y: 10)
                }
            }
    }
}

extension View {
    func cleanGlassCard(tint: Color, cornerRadius: CGFloat = 18) -> some View {
        modifier(CleanGlassCard(tint: tint, cornerRadius: cornerRadius))
    }
}

#Preview {
    TemplateManagementView()
}
