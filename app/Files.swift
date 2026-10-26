// Saving and importing in the LXR's own formats (kits .SND, patterns .PAT, banks as SD-card folders) and user samples.
// Layouts follow the LXR-02 firmware's presetManager.c (preset_saveDrumsetSD, preset_writePatternData, PatV03).
import Cocoa
import AVFoundation

enum LxrFile {
    static let steps = 64, tracks = 7, bars = 4

    // 8-character name field, space padded, as the firmware writes it.
    static func name8(_ s: String) -> [UInt8] {
        let a = Array(s.uppercased().unicodeScalars.filter { $0.isASCII && $0.value >= 32 }.map { UInt8($0.value) }.prefix(8))
        return a + [UInt8](repeating: 32, count: 8 - a.count)
    }

    // preset_makeFileNameSave: "NN-" plus the first 5 legal characters of the name.
    static func fileName(_ num: Int, _ name: String, _ ext: String) -> String {
        let legal = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$%&()-@^_`{}~")
        let cleaned = String(name.trimmingCharacters(in: .whitespaces).map { $0 == " " ? "_" : legal.contains($0) ? $0 : "_" }.prefix(5))
        return String(format: "%02d-", num % 100) + cleaned + "." + ext
    }

    static func kitData(name: String, params: [UInt8]) -> Data { Data(name8(name) + params) }

    // Our pattern: one length for all tracks, steps of [velocity (0 = off), note].
    struct Pattern { var name: String; var len: Int; var steps: [[[Int]]] }

    static func patternData(_ p: Pattern, swing: Double, kitNr: Int) -> Data {
        var d = name8(p.name) + Array("PatV03".utf8)
        func step(_ t: Int, _ s: Int) -> [Int] { s < p.len && t < p.steps.count && s < p.steps[t].count ? p.steps[t][s] : [0, 60] }
        for t in 0..<tracks {
            for s in 0..<steps {
                let st = step(t, s), v = min(max(st[0], 0), 127)
                // volume (bit 7 = active), probability, note, two automation slots
                d += [v > 0 ? UInt8(0x80 | v) : 100, 127, UInt8(min(max(st[1], 0), 127)), 0, 0, 0, 0]
            }
            d += [UInt8](repeating: 0, count: steps)   // step timing: no flam, no shift
        }
        for t in 0..<tracks {
            for bar in 0..<bars {
                var w: UInt16 = 0
                for b in 0..<16 where step(t, bar * 16 + b)[0] > 0 { w |= 1 << b }
                d += [UInt8(w & 0xff), UInt8(w >> 8)]
            }
        }
        d.append(UInt8(min(127, max(0, (swing / 0.75 * 127).rounded()))))   // shuffle 0-127
        d += [UInt8](repeating: UInt8(p.len), count: tracks)
        d.append(UInt8(clamping: kitNr))
        return Data(d)
    }

    // PatV01-03 and untagged files. A step plays when its main-step bit is set.
    static func readPattern(_ data: Data, maxSteps: Int) -> (Pattern, Double)? {
        let b = [UInt8](data)
        guard b.count > 8 else { return nil }
        let name = String(decoding: b[0..<8].prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        var at = 8, version = 1
        if b.count >= 14, String(decoding: b[8..<12], as: UTF8.self) == "PatV" {
            version = Int(String(decoding: b[12..<14], as: UTF8.self)) ?? 1
            at = 14
        }
        let trackBytes = steps * 7 + (version > 2 ? steps : 0)
        guard b.count >= at + tracks * trackBytes + tracks * bars * 2 else { return nil }
        var vol = [[UInt8]](), note = [[UInt8]]()
        for t in 0..<tracks {
            let base = at + t * trackBytes
            vol.append((0..<steps).map { b[base + $0 * 7] })
            note.append((0..<steps).map { b[base + $0 * 7 + 2] })
        }
        at += tracks * trackBytes
        var main = [[Bool]](repeating: [Bool](repeating: false, count: steps), count: tracks)
        for t in 0..<tracks {
            for bar in 0..<bars {
                let w = UInt16(b[at]) | UInt16(b[at + 1]) << 8
                at += 2
                for s in 0..<16 { main[t][bar * 16 + s] = w & (1 << s) != 0 }
            }
        }
        let shuffle = at < b.count ? Double(b[at]) : 0
        at += 1
        let lens = at + tracks <= b.count ? b[at..<at + tracks].map(Int.init) : []
        let len = min(maxSteps, max(1, lens.max().map { $0 == 0 ? 16 : $0 } ?? 16))
        let rows = (0..<tracks).map { t in
            (0..<maxSteps).map { s -> [Int] in
                let v = Int(vol[t][s] & 0x7f), n = Int(note[t][s] & 0x7f)
                return [main[t][s] ? (v == 0 ? 100 : v) : 0, n == 0 ? 60 : n]
            }
        }
        return (Pattern(name: name, len: len, steps: rows), shuffle / 127 * 0.75)
    }

    // Any audio file to mono 16-bit 44.1 kHz, what the LXR02Open sample loader accepts.
    static func readSample(_ url: URL) -> [Int16]? {
        guard let file = try? AVAudioFile(forReading: url),
              let out = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 1, interleaved: true),
              let conv = AVAudioConverter(from: file.processingFormat, to: out),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: input)) != nil else { return nil }
        conv.downmix = true
        let cap = AVAudioFrameCount(Double(input.frameLength) * 44100 / file.processingFormat.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: cap) else { return nil }
        var fed = false
        var err: NSError?
        conv.convert(to: output, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return input
        }
        guard err == nil, let ch = output.int16ChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(output.frameLength)))
    }
}

struct UserSample { let url: URL; let loop: Bool; let pcm: [Int16] }

extension App {
    var waveParams: [Int] {
        withUnsafeBytes(of: lxr_osc_wave_param) { Array($0.bindMemory(to: Int32.self)).map(Int.init) }
    }
    var bankKits: [Int] { kits.indices.filter { kits[$0].bank == kits[kit].bank } }

    func alert(_ title: String, _ text: String = "") {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.beginSheetModal(for: window)
    }

    // Never inside the app bundle: a rebuild or update replaces it and anything saved there is lost.
    func write(_ data: Data, to url: URL) -> Bool {
        if url.path.hasPrefix(Bundle.main.bundlePath) { alert("Can't save inside the app", "Pick a folder outside PHX-D01.app, e.g. a user bank."); return false }
        do { try data.write(to: url); return true } catch { alert("Couldn't save \(url.lastPathComponent)", error.localizedDescription); return false }
    }

    // After writing into a folder: make it a bank and select the given file in it.
    func reveal(folder: URL, file: String?) {
        if !folders.contains(where: { $0.path == folder.path }) { folders.append(folder) }
        reloadBanks()
        select(kits.firstIndex { $0.dir.path == folder.path && $0.file == file } ?? kit)
    }

    // ---------- kits ----------
    // Saves in place; an INIT slot becomes a real file. The factory bank is inside the app, so it saves as.
    func saveKit() {
        guard !kits.isEmpty else { return }
        let k = kits[kit]
        if k.dir.path.hasPrefix(Bundle.main.bundlePath) { js("phx.saveAs", ["morphed": false]); return }
        if write(LxrFile.kitData(name: k.name, params: k.params), to: k.dir.appendingPathComponent(k.file)) {
            kits[kit].edited = false
            reveal(folder: k.dir, file: k.file)
            js("lxrToast", ["text": "Saved \(k.bank)/\(k.file)"])
        }
    }

    // ---------- user banks: folders in ~/Documents/PHX-D01/Banks ----------
    func userBanks() -> [URL] {
        let root = userRoot.appendingPathComponent("Banks")
        let fm = FileManager.default
        if !fm.fileExists(atPath: root.path) { try? fm.createDirectory(at: root.appendingPathComponent("User 1"), withIntermediateDirectories: true) }
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return dirs.filter { $0.hasDirectoryPath && !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func newUserBank() {
        let a = NSAlert()
        a.messageText = "New user bank"
        a.informativeText = "A folder in ~/Documents/PHX-D01/Banks. It starts with 5 INIT kits to save over."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = "User \(userBanks().filter { $0.lastPathComponent.hasPrefix("User") }.count + 1)"
        a.accessoryView = field
        a.addButton(withTitle: "Create"); a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { r in
            guard r == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
            let dir = userRoot.appendingPathComponent("Banks").appendingPathComponent(field.stringValue)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.reveal(folder: dir, file: nil)
            self.select(self.kits.firstIndex { $0.dir.path == dir.path } ?? self.kit)
        }
    }

    // The save sheet (files.js): a loaded bank, a slot in it, a name. A kit it replaces goes to the Trash first.
    func saveKitTo(_ d: [String: Any]) {
        guard !kits.isEmpty, let bank = d["bank"] as? String, let dir = folder(bank: bank) else { return }
        let slot = (d["slot"] as? NSNumber)?.intValue ?? -1
        let name = (d["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        guard (0..<bankSlots).contains(slot), !name.isEmpty else { return }
        if dir.path == projectCard.path, layout(of: project) == "desktop", slot >= 64 { alert("Slot \(slot) is past the desktop's 64 kits", "This project uses the desktop layout: slots 00-63."); return }
        let params = (d["morphed"] as? Bool ?? false) ? heardParams() : kits[kit].params
        let file = LxrFile.fileName(slot, name, "SND")
        guard let old = clearSlot(dir, file), write(LxrFile.kitData(name: name, params: params), to: dir.appendingPathComponent(file)) else { return }
        reveal(folder: dir, file: file)
        js("lxrToast", ["text": "Saved \(bank)/\(file)" + (old.isEmpty ? "" : " (replaced \(old.joined(separator: ", ")), now in the Trash)")])
    }

    // One kit per slot: move every file already in the slot of `file` (NN-*.SND, iCloud placeholders too) to the Trash.
    // Returns their names, or nil (after an alert) if one can't be moved, so the caller doesn't write a second kit there.
    func clearSlot(_ dir: URL, _ file: String) -> [String]? {
        guard file.range(of: #"^\d\d-"#, options: .regularExpression) != nil else { return [] }
        let prefix = String(file.prefix(3)), fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        let inSlot = names.filter { n in
            let u = n.uppercased()
            return (n.hasPrefix(prefix) && u.hasSuffix(".SND")) || (n.hasPrefix("." + prefix) && u.hasSuffix(".SND.ICLOUD"))
        }
        for n in inSlot {
            do { try fm.trashItem(at: dir.appendingPathComponent(n), resultingItemURL: nil) }
            catch { alert("Didn't save: slot \(prefix.dropLast()) is taken", "Couldn't move \(n) to the Trash: \(error.localizedDescription)"); return nil }
        }
        return inSlot
    }

    func renameBank(_ d: [String: Any]) {
        let fm = FileManager.default
        guard let bank = d["bank"] as? String, let dir = folder(bank: bank) else { return }
        var name = (d["name"] as? String ?? "").trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        let isProject = dir.path == projectCard.path
        if isProject, name.hasPrefix("Project: ") { name = String(name.dropFirst(9)).trimmingCharacters(in: .whitespaces) }
        guard !name.isEmpty, name != bank, !name.hasPrefix(".") else { sendState(); return }
        if isProject { renameProject(to: name); return }   // the project's bank is named after the project: rename that
        let dest = dir.deletingLastPathComponent().appendingPathComponent(name)
        if fm.fileExists(atPath: dest.path) { alert("Can't rename \(bank)", "\(dest.path) already exists."); sendState(); return }
        do { try fm.moveItem(at: dir, to: dest) } catch { alert("Can't rename \(bank)", error.localizedDescription); sendState(); return }
        if let i = folders.firstIndex(of: dir) { folders[i] = dest }
        let ud = UserDefaults.standard
        if dir.path == (ud.string(forKey: "factoryBank") ?? userRoot.appendingPathComponent("Banks/Erica-factory").path) { ud.set(dest.path, forKey: "factoryBank") }
        let cur = kits.isEmpty ? nil : (kits[kit].dir.path == dir.path ? dest.path : kits[kit].dir.path, kits[kit].file)
        reloadBanks(moved: (dir, dest))
        select(cur.flatMap { c in kits.firstIndex { $0.dir.path == c.0 && $0.file == c.1 } } ?? kit)
        js("lxrToast", ["text": "Renamed \(bank) → \(name)"])
    }

    func renameProject(to name: String) {
        let fm = FileManager.default, old = project, dest = projectsRoot.appendingPathComponent(name)
        if fm.fileExists(atPath: dest.path) { alert("Can't rename the project", "\(dest.path) already exists."); sendState(); return }
        do { try fm.moveItem(at: old, to: dest) } catch { alert("Can't rename the project", error.localizedDescription); sendState(); return }
        let oldCard = folders.first { $0.path.hasPrefix(old.path + "/") }
        let cur = kits.isEmpty ? nil : (kits[kit].dir.path.replacingOccurrences(of: old.path + "/", with: dest.path + "/"), kits[kit].file)
        project = dest
        UserDefaults.standard.set(dest.path, forKey: "project")
        window.title = "PHX-D01 — \(name)"
        if let c = oldCard, let i = folders.firstIndex(of: c) { folders[i] = projectCard; reloadBanks(moved: (c, projectCard)) } else { reloadBanks() }
        select(cur.flatMap { c in kits.firstIndex { $0.dir.path == c.0 && $0.file == c.1 } } ?? kit)
        js("lxrToast", ["text": "Renamed project → \(name)"])
    }

    // "Other folder…" in the save sheet: a plain save panel. morphed: save what you hear (the kit morphed toward the target).
    func saveKitAs(morphed: Bool) {
        guard !kits.isEmpty else { return }
        let k = kits[kit]
        let p = NSSavePanel()
        let dir = k.dir.path.hasPrefix(Bundle.main.bundlePath) ? (userBanks().first ?? userRoot.appendingPathComponent("Banks/User 1")) : k.dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        p.directoryURL = dir
        p.allowedContentTypes = []
        // default to the first free NN- slot in that folder, so the suggested name never replaces a kit
        let used = Set(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).compactMap { Int($0.prefix(2)) })
        let free = (0..<bankSlots).first { !used.contains($0) } ?? bankSlots - 1
        p.nameFieldStringValue = LxrFile.fileName(free, morphed ? "M" + k.name : k.name, "SND")
        p.message = "The kit's name is the file name without its NN- prefix (8 characters)."
        p.beginSheetModal(for: window) { r in
            guard r == .OK, let url = p.url else { return }
            var stem = url.deletingPathExtension().lastPathComponent
            if let r = stem.range(of: #"^\d\d-"#, options: .regularExpression) { stem.removeSubrange(r) }
            let dest = url.pathExtension.isEmpty ? url.appendingPathExtension("SND") : url
            guard self.clearSlot(dest.deletingLastPathComponent(), dest.lastPathComponent) != nil else { return }
            if self.write(LxrFile.kitData(name: stem, params: morphed ? self.heardParams() : k.params), to: dest) {
                self.reveal(folder: dest.deletingLastPathComponent(), file: dest.lastPathComponent)
                self.js("lxrToast", ["text": "Saved \(dest.deletingLastPathComponent().lastPathComponent)/\(dest.lastPathComponent)"])
            }
        }
    }

    func setWave(voice: Int, value: Int) {
        guard !kits.isEmpty, voice >= 0, voice < 6 else { return }
        kits[kit].params[waveParams[voice]] = UInt8(clamping: value)
        kits[kit].edited = true
        applyKit()
        sendState()
    }

    func importKits() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.allowsMultipleSelection = true
        p.message = "Choose kit folders (each becomes a bank) or .SND files"
        p.beginSheetModal(for: window) { r in
            guard r == .OK else { return }
            for u in p.urls {
                if u.hasDirectoryPath { self.load(folder: u) } else { self.reveal(folder: u.deletingLastPathComponent(), file: u.lastPathComponent) }
            }
        }
    }

    // ---------- patterns ----------
    func patterns(from d: [String: Any]) -> [LxrFile.Pattern] {
        ((d["patterns"] as? [[String: Any]]) ?? []).map {
            LxrFile.Pattern(name: $0["name"] as? String ?? "PATTERN", len: ($0["len"] as? NSNumber)?.intValue ?? 16,
                            steps: ($0["steps"] as? [[[NSNumber]]])?.map { $0.map { $0.map(\.intValue) } } ?? [])
        }
    }

    func exportPatterns(_ d: [String: Any]) {
        let pats = patterns(from: d), swing = (d["swing"] as? NSNumber)?.doubleValue ?? 0
        let kitNr = max(0, bankKits.firstIndex(of: kit) ?? 0), first = (d["first"] as? NSNumber)?.intValue ?? 0
        guard !pats.isEmpty else { return }
        if pats.count == 1 {
            let p = NSSavePanel()
            p.nameFieldStringValue = LxrFile.fileName(first, pats[0].name, "PAT")
            p.beginSheetModal(for: window) { r in
                guard r == .OK, let url = p.url else { return }
                _ = self.write(LxrFile.patternData(pats[0], swing: swing, kitNr: kitNr), to: url)
            }
        } else {
            chooseFolder(prompt: "Save Patterns Here") { dir in
                for (i, pat) in pats.enumerated() {
                    guard self.write(LxrFile.patternData(pat, swing: swing, kitNr: kitNr), to: dir.appendingPathComponent(LxrFile.fileName(first + i, pat.name, "PAT"))) else { return }
                }
            }
        }
    }

    func importPatterns() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.message = "Choose LXR pattern files (.PAT); they fill the slots from the current one on"
        p.beginSheetModal(for: window) { r in
            guard r == .OK else { return }
            var out: [[String: Any]] = [], bad: [String] = [], swing: Double?
            for u in p.urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let data = try? Data(contentsOf: u), let r = LxrFile.readPattern(data, maxSteps: Int(LXA_MAX_STEPS)) else { bad.append(u.lastPathComponent); continue }
                out.append(["name": r.0.name, "len": r.0.len, "steps": r.0.steps])
                swing = swing ?? r.1
            }
            if !bad.isEmpty { self.alert("Not LXR patterns", bad.joined(separator: ", ")) }
            self.js("lxrImportPatterns", ["patterns": out, "swing": swing ?? 0])
        }
    }

    // ---------- banks: a folder of NN-NAME.SND kits and NN-NAME.PAT patterns, like a project on the SD card ----------
    func saveBank(_ d: [String: Any]) {
        guard !kits.isEmpty else { return }
        let pats = patterns(from: d), swing = (d["swing"] as? NSNumber)?.doubleValue ?? 0, ids = bankKits
        chooseFolder(prompt: "Save Bank Here") { dir in
            for (n, i) in ids.enumerated() {
                guard self.write(LxrFile.kitData(name: self.kits[i].name, params: self.kits[i].params),
                                 to: dir.appendingPathComponent(LxrFile.fileName(n, self.kits[i].name, "SND"))) else { return }
                self.kits[i].edited = false
            }
            for (n, pat) in pats.enumerated() {
                guard self.write(LxrFile.patternData(pat, swing: swing, kitNr: 0), to: dir.appendingPathComponent(LxrFile.fileName(n, pat.name, "PAT"))) else { return }
            }
            self.reveal(folder: dir, file: nil)
        }
    }

    func chooseFolder(prompt: String, then: @escaping (URL) -> Void) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = prompt
        p.beginSheetModal(for: window) { r in if r == .OK, let u = p.url { then(u) } }
    }

    // ---------- samples (LXR02Open engine) ----------
    func importSamples() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.allowsMultipleSelection = true
        p.message = "Choose audio files or folders. Files in a folder named \"loops\" loop, like the LXR02Open /loops folder."
        p.beginSheetModal(for: window) { r in
            guard r == .OK else { return }
            self.addSamples(p.urls)
        }
    }

    func addSamples(_ urls: [URL], save: Bool = true) {
        let audio = ["wav", "aif", "aiff", "caf", "mp3", "m4a", "flac"]
        var files: [URL] = []
        for u in urls {
            if u.hasDirectoryPath {
                let list = (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? []
                files += list.filter { audio.contains($0.pathExtension.lowercased()) }
            } else if audio.contains(u.pathExtension.lowercased()) { files.append(u) }
        }
        let have = Set(samples.map(\.url.path))
        let loaded = files.filter { !have.contains($0.path) }.compactMap { u in
            LxrFile.readSample(u).map { UserSample(url: u, loop: u.deletingLastPathComponent().lastPathComponent.lowercased() == "loops", pcm: $0) }
        }
        // the firmware's order: /samples sorted by name, then /loops sorted by name
        samples = (samples + loaded).sorted { ($0.loop ? 1 : 0, $0.url.lastPathComponent.lowercased()) < ($1.loop ? 1 : 0, $1.url.lastPathComponent.lowercased()) }
        samples = Array(samples.prefix(120))
        sendSamples()
        if save { saveSampleList() }
    }

    func clearSamples() { samples = []; sendSamples(); saveSampleList() }
    func saveSampleList() { UserDefaults.standard.set(samples.map(\.url.path), forKey: "samples") }
    func restoreSamples() {
        let paths = UserDefaults.standard.stringArray(forKey: "samples") ?? []
        if !paths.isEmpty { addSamples(paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }, save: false) }
    }

    // One immutable set per change; sets are kept so the audio thread never sees freed memory.
    func sendSamples() {
        let total = samples.reduce(0) { $0 + $1.pcm.count }
        let pcm = UnsafeMutablePointer<Int16>.allocate(capacity: max(total, 1))
        let offsets = UnsafeMutablePointer<UInt32>.allocate(capacity: max(samples.count, 1))
        let sizes = UnsafeMutablePointer<UInt32>.allocate(capacity: max(samples.count, 1))
        let loops = UnsafeMutablePointer<UInt8>.allocate(capacity: max(samples.count, 1))
        var at = 0
        for (i, s) in samples.enumerated() {
            s.pcm.withUnsafeBufferPointer { (pcm + at).update(from: $0.baseAddress!, count: s.pcm.count) }
            offsets[i] = UInt32(at); sizes[i] = UInt32(s.pcm.count); loops[i] = s.loop ? 1 : 0
            at += s.pcm.count
        }
        let set = UnsafeMutablePointer<LxaSamples>.allocate(capacity: 1)
        set.initialize(to: LxaSamples(pcm: pcm, offsets: offsets, sizes: sizes, loops: loops, count: Int32(samples.count)))
        lxa_samples(set)
        sendState()
    }

    func js(_ fn: String, _ obj: Any) {
        guard let json = try? JSONSerialization.data(withJSONObject: obj), let str = String(data: json, encoding: .utf8) else { return }
        web.evaluateJavaScript("\(fn)(\(str))")
    }
}

// ---------- projects ----------
// There is always a current project: Projects/Default is made on first launch. A project folder holds phx.json
// (layout, patterns, tempo, swing), samples/ and loops/, and a card folder that is also the project's own bank:
// Project00/ for the module (up to 128 kits) or PROJ00/ for the desktop (64 kits, plus the patterns as .PAT and
// PRJ.NFO, the name). To the desktop firmware missing files just mean an incomplete project, and GLO.CFG is left out
// so copying a project to a card keeps the card's global settings. No autosave: there is no undo.
extension App {
    var projectsRoot: URL { userRoot.appendingPathComponent("Projects") }
    var projectCard: URL { App.cardFolder(in: project) ?? project.appendingPathComponent(layout(of: project) == "desktop" ? "PROJ00" : "Project00") }

    static func isCard(_ u: URL) -> Bool { u.lastPathComponent.range(of: #"^(proj|project)\d\d$"#, options: [.regularExpression, .caseInsensitive]) != nil }
    static func cardFolder(in dir: URL) -> URL? {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { $0.hasDirectoryPath && isCard($0) }.sorted { $0.lastPathComponent < $1.lastPathComponent }.first
    }
    func layout(of dir: URL) -> String {
        if let d = try? Data(contentsOf: dir.appendingPathComponent("phx.json")),
           let m = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let l = m["layout"] as? String { return l }
        return App.cardFolder(in: dir)?.lastPathComponent.count == 6 ? "desktop" : "module"   // PROJnn vs Project00
    }

    // Banks are named after their folder; the project's own bank after the project.
    func bankName(_ url: URL) -> String {
        url.standardizedFileURL.path == projectCard.standardizedFileURL.path ? "Project: \(project.lastPathComponent)" : url.lastPathComponent
    }
    func folder(bank: String) -> URL? { folders.first { bankName($0) == bank } }

    func makeProject(_ dir: URL, layout: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: App.cardFolder(in: dir) ?? dir.appendingPathComponent(layout == "desktop" ? "PROJ00" : "Project00"), withIntermediateDirectories: true)
        let meta = dir.appendingPathComponent("phx.json")
        if !fm.fileExists(atPath: meta.path) { try? Data(#"{"layout":"\#(layout)"}"#.utf8).write(to: meta) }
    }

    // At launch: the last project, or Projects/Default (made if missing; module layout, the module being the one with no projects of its own).
    func ensureProject() {
        let ud = UserDefaults.standard
        var dir = ud.string(forKey: "project").map { URL(fileURLWithPath: $0) } ?? projectsRoot.appendingPathComponent("Default")
        if !FileManager.default.fileExists(atPath: dir.path) { dir = projectsRoot.appendingPathComponent("Default") }
        makeProject(dir, layout: FileManager.default.fileExists(atPath: dir.path) ? layout(of: dir) : "module")
        project = dir
        ud.set(dir.path, forKey: "project")
        window.title = "PHX-D01 — \(dir.lastPathComponent)"
    }

    // Make another project current: its bank replaces the old project's bank.
    func switchProject(to dir: URL) {
        let old = projectCard.standardizedFileURL.path
        let cur = kits.isEmpty ? nil : (kits[kit].dir.path, kits[kit].file)
        project = dir
        UserDefaults.standard.set(dir.path, forKey: "project")
        window.title = "PHX-D01 — \(dir.lastPathComponent)"
        folders.removeAll { $0.standardizedFileURL.path == old }
        folders.insert(projectCard, at: 0)
        reloadBanks()
        select(cur.flatMap { c in kits.firstIndex { $0.dir.path == c.0 && $0.file == c.1 } } ?? kits.firstIndex { $0.dir.path == projectCard.path } ?? 0)
    }

    // phx.json, samples, and for the desktop layout the card's .PAT (slots 00-07 only: others may hold the hardware's) and PRJ.NFO.
    func writeProject(_ d: [String: Any], to dir: URL) throws {
        let fm = FileManager.default, lay = layout(of: dir)
        var meta = (try? JSONSerialization.jsonObject(with: Data((d["json"] as? String ?? "{}").utf8))) as? [String: Any] ?? [:]
        meta["layout"] = lay
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]).write(to: dir.appendingPathComponent("phx.json"))
        for smp in samples where !smp.url.path.hasPrefix(dir.path + "/") {
            let sub = dir.appendingPathComponent(smp.loop ? "loops" : "samples")
            try fm.createDirectory(at: sub, withIntermediateDirectories: true)
            let dest = sub.appendingPathComponent(smp.url.lastPathComponent)
            if !fm.fileExists(atPath: dest.path) { try fm.copyItem(at: smp.url, to: dest) }
        }
        guard lay == "desktop", let card = App.cardFolder(in: dir) else { return }
        let pats = patterns(from: d), swing = (d["swing"] as? NSNumber)?.doubleValue ?? 0
        let names = (try? fm.contentsOfDirectory(atPath: card.path)) ?? []
        for (n, pat) in pats.prefix(8).enumerated() {
            let prefix = String(format: "%02d-", n)
            for f in names where f.hasPrefix(prefix) && f.uppercased().hasSuffix(".PAT") { try? fm.removeItem(at: card.appendingPathComponent(f)) }
            try LxrFile.patternData(pat, swing: swing, kitNr: 0).write(to: card.appendingPathComponent(LxrFile.fileName(n, pat.name, "PAT")))
        }
        try Data(LxrFile.name8(dir.lastPathComponent)).write(to: card.appendingPathComponent("PRJ.NFO"))
    }

    // ⌘S: the kit you're on (unless it's an untouched empty INIT slot) and the current project.
    func saveAll(_ d: [String: Any]) {
        var what: [String] = []
        if !kits.isEmpty, !(kits[kit].virtual && !kits[kit].edited) {
            let k = kits[kit]
            guard write(LxrFile.kitData(name: k.name, params: k.params), to: k.dir.appendingPathComponent(k.file)) else { return }
            kits[kit].edited = false
            reveal(folder: k.dir, file: k.file)
            what.append("\(k.bank)/\(k.file)")
        }
        do { try writeProject(d, to: project); what.append("project \(project.lastPathComponent)") }
        catch { alert("Couldn't save the project", error.localizedDescription); return }
        js("lxrToast", ["text": "Saved " + what.joined(separator: " + ")])
    }

    // A copy of the current project (its kits, samples and this state) under a new name, which becomes current.
    func saveProjectAs(_ d: [String: Any]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
        let p = NSSavePanel()
        p.directoryURL = projectsRoot
        p.nameFieldStringValue = "Project \(((try? fm.contentsOfDirectory(atPath: projectsRoot.path))?.filter { !$0.hasPrefix(".") }.count ?? 0) + 1)"
        p.prompt = "Save Project"
        let kind = NSSegmentedControl(labels: ["Module", "Desktop"], trackingMode: .selectOne, target: nil, action: nil)
        kind.selectedSegment = layout(of: project) == "desktop" ? 1 : 0
        let row = NSStackView(views: [NSTextField(labelWithString: "Card layout:"), kind])
        row.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        p.accessoryView = row
        p.beginSheetModal(for: window) { r in
            guard r == .OK, let dir = p.url else { return }
            if fm.fileExists(atPath: dir.path) { self.alert("\(dir.lastPathComponent) already exists", "Pick a new name; Save (⌘S) updates the current project."); return }
            let desktop = kind.selectedSegment == 1
            self.makeProject(dir, layout: desktop ? "desktop" : "module")
            guard let card = App.cardFolder(in: dir) else { return }
            var left = 0
            for f in ((try? fm.contentsOfDirectory(atPath: self.projectCard.path)) ?? []).filter({ $0.uppercased().hasSuffix(".SND") }) {
                if desktop, (Int(f.prefix(2)) ?? 0) >= 64 { left += 1; continue }
                try? fm.copyItem(at: self.projectCard.appendingPathComponent(f), to: card.appendingPathComponent(f))
            }
            do { try self.writeProject(d, to: dir) } catch { self.alert("Couldn't save the project", error.localizedDescription); return }
            self.switchProject(to: dir)
            self.js("lxrToast", ["text": "Saved project \(dir.lastPathComponent) (\(desktop ? "desktop" : "module"))" + (left > 0 ? ", \(left) kits past slot 63 left out" : "")])
        }
    }

    func openProject() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.directoryURL = projectsRoot
        p.message = "Choose a project, or a card folder (PROJnn from the desktop, Project00 from the module)"
        p.beginSheetModal(for: window) { r in
            guard r == .OK, let dir = p.url else { return }
            self.loadProject(dir)
        }
    }

    // A bare card folder (e.g. straight off an SD card) is copied into a new project first, so nothing is written to the card.
    func loadProject(_ picked: URL) {
        let fm = FileManager.default
        var dir = picked
        if App.isCard(picked), !fm.fileExists(atPath: picked.deletingLastPathComponent().appendingPathComponent("phx.json").path) {
            let nfo = (try? Data(contentsOf: picked.appendingPathComponent("PRJ.NFO"))).map { String(decoding: $0.prefix(8), as: UTF8.self).trimmingCharacters(in: .whitespaces.union(.controlCharacters)) }
            var name = (nfo?.isEmpty == false ? nfo! : picked.lastPathComponent), n = 2
            while fm.fileExists(atPath: projectsRoot.appendingPathComponent(name).path) { name = "\(nfo ?? picked.lastPathComponent) \(n)"; n += 1 }
            dir = projectsRoot.appendingPathComponent(name)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try fm.copyItem(at: picked, to: dir.appendingPathComponent(picked.lastPathComponent))
            } catch { alert("Couldn't import \(picked.lastPathComponent)", error.localizedDescription); return }
            makeProject(dir, layout: picked.lastPathComponent.count == 6 ? "desktop" : "module")
        } else if !fm.fileExists(atPath: dir.appendingPathComponent("phx.json").path) && App.cardFolder(in: dir) == nil {
            alert("Not a project", "\(dir.lastPathComponent) has no phx.json and no PROJnn / Project00 folder."); return
        }
        // the project's samples replace the current ones
        samples = []
        addSamples(["samples", "loops"].map { dir.appendingPathComponent($0) }.filter { fm.fileExists(atPath: $0.path) })
        // patterns: the project's own data, else the card's .PAT files (slots A-H)
        if let json = try? String(contentsOf: dir.appendingPathComponent("phx.json"), encoding: .utf8), json.contains("\"patterns\"") {
            web.evaluateJavaScript("lxrProject(\(json))")
        } else if let card = App.cardFolder(in: dir) {
            let files = ((try? fm.contentsOfDirectory(at: card, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension.uppercased() == "PAT" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            let pats = files.compactMap { (try? Data(contentsOf: $0)).flatMap { LxrFile.readPattern($0, maxSteps: Int(LXA_MAX_STEPS)) } }
                .filter { $0.0.steps.contains { $0.contains { $0[0] > 0 } } }
            js("lxrProject", ["patterns": pats.prefix(8).map { ["name": $0.0.name, "len": $0.0.len, "steps": $0.0.steps] }, "swing": pats.first?.1 ?? 0])
        }
        switchProject(to: dir)
        js("lxrToast", ["text": "Opened project \(dir.lastPathComponent)"])
    }
}
