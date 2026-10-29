import Foundation

/// The advanced-search form. It converts to and from the search-box text, so the box stays the
/// single source of truth: opening the form shows what the box says, and Search writes it back.
public struct SearchForm: Equatable, Sendable {

    public enum SizeComparison: String, CaseIterable, Identifiable, Sendable {
        case greaterThan, lessThan
        public var id: String { rawValue }
        public var title: String { self == .greaterThan ? "greater than" : "less than" }
        var field: String { self == .greaterThan ? "larger" : "smaller" }
    }

    public enum SizeUnit: String, CaseIterable, Identifiable, Sendable {
        case mb, kb, bytes
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .mb: return "MB"
            case .kb: return "KB"
            case .bytes: return "Bytes"
            }
        }
        var suffix: String {
            switch self {
            case .mb: return "MB"
            case .kb: return "KB"
            case .bytes: return ""
            }
        }
        var bytes: Double {
            switch self {
            case .mb: return 1_000_000
            case .kb: return 1_000
            case .bytes: return 1
            }
        }
    }

    public enum DateRange: String, CaseIterable, Identifiable, Sendable {
        case day, threeDays, week, twoWeeks, month, twoMonths, sixMonths, year
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .day: return "1 day"
            case .threeDays: return "3 days"
            case .week: return "1 week"
            case .twoWeeks: return "2 weeks"
            case .month: return "1 month"
            case .twoMonths: return "2 months"
            case .sixMonths: return "6 months"
            case .year: return "1 year"
            }
        }
        var components: DateComponents {
            switch self {
            case .day: return DateComponents(day: 1)
            case .threeDays: return DateComponents(day: 3)
            case .week: return DateComponents(day: 7)
            case .twoWeeks: return DateComponents(day: 14)
            case .month: return DateComponents(month: 1)
            case .twoMonths: return DateComponents(month: 2)
            case .sixMonths: return DateComponents(month: 6)
            case .year: return DateComponents(year: 1)
            }
        }
    }

    public var from = ""
    public var to = ""
    public var subject = ""
    public var hasWords = ""
    public var doesntHave = ""
    public var sizeComparison = SizeComparison.greaterThan
    public var sizeValue = ""
    public var sizeUnit = SizeUnit.mb
    public var dateRange = DateRange.day
    /// Typed date (empty = no date filter). Accepts the system short format, yyyy-mm-dd and m/d/yyyy.
    public var dateText = ""
    public var hasAttachment = false

    public init() {}

    public var isEmpty: Bool { queryString.isEmpty }

    // MARK: Form → search text

    public var queryString: String {
        var parts: [String] = []
        parts += Self.fieldTerms("from", from)
        parts += Self.fieldTerms("to", to)
        parts += Self.fieldTerms("subject", subject)
        let words = hasWords.trimmingCharacters(in: .whitespaces)
        if !words.isEmpty { parts.append(words) }
        parts += SearchQuery.tokenize(doesntHave).map { token in
            "-" + (token.field.map { $0 + ":" } ?? "") + Self.render(token.value, phrase: token.isPhrase)
        }
        if let size = Double(sizeValue.trimmingCharacters(in: .whitespaces)), size >= 0 {
            parts.append("\(sizeComparison.field):\(Self.formatNumber(size))\(sizeUnit.suffix)")
        }
        if let anchor = date, let (after, before) = Self.bounds(around: anchor, range: dateRange) {
            parts.append("after:\(Self.isoDay(after))")
            parts.append("before:\(Self.isoDay(before))")
        }
        if hasAttachment { parts.append("has:attachment") }
        return parts.joined(separator: " ")
    }

    /// The typed date, if it parses.
    public var date: Date? {
        let text = dateText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        for formatter in Self.inputFormatters {
            if let date = formatter.date(from: text) { return Calendar.current.startOfDay(for: date) }
        }
        return SearchQuery.parseDay(text)
    }

    /// True when a date was typed that can't be understood.
    public var dateIsInvalid: Bool {
        !dateText.trimmingCharacters(in: .whitespaces).isEmpty && date == nil
    }

    public mutating func setDate(_ date: Date) {
        dateText = Self.displayFormatter.string(from: date)
    }

    // MARK: Search text → form

    public init(parsing text: String) {
        var froms: [String] = [], tos: [String] = [], subjects: [String] = []
        var words: [String] = [], excluded: [String] = []
        var after: Date?, before: Date?
        var afterRaw: String?, beforeRaw: String?

        for token in SearchQuery.tokenize(text) {
            let value = Self.render(token.value, phrase: token.isPhrase)
            if token.negated {
                excluded.append((token.field.map { $0 + ":" } ?? "") + value)
                continue
            }
            switch token.field {
            case "from": froms.append(value)
            case "to": tos.append(value)
            case "subject": subjects.append(value)
            case "has" where token.value.lowercased().hasPrefix("attach"):
                hasAttachment = true
            case "larger", "smaller":
                if let parsed = Self.parseSizeField(token.value) {
                    sizeComparison = token.field == "larger" ? .greaterThan : .lessThan
                    (sizeValue, sizeUnit) = parsed
                } else {
                    words.append(Self.raw(token))
                }
            case "after":
                after = SearchQuery.parseDay(token.value); afterRaw = Self.raw(token)
            case "before":
                before = SearchQuery.parseDay(token.value); beforeRaw = Self.raw(token)
            default:
                words.append(Self.raw(token))
            }
        }

        // after:/before: map back to "within <range> of <date>" only when they fit one exactly.
        if let after, let before, let (range, anchor) = Self.rangeMatching(after: after, before: before) {
            dateRange = range
            setDate(anchor)
        } else {
            words += [afterRaw, beforeRaw].compactMap { $0 }
        }

        from = froms.joined(separator: " ")
        to = tos.joined(separator: " ")
        subject = subjects.joined(separator: " ")
        hasWords = words.joined(separator: " ")
        doesntHave = excluded.joined(separator: " ")
    }

    // MARK: Helpers

    /// "dan smith" → from:dan from:smith (each word prefix-matched); quoted text stays a phrase.
    static func fieldTerms(_ field: String, _ text: String) -> [String] {
        SearchQuery.tokenize(text).map { "\(field):" + render($0.value, phrase: $0.isPhrase) }
    }

    static func render(_ value: String, phrase: Bool) -> String {
        phrase || value.contains(" ") ? "\"\(value)\"" : value
    }

    static func raw(_ token: SearchQuery.Token) -> String {
        (token.negated ? "-" : "") + (token.field.map { $0 + ":" } ?? "") + render(token.value, phrase: token.isPhrase)
    }

    static func parseSizeField(_ value: String) -> (String, SizeUnit)? {
        guard let bytes = SearchQuery.parseSize(value) else { return nil }
        let lower = value.lowercased()
        let unit: SizeUnit = lower.hasSuffix("m") || lower.hasSuffix("mb") ? .mb
            : lower.hasSuffix("k") || lower.hasSuffix("kb") ? .kb
            : lower.hasSuffix("g") || lower.hasSuffix("gb") ? .mb
            : .bytes
        return (formatNumber(Double(bytes) / unit.bytes), unit)
    }

    static func formatNumber(_ n: Double) -> String {
        n == n.rounded() ? String(Int(n)) : String(n)
    }

    /// The day range searched: from `range` before the anchor through `range` after it.
    /// `before` is exclusive (the day after the last included day).
    static func bounds(around anchor: Date, range: DateRange) -> (Date, Date)? {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: anchor)
        var negative = range.components
        negative.day = negative.day.map { -$0 }
        negative.month = negative.month.map { -$0 }
        negative.year = negative.year.map { -$0 }
        guard let after = calendar.date(byAdding: negative, to: day),
              let last = calendar.date(byAdding: range.components, to: day),
              let before = calendar.date(byAdding: .day, value: 1, to: last) else { return nil }
        return (after, before)
    }

    static func rangeMatching(after: Date, before: Date) -> (DateRange, Date)? {
        let calendar = Calendar.current
        guard let last = calendar.date(byAdding: .day, value: -1, to: before) else { return nil }
        for range in DateRange.allCases {
            var negative = range.components
            negative.day = negative.day.map { -$0 }
            negative.month = negative.month.map { -$0 }
            negative.year = negative.year.map { -$0 }
            guard let anchor = calendar.date(byAdding: negative, to: last),
                  let bounds = bounds(around: anchor, range: range) else { continue }
            if calendar.isDate(bounds.0, inSameDayAs: after), calendar.isDate(bounds.1, inSameDayAs: before) {
                return (range, anchor)
            }
        }
        return nil
    }

    static func isoDay(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    static let inputFormatters: [DateFormatter] = {
        var formatters = [displayFormatter]
        let short = DateFormatter()
        short.dateStyle = .short
        short.timeStyle = .none
        formatters.append(short)
        for format in ["yyyy-MM-dd", "M/d/yyyy", "M/d/yy", "MMM d, yyyy", "d MMM yyyy"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = format
            formatters.append(f)
        }
        return formatters
    }()
}
