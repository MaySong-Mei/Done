//
//  ViewportState.swift
//  Done
//
//  Created by Codex on 3/10/26.
//

import Combine
import CoreGraphics
import Foundation
import SwiftUI

@MainActor
final class ViewportState: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    @Published var verticalOffset: CGFloat = 0
    @Published var horizontalOffset: CGFloat = 0
    @Published var visibleWidth: CGFloat = 0
    @Published var visibleHeight: CGFloat = 0
}
