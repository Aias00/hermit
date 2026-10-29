import Foundation

// MARK: - What a tap can open

/// Files a tap on a terminal path opens in place — what QuickLook shows on
/// iOS without help: images, video, audio, PDF, Office/iWork documents and
/// plain text. Agents report their output as paths ("对比图：qchar/out/
/// GripLab.png"); this list is what makes such a path worth a link.
///
/// Source code is deliberately NOT here. Claude Code mentions dozens of
/// source paths per turn, and underlining every one of them would bury the
/// handful of outputs a person actually wants to look at.
enum PreviewableFile {
    enum Kind: Equatable, Sendable {
        case image, video, audio, pdf, document, text
    }

    static let kinds: [String: Kind] = {
        var map: [String: Kind] = [:]
        for ext in ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff", "avif", "ico"] {
            map[ext] = .image
        }
        for ext in ["mp4", "mov", "m4v"] { map[ext] = .video }
        for ext in ["mp3", "m4a", "wav", "aac", "aiff", "flac"] { map[ext] = .audio }
        map["pdf"] = .pdf
        for ext in ["docx", "doc", "xlsx", "xls", "pptx", "ppt", "key", "pages", "numbers", "rtf"] {
            map[ext] = .document
        }
        for ext in ["md", "markdown", "txt", "csv", "tsv", "json", "html", "htm", "svg", "log"] {
            map[ext] = .text
        }
        return map
    }()

    /// The kind a path's extension names, case-insensitively. nil for
    /// anything QuickLook wouldn't show (or that isn't worth a link).
    static func kind(of path: String) -> Kind? {
        guard let dot = path.lastIndex(of: "."),
              path[dot...].count > 1,
              !path[dot...].contains("/") else { return nil }
        return kinds[path[path.index(after: dot)...].lowercased()]
    }

    /// The extensions as one ERE, for the host-side probe's "does this
    /// folder hold anything previewable" check.
    static var extensionPattern: String {
        "\\.(" + kinds.keys.sorted().joined(separator: "|") + ")$"
    }
}

// MARK: - Finding paths in terminal text

/// Picks out the runs of a terminal line that could name a file or folder
/// on the host — candidates only. Nothing here knows whether a path EXISTS;
/// `PathProbe` asks the host, and only what it confirms ever becomes a
/// link, which is what keeps prose like "s45/s55" or "and/or" from turning
/// blue.
///
/// Splits on anything that can't be part of a path, rather than matching a
/// path regex: a sentence-ending period, a full-width colon (Claude Code's
/// "对比图："), Markdown emphasis, quotes and parentheses all just end the
/// run. ASCII runs — a path glued to CJK prose ("保存到out/a.png") then
/// starts where the ASCII does. A CJK NAME inside a path
/// ("episodes/nolift/改稿建议.md") is picked back up by `wideNameTail`.
enum TerminalPathScanner {
    struct Candidate: Equatable, Sendable {
        /// The path as printed (`~/…`, `/…`, `./…`, relative, or a bare
        /// file name).
        let token: String
        /// Character offset of the first character within the scanned line.
        /// `Terminal.viewportLineText` yields one Character per column, so
        /// this is also the column offset.
        let offset: Int
        let length: Int
        /// True when the token can only be worth a link as a FOLDER: its
        /// last component names no previewable file. The probe then accepts
        /// it only if it is a directory holding something previewable.
        let directoryOnly: Bool
    }

    static func scan(_ line: String) -> [Candidate] {
        let characters = Array(line)
        var found: [Candidate] = []
        var index = 0
        while index < characters.count {
            guard isPathCharacter(characters[index]) else {
                index += 1
                continue
            }
            let start = index
            while index < characters.count, isPathCharacter(characters[index]) { index += 1 }
            let run = String(characters[start..<index])
            let tail = run.contains("/") ? wideNameTail(characters, from: index) : nil
            let body = run + (tail?.name ?? "")
            let end = index + (tail?.columns ?? 0)
            // Longest first: the link pass tags the first one the host
            // confirms, and the shorter ones then start inside its link.
            var variants: [Candidate] = []
            for headStart in wideHeadStarts(characters, before: start, run: run) {
                let head = String(characters[headStart..<start].filter { $0 != "\0" })
                if let candidate = classify(head + body, at: headStart, columns: end - headStart) {
                    variants.append(candidate)
                }
            }
            if tail != nil, let candidate = classify(body, at: start, columns: end - start) {
                variants.append(candidate)
            }
            if tail != nil, !variants.isEmpty {
                found += variants
                index = end
                continue
            }
            if let candidate = classify(run, at: start) { variants.append(candidate) }
            found += variants
        }
        return found
    }

