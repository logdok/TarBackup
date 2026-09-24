// TarBackup - Copyright (c) 2026 Vitalii Yurchenko. All Rights Reserved.

import Foundation

struct TarPathPattern {
    private let regularExpression: NSRegularExpression

    init(_ pattern: String) {
        let characters = Array(pattern)
        var expression = "^"
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if character == "*" {
                let nextIndex = index + 1
                if nextIndex < characters.count, characters[nextIndex] == "*" {
                    let slashIndex = nextIndex + 1
                    if slashIndex < characters.count, characters[slashIndex] == "/" {
                        expression += "(?:.*/)?"
                        index = slashIndex + 1
                    } else {
                        expression += ".*"
                        index = nextIndex + 1
                    }
                } else {
                    expression += "[^/]*"
                    index += 1
                }
            } else if character == "?" {
                expression += "[^/]"
                index += 1
            } else {
                expression += NSRegularExpression.escapedPattern(for: String(character))
                index += 1
            }
        }

        expression += "$"
        regularExpression = try! NSRegularExpression(pattern: expression)
    }

    func matches(_ path: String) -> Bool {
        let range = NSRange(path.startIndex..<path.endIndex, in: path)
        return regularExpression.firstMatch(in: path, range: range) != nil
    }
}
