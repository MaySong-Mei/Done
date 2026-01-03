//
//  TimelineEventType.swift
//  Done
//
//  Created by Shiqi Liu on 1/3/26.
//

import Foundation

enum TimelineEventType: String, CaseIterable, Codable {
    case completed
    case ongoing
    case draft
    case empty
}
