// The LXR02Open sample loader (Core/Menu/menu.c, Core/Hardware/SD/filesystem.c, Core/SampleRom/SampleMemory.c),
// reading a card folder from disk; RAM stands in for the sample flash.
import Foundation

struct FlashSample {
    let display: [UInt8]   // 8 characters; 0 is the LCD's ellipsis
    let loop: Bool
    let pcm: [Int16]
}

enum SampleLoader {
    static let lfnMax = 80   // FS_SAMPLE_LFN_MAX
    static let notWav = "not a mono 16-bit 44.1 kHz PCM WAV"

    struct Pass { var installed: [String] = [], skipped: [(String, String)] = [] }
    struct Report { var samples = Pass(), loops = Pass(), failed: String? }

    // filesystem_parseWav: RIFF/WAVE with a PCM, mono, 44100 Hz, 16-bit fmt chunk and a non-empty, even data chunk.
    // Returns the data chunk as it is in the file.
    static func parseWav(_ file: Data) -> [Int16]? {
        let b = [UInt8](file)
        func id(_ o: Int, _ s: String) -> Bool { o + 4 <= b.count && Array(b[o..<o + 4]) == Array(s.utf8) }
        func le16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func le32(_ o: Int) -> Int { le16(o) | le16(o + 2) << 16 }
        guard id(0, "RIFF"), id(8, "WAVE") else { return nil }
        var pos = 12, fmtOk = false, data: Range<Int>?
        while pos + 8 <= b.count {
            let size = le32(pos + 4), body = pos + 8, next = body + size + (size & 1)
            if id(pos, "fmt ") {
                guard size >= 16, body + 16 <= b.count else { return nil }
                fmtOk = le16(body) == 1 && le16(body + 2) == 1 && le32(body + 4) == 44100 && le16(body + 14) == 16
                guard fmtOk else { return nil }
            } else if id(pos, "data") {
                data = size != 0 && size & 1 == 0 ? body..<body + size : nil
            }
            guard next <= b.count else { return nil }   // the seek past the chunk fails
            pos = next
            if fmtOk && data != nil { break }
        }
        guard fmtOk, let r = data else { return nil }
        return stride(from: r.lowerBound, to: r.upperBound, by: 2).map { Int16(bitPattern: UInt16(b[$0]) | UInt16(b[$0 + 1]) << 8) }
    }

    // filesystem_lfnAppendEntry: the long name as the card stores it, ASCII with anything else as '_'.
    static func lfn(_ name: String) -> [UInt8] {
        Array(name.precomposedStringWithCanonicalMapping.utf16.map { $0 < 0x80 ? UInt8($0) : UInt8(ascii: "_") }.prefix(lfnMax - 1))
    }

    // filesystem_isWavName
    static func isWavName(_ n: [UInt8]) -> Bool {
        n.count >= 5 && n[n.count - 4] == UInt8(ascii: ".") && String(decoding: n.suffix(3), as: UTF8.self).lowercased() == "wav"
    }

    // filesystem_displayNameFromFilename: the stem if it fits in 8, else its first 4, an ellipsis and its last 3.
    static func displayName(_ n: [UInt8]) -> [UInt8] {
        let dot = n.lastIndex(of: UInt8(ascii: ".")) ?? 0
        let stem = dot == 0 ? n.count : dot
        if stem > 8 { return Array(n[0..<4]) + [0] + Array(n[stem - 3..<stem]) }
        return Array(n[0..<stem]) + [UInt8](repeating: 32, count: 8 - stem)
    }

    // filesystem_compareSampleNameStrict: ASCII case-insensitive.
    static func precedes(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        let lower = { (c: UInt8) in c >= 65 && c <= 90 ? c + 32 : c }
        return a.map(lower).lexicographicallyPrecedes(b.map(lower))
    }

    // filesystem_manifestCanFit: the data rounded up to 4 bytes, plus one zero pad word.
    static func flashBytes(_ pcm: [Int16]) -> Int { ((pcm.count * 2 + 3) & ~3) + 4 }

    // filesystem_scanSamples: the folder's .wav files (not subfolders) that parse, in long-name order; the first
    // maxCount of them, then the first maxNew that fit in bytesFree, skipping any that don't. Nil if the folder can't be opened.
    static func scan(_ dir: URL, maxCount: Int, maxNew: Int, bytesFree: Int, loop: Bool) -> ([FlashSample], Pass)? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue,
              let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return nil }
        var pass = Pass()
        var found: [(name: String, lfn: [UInt8], pcm: [Int16])] = []
        for name in names {
            var sub: ObjCBool = false
            guard fm.fileExists(atPath: dir.appendingPathComponent(name).path, isDirectory: &sub), !sub.boolValue else { continue }
            let l = lfn(name)
            guard isWavName(l) else { continue }
            guard let pcm = (try? Data(contentsOf: dir.appendingPathComponent(name))).flatMap(parseWav) else {
                pass.skipped.append((name, notWav)); continue
            }
            found.append((name, l, pcm))
        }
        found.sort { precedes($0.lfn, $1.lfn) }
        for f in found.dropFirst(maxCount) { pass.skipped.append((f.name, "over \(maxCount) samples")) }
        var out: [FlashSample] = [], left = bytesFree
        for f in found.prefix(maxCount) {
            if out.count >= maxNew { pass.skipped.append((f.name, "over \(maxCount) samples")); continue }
            guard flashBytes(f.pcm) <= left else { pass.skipped.append((f.name, "no room in the sample flash")); continue }
            left -= flashBytes(f.pcm)
            out.append(FlashSample(display: displayName(f.lfn), loop: loop, pcm: f.pcm))
            pass.installed.append(f.name)
        }
        return (out, pass)
    }

    // menu_loadSamplesModal: filesystem_installSamplesBlocking (a new set from /samples; the old one stays if the folder
    // can't be opened), then filesystem_installLoopsBlocking (/loops appended, looped). Either failing shows "<stage> Failed".
    static func load(card: URL, current: [FlashSample], maxCount: Int, romBytes: Int) -> ([FlashSample], Report) {
        var report = Report(), flash = current
        let free = romBytes - 4   // the first word of the flash holds the count
        let samples = scan(card.appendingPathComponent("samples"), maxCount: maxCount, maxNew: maxCount, bytesFree: free, loop: false)
        if let (set, pass) = samples { flash = set; report.samples = pass }
        let used = flash.reduce(0) { $0 + flashBytes($1.pcm) }
        let loops = scan(card.appendingPathComponent("loops"), maxCount: maxCount, maxNew: maxCount - flash.count, bytesFree: free - used, loop: true)
        if let (set, pass) = loops { flash += set; report.loops = pass }
        if samples == nil { report.failed = "Sample upload" } else if loops == nil { report.failed = "Loop upload" }
        return (flash, report)
    }
}