    /// How far back a CJK name glued to a path is followed.
    static let headLimit = 16

    /// Where a path may start before its ASCII run, when the run opens on a
    /// separator glued to a CJK name: `成品` + `/西游.mp4`, `粗剪` + `.mp4`,
    /// `写实版-粗剪` + `.mp4`. Chinese prose runs into the name with no space
    /// ("已经输出到成品/a.mp4"), so the start can't be read off the text:
    /// every ideograph back to the nearest break is offered, farthest
    /// (longest path) first, and the host settles which exists. A run that
    /// opens on a letter ("保存到out/a.png") gets none — that is prose
    /// meeting a path, not a CJK name.
    private static func wideHeadStarts(_ characters: [Character], before start: Int, run: String) -> [Int] {
        guard let first = run.first, "/.-_".contains(first) else { return [] }
        var starts: [Int] = []
        var index = start
        while index > 0, starts.count < headLimit {
            let c = characters[index - 1]
            if c == "\0" {
                // A wide character's second column.
                guard index >= 2, !characters[index - 2].isASCII else { break }
            } else if isWideNameCharacter(c) {
                starts.append(index - 1)
            } else if !"-_.".contains(c) {
                break
            }
            index -= 1
        }
        return starts.reversed()
    }

    /// The CJK-named rest of a path whose ASCII run stopped at an ideograph:
    /// `episodes/nolift/` + `改稿建议.md`, `out/` + `羽毛球/a.png`. Taken only
    /// when it ends the way a path does — a previewable file or a `/` — so
    /// prose that merely follows a path ("保存到out/a.png了", "在 out/里面")
    /// stays prose. A wide character's second column reads as "\0" in the
    /// row text: dropped from the name, still counted in the columns.
    private static func wideNameTail(_ characters: [Character], from start: Int) -> (name: String, columns: Int)? {
        guard start < characters.count, isWideNameCharacter(characters[start]) else { return nil }
        var end = start
        while end < characters.count {
            let c = characters[end]
            if c == "\0" {
                guard end > start, !characters[end - 1].isASCII else { break }
            } else if !isPathCharacter(c) && !isWideNameCharacter(c) {
                break
            }
            end += 1
        }
        while end > start, characters[end - 1] == "." || characters[end - 1] == "-" { end -= 1 }
        let name = String(characters[start..<end].filter { $0 != "\0" })
        let last = name.split(separator: "/").last.map(String.init) ?? ""
        guard name.hasSuffix("/") || PreviewableFile.kind(of: last) != nil else { return nil }
        return (name, end - start)
    }

    private static func isWideNameCharacter(_ c: Character) -> Bool {
        !c.isASCII && (c.isLetter || c.isNumber)
    }

    private static func isPathCharacter(_ c: Character) -> Bool {
        guard c.isASCII else { return false }
        if c.isLetter || c.isNumber { return true }
        return "._@+-/~".contains(c)
    }

