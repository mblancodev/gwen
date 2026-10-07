// Gwen's menu → Microphone: "Same as Mac" follows System Settings → Sound → Input, or one input device by
// name. The choice is `mic` in ~/.gwen/config.json; `input <name|default>` tells the listener to reopen the mic.
import AppKit
import CoreAudio

struct InputDevice {
    let id: AudioObjectID
    let name: String
    let bluetooth: Bool
}

extension HUD {
    static let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
    static var micChoice: String { (GwenConfig.load()["mic"] as? String) ?? "default" }

    /// Rebuilt each time Gwen's menu opens: devices come and go (AirPods, a USB mic).
    func fillMicMenu() {
        let menu = NSMenu()
        let devices = inputDevices()
        let choice = HUD.micChoice
        let mac = defaultDevice(kAudioHardwarePropertyDefaultInputDevice).flatMap { id in devices.first { $0.id == id } }
        let choices = [("Same as Mac" + (mac.map { " (\($0.name))" } ?? ""), "default")] + devices.map { ($0.name, $0.name) }
        for (i, (title, value)) in choices.enumerated() {
            let m = NSMenuItem(title: title, action: #selector(pickMic(_:)), keyEquivalent: "")
            m.representedObject = value
            m.target = self
            m.state = value == choice ? .on : .off
            menu.addItem(m)
            if i == 0 { menu.addItem(.separator()) }
        }
        let using = choice == "default" ? mac : devices.first { $0.name == choice }
        if using?.bluetooth == true {
            menu.addItem(.separator())
            for line in ["A Bluetooth mic switches your headphones to call", "quality: pick the Mac's own mic to avoid it."] {
                let note = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                note.isEnabled = false
                menu.addItem(note)
            }
        }
        HUD.micItem.submenu = menu
    }

    @objc func pickMic(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, value != HUD.micChoice else { return }
        GwenConfig.set("mic", value)
        emit("input " + value)
    }
}

/// Every device with an input stream, by the name System Settings shows (`mic plain` finds it by that name, Mic.swift).
func inputDevices() -> [InputDevice] {
    let system = AudioObjectID(kAudioObjectSystemObject)
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.compactMap { id in
        var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0 else { return nil }
        var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var n = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &n, &name) == noErr,
              let s = name?.takeRetainedValue() as String?, !s.isEmpty else { return nil }
        return InputDevice(id: id, name: s, bluetooth: isBluetooth(id))
    }
}
