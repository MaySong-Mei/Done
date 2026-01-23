//
//  TypingSubtitleController.swift
//  Done
//
//  Drives the typing animation independent of view lifecycle so mode switches
//  or transitions do not reset progress.
//

import Foundation
import Combine

@MainActor
final class TypingSubtitleController: ObservableObject {
    @Published var progress: Int = 0

    private var task: Task<Void, Never>?
    private var currentText: String = ""

    func start(text: String, interval: TimeInterval) {
        guard text != currentText else { return }
        currentText = text

        task?.cancel()
        progress = 0

        guard !text.isEmpty else { return }

        let ns = UInt64(max(0.001, interval) * 1_000_000_000)

        task = Task { [weak self] in
            guard let self else { return }
            for i in 1...text.count {
                try? await Task.sleep(nanoseconds: ns)
                if Task.isCancelled { return }
                self.progress = i
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
