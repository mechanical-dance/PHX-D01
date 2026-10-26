// What survives a restart besides saved files: the engine, the panel, the kit you're on, your unsaved kit edits and
// the morph. Written on every change, read back once the banks are loaded.
import Foundation

extension App {
    private func path(_ k: Kit) -> String { k.dir.path + "/" + k.file }

    func saveSession() {
        guard sessionRestored, !kits.isEmpty else { return }   // not before the restore, or launch would overwrite it
        let edits: [[String: Any]] = kits.filter(\.edited).map { ["path": path($0), "name": $0.name, "params": Data($0.params)] }
        UserDefaults.standard.set(["engine": Int(engine), "hw": Int(hw), "kit": path(kits[kit]),
                                   "morphTarget": morphTarget >= 0 && morphTarget < kits.count ? path(kits[morphTarget]) : "",
                                   "morphAmount": Int(morphAmount), "edits": edits], forKey: "session")
    }

    func restoreSession() {
        defer { sessionRestored = true }
        guard let s = UserDefaults.standard.dictionary(forKey: "session"), !kits.isEmpty else { return }
        for e in s["edits"] as? [[String: Any]] ?? [] {
            guard let p = e["path"] as? String, let params = e["params"] as? Data, params.count == kitBytes,
                  let i = kits.firstIndex(where: { path($0) == p }) else { continue }
            kits[i].params = [UInt8](params)
            kits[i].name = e["name"] as? String ?? kits[i].name
            kits[i].edited = true
        }
        if let p = s["kit"] as? String, let i = kits.firstIndex(where: { path($0) == p }) { kit = i }
        if let p = s["morphTarget"] as? String, let i = kits.firstIndex(where: { path($0) == p }) { morphTarget = i }
        morphAmount = UInt8(clamping: s["morphAmount"] as? Int ?? 0)
        let e = Int32(s["engine"] as? Int ?? 0)
        if e >= 0 && e < lxa_engine_count() { engine = e; lxa_engine(e) }
        hw = Int32(s["hw"] as? Int ?? 0) == LXA_MODULE ? Int32(LXA_MODULE) : Int32(LXA_DESKTOP)
        lxa_hardware(hw)
    }
}
