//
//  SettingsView.swift
//  Done
//
//  Created by Yifan Mei on 12/10/25.
//

import SwiftUI

struct SettingsView: View {
    @StateObject private var calendarService = GoogleCalendarService.shared
    @StateObject private var dataManager = DataManager.shared
    @State private var showingAuthError = false
    @State private var authError: Error?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if calendarService.isAuthenticated {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Connected")
                                    .font(.headline)
                                    .foregroundColor(.green)

                                if let email = calendarService.userEmail {
                                    Text(email)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                            }

                            Spacer()

                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.title2)
                        }

                        Button("Sign Out", role: .destructive) {
                            calendarService.signOut()
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Not Connected")
                                .font(.headline)
                                .foregroundColor(.secondary)

                            Text("Connect your Google account to sync time entries to Google Calendar")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 4)

                        Button {
                            Task {
                                await authenticateWithGoogle()
                            }
                        } label: {
                            HStack {
                                Image(systemName: "calendar")
                                Text("Connect Google Calendar")
                            }
                        }
                    }
                } header: {
                    Text("Google Calendar")
                } footer: {
                    Text("Time entries will be automatically synced to your Google Calendar when you stop tracking.")
                }

                Section {
                    Toggle(isOn: Binding(
                        get: { dataManager.wordlessMode },
                        set: { newValue in
                            dataManager.wordlessMode = newValue
                            dataManager.saveWordlessMode()
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Wordless Mode")
                                .font(.body)
                            Text("Hide all text, show colors only")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Toggle(isOn: Binding(
                        get: { dataManager.showDayNightBackground },
                        set: { newValue in
                            dataManager.showDayNightBackground = newValue
                            dataManager.saveDayNightBackground()
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Day/Night Background")
                                .font(.body)
                            Text("Show time-based background colors")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Toggle(isOn: Binding(
                        get: { dataManager.useLiquidGlassHeader },
                        set: { newValue in
                            dataManager.useLiquidGlassHeader = newValue
                            dataManager.saveUseLiquidGlassHeader()
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Liquid Glass Header")
                                .font(.body)
                            Text("Use liquid glass styling for the timeline header")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Picker(selection: Binding(
                        get: { dataManager.appearanceMode },
                        set: { newValue in
                            dataManager.appearanceMode = newValue
                            dataManager.saveAppearanceMode()
                        }
                    )) {
                        ForEach(AppearanceMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Appearance")
                                .font(.body)
                            Text("Choose light, dark, or system")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Display")
                } footer: {
                    Text("Wordless mode hides template names. Day/Night background shows time-based colors. Liquid glass changes the timeline header style. Appearance controls the app's color scheme.")
                }

                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }

                    Link(destination: URL(string: "https://github.com")!) {
                        HStack {
                            Text("GitHub")
                            Spacer()
                            Image(systemName: "arrow.up.forward")
                                .font(.caption)
                        }
                    }
                } header: {
                    Text("About")
                }

            }
            .navigationTitle("Settings")
            .alert("Authentication Error", isPresented: $showingAuthError) {
                Button("OK") {
                    authError = nil
                }
            } message: {
                if let error = authError {
                    Text(error.localizedDescription)
                }
            }
        }
    }

    private func authenticateWithGoogle() async {
        do {
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let window = windowScene.windows.first else {
                return
            }

            try await calendarService.authenticate(presentationAnchor: window)
        } catch {
            authError = error
            showingAuthError = true
        }
    }
}

#Preview {
    SettingsView()
}
