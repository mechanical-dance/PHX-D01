// Saving and importing in the LXR's own formats (kits .SND, patterns .PAT, banks as SD-card folders) and loading samples (SampleLoader.swift).
// Layouts follow the LXR-02 firmware's presetManager.c (preset_saveDrumsetSD, preset_writePatternData, PatV03).
import Cocoa
import UniformTypeIdentifiers

enum LxrFile {
    static let steps = 64, tracks = 7, bars = 4

    // 8-character name field, space padded, as the firmware writes it.
    static func name8(_ s: String) -> [UInt8] {
        let a = Array(s.uppercased().unicodeScalars.filter { $0.isASCII && $0.value >= 32 }.map { UInt8($0.value) }.prefix(8))
        return a + [UInt8](repeating: 32, count: 8 - a.count)
    }

    // preset_makeFileNameSave: "NN-" plus the first 5 legal characters of the name; the module's slots 100-127 are
    // "NNN-" plus 4 (an 8-character stem either way, as on its card: 101-ELEC.SND).
    static func fileName(_ num: Int, _ name: String, _ ext: String) -> String {
        let legal = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$%&()-@^_`{}~")
        let cleaned = String(name.trimmingCharacters(in: .whitespaces).map { $0 == " " ? "_" : legal.contains($0) ? $0 : "_" }.prefix(num >= 100 ? 4 : 5))
        return String(format: num >= 100 ? "%03d-" : "%02d-", num) + cleaned + "." + ext
    }
    // The slot of NN-NAME.SND / NNN-NAME.SND.
    static func slot(_ file: String) -> Int? { Int(file.prefix { $0.isNumber }) }

    // A kit's params are the 247 LXR-2 bytes plus the module's 54 mod-matrix bytes. With every matrix slot off it's
    // written as the desktop's 255-byte file (which the module reads too); otherwise as the module's 309 bytes.
    static func kitData(name: String, params: [UInt8]) -> Data {
        let base = Int(LXR_KIT_PARAMS), matrix = params.dropFirst(base)
        return Data(name8(name) + params.prefix(base) + (matrix.contains { $0 != 0 } ? Array(matrix) : []))
    }

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

}

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
        guard let n = LxrFile.slot(file), file.range(of: #"^\d+-"#, options: .regularExpression) != nil else { return [] }
        let prefix = String(format: n >= 100 ? "%03d-" : "%02d-", n), fm = FileManager.default
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
        let used = Set(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).compactMap { LxrFile.slot($0) })
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
    // Load Samples on the card: the current project's folder, which holds the card layout, or a folder you pick.
    func loadSamples(from card: URL? = nil) {
        guard let card else {
            let p = NSOpenPanel()
            p.canChooseDirectories = true
            p.canChooseFiles = false
            p.message = "Choose the card: the folder that holds samples/ and loops/"
            p.beginSheetModal(for: window) { r in if r == .OK, let u = p.url { self.loadSamples(from: u) } }
            return
        }
        var count: UInt32 = 0, bytes: UInt32 = 0
        lxa_sample_limits(&count, &bytes)
        guard count > 0 else { alert("No sample engine", "The LXR-1 engine (engine-lxr1.dylib) isn't installed."); return }
        if card == project {   // the project's card always has both folders, so a load replaces the set
            for d in ["samples", "loops"] { try? FileManager.default.createDirectory(at: project.appendingPathComponent(d), withIntermediateDirectories: true) }
        }
        cardList = nil
        let (flash, report) = SampleLoader.load(card: card, current: samples, maxCount: Int(count), romBytes: Int(bytes))
        samples = flash
        sampleReport = report
        saveSampleFlash()
        sendSamples()
        js("lxrToast", ["text": report.failed.map { "\($0) Failed" } ?? "Loaded \(report.samples.installed.count) samples, \(report.loops.installed.count) loops"])
    }

    // The project folder is the card: its samples/ and loops/ as Load Samples reads them, valid or not.
    func cardFiles() -> [[String: Any]] {
        if let cardList { return cardList }
        let list = ["samples", "loops"].flatMap { sub -> [[String: Any]] in
            let dir = project.appendingPathComponent(sub)
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { SampleLoader.isWavName(SampleLoader.lfn($0)) }
            return names.sorted { SampleLoader.precedes(SampleLoader.lfn($0), SampleLoader.lfn($1)) }.map { n in
                let data = try? Data(contentsOf: dir.appendingPathComponent(n)), pcm = data.flatMap(SampleLoader.parseWav)
                return ["dir": sub, "file": n, "sec": Double(pcm?.count ?? 0) / 44100, "problem": pcm != nil ? "" : data.map(SampleLoader.problem) ?? "unreadable"]
            }
        }
        cardList = list
        return list
    }

    // Copies WAVs onto the card (your originals stay where they are), then loads the card.
    func addToCard(loops: Bool) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.allowedContentTypes = [.wav]
        p.message = "Copy WAV files to the card's \(loops ? "loops" : "samples") folder"
        p.beginSheetModal(for: window) { r in
            guard r == .OK else { return }
            let fm = FileManager.default, dir = self.project.appendingPathComponent(loops ? "loops" : "samples")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var clash: [String] = []
            for u in p.urls {
                let dest = dir.appendingPathComponent(u.lastPathComponent)
                if fm.fileExists(atPath: dest.path) { clash.append(u.lastPathComponent); continue }
                do { try fm.copyItem(at: u, to: dest) } catch { clash.append(u.lastPathComponent) }
            }
            self.loadSamples(from: self.project)
            if !clash.isEmpty { self.alert("Not copied", "Already on the card or unreadable: " + clash.joined(separator: ", ")) }
        }
    }

    // Moves a file on the card to the Trash, then loads the card.
    func removeFromCard(_ sub: String, _ file: String) {
        guard ["samples", "loops"].contains(sub), !file.isEmpty, !file.contains("/"), file != ".", file != ".." else { return }
        do { try FileManager.default.trashItem(at: project.appendingPathComponent(sub).appendingPathComponent(file), resultingItemURL: nil) }
        catch { alert("Couldn't remove \(file)", error.localizedDescription); return }
        loadSamples(from: project)
    }

    // The sample flash keeps its contents across restarts: count, then per sample loop flag, display name, frames, PCM.
    var sampleFlashURL: URL { userRoot.appendingPathComponent("SampleFlash.bin") }
    func saveSampleFlash() {
        var d = Data("PHXF".utf8)
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        u32(samples.count)
        for s in samples {
            d.append(s.loop ? 1 : 0); d.append(contentsOf: s.display); u32(s.pcm.count)
            s.pcm.withUnsafeBytes { d.append(contentsOf: $0) }
        }
        try? FileManager.default.createDirectory(at: userRoot, withIntermediateDirectories: true)
        try? d.write(to: sampleFlashURL)
    }
    func restoreSampleFlash() {
        guard let d = try? Data(contentsOf: sampleFlashURL), d.prefix(4) == Data("PHXF".utf8) else { return }
        let b = [UInt8](d)
        var at = 4
        func u32() -> Int? {
            guard at + 4 <= b.count else { return nil }
            defer { at += 4 }
            return Int(b[at]) | Int(b[at + 1]) << 8 | Int(b[at + 2]) << 16 | Int(b[at + 3]) << 24
        }
        guard let n = u32() else { return }
        var out: [FlashSample] = []
        for _ in 0..<n {
            guard at + 9 <= b.count else { return }
            let loop = b[at] != 0, display = Array(b[at + 1..<at + 9]); at += 9
            guard let frames = u32(), at + frames * 2 <= b.count else { return }
            let pcm = stride(from: at, to: at + frames * 2, by: 2).map { Int16(bitPattern: UInt16(b[$0]) | UInt16(b[$0 + 1]) << 8) }
            at += frames * 2
            out.append(FlashSample(display: display, loop: loop, pcm: pcm))
        }
        samples = out
        sendSamples()
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
// (layout, patterns, tempo, swing), a card folder that is also the project's own bank:
// PROJ00/ (module: up to 128 kits; desktop: 64 kits plus the patterns as .PAT), with PRJ.NFO, the name. Like a card root it can hold samples/ and loops/ for Load Samples. To the desktop firmware missing files just mean an incomplete project, and GLO.CFG is left out
// so copying a project to a card keeps the card's global settings. No autosave: there is no undo.
extension App {
    var projectsRoot: URL { userRoot.appendingPathComponent("Projects") }
    var projectCard: URL { App.cardFolder(in: project) ?? project.appendingPathComponent("PROJ00") }

    static func isCard(_ u: URL) -> Bool { u.lastPathComponent.range(of: #"^(proj|project)\d\d$"#, options: [.regularExpression, .caseInsensitive]) != nil }
    static func cardFolder(in dir: URL) -> URL? {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { $0.hasDirectoryPath && isCard($0) }.sorted { $0.lastPathComponent < $1.lastPathComponent }.first
    }
    func layout(of dir: URL) -> String {
        if let d = try? Data(contentsOf: dir.appendingPathComponent("phx.json")),
           let m = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let l = m["layout"] as? String { return l }
        return App.cardFolder(in: dir).map(App.cardLayout) ?? "module"
    }
    // Both machines' cards hold PROJnn folders with .SND, .PAT, .SNG, GLO.CFG and PRJ.NFO (the module manual's
    // "Project00" is out of date), so only the kits tell them apart: a 309-byte kit (mod matrix) or a slot past 63 is
    // the module's. Otherwise: the desktop if it has patterns, else the module.
    static func cardLayout(_ card: URL) -> String {
        let fm = FileManager.default, files = (try? fm.contentsOfDirectory(atPath: card.path)) ?? []
        let kits = files.filter { $0.uppercased().hasSuffix(".SND") }
        if kits.contains(where: { (LxrFile.slot($0) ?? 0) >= 64 || (try? fm.attributesOfItem(atPath: card.appendingPathComponent($0).path)[.size] as? Int) == 309 }) { return "module" }
        return files.contains { $0.uppercased().hasSuffix(".PAT") } ? "desktop" : "module"
    }

    // Banks are named after their folder; the project's own bank after the project.
    func bankName(_ url: URL) -> String {
        url.standardizedFileURL.path == projectCard.standardizedFileURL.path ? "Project: \(project.lastPathComponent)" : url.lastPathComponent
    }
    func folder(bank: String) -> URL? { folders.first { bankName($0) == bank } }

    func makeProject(_ dir: URL, layout: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: App.cardFolder(in: dir) ?? dir.appendingPathComponent("PROJ00"), withIntermediateDirectories: true)
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
        cardList = nil
        UserDefaults.standard.set(dir.path, forKey: "project")
        window.title = "PHX-D01 — \(dir.lastPathComponent)"
        folders.removeAll { $0.standardizedFileURL.path == old }
        folders.insert(projectCard, at: 0)
        reloadBanks()
        select(cur.flatMap { c in kits.firstIndex { $0.dir.path == c.0 && $0.file == c.1 } } ?? kits.firstIndex { $0.dir.path == projectCard.path } ?? 0)
    }

    // phx.json, and for the desktop layout the card's .PAT (slots 00-07 only: others may hold the hardware's) and PRJ.NFO.
    func writeProject(_ d: [String: Any], to dir: URL) throws {
        let fm = FileManager.default, lay = layout(of: dir)
        var meta = (try? JSONSerialization.jsonObject(with: Data((d["json"] as? String ?? "{}").utf8))) as? [String: Any] ?? [:]
        meta["layout"] = lay
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]).write(to: dir.appendingPathComponent("phx.json"))
        guard let card = App.cardFolder(in: dir) else { return }
        try Data(LxrFile.name8(dir.lastPathComponent)).write(to: card.appendingPathComponent("PRJ.NFO"))
        guard lay == "desktop" else { return }
        let pats = patterns(from: d), swing = (d["swing"] as? NSNumber)?.doubleValue ?? 0
        let names = (try? fm.contentsOfDirectory(atPath: card.path)) ?? []
        for (n, pat) in pats.prefix(8).enumerated() {
            let prefix = String(format: "%02d-", n)
            for f in names where f.hasPrefix(prefix) && f.uppercased().hasSuffix(".PAT") { try? fm.removeItem(at: card.appendingPathComponent(f)) }
            try LxrFile.patternData(pat, swing: swing, kitNr: 0).write(to: card.appendingPathComponent(LxrFile.fileName(n, pat.name, "PAT")))
        }
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

    // A copy of the current project (its kits and this state) under a new name, which becomes current.
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
                if desktop, (LxrFile.slot(f) ?? 0) >= 64 { left += 1; continue }
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
        p.message = "Choose a project, or a card folder (PROJnn from an SD card)"
        p.beginSheetModal(for: window) { r in
            guard r == .OK, let dir = p.url else { return }
            self.loadProject(dir)
        }
    }

    // A bare card folder (e.g. straight off an SD card) is copied into a new project first, so nothing is written to the card.
    func loadProject(_ picked: URL) {
        let fm = FileManager.default
        var dir = picked
        // the card folder inside one of our projects: open that project
        if App.isCard(picked), fm.fileExists(atPath: picked.deletingLastPathComponent().appendingPathComponent("phx.json").path) {
            dir = picked.deletingLastPathComponent()
        } else if App.isCard(picked), !fm.fileExists(atPath: picked.deletingLastPathComponent().appendingPathComponent("phx.json").path) {
            let nfo = (try? Data(contentsOf: picked.appendingPathComponent("PRJ.NFO"))).map { String(decoding: $0.prefix(8), as: UTF8.self).trimmingCharacters(in: .whitespaces.union(.controlCharacters)) }
            var name = (nfo?.isEmpty == false ? nfo! : picked.lastPathComponent), n = 2
            while fm.fileExists(atPath: projectsRoot.appendingPathComponent(name).path) { name = "\(nfo ?? picked.lastPathComponent) \(n)"; n += 1 }
            dir = projectsRoot.appendingPathComponent(name)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try fm.copyItem(at: picked, to: dir.appendingPathComponent(picked.lastPathComponent))
            } catch { alert("Couldn't import \(picked.lastPathComponent)", error.localizedDescription); return }
            makeProject(dir, layout: App.cardLayout(picked))
        } else if !fm.fileExists(atPath: dir.appendingPathComponent("phx.json").path) && App.cardFolder(in: dir) == nil {
            alert("Not a project", "\(dir.lastPathComponent) has no phx.json and no PROJnn folder."); return
        }
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
