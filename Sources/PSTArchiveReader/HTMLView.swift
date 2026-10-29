import AppKit
import PSTCore
import SwiftUI
import WebKit

/// Shows an email's HTML body. JavaScript is off, and a Content-Security-Policy blocks anything
/// remote (tracking pixels, external images) unless the user asks to load it.
struct HTMLView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Always take exactly the space offered: the page scrolls inside the view, and never asks
    /// SwiftUI for a size of its own.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WKWebView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? 400)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = true
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        webView.loadHTMLString(html, baseURL: nil)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML: String?

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            // Links open in the default browser instead of inside the message pane.
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                    NSWorkspace.shared.open(url)
                }
                return .cancel
            }
            return .allow
        }
    }
}

enum MessageHTML {
    static func document(for message: ParsedMessage, allowRemoteContent: Bool) -> String {
        var body = message.htmlBody
            ?? "<pre style=\"white-space: pre-wrap; font: inherit\">\(TextDecoding.escapeHTML(message.plainText))</pre>"

        // Swap cid: references for inline data so embedded images show.
        for part in message.inlineParts {
            guard let cid = part.contentID, !cid.isEmpty else { continue }
            let dataURI = "data:\(part.mimeType);base64,\(part.data.base64EncodedString())"
            body = body.replacingOccurrences(of: "cid:\(cid)", with: dataURI, options: .caseInsensitive)
        }

        let remote = allowRemoteContent ? " https: http:" : ""
        let policy = "default-src 'none'; img-src data:\(remote); style-src 'unsafe-inline'\(remote); font-src data:\(remote); media-src data:\(remote)"
        return """
        <!doctype html>
        <html><head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(policy)">
        <style>
          html, body { background: #ffffff; color: #1d1d1f; }
          body { font: 13px -apple-system, "Helvetica Neue", sans-serif; margin: 16px; word-wrap: break-word; }
          img { max-width: 100%; height: auto; }
          pre { white-space: pre-wrap; }
          blockquote { border-left: 2px solid #ccc; margin-left: 0; padding-left: 10px; color: #555; }
        </style>
        </head><body>
        \(body)
        </body></html>
        """
    }

    static func hasRemoteContent(_ message: ParsedMessage) -> Bool {
        guard let html = message.htmlBody else { return false }
        return html.range(of: #"(src|background)\s*=\s*["']?\s*https?:"#, options: [.regularExpression, .caseInsensitive]) != nil
            || html.range(of: #"url\(\s*["']?https?:"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
