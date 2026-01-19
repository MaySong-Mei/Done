//
//  EventGridLayout.swift
//  Done
//
//  Created by Shiqi Liu on 1/12/26.
//

import Foundation

enum EventGridLayout {
    static let columnsCount = 16

    struct Rect {
        let x: Int
        let y: Int
        let width: Int
        let height: Int

        func intersects(x: Int, y: Int, width: Int, height: Int) -> Bool {
            let separated = x + width <= self.x
                || self.x + self.width <= x
                || y + height <= self.y
                || self.y + self.height <= y
            return !separated
        }
    }

    static func spanColumns(for event: Event) -> Int {
        max(3, min(columnsCount, event.gridWidth))
    }

    static func spanRows(for event: Event) -> Int {
        max(3, event.gridHeight)
    }

    static func nextAvailablePosition(for event: Event, in events: [Event]) -> (x: Int, y: Int) {
        let occupied = events.compactMap { existing -> Rect? in
            guard let x = existing.gridX, let y = existing.gridY else {
                return nil
            }
            return Rect(
                x: x,
                y: y,
                width: spanColumns(for: existing),
                height: spanRows(for: existing)
            )
        }
        return nextAvailablePosition(
            spanColumns: spanColumns(for: event),
            spanRows: spanRows(for: event),
            occupied: occupied
        )
    }

    static func nextAvailablePosition(
        spanColumns: Int,
        spanRows: Int,
        occupied: [Rect]
    ) -> (x: Int, y: Int) {
        let maxX = max(0, columnsCount - spanColumns)
        var y = 0

        while true {
            for x in 0...maxX {
                if fits(
                    x: x,
                    y: y,
                    spanColumns: spanColumns,
                    spanRows: spanRows,
                    occupied: occupied
                ) {
                    return (x: x, y: y)
                }
            }
            y += 1
        }
    }

    private static func fits(
        x: Int,
        y: Int,
        spanColumns: Int,
        spanRows: Int,
        occupied: [Rect]
    ) -> Bool {
        for rect in occupied {
            if rect.intersects(x: x, y: y, width: spanColumns, height: spanRows) {
                return false
            }
        }
        return true
    }
}
