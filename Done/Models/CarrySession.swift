//
//  CarrySession.swift
//  Done
//
//  Created by Codex on 3/10/26.
//

import CoreGraphics
import Foundation

/*
 CarrySession keeps the event being carried while a second finger scrolls; the
 ghostScreenPoint will be mapped through viewport offsets to compute the drop
 target later (for now it is fed by local drag callbacks).
*/
struct CarrySession {
    let eventId: UUID
    let originalStart: Date
    let originalEnd: Date
    let duration: TimeInterval
    var isCarrying: Bool
    var fingerAIdentifier: Int?
    var anchorScreenPoint: CGPoint
    var ghostScreenPoint: CGPoint
    var ghostAnchorOffset: CGSize
    var currentDropTarget: DropTarget?
}