    /// `columns`: how many row columns `raw` spans, when that isn't its
    /// character count (a wide name's "\0" columns are not in `raw`).
    private static func classify(_ raw: String, at start: Int, columns: Int? = nil) -> Candidate? {
        // A sentence or list that ends on the path ("saved to out/a.png.")
        // leaves its punctuation on the run.
        var token = Substring(raw)
        while let last = token.last, last == "." || last == "-" { token = token.dropLast() }
        guard !token.isEmpty, token.count <= 1024 else { return nil }
        // `//` is a URL's remains (`https:` already split off) or a typo;
        // `~` anywhere but a leading `~/` is not a path at all.
        guard !token.contains("//") else { return nil }
        if let tilde = token.firstIndex(of: "~") {
            guard tilde == token.startIndex, token.hasPrefix("~/"),
                  token.dropFirst().firstIndex(of: "~") == nil else { return nil }
        }

        let path = String(token)
        let endsWithSlash = path.hasSuffix("/")
        let lastComponent = path.split(separator: "/").last.map(String.init) ?? ""
        guard !lastComponent.isEmpty, lastComponent != ".", lastComponent != ".." else { return nil }

        let previewable = !endsWithSlash && PreviewableFile.kind(of: lastComponent) != nil
        // An extension with no name in front (".mp4"): what is left of a
        // CJK file name once the ideographs are cut off, never a file.
        if previewable, lastComponent.hasPrefix("."), !lastComponent.dropFirst().contains(".") { return nil }
        if !path.contains("/") {
            // A bare word is only a candidate when it names a previewable
            // file ("01_character_sheet.png").
            guard previewable else { return nil }
        } else if !previewable {
            // Folder candidates: no extension, or a trailing slash. Anything
            // else with an extension (`src/main.swift`) is a file we don't
            // preview — not a folder.
            guard endsWithSlash || !lastComponent.contains(".") else { return nil }
            // Dates and fractions ("10/18", "1/2").
            let segments = path.split(separator: "/")
            guard !segments.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
            // A single rooted word is a slash command far more often than a
            // folder of outputs ("/config", "/help").
            if path.hasPrefix("/"), segments.count < 2 { return nil }
        }
        return Candidate(token: path, offset: start, length: (columns ?? raw.count) - (raw.count - token.count),
                         directoryOnly: !previewable)
    }
}

// MARK: - Asking the host

/// One exec round trip that settles a batch of candidates: which of them
/// name a previewable file or a folder of them, and where. Pure builders and
/// a parser, unit tested — the script runs on someone else's machine.
///
/// Strict POSIX sh, run through `sh -c` so the login shell (zsh, fish…)
/// never parses it; every argument goes through the one quoter
/// (`ExecUploadCommands.quote`).
///
/// A relative path resolves against the pane's working directory. When it
/// isn't there, it is looked up BELOW that directory too, newest match wins:
/// an agent that ran `cd v2 && …` reports `out/a.png` relative to `v2`,
/// while the pane (the agent's own process) never left the parent. One
/// `find` covers every miss in the batch, and a pane sitting in `$HOME` or
/// `/` is never searched — those trees are too big to walk on a whim.
enum PathProbe {
    struct Hit: Equatable, Sendable {
        let path: String
        let isDirectory: Bool
    }

    /// How deep the below-the-working-directory lookup goes. Enough for
    /// `repo/episodes/name/build/concept/v2/a.png`; about a second on a
    /// 65k-entry project tree.
    static let searchDepth = 6

