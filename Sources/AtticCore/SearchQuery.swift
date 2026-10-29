import Foundation

/// Turns what the user types in the search field into an SQLite FTS5 expression plus SQL filters.
///
/// Supported syntax:
///   budget meeting            all words, prefix-matched (budg finds budget)
///   "exact phrase"            phrase match
///   -word                     exclude messages containing word
///   from:dan  to:alice  cc:bob  subject:report  body:invoice
///   attachment:pdf  (alias file:)   matches attachment names and text inside PDF attachments
///   has:attachment
///   larger:5MB  smaller:200KB        message size (units: B, KB, MB, GB; plain numbers are bytes)
///   after:2019-01-01  before:2020-06-30  (dates are local, before: is exclusive)
public struct SearchQuery: Sendable, Equatable {
    public var matchExpression: String?
    public var excludeExpression: String?
    public var after: Date?
    public var before: Date?
    public var requiresAttachment = false
    /// Message size bounds in bytes (exclusive).
    public var largerThan: Int?
    public var smallerThan: Int?

    public var isEmpty: Bool {
        matchExpression == nil && excludeExpression == nil && after == nil && before == nil && !requiresAttachment
            && largerThan == nil && smallerThan == nil
    }

    private static let columnForField: [String: String] = [
        "from": "sender",
        "to": "recipients",
        "cc": "recipients",
        "subject": "subject",
        "body": "body",
        "attachment": "attachments",
        "file": "attachments",
    ]

    static let filterFields: Set<String> = ["has", "before", "after", "larger", "smaller"]

    public struct Token: Equatable, Sendable {
        var negated = false
        var field: String?
        var value = ""
        var isPhrase = false
    }

    public init(parsing text: String) {
        var positives: [String] = []
        var negatives: [String] = []

        for token in Self.tokenize(text) {
            if let field = token.field, Self.filterFields.contains(field) {
                applyFilter(field: field, value: token.value.lowercased())
                continue
            }
            guard let phrase = Self.ftsPhrase(token.value, prefix: !token.isPhrase) else { continue }
            var term = phrase
            if let field = token.field, let column = Self.columnForField[field] {
                term = "\(column) : \(phrase)"
            }
            if token.negated { negatives.append(term) } else { positives.append(term) }
        }

        matchExpression = positives.isEmpty ? nil : positives.joined(separator: " AND ")
        excludeExpression = negatives.isEmpty ? nil : negatives.joined(separator: " OR ")
    }

    private mutating func applyFilter(field: String, value: String) {
        switch field {
        case "has":
            if value.hasPrefix("attach") || value == "file" || value == "files" { requiresAttachment = true }
        case "after":
            if let date = Self.parseDay(value) { after = date }
        case "before":
            if let date = Self.parseDay(value) { before = date }
        case "larger":
            if let bytes = Self.parseSize(value) { largerThan = bytes }
        case "smaller":
            if let bytes = Self.parseSize(value) { smallerThan = bytes }
        default:
            break
        }
    }

    static func parseDay(_ value: String) -> Date? {
        let parts = value.split(whereSeparator: { $0 == "-" || $0 == "/" || $0 == "." }).compactMap { Int($0) }
        var components = DateComponents()
        switch parts.count {
        case 1:  // a bare year
            guard parts[0] > 1900 else { return nil }
            components.year = parts[0]; components.month = 1; components.day = 1
        case 2:
            components.year = parts[0]; components.month = parts[1]; components.day = 1
        case 3:
            components.year = parts[0]; components.month = parts[1]; components.day = parts[2]
        default:
            return nil
        }
        return Calendar.current.date(from: components)
    }

    /// "5MB", "1.5mb", "200k", "300" (bytes). Decimal units, matching Finder's file sizes.
    public static func parseSize(_ value: String) -> Int? {
        let v = value.trimmingCharacters(in: .whitespaces).lowercased()
        let digits = v.prefix { $0.isNumber || $0 == "." }
        guard let number = Double(digits), number >= 0 else { return nil }
        let multiplier: Double
        switch v.dropFirst(digits.count) {
        case "", "b", "bytes", "byte": multiplier = 1
        case "k", "kb": multiplier = 1_000
        case "m", "mb": multiplier = 1_000_000
        case "g", "gb": multiplier = 1_000_000_000
        default: return nil
        }
        return Int(number * multiplier)
    }

    /// Quotes a value as an FTS5 string. Returns nil for values with nothing searchable in them,
    /// which FTS5 would otherwise reject or match nothing for.
    static func ftsPhrase(_ value: String, prefix: Bool) -> String? {
        let cleaned = value.replacingOccurrences(of: "\"", with: " ").trimmingCharacters(in: .whitespaces)
        guard cleaned.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { return nil }
        return "\"\(cleaned)\"" + (prefix ? "*" : "")
    }

    static func tokenize(_ text: String) -> [Token] {
        let knownFields = Set(columnForField.keys).union(filterFields)
        var tokens: [Token] = []
        let chars = Array(text)
        var i = 0

        while i < chars.count {
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            guard i < chars.count else { break }

            var token = Token()
            if chars[i] == "-", i + 1 < chars.count, !chars[i + 1].isWhitespace {
                token.negated = true
                i += 1
            }

            // Optional "field:" prefix.
            var j = i
            while j < chars.count, chars[j].isLetter { j += 1 }
            if j > i, j < chars.count, chars[j] == ":" {
                let field = String(chars[i..<j]).lowercased()
                if knownFields.contains(field) {
                    token.field = field
                    i = j + 1
                }
            }

            if i < chars.count, chars[i] == "\"" {
                token.isPhrase = true
                i += 1
                while i < chars.count, chars[i] != "\"" { token.value.append(chars[i]); i += 1 }
                if i < chars.count { i += 1 }  // closing quote
            } else {
                while i < chars.count, !chars[i].isWhitespace { token.value.append(chars[i]); i += 1 }
            }

            if !token.value.isEmpty { tokens.append(token) }
        }
        return tokens
    }
}
