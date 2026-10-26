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

    func write(_ data: Data, to url: URL) -> Bool {
        do { try data.write(to: url); return true } catch { alert("Couldn't save \(url.lastPathComponent)", error.localizedDescription); return false }
    }

    // After writing into a folder: make it a bank and select the given file in it.
    func reveal(folder: URL, file: String?) {
        if !folders.contains(where: { $0.path == folder.path }) { folders.append(folder) }
        reloadBanks()
        select(kits.firstIndex { $0.dir.path == folder.path && $0.file == file } ?? kit)
    }

    // ---------- kits ----------
    func saveKit() {
        guard !kits.isEmpty else { return }
        let k = kits[kit]
        if write(LxrFile.kitData(name: k.name, params: k.params), to: k.dir.appendingPathComponent(k.file)) {
            kits[kit].edited = false
            sendState()
        }
    }

    // morphed: save what you hear (the kit morphed toward the target) as a new kit.
    func saveKitAs(morphed: Bool) {
        guard !kits.isEmpty else { return }
        let k = kits[kit]
        let p = NSSavePanel()
        p.directoryURL = k.dir
        p.allowedContentTypes = []
        p.nameFieldStringValue = morphed ? LxrFile.fileName(bankKits.count, "M" + k.name, "SND") : LxrFile.fileName(bankKits.count, k.name, "SND")
        p.message = "The kit's name is the file name without its NN- prefix (8 characters)."
        p.beginSheetModal(for: window) { r in
            guard r == .OK, let url = p.url else { return }
            var stem = url.deletingPathExtension().lastPathComponent
            if let r = stem.range(of: #"^\d\d-"#, options: .regularExpression) { stem.removeSubrange(r) }
            let dest = url.pathExtension.isEmpty ? url.appendingPathExtension("SND") : url
            if self.write(LxrFile.kitData(name: stem, params: morphed ? self.heardParams() : k.params), to: dest) {
                self.reveal(folder: dest.deletingLastPathComponent(), file: dest.lastPathComponent)
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