    static let script = """
        cwd=$1; re=$2; shift 2; i=0; miss=; tab=$(printf '\\t')
        for a in "$@"; do
          t=${a#?}; k=${a%"$t"}
          case $t in
            "~/"*) p=$HOME/${t#??} ;;
            /*) p=$t ;;
            *) p=${cwd:-$HOME}/$t ;;
          esac
          hit=
          case $k in
            F) [ -f "$p" ] && hit=f ;;
          esac
          if [ -z "$hit" ] && [ -d "$p" ]; then
            ls -1 "$p" 2>/dev/null | grep -qiE "$re" && hit=d
          fi
          if [ -n "$hit" ]; then
            printf '%s\\t%s\\t%s\\n' "$i" "$hit" "$p"
          else
            case $t in
              /*|"~/"*|../*) ;;
              *) s=${t#./}; miss="$miss$i$tab$k$tab${s%/}
        " ;;
            esac
          fi
          i=$((i+1))
        done
        case $cwd in ""|/|"$HOME") exit 0 ;; esac
        set --
        while IFS=$tab read -r i k s; do
          [ -n "$s" ] || continue
          [ $# -eq 0 ] || set -- "$@" -o
          set -- "$@" -name "${s##*/}"
        done <<EOF
        $miss
        EOF
        [ $# -gt 0 ] || exit 0
        found=$(find "$cwd" -maxdepth \(searchDepth) \\( -name .git -o -name node_modules -o -name Library \
          -o -name .cache -o -name .build -o -name DerivedData -o -name Pods \\) -prune \
          -o \\( "$@" \\) -print 2>/dev/null)
        [ -n "$found" ] || exit 0
        while IFS=$tab read -r i k s; do
          [ -n "$s" ] || continue
          set --
          while IFS= read -r f; do
            case $f in
              */"$s")
                if [ "$k" = F ] && [ -f "$f" ]; then set -- "$@" "$f"
                elif [ -d "$f" ] && ls -1 "$f" 2>/dev/null | grep -qiE "$re"; then set -- "$@" "$f"
                fi ;;
            esac
          done <<EOF
        $found
        EOF
          [ $# -gt 0 ] || continue
          h=$(ls -1td -- "$@" 2>/dev/null | head -n 1)
          [ -n "$h" ] || continue
          if [ -d "$h" ]; then hit=d; else hit=f; fi
          printf '%s\\t%s\\t%s\\n' "$i" "$hit" "$h"
        done <<EOF
        $miss
        EOF
        """

    /// The full command line for one batch. `cwd` nil = unknown (a plain
    /// shell that never reported one): relative paths then resolve against
    /// `$HOME` and nothing is searched for.
    static func command(cwd: String?, candidates: [TerminalPathScanner.Candidate]) -> String {
        let q = ExecUploadCommands.quote
        let args = candidates.map { q(($0.directoryOnly ? "D" : "F") + $0.token) }
        return (["sh", "-c", q(script), "moshpit-probe", q(cwd ?? ""), q(PreviewableFile.extensionPattern)]
                + args).joined(separator: " ")
    }

    /// Parse the probe's `index<TAB>f|d<TAB>path` lines back onto the batch.
    /// Indexes outside the batch and malformed lines are ignored.
    static func parse(_ output: String, count: Int) -> [Int: Hit] {
        var hits: [Int: Hit] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, let index = Int(fields[0]), index >= 0, index < count,
                  fields[1] == "f" || fields[1] == "d", fields[2].hasPrefix("/") else { continue }
            hits[index] = Hit(path: tidy(String(fields[2])), isDirectory: fields[1] == "d")
        }
        return hits
    }

    /// Lexical cleanup of what the shell built (`/repo/./out/`, `//`).
    /// `..` is left alone: resolving it lexically can disagree with the
    /// filesystem once symlinks are involved, and the host is the authority.
    static func tidy(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) where part != "." {
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }
}

// MARK: - The link a tap carries

/// What a confirmed path is tagged with on the terminal cells, and what a
/// tap hands back: a private scheme only this app interprets, so the link
/// handler can tell a host path from a web URL without guessing. Claude
/// Code's own OSC-8 `file://` links (rare, but real) route the same way.
enum RemotePathLink {
    static let scheme = "moshpit-preview"

    static func url(for path: String) -> String {
        var components = URLComponents()
        components.scheme = scheme
        components.host = ""
        components.path = path
        return components.string ?? "\(scheme)://\(path)"
    }

    /// The host path a tapped link names, or nil if it isn't one of ours or
    /// a `file://` link.
    static func path(from link: String) -> String? {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == Self.scheme || scheme == "file" else { return nil }
        let path = url.path
        return path.hasPrefix("/") ? path : nil
    }
}

// MARK: - Reading what a link points at

/// One file or folder on the host, as the preview needs it.
struct RemoteFileEntry: Sendable, Hashable, Identifiable {
    let path: String
    let isDirectory: Bool
    /// nil when the host didn't say (the exec fallback lists names only).
    let size: UInt64?
    let modified: Date?

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var kind: PreviewableFile.Kind? { isDirectory ? nil : PreviewableFile.kind(of: name) }
    /// Images and video — what a folder shows as thumbnails, ahead of
    /// everything else: they are what an agent's output folder is opened for.
    var isMedia: Bool { kind == .image || kind == .video }

