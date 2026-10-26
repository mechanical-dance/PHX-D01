// PHX-D01: a window with the LXR front panel (app/web, drawn in a WKWebView) on top of the lxa audio runtime.
// The page posts commands ({cmd: "hit", t, vel}, ...); the app owns the kit list and sends state back with lxrState().
import Cocoa
import WebKit

struct Kit { var name: String; var file: String; let bank: String; var params: [UInt8]; let dir: URL; var edited = false; var virtual = false }

// The firmware's limits: 64 kits per project; banks show up to 5 empty INIT slots until they reach it.
let bankSize = 64, initPadding = 5
let userRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/PHX-D01")
let initParams: [UInt8] = {
    var p = [UInt8](repeating: 0, count: Int(LXR_KIT_PARAMS)), n = [CChar](repeating: 0, count: 9)
    if let u = Bundle.main.resourceURL?.appendingPathComponent("INIT.SND") { _ = lxr_read_kit(u.path, &p, &n) }
    return p
}()

final class App: NSObject, NSApplicationDelegate, WKScriptMessageHandler {
    var window: NSWindow!
    var web: WKWebView!
    var kits: [Kit] = []
    var kit = 0
    var morphTarget = 0
    var morphAmount: UInt8 = 0
    var folders: [URL] = []   // kit banks, in the order they were added
    var samples: [UserSample] = []

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
        let exeDir = Bundle.main.executableURL!.deletingLastPathComponent().path
        if lxa_start(exeDir) == 0 {
            let a = NSAlert()
            a.messageText = "No audio"
            a.informativeText = "Couldn't load the engines or open the audio output."
            a.runModal()
            NSApp.terminate(nil)
        }
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(self, name: "lxr")
        web = WKWebView(frame: .zero, configuration: cfg)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 940),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "PHX-D01"
        window.minSize = NSSize(width: 900, height: 720)
        window.contentView = web
        window.center()
        window.setFrameAutosaveName("main")
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(web)
        let webDir = Bundle.main.resourceURL!.appendingPathComponent("web")
        web.loadFileURL(webDir.appendingPathComponent("index.html"), allowingReadAccessTo: webDir)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ note: Notification) { lxa_stop() }

    func userContentController(_ c: WKUserContentController, didReceive msg: WKScriptMessage) {
        guard let d = msg.body as? [String: Any], let cmd = d["cmd"] as? String else { return }
        func int(_ k: String) -> Int32 { Int32((d[k] as? NSNumber)?.intValue ?? 0) }
        switch cmd {
        case "ready":
            restoreIO()
            startFolder()
            restoreSamples()
            sendSeqState(saved: true)
            startTicks()
        case "hit": lxa_hit(int("t"), int("vel"))
        case "kit": select(Int(int("i")))
        case "engine": lxa_engine(int("i"))
        case "hw": lxa_hardware(int("v"))
        case "fader": lxa_fader(int("i"), (d["pos"] as? NSNumber)?.floatValue ?? 1)
        case "solo": lxa_solo(int("jack"))
        case "open": chooseFolder()
        case "note": lxa_note(int("t"), int("note"), int("vel"))
        case "transport": lxa_transport(int("on"))
        case "tempo": lxa_tempo((d["bpm"] as? NSNumber)?.floatValue ?? 120, (d["swing"] as? NSNumber)?.floatValue ?? 0)
        case "pattern": sendPattern(d)
        case "savePatterns": UserDefaults.standard.set(d["json"] as? String, forKey: "patterns")
        case "audioOut":
            let i = int("i"), ch = int("channels"), first = int("first")
            if lxa_set_output(i, ch, first) != 0 {
                UserDefaults.standard.set(i >= 0 ? String(cString: lxa_output_name(i)) : nil, forKey: "audioOut")
                UserDefaults.standard.set([Int(ch), Int(first)], forKey: "audioLayout")
            }
        case "morph":
            morphTarget = Int(int("target"))
            morphAmount = UInt8(clamping: int("amount"))
            applyKit()
        case "midiOut":
            midi_out_select(int("i"))
            UserDefaults.standard.set(int("i") >= 0 ? String(cString: midi_out_name(int("i"))) : nil, forKey: "midiOut")
        case "midiIn":
            midi_in_select(int("i"))
            UserDefaults.standard.set(int("i") >= 0 ? String(cString: midi_in_name(int("i"))) : nil, forKey: "midiIn")
        case "midiMode":
            midi_set_mode(int("mode"), int("ch"))
            UserDefaults.standard.set([int("mode"), int("ch")], forKey: "midiMode")
        case "rescan": sendSeqState(saved: false)
        case "saveKit": saveKit()
        case "saveKitAs": saveKitAs(morphed: false)
        case "saveMorph": saveKitAs(morphed: true)
        case "importKits": importKits()
        case "newBank": newUserBank()
        case "wave": setWave(voice: Int(int("voice")), value: Int(int("value")))
        case "exportPatterns": exportPatterns(d)
        case "importPatterns": importPatterns()
        case "saveBank": saveBank(d)
        case "importSamples": importSamples()
        case "clearSamples": clearSamples()
        case "param":
            let i = Int(int("i"))
            guard !kits.isEmpty, i >= 0, i < Int(LXR_KIT_PARAMS) else { break }
            kits[kit].params[i] = UInt8(clamping: int("v"))
            kits[kit].edited = true
            applyKit()
        case "mute": lxa_mute(int("t"), int("on"))
        default: break
        }
    }

    // Banks: the saved kit folders plus any given on the command line; with none, the user picks one.
    func startFolder() {
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        var paths = UserDefaults.standard.stringArray(forKey: "kitFolders") ?? UserDefaults.standard.string(forKey: "kitFolder").map { [$0] } ?? []
        paths += args.map { ($0 as NSString).expandingTildeInPath }
        // Erica's factory kits ship inside the app and are always the first bank; then the user banks.
        if let factory = Bundle.main.resourceURL?.appendingPathComponent("Erica-factory") { folders.append(factory) }
        folders += userBanks()
        for path in paths where FileManager.default.fileExists(atPath: path) && !folders.contains(where: { $0.path == path }) {
            folders.append(URL(fileURLWithPath: path))
        }
        if folders.isEmpty { sendState(); chooseFolder(); return }
        reloadBanks()
        select(args.last.flatMap { a in kits.firstIndex { $0.bank == URL(fileURLWithPath: (a as NSString).expandingTildeInPath).lastPathComponent } } ?? 0)
    }

    func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.message = "Choose a folder of LXR kits (.SND), e.g. the kit folder from your SD card"
        p.beginSheetModal(for: window) { r in if r == .OK, let u = p.url { self.load(folder: u) } }
    }

    static func readKits(_ url: URL) -> [Kit] {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".snd") && !$0.hasPrefix(".") }.sorted()
        var kits: [Kit] = files.compactMap { f in
            var params = [UInt8](repeating: 0, count: Int(LXR_KIT_PARAMS))
            var name = [CChar](repeating: 0, count: 9)
            guard lxr_read_kit(url.appendingPathComponent(f).path, &params, &name) == 0 else { return nil }
            return Kit(name: String(cString: name).trimmingCharacters(in: .whitespaces), file: f, bank: url.lastPathComponent, params: params, dir: url)
        }
        // empty INIT slots after the last kit, numbered on from the highest NN- prefix
        let next = (kits.compactMap { Int($0.file.prefix(2)) }.max() ?? -1) + 1
        let trailing = kits.reversed().prefix { $0.name.uppercased().hasPrefix("INIT") }.count
        for n in next..<min(bankSize, next + max(0, initPadding - trailing)) {
            kits.append(Kit(name: "INIT", file: String(format: "%02d-INIT.SND", n), bank: url.lastPathComponent, params: initParams, dir: url, virtual: true))
        }
        return kits
    }

    func reloadBanks() {
        kits = folders.flatMap(App.readKits)
        UserDefaults.standard.set(folders.map(\.path).filter { !$0.hasPrefix(Bundle.main.bundlePath) }, forKey: "kitFolders")
    }

    // Opening a folder adds it as a bank (or jumps to it if it's already one).
    func load(folder url: URL) {
        let found = App.readKits(url).filter { !$0.virtual }
        guard !found.isEmpty || url.path.hasPrefix(userRoot.path) else {
            let a = NSAlert()
            a.messageText = "No kits in \(url.lastPathComponent)"
            a.informativeText = "Pick a folder that contains LXR .SND kit files."
            a.beginSheetModal(for: window)
            return
        }
        if !folders.contains(where: { $0.path == url.path }) { folders.append(url) }
        reloadBanks()
        select(kits.firstIndex { $0.bank == url.lastPathComponent } ?? 0)
    }

    func select(_ i: Int) {
        guard !kits.isEmpty else { return }
        kit = ((i % kits.count) + kits.count) % kits.count
        applyKit()
        sendState()
    }

    // The selected kit, morphed toward the morph target by the firmware's rule.
    func applyKit() {
        guard !kits.isEmpty else { return }
        heardParams().withUnsafeBufferPointer { lxa_load($0.baseAddress) }
    }

    func heardParams() -> [UInt8] {
        var p = kits[kit].params
        if morphAmount > 0, morphTarget >= 0, morphTarget < kits.count {
            var out = p
            lxr_morph_kit(kits[kit].params, kits[morphTarget].params, morphAmount, &out)
            p = out
        }
        return p
    }

    func sendState() {
        let engines = (0..<lxa_engine_count()).map { String(cString: lxa_engine_name($0)) }
        let s: [String: Any] = ["engines": engines, "kit": kit,
                                "kits": kits.map { ["name": $0.name, "file": $0.file, "bank": $0.bank, "edited": $0.edited, "virtual": $0.virtual] },
                                "waves": kits.isEmpty ? [] : waveParams.map { Int(kits[kit].params[$0]) },
                                "params": kits.isEmpty ? [] : kits[kit].params.map(Int.init),
                                "sampleEngines": (0..<lxa_engine_count()).map { lxa_engine_has_samples($0) != 0 },
                                "samples": samples.map { ["name": $0.url.deletingPathExtension().lastPathComponent, "loop": $0.loop,
                                                          "sec": Double($0.pcm.count) / 44100] }]
        js("lxrState", s)
    }

    // Pattern from the page: 7 tracks of [velocity, note] per step.
    func sendPattern(_ d: [String: Any]) {
        guard let rows = d["steps"] as? [[[NSNumber]]] else { return }
        var steps = [LxaStep](repeating: LxaStep(vel: 0, note: 60), count: Int(LXA_TRACKS) * Int(LXA_MAX_STEPS))
        for (t, row) in rows.prefix(Int(LXA_TRACKS)).enumerated() {
            for (s, st) in row.prefix(Int(LXA_MAX_STEPS)).enumerated() where st.count == 2 {
                steps[t * Int(LXA_MAX_STEPS) + s] = LxaStep(vel: st[0].uint8Value, note: st[1].uint8Value)
            }
        }
        let len = Int32((d["length"] as? NSNumber)?.intValue ?? 16)
        steps.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: (LxaStep, LxaStep, LxaStep, LxaStep, LxaStep, LxaStep, LxaStep, LxaStep,
                                                     LxaStep, LxaStep, LxaStep, LxaStep, LxaStep, LxaStep, LxaStep, LxaStep,
                                                     LxaStep, LxaStep, LxaStep, LxaStep, LxaStep, LxaStep, LxaStep, LxaStep,
                                                     LxaStep, LxaStep, LxaStep, LxaStep, LxaStep, LxaStep, LxaStep, LxaStep).self,
                                               capacity: Int(LXA_TRACKS)) { lxa_pattern($0, len) }
        }
    }

    func names(_ count: Int32, _ name: (Int32) -> UnsafePointer<CChar>?) -> [String] {
        (0..<max(count, 0)).map { String(cString: name($0)!) }
    }

    // Devices are remembered by name, since their indexes change as things are plugged in.
    func restoreIO() {
        let ud = UserDefaults.standard
        let layout = ud.array(forKey: "audioLayout") as? [Int] ?? [2, 0]
        if let n = ud.string(forKey: "audioOut"), let i = names(lxa_output_count(), lxa_output_name).firstIndex(of: n) {
            lxa_set_output(Int32(i), Int32(layout[0]), Int32(layout[1]))
        } else if layout[0] == 4 || layout[1] > 0 { lxa_set_output(-1, Int32(layout[0]), Int32(layout[1])) }
        if let n = ud.string(forKey: "midiOut"), let i = names(midi_out_count(), midi_out_name).firstIndex(of: n) { midi_out_select(Int32(i)) }
        if let n = ud.string(forKey: "midiIn"), let i = names(midi_in_count(), midi_in_name).firstIndex(of: n) { midi_in_select(Int32(i)) }
        if let m = ud.array(forKey: "midiMode") as? [Int], m.count == 2 { midi_set_mode(Int32(m[0]), Int32(m[1])) }
    }

    func sendSeqState(saved: Bool) {
        let ud = UserDefaults.standard
        let audioOuts = names(lxa_output_count(), lxa_output_name), midiOuts = names(midi_out_count(), midi_out_name)
        let midiIns = names(midi_in_count(), midi_in_name)
        let mode = ud.array(forKey: "midiMode") as? [Int] ?? [0, 0]
        var s: [String: Any] = ["io": [
            "audioOuts": audioOuts, "audioOut": ud.string(forKey: "audioOut").flatMap { audioOuts.firstIndex(of: $0) } ?? -1,
            "audioChannels": (0..<Int32(audioOuts.count)).map { Int(lxa_output_channels($0)) },
            "audioLayout": ud.array(forKey: "audioLayout") as? [Int] ?? [2, 0],
            "midiOuts": midiOuts, "midiOut": ud.string(forKey: "midiOut").flatMap { midiOuts.firstIndex(of: $0) } ?? -1,
            "midiIns": midiIns, "midiIn": ud.string(forKey: "midiIn").flatMap { midiIns.firstIndex(of: $0) } ?? -1,
            "midiMode": mode[0], "midiCh": mode[1]]]
        if saved, let p = ud.string(forKey: "patterns") { s["saved"] = p }
        guard let json = try? JSONSerialization.data(withJSONObject: s), let str = String(data: json, encoding: .utf8) else { return }
        web.evaluateJavaScript("lxrSeqState(\(str))")
    }

    // Playhead and hit counters for the page, ~30 times a second, only when something changed.
    var lastTick = ""
    func startTicks() {
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            var counts = [UInt32](repeating: 0, count: Int(LXA_TRACKS))
            counts.withUnsafeMutableBufferPointer { lxa_hit_counts($0.baseAddress) }
            let tick = "\(lxa_playhead()),[\(counts.map(String.init).joined(separator: ","))]"
            if tick != self.lastTick { self.lastTick = tick; self.web.evaluateJavaScript("lxrTick(\(tick))") }
        }
    }

    func buildMenu() {
        let main = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem()
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            item.submenu = m
            main.addItem(item)
        }
        func item(_ title: String, _ key: String, _ mods: NSEvent.ModifierFlags = .command, _ run: @escaping () -> Void) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: #selector(runMenu(_:)), keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = self
            i.representedObject = run
            return i
        }
        func page(_ call: String) -> () -> Void { { [weak self] in self?.web.evaluateJavaScript(call) } }
        menu("PHX-D01", [item("Settings…", ",", .command, page("phx.prefs()")), .separator(),
                         NSMenuItem(title: "Hide PHX-D01", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"),
                         NSMenuItem(title: "Quit PHX-D01", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")])
        menu("File", [item("Open Kit Folder…", "o") { [weak self] in self?.chooseFolder() },
                      item("Import Kits…", "o", [.command, .shift]) { [weak self] in self?.importKits() },
                      item("New User Bank…", "n", [.command, .shift]) { [weak self] in self?.newUserBank() },
                      item("Import Patterns…", "i") { [weak self] in self?.importPatterns() },
                      item("Import Samples…", "i", [.command, .shift]) { [weak self] in self?.importSamples() },
                      .separator(),
                      item("Save Kit", "s") { [weak self] in self?.saveKit() },
                      item("Save Kit As…", "s", [.command, .shift]) { [weak self] in self?.saveKitAs(morphed: false) },
                      item("Save Morph as Kit…", "s", [.command, .option]) { [weak self] in self?.saveKitAs(morphed: true) },
                      .separator(),
                      item("Export Pattern…", "e", .command, page("phx.exportPatterns(false)")),
                      item("Export All Patterns…", "e", [.command, .shift], page("phx.exportPatterns(true)")),
                      item("Save Bank As…", "b", [.command, .shift], page("phx.saveBank()")),
                      .separator(),
                      NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")])
        // standard editing keys for the text fields in the page
        menu("Edit", [NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"),
                      NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
                      NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
                      NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
                      NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")])
        menu("View", [item("Sidebar", "\\", .command, page("phx.sidebar()")),
                      item("Sequencer", "j", .command, page("phx.sequencer()"))])
        NSApp.mainMenu = main
    }
    @objc func runMenu(_ sender: NSMenuItem) { (sender.representedObject as? () -> Void)?() }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
