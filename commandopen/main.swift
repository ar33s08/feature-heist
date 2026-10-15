// CommandOpen — a rebuilt-from-behavior quick launcher for macOS.
// Original implementation; design informed by public behavior of desktop "quick search" overlays.
// Build: swiftc -O -o CommandOpen main.swift -framework Cocoa -framework Carbon

import Cocoa
import Carbon.HIToolbox

// MARK: - Search engine

struct Item {
    let name: String
    let url: URL?
    let kind: Kind
    enum Kind { case app, file, web }
}

final class Engine {
    private(set) var apps: [Item] = []
    private let formatter = NumberFormatter()

    init() {
        reloadApps()
    }

    func reloadApps() {
        var out: [Item] = []
        let dirs = ["/Applications", NSHomeDirectory() + "/Applications", "/System/Applications", "/System/Applications/Utilities"]
        for d in dirs {
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: d) {
                for e in entries where e.hasSuffix(".app") {
                    let name = String(e.dropLast(4))
                    out.append(Item(name: name, url: URL(fileURLWithPath: d).appendingPathComponent(e), kind: .app))
                }
            }
        }
        apps = out
    }

    // fuzzy: subsequence match, prefer prefix and contiguous matches
    private func score(_ q: String, _ name: String) -> Int? {
        let ql = Array(q.lowercased()), nl = Array(name.lowercased())
        if String(nl.prefix(ql.count)) == String(ql) && !ql.isEmpty { return 1000 }
        var hits = 0, streak = 0, best = 0, firstIdx = -1
        var qi = 0
        for (pos, c) in nl.enumerated() {
            if qi < ql.count && c == ql[qi] {
                hits += 1; streak += 1; best = max(best, streak)
                if firstIdx < 0 { firstIdx = pos }
                qi += 1
            } else { streak = 0 }
        }
        guard qi == ql.count else { return nil }
        let prevIsSpace = firstIdx > 0 && nl[firstIdx - 1] == " "
        return 100 * best + (firstIdx == 0 ? 40 : 0) + (prevIsSpace ? 30 : 0) - firstIdx
    }

    func search(_ q: String) -> [Item] {
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        var results: [(Int, Item)] = []
        for a in apps { if let s = score(q, a.name) { results.append((s + 500, a)) } } // apps dominate
        for f in spotlight(q) { if let s = score(q, (f.url?.lastPathComponent ?? f.name)) { results.append((s, f)) } }
        results.sort { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1.name < $1.1.name }
        var out = results.prefix(9).map { $0.1 }
        if !q.contains(" ") {
            out.append(Item(name: "Search the web for \"\(q)\"", url: URL(string: "https://duckduckgo.com/?q=" + q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)!, kind: .web))
        }
        return out
    }

    private func spotlight(_ q: String) -> [Item] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = ["-name", q]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return [] }
        p.waitUntilExit(timeout: 0.7)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let s = String(data: data, encoding: .utf8) else { return [] }
        let junk = ["/node_modules/", "/_CodeSignature/", "/Library/Developer/", "/System/DriverKit/"]
        return s.split(separator: "\n").filter { l in !junk.contains { l.contains($0) } }
            .prefix(24).map { line in
                let path = String(line)
                return Item(name: (path as NSString).lastPathComponent, url: URL(fileURLWithPath: path), kind: .file)
            }
    }
}

extension Process {
    func waitUntilExit(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while isRunning && Date() < deadline { usleep(20_000) }
        if isRunning { terminate() }
    }
}

// MARK: - Overlay UI

