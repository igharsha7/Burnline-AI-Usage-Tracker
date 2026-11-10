//
//  SwiftSource.swift
//  Burnline
//
//  Copyright (C) 2026 Challapalli Harshavardhan Reddy
//  Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.

/// Just enough Swift lexing for the fitness rules: comments and string contents
/// are blanked out, so documentation that names a forbidden construct, or a
/// URL whose `//` looks like a comment, cannot fool a rule.
///
/// Line breaks are kept, so a match's line number is the line in the file.
/// Deliberately not a parser: it handles line and nested block comments, plain
/// and multi-line strings, and escapes. Code inside a string interpolation is
/// blanked with the string, which is an accepted blind spot.
enum SwiftSource {
    static func code(_ source: String) -> String {
        enum State { case code, lineComment, blockComment(depth: Int), string, multilineString }

        let chars = Array(source)
        var output = ""
        output.reserveCapacity(chars.count)
        var state = State.code
        var index = 0

        func at(_ offset: Int, _ text: String) -> Bool {
            let start = index + offset
            let needle = Array(text)
            return start + needle.count <= chars.count && Array(chars[start..<start + needle.count]) == needle
        }
        /// Emits `count` characters as blanks, keeping line breaks.
        func blank(_ count: Int) {
            for character in chars[index..<min(index + count, chars.count)] {
                output.append(character == "\n" ? "\n" : " ")
            }
            index += count
        }
        func keep(_ count: Int) {
            output.append(contentsOf: chars[index..<min(index + count, chars.count)])
            index += count
        }

        while index < chars.count {
            switch state {
            case .code:
                if at(0, "//") { state = .lineComment; blank(2) }
                else if at(0, "/*") { state = .blockComment(depth: 1); blank(2) }
                else if at(0, "\"\"\"") { state = .multilineString; keep(3) }
                else if at(0, "\"") { state = .string; keep(1) }
                else { keep(1) }
            case .lineComment:
                if chars[index] == "\n" { state = .code; keep(1) } else { blank(1) }
            case .blockComment(let depth):
                if at(0, "/*") { state = .blockComment(depth: depth + 1); blank(2) }
                else if at(0, "*/") { state = depth == 1 ? .code : .blockComment(depth: depth - 1); blank(2) }
                else { blank(1) }
            case .string:
                if at(0, "\\") { blank(2) }
                else if at(0, "\"") { state = .code; keep(1) }
                else if chars[index] == "\n" { state = .code; keep(1) }   // unterminated; recover
                else { blank(1) }
            case .multilineString:
                if at(0, "\\") { blank(2) }
                else if at(0, "\"\"\"") { state = .code; keep(3) }
                else { blank(1) }
            }
        }
        return output
    }

    /// One-based line number of a position in `text`.
    static func line(of position: String.Index, in text: String) -> Int {
        text[..<position].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }
}
