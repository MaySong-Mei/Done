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
                } header: {
                    Text("Display")
                } footer: {
                    Text("When enabled, template names and other text will be hidden. Only colors will be shown.")
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