final class Panel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 680, height: 44 + 9 * 38),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        let b = contentRect(forFrameRect: frame)
        let root = NSView(frame: NSRect(origin: .zero, size: frame.size))
        root.wantsLayer = true
        root.layer?.cornerRadius = 14
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.98).cgColor
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor.separatorColor.cgColor
        root.layer?.masksToBounds = true

        let field = NSSearchField(frame: NSRect(x: 12, y: frame.height - 40, width: frame.width - 24, height: 28))
        field.placeholderString = "Search apps, files, or type anything…"
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: 17, weight: .regular)
        field.target = self
        field.action = #selector(runSearch)
        (field.cell as? NSSearchFieldCell)?.sendsWholeSearchString = false
        if let buttonCell = (field.cell as? NSSearchFieldCell)?.searchButtonCell {
            buttonCell.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "search")
        }
        root.addSubview(field)

        var rows: [ResultRow] = []
        var rowsBox: [NSView] = []
        for i in 0..<9 {
            let yy = (i + 1) * 38
            let y: CGFloat = frame.height - CGFloat(44 + yy) + 2
            let row = ResultRow(frame: NSRect(x: 8, y: y, width: frame.width - 16, height: 36), index: i)
            row.onOpen = { [weak self] item in self?.openItem(item) }
            root.addSubview(row)
            rows.append(row)
            rowsBox.append(row)
        }
        self.field = field
        self.rows = rows
        self.rowsBox = rowsBox
        contentView = root
        sel = 0
    }

    private(set) var field: NSSearchField!
    private var rows: [ResultRow]!
    private var rowsBox: [NSView]!
    private var results: [Item] = []
    var sel = 0 { didSet { refreshSelection() } }
    private let engine = Engine()
    var shownAt = Date.distantPast

    @objc private func runSearch() { doSearch() }

    func doSearch() {
        let q = field.stringValue
        results = engine.search(q)
        for (i, row) in rows.enumerated() {
            if i < results.count {
                row.item = results[i]
                row.isHidden = false
                let icon: NSImage?
                switch results[i].kind {
                case .app: icon = results[i].url.flatMap { NSWorkspace.shared.icon(forFile: $0.path) }
                case .file: icon = results[i].url.flatMap { NSWorkspace.shared.icon(forFile: $0.path) }
                case .web: icon = NSImage(systemSymbolName: "globe", accessibilityDescription: "web")
                }
                row.set(icon: icon, title: results[i].name,
                        subtitle: results[i].kind == .web ? "" : results[i].url?.path ?? "")
            } else { row.isHidden = true; row.item = nil }
        }
        sel = 0
    }

    private func refreshSelection() {
        for (i, row) in rows.enumerated() { row.selected = (i == sel) }
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        sel = (sel + delta + results.count) % results.count
    }

    func openSelected() {
        guard sel < results.count else { return }
        openItem(results[sel])
    }

    private var debounceTimer: Timer?

    func openItem(_ item: Item) {
        hide()
        switch item.kind {
        case .web: NSWorkspace.shared.open(item.url!)
        default:
            guard let url = item.url else { return }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.open([url], withApplicationAt: url, configuration: cfg) { _, err in
                if err != nil || item.kind == .file { NSWorkspace.shared.open(url) }
            }
        }
    }

    func present() {
        field.stringValue = ""
        doSearch()
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let f = screen.visibleFrame
        setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.midY + f.height * 0.18))
        orderFrontRegardless()
        makeKey()
        NSApp.activate(ignoringOtherApps: true)
        if let win = self.field.window { win.makeFirstResponder(field) }
        shownAt = Date()
    }

    func hide() { orderOut(nil) }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { hide() }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case UInt16(kVK_Escape): hide()
        case UInt16(kVK_DownArrow): move(1)
        case UInt16(kVK_UpArrow): move(-1)
        case UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter): openSelected()
        default: super.keyDown(with: event)
        }
    }

    func keyPressed(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_DownArrow) { move(1) }
        else if event.keyCode == UInt16(kVK_UpArrow) { move(-1) }
        else if event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) { openSelected() }
        else if event.keyCode == UInt16(kVK_Escape) { hide() }
    }
}

final class ResultRow: NSView {
    var onOpen: ((Item) -> Void)?
    var item: Item?
    var selected = false { didSet { needsDisplay = true } }
    private let iconView = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let index: Int

