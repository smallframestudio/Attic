import Foundation

/// Character-set, header and HTML helpers used by the MIME parser and the indexer.
public enum TextDecoding {

    // MARK: Character sets

    private static let charsetAliases: [String: String] = [
        "utf8": "utf-8",
        "unicode-1-1-utf-7": "utf-7",
        "ks_c_5601-1987": "euc-kr",
        "x-sjis": "shift_jis",
        "gb2312": "gbk",
        "ascii": "us-ascii",
        "latin1": "iso-8859-1",
        "cp1252": "windows-1252",
    ]

    public static func encoding(forCharset rawName: String) -> String.Encoding? {
        var name = rawName.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).lowercased()
        if let alias = charsetAliases[name] { name = alias }
        guard !name.isEmpty else { return nil }
        #if canImport(Darwin)
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
        #else
        // Only used when building the core on Linux for testing.
        let basic: [String: String.Encoding] = [
            "utf-8": .utf8, "us-ascii": .ascii, "iso-8859-1": .isoLatin1, "windows-1252": .windowsCP1252,
            "iso-8859-2": .isoLatin2, "utf-16": .utf16,
        ]
        return basic[name]
        #endif
    }

    /// Decodes bytes as text, trying the declared charset first, then UTF-8, then Windows-1252.
    public static func decode(_ data: Data, charset: String?) -> String {
        if let charset, let enc = encoding(forCharset: charset), let s = String(data: data, encoding: enc) {
            return s
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .windowsCP1252) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    /// Header lines are supposed to be ASCII but often aren't; prefer UTF-8, fall back to Latin-1.
    static func decodeHeaderBytes<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        if let s = String(bytes: bytes, encoding: .utf8) { return s }
        return String(bytes: bytes, encoding: .isoLatin1) ?? ""
    }

    // MARK: RFC 2047 encoded words  (=?charset?B?...?= / =?charset?Q?...?=)

    private static let encodedWordRegex = try! NSRegularExpression(
        pattern: #"=\?([^?\s]+)\?([bBqQ])\?([^?\s]*)\?="#)

    public static func decodeEncodedWords(_ input: String) -> String {
        guard input.contains("=?") else { return input }
        let ns = input as NSString
        let matches = encodedWordRegex.matches(in: input, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return input }

        var output = ""
        var cursor = 0
        var previousWasEncoded = false
        for match in matches {
            let gap = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            // Whitespace between two adjacent encoded words is dropped (RFC 2047 §6.2).
            if !(previousWasEncoded && gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                output += gap
            }
            var charset = ns.substring(with: match.range(at: 1))
            if let star = charset.firstIndex(of: "*") { charset = String(charset[..<star]) }  // RFC 2231 language
            let mode = ns.substring(with: match.range(at: 2)).uppercased()
            let payload = ns.substring(with: match.range(at: 3))

            let bytes: Data?
            if mode == "B" {
                bytes = base64Decode(Array(payload.utf8)[...])
            } else {
                let underscoresAsSpaces = Array(payload.utf8).map { $0 == UInt8(ascii: "_") ? UInt8(ascii: " ") : $0 }
                bytes = quotedPrintableDecode(underscoresAsSpaces[...])
            }
            if let bytes {
                output += decode(bytes, charset: charset)
            } else {
                output += ns.substring(with: match.range)
            }
            cursor = match.range.location + match.range.length
            previousWasEncoded = true
        }
        output += ns.substring(from: cursor)
        return output
    }

    // MARK: Transfer encodings

    public static func base64Decode(_ bytes: ArraySlice<UInt8>) -> Data? {
        var clean = [UInt8]()
        clean.reserveCapacity(bytes.count)
        for b in bytes {
            switch b {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "+"), UInt8(ascii: "/"):
                clean.append(b)
            case UInt8(ascii: "-"): clean.append(UInt8(ascii: "+"))   // tolerate base64url
            case UInt8(ascii: "_"): clean.append(UInt8(ascii: "/"))
            default: continue  // whitespace, padding, junk
            }
        }
        if clean.count % 4 == 1 { clean.removeLast() }
        while clean.count % 4 != 0 { clean.append(UInt8(ascii: "=")) }
        return Data(base64Encoded: Data(clean))
    }

    public static func quotedPrintableDecode(_ bytes: ArraySlice<UInt8>) -> Data {
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        var i = bytes.startIndex
        let end = bytes.endIndex
        while i < end {
            let c = bytes[i]
            if c == UInt8(ascii: "=") {
                // Soft line break: "=\n" or "=\r\n"
                if i + 1 < end, bytes[i + 1] == 10 { i += 2; continue }
                if i + 2 < end, bytes[i + 1] == 13, bytes[i + 2] == 10 { i += 3; continue }
                if i + 2 < end, let hi = hexValue(bytes[i + 1]), let lo = hexValue(bytes[i + 2]) {
                    out.append(hi << 4 | lo)
                    i += 3
                    continue
                }
                if i + 1 == end { break }  // trailing "=" at end of input
            }
            out.append(c)
            i += 1
        }
        return Data(out)
    }

    private static func hexValue(_ b: UInt8) -> UInt8? {
        switch b {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return b - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return b - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return b - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    // MARK: HTML → plain text (for indexing and the plain-text view)

    private static let spaceRuns = try! NSRegularExpression(pattern: #"[ \t\u00A0]+"#)
    private static let blankLines = try! NSRegularExpression(pattern: #"\n[ \t]*(\n[ \t]*)+"#)
    private static let entity = try! NSRegularExpression(pattern: #"&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z][a-zA-Z0-9]{1,10});"#)

    /// Largest HTML body converted for indexing; beyond this the text adds little and costs time.
    static let maxHTMLBytes = 4_000_000

    /// Converts HTML to plain text in a single forward pass, so time grows linearly with size even
    /// for broken markup (unclosed comments, <style> or <script> tags, stray "<").
    public static func htmlToText(_ html: String) -> String {
        var bytes = Array(html.utf8)
        if bytes.count > maxHTMLBytes { bytes.removeSubrange(maxHTMLBytes...) }
        let n = bytes.count
        var out = [UInt8]()
        out.reserveCapacity(n / 2)

        let lt = UInt8(ascii: "<"), gt = UInt8(ascii: ">"), slash = UInt8(ascii: "/"), bang = UInt8(ascii: "!")
        let newline = UInt8(ascii: "\n"), space = UInt8(ascii: " ")
        var nextGT = -1          // cached position of the next ">" (n means there is none)

        @inline(__always) func lower(_ b: UInt8) -> UInt8 { (b >= 65 && b <= 90) ? b + 32 : b }
        @inline(__always) func isLetter(_ b: UInt8) -> Bool { let l = lower(b); return l >= 97 && l <= 122 }

        /// Index just past the first occurrence of `needle` (ASCII, matched case-insensitively) at or after `from`, or nil.
        func find(_ needle: [UInt8], from: Int) -> Int? {
            guard let first = needle.first, needle.count <= n else { return nil }
            var i = from
            while i <= n - needle.count {
                if lower(bytes[i]) == first {
                    var k = 1
                    while k < needle.count, lower(bytes[i + k]) == needle[k] { k += 1 }
                    if k == needle.count { return i + needle.count }
                }
                i += 1
            }
            return nil
        }

        var i = 0
        while i < n {
            let b = bytes[i]
            guard b == lt, i + 1 < n else { out.append(b); i += 1; continue }
            let c = bytes[i + 1]

            // Comment: skip to "-->", or drop the rest if it never closes.
            if c == bang, i + 3 < n, bytes[i + 2] == UInt8(ascii: "-"), bytes[i + 3] == UInt8(ascii: "-") {
                i = find(Array("-->".utf8), from: i + 4) ?? n
                continue
            }
            // Not a tag ("a < b"): keep the "<" as text.
            guard isLetter(c) || c == slash || c == bang else { out.append(b); i += 1; continue }

            if nextGT < i {
                nextGT = i
                while nextGT < n, bytes[nextGT] != gt { nextGT += 1 }
            }
            if nextGT >= n { out.append(b); i += 1; continue }   // no ">" anywhere after: plain text

            // Tag name.
            let closing = c == slash
            var j = closing ? i + 2 : i + 1
            var name: [UInt8] = []
            while j < n, j < nextGT, isLetter(bytes[j]) || (bytes[j] >= 48 && bytes[j] <= 57) {
                if name.count < 12 { name.append(lower(bytes[j])) }
                j += 1
            }
            let tagEnd = nextGT + 1
            let tag = String(decoding: name, as: UTF8.self)

            if !closing, ["script", "style", "head", "title"].contains(tag) {
                // Skip everything up to the matching close tag, or the rest if it never closes.
                if let close = find(Array("</\(tag)".utf8), from: tagEnd) {
                    var k = close
                    while k < n, bytes[k] != gt { k += 1 }
                    i = min(n, k + 1)
                } else {
                    i = n
                }
                out.append(space)
                continue
            }

            let breaks: Set<String> = ["p", "div", "tr", "li", "h1", "h2", "h3", "h4", "h5", "h6",
                                       "table", "blockquote", "pre"]
            if tag == "br" || (closing && breaks.contains(tag)) {
                out.append(newline)
            } else {
                out.append(space)
            }
            i = tagEnd
        }

        var s = String(decoding: out, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        s = decodeEntities(s)
        s = spaceRuns.replace(in: s, with: " ")
        s = blankLines.replace(in: s, with: "\n\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "ndash": "–", "mdash": "—", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "hellip": "…", "bull": "•", "middot": "·", "copy": "©", "reg": "®", "trade": "™",
        "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "deg": "°", "times": "×",
        "eacute": "é", "egrave": "è", "aacute": "á", "agrave": "à", "uuml": "ü", "ouml": "ö",
        "auml": "ä", "szlig": "ß", "ccedil": "ç", "ntilde": "ñ", "iacute": "í", "oacute": "ó", "uacute": "ú",
        "zwnj": "", "zwj": "", "shy": "",
    ]

    public static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let ns = s as NSString
        var out = ""
        var cursor = 0
        for match in entity.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let name = ns.substring(with: match.range(at: 1))
            if let value = entityValue(name) {
                out += value
            } else {
                out += ns.substring(with: match.range)
            }
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    private static func entityValue(_ name: String) -> String? {
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let code: UInt32?
            if digits.first == "x" || digits.first == "X" {
                code = UInt32(digits.dropFirst(), radix: 16)
            } else {
                code = UInt32(digits)
            }
            guard let code, let scalar = Unicode.Scalar(code) else { return nil }
            return String(Character(scalar))
        }
        return namedEntities[name.lowercased()]
    }

    public static func escapeHTML(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(ch)
            }
        }
        return out
    }

    /// First `limit` characters of `text` with all runs of whitespace collapsed to single spaces.
    /// Invisible characters are dropped too: marketing emails often open with "preheader padding"
    /// (zero-width joiners, U+034F, soft hyphens) that would otherwise make the preview look empty.
    public static func snippet(_ text: String, limit: Int = 240) -> String {
        var out = ""
        out.reserveCapacity(limit)
        var pendingSpace = false
        var count = 0
        for ch in text {
            if ch.isWhitespace || isInvisible(ch) {
                if ch.unicodeScalars.contains(where: { $0.properties.isWhitespace }) { pendingSpace = count > 0 }
                continue
            }
            if pendingSpace { out.append(" "); count += 1; pendingSpace = false }
            out.append(ch)
            count += 1
            if count >= limit { break }
        }
        return out
    }

    static func isInvisible(_ ch: Character) -> Bool {
        ch.unicodeScalars.allSatisfy { s in
            s.properties.generalCategory == .format          // zero-width space/joiners, soft hyphen, BOM
                || s.value == 0x034F                         // combining grapheme joiner
                || (0xFE00...0xFE0F).contains(s.value)       // variation selectors
                || s.properties.isWhitespace
        }
    }

    // MARK: Dates

    private static let dateFormatters: [DateFormatter] = [
        "EEE, d MMM yyyy HH:mm:ss Z",
        "d MMM yyyy HH:mm:ss Z",
        "EEE, d MMM yyyy HH:mm Z",
        "d MMM yyyy HH:mm Z",
        "EEE, d MMM yyyy HH:mm:ss zzz",
        "d MMM yyyy HH:mm:ss zzz",
        "EEE, d MMM yy HH:mm:ss Z",
        "EEE, d MMM yyyy HH:mm:ss",
    ].map { format in
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = format
        return f
    }

    public static func parseDate(_ raw: String?) -> Date? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if let paren = s.firstIndex(of: "(") {
            s = String(s[..<paren]).trimmingCharacters(in: .whitespaces)
        }
        s = s.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        for formatter in dateFormatters {
            if let date = formatter.date(from: s) { return date }
        }
        return nil
    }
}

extension NSRegularExpression {
    func replace(in s: String, with template: String) -> String {
        stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
    }
}
