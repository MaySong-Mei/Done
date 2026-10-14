//
//  EraseWiringScan.swift
//  DoneTests
//
//  Reading `resetAllLocalData()`'s source as CODE, with the comments taken
//  out, so a sentence about a call cannot stand in for the call.
//

import Foundation
import XCTest

/// Why this exists, given that gh#266 just retired a source-scanning test.
///
/// The census tried to prove **completeness** by syntax: "every store that
/// writes user data is named here". That set is open-ended, so the needles
/// could only approximate it, and four review rounds each found a medium
/// they missed — then it certified a genuinely unswept key as covered.
///
/// A wiring assertion proves one closed, named fact: *this* call is present
/// in *this* function. There is nothing to approximate and no way to emit a
/// false green about anything other than the single line it names. The repo
/// already relies on the idiom (`BackupSnapshotDirtyCheckTests`), and the
/// erase cites it by name.
///
/// It is the available instrument, not the right one. `resetAllLocalData()`
/// is `private` on a SwiftUI view, so no test can drive it; reading its
/// source is the only way to witness that a purge is still wired in. The
/// right instrument is gh#266's registry, where the list is derived and
/// omission is a compile error — at which point these go away.
enum EraseWiringScan {
    enum Failure: Error, CustomStringConvertible {
        case fileUnreadable(String)
        case functionNotFound(String)
        case functionEndNotFound(String)

        var description: String {
            switch self {
            case .fileUnreadable(let path):
                return "could not read \(path) — the scan's anchor file moved"
            case .functionNotFound(let name):
                return "\(name) has been renamed or moved — re-point this scan"
            case .functionEndNotFound(let name):
                return "could not find the end of \(name) — re-derive the scan"
            }
        }
    }

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DoneTests/
            .deletingLastPathComponent()   // repo root
    }

    /// The body of a function, **with comments removed**.
    ///
    /// Stripping is the whole point of this helper, and it is not tidiness.
    /// `MeAvatarStore.delete()` appeared three times inside
    /// `resetAllLocalData()`: the real call, and twice in comments explaining
    /// which test anchors on it. `range(of:)` matched a comment, so deleting
    /// the real call left the ordering test green — the documentation of an
    /// anchor had become the anchor. Any scan that reads prose as code can be
    /// disarmed by writing about it.
    /// `closingBrace` defaults to a method's — four spaces of indentation.
    /// File-scope functions (`fetchLLMResponseJSON` and the ledger helpers
    /// are not inside a type) close at column 0, so they pass "\n}\n".
    static func functionBody(
        of signature: String,
        inFileAt relativePath: String,
        closingBrace: String = "\n    }\n"
    ) throws -> String {
        let url = repoRoot.appendingPathComponent(relativePath)
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw Failure.fileUnreadable(relativePath)
        }
        guard let start = source.range(of: signature) else {
            throw Failure.functionNotFound(signature)
        }
        let rest = source[start.upperBound...]
        // The closing brace at the declaration's own indentation.
        guard let end = rest.range(of: closingBrace) else {
            throw Failure.functionEndNotFound(signature)
        }
        return strippingComments(String(rest[..<end.lowerBound]))
    }

    /// Removes `//` line comments and `/* */` block comments while leaving
    /// string literals alone — a `//` inside a quoted URL is code, not a
    /// comment. Deliberately not a Swift parser: it does not handle raw
    /// strings (`#"…"#`) or multi-line literals, neither of which appears in
    /// the functions scanned here. A literal that did appear would show up
    /// as a scan that cannot find its anchor, which fails loudly.
    static func strippingComments(_ source: String) -> String {
        var out = ""
        var inString = false
        var inLineComment = false
        var inBlockComment = false
        var escaped = false
        var index = source.startIndex

        while index < source.endIndex {
            let character = source[index]
            let next = source.index(after: index)
            let peek: Character? = next < source.endIndex ? source[next] : nil

            if inLineComment {
                if character == "\n" { inLineComment = false; out.append(character) }
            } else if inBlockComment {
                if character == "*", peek == "/" {
                    inBlockComment = false
                    index = next
                }
            } else if inString {
                out.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else if character == "/", peek == "/" {
                inLineComment = true
                index = next
            } else if character == "/", peek == "*" {
                inBlockComment = true
                index = next
            } else {
                if character == "\"" { inString = true }
                out.append(character)
            }
            index = source.index(after: index)
        }
        return out
    }

    /// Asserts the call is present, and returns where — so an ordering
    /// assertion can be built on a position that is real code.
    @discardableResult
    static func assertCalls(
        _ call: String,
        in body: String,
        because reason: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Range<String.Index>? {
        guard let range = body.range(of: call) else {
            XCTFail("the erase must still call `\(call)` — \(reason)", file: file, line: line)
            return nil
        }
        return range
    }
}