    init(frame: NSRect, index: Int) {
        self.index = index
        super.init(frame: frame)
        iconView.frame = NSRect(x: 8, y: 6, width: 24, height: 24)
        title.frame = NSRect(x: 40, y: 17, width: frame.width - 60, height: 17)
        title.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        subtitle.frame = NSRect(x: 40, y: 2, width: frame.width - 60, height: 14)
        subtitle.font = NSFont.systemFont(ofSize: 10.5)
        subtitle.textColor = .tertiaryLabelColor
        subtitle.lineBreakMode = .byTruncatingMiddle
        addSubview(iconView); addSubview(title); addSubview(subtitle)
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(icon: NSImage?, title: String, subtitle: String) {
        iconView.image = icon
        self.title.stringValue = title
        self.subtitle.stringValue = subtitle
        self.subtitle.isHidden = subtitle.isEmpty
    }

    override func draw(_ dirtyRect: NSRect) {
        if selected {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
            title.textColor = .selectedControlTextColor
            subtitle.textColor = NSColor.selectedControlTextColor.withAlphaComponent(0.75)
        } else {
            title.textColor = .labelColor
            subtitle.textColor = .tertiaryLabelColor
        }
        super.draw(dirtyRect)
    }

    override func mouseUp(with event: NSEvent) { if let it = item { onOpen?(it) } }
}

// MARK: - Hotkey

struct HotKey {
    static var ref: EventHotKeyRef?
    static func register(carbonEventHandler: EventHandlerUPP) -> Bool {
        var ek = EventHotKeyID(signature: OSType(0x43485354 /* 'CHST' */), id: 1)
        let mods: UInt32 = UInt32(optionKey)
        return RegisterEventHotKey(UInt32(kVK_Space), mods, ek, GetApplicationEventTarget(), 0, &ref) == noErr
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: Panel!
    var eventHandler: EventHandlerRef?

    func applicationDidFinishLaunching(_ note: Notification) {
        panel = Panel()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let ud = userData else { return noErr }
            let me = Unmanaged<AppDelegate>.fromOpaque(ud).takeUnretainedValue()
            me.toggle()
            return noErr
        }, 1, &spec, selfPtr, &eventHandler)
        _ = HotKey.register(carbonEventHandler: { _, _, _ in noErr })
        if UserDefaults.standard.object(forKey: "noDock") != nil || true {
            NSApp.setActivationPolicy(.accessory)
        }
        print("READY")
    }

    @objc func toggle() {
        if panel.isVisible, Date().timeIntervalSince(panel.shownAt) < 0.3 { panel.hide() }
        else { panel.present() }
    }
}

// MARK: - Headless verification mode

func cliSearch(_ query: String) -> Int32 {
    let e = Engine()
    let r = e.search(query)
    for item in r {
        let p = item.kind == .web ? "(web)" : (item.url?.path ?? "")
        print("\(item.kind == .app ? "APP " : item.kind == .file ? "FILE" : "WEB ") \t\(item.name)\t\(p)")
    }
    return r.isEmpty ? 1 : 0
}

let args = CommandLine.arguments
if let qi = args.firstIndex(of: "--query") {
    exit(cliSearch(args.count > qi + 1 ? args[qi + 1] : ""))
}
if args.contains("--engine-test") {
    let e = Engine()
    var failures = 0
    func check(_ q: String, contains: String) {
        let names = e.search(q).map { $0.name }
        if names.contains(where: { $0.localizedCaseInsensitiveContains(contains) }) {
            print("PASS  \"\(q)\" -> \(contains)  [\(names.prefix(3).joined(separator: ", "))]")
        } else { print("FAIL  \"\(q)\" -> expected \(contains), got \(names.prefix(5))"); failures += 1 }
    }
    check("safari", contains: "Safari")
    check("term", contains: "Term")
    check("visual", contains: "Visual Studio Code")
    check("notion", contains: "Notion")
    check("chrom", contains: "Chrome")
    check("swift", contains: "swift")
    check("xcode", contains: "Xcode")
    exit(failures == 0 ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
