// attic-pdftext: prints the text of a PDF to stdout.
// Attic runs this as a separate process for each PDF attachment so that a PDF which makes
// Apple's text extraction hang (or balloon in memory) can be killed without affecting the app.
// Usage: attic-pdftext <file.pdf> [maxPages] [maxCharacters]
import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: attic-pdftext <file.pdf> [maxPages] [maxCharacters]\n".utf8))
    exit(2)
}
let maxPages = args.count > 2 ? Int(args[2]) ?? 40 : 40
let maxCharacters = args.count > 3 ? Int(args[3]) ?? 150_000 : 150_000

#if canImport(PDFKit)
guard let document = PDFDocument(url: URL(fileURLWithPath: args[1])) else { exit(1) }
var written = 0
for index in 0..<min(document.pageCount, maxPages) {
    guard let text = document.page(at: index)?.string, !text.isEmpty else { continue }
    let data = Data((text + "\n").utf8)
    FileHandle.standardOutput.write(data)
    written += data.count
    if written >= maxCharacters { break }
}
exit(0)
#else
exit(1)
#endif
