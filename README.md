# Attic

A Mac app for reading and searching old Outlook mail archives (.pst and .ost files).


- Import one or more `.pst` files; browse their folder tree, message list and messages
- Fast full-text search across subject, sender, recipients, body, attachment names, and the text inside PDF/text attachments
- Search syntax: `"exact phrase"`, `-exclude`, `from:` `to:` `cc:` `subject:` `body:` `attachment:`, `has:attachment`, `after:2019-01-01` `before:2020`, `larger:5MB` `smaller:200KB`
- Advanced search: the options button at the right of the search box (⌥⌘F) opens a form for sender, recipients, subject, words, size, date range, folder and attachments
- HTML mail rendered with JavaScript off and remote images blocked until you click **Load Remote Images**
- Open or save attachments, open any message in Mail, or save it as `.eml`
- Everything stays on your Mac. Your original `.pst` is only read, never modified.

## Setup (one time)

1. **Swift toolchain** — Xcode 15 or later, or just the Command Line Tools (`xcode-select --install`).
2. **readpst** — the free libpst tool the app uses to unpack the PST format:
   ```
   brew install libpst
   ```
   (No Homebrew? Get it from https://brew.sh.) If readpst is missing, the app explains this when you import.

## Build and run

```
cd attic
./build-app.sh
open "build/Attic.app"
```

Drag the app into `/Applications` if you want to keep it.

To make an installer instead, run `./make-dmg.sh`. It builds the app and creates `build/Attic-1.1.dmg`; open that and drag Attic onto Applications. The .dmg works on other Macs too (see the note on sharing below). Alternatively, open `Package.swift` in Xcode, choose the **Attic** scheme and press Run.

Run the parser and search tests with `swift test` (needs full Xcode).

## Using it

**File ▸ Import Outlook Archive…** (⌘O), or drop a `.pst` onto the window. Import time is roughly a minute per few GB. Searches apply to whatever is selected in the sidebar, so select **All Messages** (or **All Archives**) to search everything. Right-click an archive name to remove it.

## Where things are kept

`~/Library/Application Support/Attic/`

- `library.sqlite` — metadata and the SQLite FTS5 search index
- `archives/<id>/mail/` — the messages extracted from each PST as `.eml` files (about the size of the original PST)

Removing an archive in the app deletes its folder here. Deleting this whole folder resets the app.

## How it works

| File | Role |
| --- | --- |
| `Sources/AtticCore/ArchiveImporter.swift` | Runs `readpst -e` to unpack the PST into `.eml` files, then parses them in parallel and indexes them |
| `Sources/AtticCore/MIMEParser.swift` | MIME parser: multipart, base64/quoted-printable, RFC 2047/2231 names, charsets, inline images |
| `Sources/AtticCore/TextDecoding.swift` | Charset handling, HTML-to-text, date parsing |
| `Sources/AtticCore/Library.swift` | SQLite store, FTS5 index and search |
| `Sources/AtticCore/SearchQuery.swift` | Turns the search box text into an FTS5 query |
| `Sources/AtticCore/SearchForm.swift` | The advanced-search form, converted to and from search-box text |
| `Sources/Attic/` | SwiftUI interface |
| `Resources/` | App icon: `AppIcon.svg` (source), `AppIcon.icns` (used by the build); `make_icon.py` regenerates it |

## Sharing the .dmg with others

- The app is signed only for local use, so on another Mac the first launch shows an "unidentified developer" warning. They can right-click Attic → Open → Open once, or allow it in System Settings → Privacy & Security. Removing that warning entirely requires an Apple Developer ID ($99/year) and Apple's notarization.
- Each Mac also needs `brew install libpst` for readpst. The app explains this the first time someone imports a .pst.

## Limitations

- Email only. Calendar, contacts and tasks in the PST are skipped.
- Text inside Word and Excel attachments is not indexed (their file names are).
- Very old ANSI-format PSTs (Outlook 97–2002) work if readpst can read them; password-protected PSTs open without the password, as with readpst.
