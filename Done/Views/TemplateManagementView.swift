//
//  TemplateManagementView.swift
//  Done
//
//  Created by Yifan Mei on 12/10/25.
//

import SwiftUI
import UIKit

// 生成圆点 UIImage
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

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)
                    ],
                    spacing: 12
                ) {
                    if let active = dataManager.activeEntry {
                        ActiveTimerCardRow(entry: active)
                            .gridCellColumns(2)
                    }

                    ForEach(dataManager.templates) { template in
                        Button {
                            selectedTemplate = template
                        } label: {
                            TemplateCardRow(template: template)
                        }
                        .buttonStyle(.plain)
                    }

                    if dataManager.wordlessMode {
                        Button {
                            showingAddTemplate = true
                        } label: {
                            AddTemplateCardRow()
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, dataManager.wordlessMode ? 20 : 16)
            }
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
            .scrollContentBackground(.hidden)
            .navigationTitle(dataManager.wordlessMode ? "" : "Activity Templates")
            .toolbar {
                if !dataManager.wordlessMode {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingAddTemplate = true
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        EditButton()
                    }
                }
            }
            .navigationDestination(item: $selectedTemplate) { template in
                TemplateEditView(template: template)
            }
            .sheet(isPresented: $showingAddTemplate) {
                NavigationStack {
                    TemplateEditView(template: nil)
                }
            }
        }
    }

    private func deleteTemplates(at offsets: IndexSet) {
        guard !dataManager.wordlessMode else { return }
        for index in offsets {
            dataManager.deleteTemplate(dataManager.templates[index])
        }
    }

    private func moveTemplates(from source: IndexSet, to destination: Int) {
        guard !dataManager.wordlessMode else { return }
        dataManager.reorderTemplates(from: source, to: destination)
    }
}

struct TemplateCardRow: View {
    let template: ActivityTemplate
    @ObservedObject var dataManager = DataManager.shared

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: template.icon)
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(dataManager.wordlessMode ? template.color : .white)
                .if(dataManager.wordlessMode) { view in
                    view.shadow(color: .white.opacity(0.6), radius: 0, x: 0, y: 1)
                        .shadow(color: .black.opacity(0.12), radius: 2, x: 0, y: 1)
                }
                .frame(width: 52, height: 52)
                .background(dataManager.wordlessMode ? Color.clear : template.color)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            if !dataManager.wordlessMode {
                Text(template.name)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 20)
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
        VStack(spacing: 12) {
            Image(systemName: "plus")
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 52, height: 52)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 20)
        .cleanGlassCard(tint: .gray)
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
        HStack(spacing: 16) {
            if dataManager.wordlessMode {
                // 无字模式：图标颜色和卡片背景颜色一致
                Image(systemName: "livephoto.play")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(entryColor)
                    .shadow(color: .white.opacity(0.6), radius: 0, x: 0, y: 1)
                    .shadow(color: .black.opacity(0.12), radius: 2, x: 0, y: 1)
                    .frame(width: 44, height: 44)
                    .background(Color.clear)
            } else {
                // 正常模式：白色图标，实心圆圈背景
                Circle()
                    .fill(entryColor)
                    .frame(width: 44, height: 44)
                    .overlay(
                        Image(systemName: "livephoto.play")
                            .foregroundColor(.white)
                            .font(.title3)
                    )
            }

            if !dataManager.wordlessMode {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.templateName)
                        .font(.headline)
                        .fontWeight(.semibold)
                        .lineLimit(1)

                    Text(elapsed.formatAsTimer())
                        .font(.subheadline.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if !dataManager.wordlessMode {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("In Progress")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.green)

                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                }
            } else {
                Circle()
                    .fill(.green)
                    .frame(width: 12, height: 12)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .if(dataManager.wordlessMode) { view in
            view.cleanGlassCard(tint: entryColor)
        }
        .if(!dataManager.wordlessMode) { view in
            view.background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.systemBackground))
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
        Form {
            if dataManager.wordlessMode {
                Section {
                    // 无字模式：完整卡片样式预览
                    HStack(spacing: 16) {
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
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(selectedColor.opacity(0.15))
                    )
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            } else {
                Section {
                    // 普通模式：名称编辑
                    HStack(spacing: 16) {
                        Image(systemName: selectedIcon)
                            .font(.title3)
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(selectedColor)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                        TextField("Template Name", text: $name)
                            .font(.headline)
                            .fontWeight(.semibold)
                            .foregroundColor(name.isEmpty ? .secondary : .primary)
                            .textInputAutocapitalization(.words)
                            .disableAutocorrection(true)

                        Spacer()
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Preview")
                        .textCase(nil)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker(dataManager.wordlessMode ? "" : "Color", selection: $selectedColorHex) {
                    ForEach(availableColors, id: \.hex) { colorItem in
                        HStack {
                            Image(uiImage: colorDotImage(UIColor(colorItem.color)))
                            if !dataManager.wordlessMode {
                                Text(colorItem.name)
                            }
                        }
                        .tag(colorItem.hex)
                    }
                }
            } header: {
                if !dataManager.wordlessMode {
                    Text("Color")
                        .textCase(nil)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker(dataManager.wordlessMode ? "" : "Icon", selection: $selectedIcon) {
                    ForEach(availableIcons, id: \.systemName) { iconItem in
                        HStack {
                            Image(systemName: iconItem.systemName)
                            if !dataManager.wordlessMode {
                                Text(iconItem.name)
                            }
                        }
                        .tag(iconItem.systemName)
                    }
                }
            } header: {
                if !dataManager.wordlessMode {
                    Text("Icon")
                        .textCase(nil)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(dataManager.wordlessMode ? "" : (template == nil ? "New Template" : "Edit Template"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            if template == nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button(dataManager.wordlessMode ? "" : "Cancel") {
                        dismiss()
                    }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(dataManager.wordlessMode ? "" : "Save") {
                    saveTemplate()
                    dismiss()
                }
                .disabled(!dataManager.wordlessMode && name.isEmpty)
                .fontWeight(.semibold)
            }
        }
    }

    private func saveTemplate() {
        let selectedKey = CategoryColorKey.from(hex: selectedColorHex)

        // 无字模式下允许空名称，普通模式下空名称时不保存
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

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

        content
            .background {
                ZStack {
                    // 1) 底色
                    shape.fill(tint.opacity(0.16))

                    // 2) 主题色边框（比底色略深）
                    shape.strokeBorder(tint.opacity(0.35), lineWidth: 1.0)

                    // 3) 上亮边
                    shape.strokeBorder(.white.opacity(0.75), lineWidth: 0.8)

                    // 4) 下暗边
                    shape.strokeBorder(.black.opacity(0.06), lineWidth: 0.6)

                    // 5) 接触影（短、略硬）
                    shape.fill(Color.clear)
                        .shadow(color: .black.opacity(0.12), radius: 3, x: 0, y: 2)

                    // 6) 环境影（长、很淡）
                    shape.fill(Color.clear)
                        .shadow(color: .black.opacity(0.05), radius: 14, x: 0, y: 10)
                }
            }
    }
}

extension View {
    func cleanGlassCard(tint: Color) -> some View {
        modifier(CleanGlassCard(tint: tint))
    }
}

#Preview {
    TemplateManagementView()
}
