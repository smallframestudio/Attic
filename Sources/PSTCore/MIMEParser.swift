import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

// MARK: - Public model

public struct HeaderField: Sendable, Hashable {
    public let name: String
    public let value: String
}

public struct MIMEHeaders: Sendable {
    public let fields: [HeaderField]

    /// First value for a header, matched case-insensitively. Values are raw (not RFC 2047 decoded).
    public subscript(_ name: String) -> String? {
        fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public func values(_ name: String) -> [String] {
        fields.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }
}

public struct EmailAddress: Sendable, Hashable {
    public let name: String
    public let address: String

    public init(name: String, address: String) {
        self.name = name
        self.address = address
    }

    /// What to show in a list: the display name when there is one, otherwise a readable address.
    /// Exchange-internal addresses ("/O=ORG/OU=.../CN=RECIPIENTS/CN=jsmith") are reduced to their last CN.
    public var display: String {
        if !name.isEmpty { return name }
        if address.hasPrefix("/"), let range = address.range(of: "cn=", options: [.caseInsensitive, .backwards]) {
            return String(address[range.upperBound...])
        }
        return address
    }

    /// "Name <address>" when both exist.
    public var full: String {
        if name.isEmpty { return address }
        if address.isEmpty || address.hasPrefix("/") { return name }
        return "\(name) <\(address)>"
    }
}

public struct MessageAttachment: Sendable, Identifiable {
    public let id: Int
    public let filename: String
    public let mimeType: String
    public let contentID: String?
    public let data: Data

    public var size: Int { data.count }
}

public struct ParsedMessage: Sendable {
    public let headers: MIMEHeaders
    public let subject: String
    public let from: EmailAddress?
    public let to: [EmailAddress]
    public let cc: [EmailAddress]
    public let bcc: [EmailAddress]
    public let date: Date?
    public let textBody: String?
    public let htmlBody: String?
    /// Files the user would think of as attachments.
    public let attachments: [MessageAttachment]
    /// Images referenced from the HTML body by `cid:` (signatures, embedded pictures).
    public let inlineParts: [MessageAttachment]

    /// Best plain-text rendering of the body.
    public var plainText: String {
        if let textBody, !textBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return textBody }
        if let htmlBody { return TextDecoding.htmlToText(htmlBody) }
        return ""
    }
}

// MARK: - Parser

public enum MIMEParser {