    /// The folders enclosing `path`, nearest first, down to `/` — the
    /// folder sheet's title menu, for climbing out of where it opened.
    static func enclosingFolders(of path: String) -> [String] {
        var parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard path.hasPrefix("/"), !parts.isEmpty else { return [] }
        var folders: [String] = []
        while !parts.isEmpty {
            parts.removeLast()
            folders.append("/" + parts.joined(separator: "/"))
        }
        return folders
    }

    /// What a folder view shows: subfolders and previewable files, no dot
    /// files, newest first (a folder an agent just wrote into leads with
    /// what it wrote). Entries the host gave no time for keep their order,
    /// after the dated ones.
    static func browsable(_ entries: [RemoteFileEntry]) -> [RemoteFileEntry] {
        let shown = entries.filter { !$0.name.hasPrefix(".") && ($0.isDirectory || $0.kind != nil) }
        return shown.enumerated().sorted { a, b in
            switch (a.element.modified, b.element.modified) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }
}

/// The exec-channel fallbacks for a host whose sshd has the SFTP subsystem
/// turned off — the same situation `ExecUploadCommands` covers for uploads.
/// Pure builders and parsers; strict POSIX sh through the one quoter.
enum RemoteFileCommands {
    /// The fallback download moves the file as base64 in ONE exec reply;
    /// past this it isn't worth holding in memory twice.
    static let execDownloadLimit: UInt64 = 32 * 1024 * 1024

    static func stat(_ path: String) -> String {
        let q = ExecUploadCommands.quote(path)
        return "if [ -d \(q) ]; then echo d; elif [ -f \(q) ]; then printf 'f '; wc -c < \(q); fi"
    }

    static func parseStat(_ output: String, path: String) -> RemoteFileEntry? {
        let line = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if line == "d" { return RemoteFileEntry(path: path, isDirectory: true, size: nil, modified: nil) }
        guard line.hasPrefix("f") else { return nil }
        let size = UInt64(line.dropFirst().trimmingCharacters(in: .whitespaces))
        return RemoteFileEntry(path: path, isDirectory: false, size: size, modified: nil)
    }

    /// `ls -t` is the one portable way to get mtime order without parsing
    /// `ls -l` dates; `-p` marks folders, `-A` drops `.` and `..`.
    static func list(_ path: String) -> String {
        "cd \(ExecUploadCommands.quote(path)) && ls -1Apt"
    }

    static func parseList(_ output: String, in folder: String) -> [RemoteFileEntry] {
        let base = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        return output.split(separator: "\n").compactMap { line in
            let isDirectory = line.hasSuffix("/")
            let name = isDirectory ? line.dropLast() : line[...]
            guard !name.isEmpty, !name.contains("/") else { return nil }
            return RemoteFileEntry(path: base + "/" + name, isDirectory: isDirectory, size: nil, modified: nil)
        }
    }

