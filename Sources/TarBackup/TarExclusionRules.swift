// TarBackup - Copyright (c) 2026 Vitalii Yurchenko. All Rights Reserved.

import Foundation

struct TarExclusionRules {
    private struct Rule {
        let pathPattern: TarPathPattern
        let namePattern: TarPathPattern?
        let subtreeRootPattern: TarPathPattern?
    }

    private let rules: [Rule]

    init(patterns: [String]) {
        rules = patterns.compactMap { pattern in
            var normalized = pattern
            while normalized.hasPrefix("./") {
                normalized.removeFirst(2)
            }
            while normalized.hasSuffix("/") {
                normalized.removeLast()
            }
            guard !normalized.isEmpty else { return nil }

            let namePattern = normalized.contains("/") ? nil : TarPathPattern(normalized)
            let subtreeRoot: String?
            if normalized.hasSuffix("/**") {
                subtreeRoot = String(normalized.dropLast(3))
            } else {
                subtreeRoot = nil
            }

            return Rule(
                pathPattern: TarPathPattern(normalized),
                namePattern: namePattern,
                subtreeRootPattern: subtreeRoot.map(TarPathPattern.init)
            )
        }
    }

    func excludes(_ relativePath: String, isDirectory: Bool) -> Bool {
        let components = relativePath.split(separator: "/").map(String.init)

        return rules.contains { rule in
            let matchesAComponent = rule.namePattern.map { namePattern in
                components.contains(where: namePattern.matches)
            } ?? false
            if rule.pathPattern.matches(relativePath) || matchesAComponent {
                return true
            }
            return isDirectory && rule.subtreeRootPattern?.matches(relativePath) == true
        }
    }
}