    public static func parse(_ data: Data) -> ParsedMessage {
        let bytes = [UInt8](data)
        let root = parsePart(bytes[...], depth: 0)
        var collector = Collector()
        collector.visit(root)

        let h = root.headers
        return ParsedMessage(
            headers: h,
            subject: TextDecoding.decodeEncodedWords(h["Subject"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            from: parseAddressList(h["From"] ?? h["Sender"] ?? "").first,
            to: parseAddressList(h["To"] ?? ""),
            cc: parseAddressList(h["Cc"] ?? ""),
            bcc: parseAddressList(h["Bcc"] ?? ""),
            date: TextDecoding.parseDate(h["Date"]),
            textBody: collector.text,
            htmlBody: collector.html,
            attachments: collector.attachments,
            inlineParts: collector.inline
        )
    }

    // MARK: Parts

    struct Part {
        let headers: MIMEHeaders
        let body: ArraySlice<UInt8>
        let contentType: String
        let params: [String: String]
        let children: [Part]
    }

    static func parsePart(_ bytes: ArraySlice<UInt8>, depth: Int) -> Part {
        let (headerBytes, body) = splitHeaderAndBody(bytes)
        let headers = parseHeaders(headerBytes)
        let (rawType, params) = parseParameterized(headers["Content-Type"] ?? "")
        let contentType = rawType.contains("/") ? rawType : "text/plain"

        var children: [Part] = []
        if contentType.hasPrefix("multipart/"), depth < 25,
           let boundary = params["boundary"], !boundary.isEmpty {
            children = splitMultipart(body, boundary: boundary).map { parsePart($0, depth: depth + 1) }
        }
        return Part(headers: headers, body: body, contentType: contentType, params: params, children: children)
    }

    /// Calls `body` with the byte range of each line (excluding the line ending) and the index where
    /// the next line starts. Return false from `body` to stop early.
    @inline(__always)
    static func forEachLine(_ s: ArraySlice<UInt8>, _ body: (Range<Int>, Int) -> Bool) {
        var start = s.startIndex
        while start < s.endIndex {
            let newline = s[start...].firstIndex(of: 10) ?? s.endIndex
            var end = newline
            if end > start, s[end - 1] == 13 { end -= 1 }
            let next = newline < s.endIndex ? newline + 1 : s.endIndex
            if !body(start..<end, next) { return }
            start = next
        }
    }

    static func splitHeaderAndBody(_ s: ArraySlice<UInt8>) -> (ArraySlice<UInt8>, ArraySlice<UInt8>) {
        var result: (ArraySlice<UInt8>, ArraySlice<UInt8>)?
        forEachLine(s) { range, next in
            if range.isEmpty {
                result = (s[s.startIndex..<range.lowerBound], s[next..<s.endIndex])
                return false
            }
            return true
        }
        return result ?? (s, s[s.endIndex..<s.endIndex])
    }

    static func parseHeaders(_ bytes: ArraySlice<UInt8>) -> MIMEHeaders {
        var fields: [HeaderField] = []
        var name: String?
        var value = ""

        forEachLine(bytes) { range, _ in
            let lineBytes = bytes[range]
            guard let first = lineBytes.first else { return true }
            let line = TextDecoding.decodeHeaderBytes(lineBytes)
            if first == 32 || first == 9 {
                // Folded continuation of the previous header.
                if name != nil { value += " " + line.trimmingCharacters(in: .whitespaces) }
                return true
            }
            if let n = name { fields.append(HeaderField(name: n, value: value)) }
            name = nil
            value = ""
            if let colon = line.firstIndex(of: ":") {
                let candidate = line[..<colon].trimmingCharacters(in: .whitespaces)
                if !candidate.isEmpty, !candidate.contains(" ") {
                    name = candidate
                    value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                }
            }
            return true
        }
        if let n = name { fields.append(HeaderField(name: n, value: value)) }
        return MIMEHeaders(fields: fields)
    }

    static func splitMultipart(_ body: ArraySlice<UInt8>, boundary: String) -> [ArraySlice<UInt8>] {
        let delimiter = Array(("--" + boundary).utf8)
        let dash = UInt8(ascii: "-")
        var parts: [ArraySlice<UInt8>] = []
        var partStart: Int?
        var closed = false

        forEachLine(body) { range, next in
            let line = body[range]
            guard line.count >= delimiter.count, line.starts(with: delimiter) else { return true }
            let rest = line.dropFirst(delimiter.count)
            let isClose = rest.count >= 2 && rest[rest.startIndex] == dash && rest[rest.startIndex + 1] == dash
            let trailing = isClose ? rest.dropFirst(2) : rest
            guard trailing.allSatisfy({ $0 == 32 || $0 == 9 }) else { return true }

            if let start = partStart {
                // The line break before a delimiter belongs to the delimiter, not the part.
                var end = range.lowerBound
                if end > start, body[end - 1] == 10 {
                    end -= 1
                    if end > start, body[end - 1] == 13 { end -= 1 }
                }
                parts.append(body[start..<max(start, end)])
            }
            if isClose {
                closed = true
                return false
            }
            partStart = next
            return true
        }
        if !closed, let start = partStart, start < body.endIndex {
            parts.append(body[start..<body.endIndex])  // missing closing delimiter
        }
        return parts
    }

    // MARK: Header values with parameters (Content-Type, Content-Disposition)

    /// Returns the lower-cased main value and its parameters (keys lower-cased, RFC 2231 decoded).
    static func parseParameterized(_ raw: String) -> (String, [String: String]) {
        let segments = split(raw, on: ";", trackAngles: false)
        let main = (segments.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var params: [String: String] = [:]
        var continuations: [String: [(index: Int, value: String, encoded: Bool)]] = [:]

        for segment in segments.dropFirst() {
            guard let eq = segment.firstIndex(of: "=") else { continue }
            var key = segment[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = unquote(String(segment[segment.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines))
            guard !key.isEmpty else { continue }

            var encoded = false
            if key.hasSuffix("*") {
                encoded = true
                key.removeLast()
            }
            if let star = key.firstIndex(of: "*"), let n = Int(key[key.index(after: star)...]) {
                continuations[String(key[..<star]), default: []].append((n, value, encoded))
                continue
            }
            params[key] = encoded ? decodeRFC2231([(0, value, true)]) : value
        }
        for (key, pieces) in continuations {
            params[key] = decodeRFC2231(pieces.sorted { $0.index < $1.index })
        }
        return (main, params)
    }

    private static func decodeRFC2231(_ pieces: [(index: Int, value: String, encoded: Bool)]) -> String {
        var charset = "utf-8"
        var bytes: [UInt8] = []
        for (position, piece) in pieces.enumerated() {
            var value = piece.value
            if position == 0, piece.encoded {
                let fields = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                if fields.count == 3 {
                    if !fields[0].isEmpty { charset = String(fields[0]) }
                    value = String(fields[2])
                }
            }
            bytes += piece.encoded ? percentDecode(value) : Array(value.utf8)
        }
        return TextDecoding.decode(Data(bytes), charset: charset)
    }

    private static func percentDecode(_ s: String) -> [UInt8] {
        let utf8 = Array(s.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(utf8.count)
        var i = 0
        while i < utf8.count {
            if utf8[i] == UInt8(ascii: "%"), i + 2 < utf8.count,
               let byte = UInt8(String(decoding: utf8[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
                out.append(byte)
                i += 3
            } else {
                out.append(utf8[i])
                i += 1
            }
        }
        return out
    }

    private static func unquote(_ s: String) -> String {
        guard s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") else { return s }
        var out = ""
        var escaped = false
        for ch in s.dropFirst().dropLast() {
            if escaped { out.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            out.append(ch)
        }
        return out
    }

    /// Splits on `separator`, ignoring separators inside double quotes (and, optionally, <angle brackets>).
    static func split(_ s: String, on separator: Character, trackAngles: Bool) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        var angleDepth = 0
        for ch in s {
            if escaped { current.append(ch); escaped = false; continue }
            if inQuotes, ch == "\\" { current.append(ch); escaped = true; continue }
            if ch == "\"" { inQuotes.toggle(); current.append(ch); continue }
            if !inQuotes, trackAngles {
                if ch == "<" { angleDepth += 1 }
                if ch == ">" { angleDepth = max(0, angleDepth - 1) }
            }
            if ch == separator, !inQuotes, angleDepth == 0 {
                parts.append(current)
                current = ""
                continue
            }
            current.append(ch)
        }
        parts.append(current)
        return parts
    }

    // MARK: Addresses

    public static func parseAddressList(_ raw: String) -> [EmailAddress] {
        // Outlook often writes unquoted "Last, First <addr>" names. A piece with no address in it
        // is treated as the first half of the next piece's display name.
        var pieces: [String] = []
        var carry = ""
        for piece in split(raw, on: ",", trackAngles: true) {
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let combined = carry.isEmpty ? trimmed : carry + ", " + trimmed
            let looksLikeAddress = trimmed.contains("@") || trimmed.contains("<") || trimmed.hasPrefix("/")
                || trimmed.contains("=?")
            if looksLikeAddress {
                pieces.append(combined)
                carry = ""
            } else {
                carry = combined
            }
        }
        if !carry.isEmpty { pieces.append(carry) }
        return pieces.compactMap(parseAddress)
    }

    static func parseAddress(_ raw: String) -> EmailAddress? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        if let lt = s.lastIndex(of: "<"), let gt = s.lastIndex(of: ">"), lt < gt {
            let address = s[s.index(after: lt)..<gt].trimmingCharacters(in: .whitespaces)
            var name = s[..<lt].trimmingCharacters(in: .whitespaces)
            name = unquote(name)
            name = TextDecoding.decodeEncodedWords(name).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("'"), name.hasSuffix("'"), name.count >= 2 { name = String(name.dropFirst().dropLast()) }
            if name == address { name = "" }
            return EmailAddress(name: name, address: address)
        }
        if let lp = s.firstIndex(of: "("), let rp = s.lastIndex(of: ")"), lp < rp {
            let name = TextDecoding.decodeEncodedWords(String(s[s.index(after: lp)..<rp]))
            let address = s[..<lp].trimmingCharacters(in: .whitespaces)
            return EmailAddress(name: name, address: address)
        }
        let decoded = TextDecoding.decodeEncodedWords(unquote(s))
        if decoded.contains("@") || decoded.hasPrefix("/") {
            return EmailAddress(name: "", address: decoded)
        }
        return EmailAddress(name: decoded, address: "")
    }

    // MARK: Body decoding

    static func decodedBody(_ part: Part) -> Data {
        let encoding = (part.headers["Content-Transfer-Encoding"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch encoding {
        case "base64": return TextDecoding.base64Decode(part.body) ?? Data(part.body)
        case "quoted-printable": return TextDecoding.quotedPrintableDecode(part.body)
        default: return Data(part.body)
        }
    }

    /// Walks the part tree, picking out the readable bodies and the attachments.
    struct Collector {
        var text: String?
        var html: String?
        var attachments: [MessageAttachment] = []
        var inline: [MessageAttachment] = []
        private var nextID = 0

        mutating func visit(_ part: Part) {
            let type = part.contentType
            if type.hasPrefix("multipart/") {
                for child in part.children { visit(child) }
                return
            }

            let (disposition, dispositionParams) = MIMEParser.parseParameterized(part.headers["Content-Disposition"] ?? "")
            var filename = (dispositionParams["filename"] ?? part.params["name"]).map {
                TextDecoding.decodeEncodedWords($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if filename?.isEmpty == true { filename = nil }
            let isAttachment = disposition == "attachment"
            let contentID = part.headers["Content-ID"].map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t"))
            }

            if !isAttachment, filename == nil {
                if type == "text/plain" {
                    if text == nil { text = TextDecoding.decode(MIMEParser.decodedBody(part), charset: part.params["charset"]) }
                    return
                }
                if type == "text/html" {
                    if html == nil { html = TextDecoding.decode(MIMEParser.decodedBody(part), charset: part.params["charset"]) }
                    return
                }
            }

            let data = MIMEParser.decodedBody(part)
            if data.isEmpty, filename == nil { return }
            nextID += 1

            if let contentID, type.hasPrefix("image/"), !isAttachment {
                inline.append(MessageAttachment(
                    id: nextID, filename: filename ?? "image-\(nextID)", mimeType: type, contentID: contentID, data: data))
                return
            }

            let name = filename ?? Self.defaultFilename(type: type, data: data, index: nextID)
            attachments.append(MessageAttachment(id: nextID, filename: name, mimeType: type, contentID: contentID, data: data))
        }

        static func defaultFilename(type: String, data: Data, index: Int) -> String {
            switch type {
            case "message/rfc822":
                let bytes = [UInt8](data.prefix(64 * 1024))
                let headers = MIMEParser.parseHeaders(MIMEParser.splitHeaderAndBody(bytes[...]).0)
                let subject = TextDecoding.decodeEncodedWords(headers["Subject"] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (subject.isEmpty ? "Attached message" : MIMEParser.sanitizeFilename(subject)) + ".eml"
            case "text/calendar":
                return "invite.ics"
            default:
                #if canImport(UniformTypeIdentifiers)
                let ext = UTType(mimeType: type)?.preferredFilenameExtension
                #else
                let ext: String? = nil
                #endif
                return "attachment-\(index)" + (ext.map { "." + $0 } ?? "")
            }
        }
    }

    public static func sanitizeFilename(_ s: String) -> String {
        let cleaned = s.map { "/:\\\0".contains($0) ? "_" : $0 }
        let result = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(result.prefix(150))
    }
}