    static func cat(_ path: String) -> String {
        "base64 < \(ExecUploadCommands.quote(path))"
    }
}

// MARK: - Pulling a file down

/// Reads a whole remote file through positioned reads, several in flight at
/// once. An SFTP server may answer a read with FEWER bytes than asked —
/// OpenSSH's caps every read at 255 KiB — and that is not the end of the
/// file: the rest of that range is asked for again. Only an empty answer
/// (EOF) ends the file early, e.g. one that shrank since it was sized.
/// Treating a short read as EOF is what cut a 1.3 MB PNG off after its
/// first strip.
enum WindowedRead {
    /// Pulls `size` bytes. `read(offset, length)` answers at most `length`
    /// bytes starting at `offset` (empty = EOF); `write(offset, bytes)` gets
    /// every piece at its place in the file, in whatever order they land.
    /// Returns how many bytes the file turned out to have. A `size` of 0
    /// (unknown) reads one range at a time until EOF.
    static func pull(size: UInt64, chunk: UInt32, window: Int,
                     read: @escaping @Sendable (UInt64, UInt32) async throws -> [UInt8],
                     write: (UInt64, [UInt8]) throws -> Void,
                     progress: ((UInt64) -> Void)? = nil) async throws -> UInt64 {
        precondition(chunk > 0 && window > 0)
        return try await withThrowingTaskGroup(of: (UInt64, UInt32, [UInt8]).self) { group in
            var next: UInt64 = 0
            var gaps: [(UInt64, UInt32)] = []
            var end: UInt64? = size > 0 ? size : nil
            var eof = false
            var received: UInt64 = 0
            var inFlight = 0

            func nextRange() -> (UInt64, UInt32)? {
                if let gap = gaps.popLast() { return gap }
                if let end {
                    guard next < end else { return nil }
                    let length = UInt32(min(UInt64(chunk), end - next))
                    defer { next += UInt64(length) }
                    return (next, length)
                }
                // Unknown size: one range at a time, so EOF is never raced.
                guard !eof, inFlight == 0 else { return nil }
                defer { next += UInt64(chunk) }
                return (next, chunk)
            }
            func fill() {
                while inFlight < window, let (offset, length) = nextRange() {
                    group.addTask { (offset, length, try await read(offset, length)) }
                    inFlight += 1
                }
            }

            fill()
            while let (offset, length, answer) = try await group.next() {
                inFlight -= 1
                try Task.checkCancellation()
                let bytes = answer.count > Int(length) ? Array(answer.prefix(Int(length))) : answer
                if bytes.isEmpty {
                    // EOF here: nothing at or past this offset exists.
                    eof = true
                    end = min(end ?? offset, offset)
                    gaps.removeAll { $0.0 >= offset }
                } else {
                    try write(offset, bytes)
                    received += UInt64(bytes.count)
                    progress?(received)
                    if bytes.count < Int(length) {
                        gaps.append((offset + UInt64(bytes.count), length - UInt32(bytes.count)))
                    }
                }
                fill()
            }
            return min(received, end ?? received)
        }
    }
}

/// Puts pieces that land out of order back in order. A player fed from
/// `WindowedRead` takes bytes only at the end of what it already has, while
/// the window's answers (and the gaps a short read leaves) arrive in any
/// order; this holds each piece until everything before it is in.
struct InOrderBytes {
    /// The offset of the next byte owed to the reader.
    private(set) var next: UInt64
    private var held: [UInt64: [UInt8]] = [:]

    init(from start: UInt64 = 0) { next = start }

    /// Takes the piece at `offset`; returns whatever is now contiguous from
    /// `next` (often nothing, sometimes several pieces at once).
    mutating func take(_ offset: UInt64, _ bytes: [UInt8]) -> [UInt8] {
        guard !bytes.isEmpty, offset >= next else { return [] }
        held[offset] = bytes
        var ready: [UInt8] = []
        while let piece = held.removeValue(forKey: next) {
            ready += piece
            next += UInt64(piece.count)
        }
        return ready
    }
}

// MARK: - Changing files on the host

/// The folder sheet's create / rename / delete / upload, as far as they are
/// names and command lines: pure, unit tested. SFTP does the work when the
/// host has it; these exec forms are the fallback for one that doesn't.
/// Every script runs through `sh -c` with its paths as positional
/// arguments, so neither the login shell (zsh, fish…) nor a quote in a file
/// name ever gets to reinterpret it.
enum RemoteFileEdits {
    /// Printed by an exec form that did what it was asked.
    static let okMarker = "MOSHPIT_EDIT_OK"
    /// Printed when the target name is already taken.
    static let takenMarker = "MOSHPIT_EDIT_TAKEN"

    /// A name the user typed, trimmed; nil when it can't name one item in a
    /// folder (empty, `.`/`..`, or carrying a `/`).
    static func validName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\0") else { return nil }
        return name
    }

    /// `name`, or the first Finder-style variant not in `taken`:
    /// `shot.png` → `shot 2.png` → `shot 3.png`. An upload never overwrites.
    static func uniqueName(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ext.isEmpty || ns.deletingPathExtension.isEmpty ? name : ns.deletingPathExtension
        let suffix = stem == name ? "" : "." + ext
        var n = 2
        while taken.contains("\(stem) \(n)\(suffix)") { n += 1 }
        return "\(stem) \(n)\(suffix)"
    }

    static func child(_ name: String, of directory: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    /// Whether a path may be deleted from the sheet at all: absolute and at
    /// least two levels deep — never `/`, never a top-level `/usr`.
    static func deletable(_ path: String) -> Bool {
        path.hasPrefix("/") && path.split(separator: "/").filter { $0 != "." }.count >= 2
            && !path.split(separator: "/").contains("..")
    }

    static func makeDirectory(_ path: String) -> String {
        sh("mkdir -- \"$1\" && echo \(okMarker)", [path])
    }

    static func rename(_ path: String, to newPath: String) -> String {
        sh("if [ -e \"$2\" ] || [ -L \"$2\" ]; then echo \(takenMarker); exit 1; fi; "
           + "mv -- \"$1\" \"$2\" && echo \(okMarker)", [path, newPath])
    }

    /// nil for a path `deletable` refuses.
    static func remove(_ path: String, isDirectory: Bool) -> String? {
        guard deletable(path) else { return nil }
        return sh((isDirectory ? "rm -rf" : "rm -f") + " -- \"$1\" && echo \(okMarker)", [path])
    }

    /// An upload over exec: a mode-0700 directory protects both staging files
    /// from substitution by another user of a shared destination directory.
    /// Refuses to start over an existing name.
    struct UploadPlan {
        let begin: String
        let append: (String) -> String
        let finish: String
        /// Call only after begin confirms ownership. Removes only this
        /// attempt's known scratch files and its now-empty directory, never
        /// the target (its ownership is ambiguous after a lost finish reply).
        let cleanup: String
    }

    static func upload(to path: String) -> UploadPlan {
        let scratch = uploadScratchDirectory(for: path)
        let encoded = child("payload.b64part", of: scratch)
        let decoded = child("payload.decoded", of: scratch)
        return UploadPlan(
            begin: sh("if [ -e \"$1\" ] || [ -L \"$1\" ]; then echo \(takenMarker); exit 1; fi; "
                      + "umask 077; mkdir -m 700 -- \"$2\" || exit 1; "
                      + "if : > \"$3\"; then echo \(okMarker); else rmdir -- \"$2\"; exit 1; fi",
                      [path, scratch, encoded]),
            // The base64 alphabet is inert inside single quotes.
            append: { chunk in sh("printf %s \"$2\" >> \"$1\"", [encoded, chunk]) },
            finish: sh("command -v link >/dev/null 2>&1 || exit 1; "
                       + "umask 077; { base64 -d < \"$2\" > \"$3\" 2>/dev/null "
                       + "|| base64 -D < \"$2\" > \"$3\"; } || exit 1; "
                       + "if [ -e \"$1\" ] || [ -L \"$1\" ]; then echo \(takenMarker); exit 1; fi; "
                       + "case \"$1\" in /*) target=$1;; *) target=./$1;; esac; "
                       + "case \"$3\" in /*) source=$3;; *) source=./$3;; esac; "
                       + "link \"$source\" \"$target\" && rm -f -- \"$2\" \"$3\" "
                       + "&& rmdir -- \"$4\" && echo \(okMarker)",
                       [path, encoded, decoded, scratch]),
            cleanup: sh("rm -f -- \"$1\" \"$2\" && rmdir -- \"$3\"", [encoded, decoded, scratch]))
    }

    static func uploadScratchDirectory(for path: String) -> String {
        let directory = (path as NSString).deletingLastPathComponent
        let scratchName = ".hermit-upload-" + UUID().uuidString
        return directory.isEmpty ? scratchName : child(scratchName, of: directory)
    }

    static func sftpUploadCleanup(directory: String) -> String {
        sh("rm -f -- \"$1\" && rmdir -- \"$2\"", [child("payload", of: directory), directory])
    }

    private static func sh(_ script: String, _ args: [String]) -> String {
        let q = ExecUploadCommands.quote
        return (["sh", "-c", q(script), "moshpit-edit"] + args.map(q)).joined(separator: " ")
    }
}
