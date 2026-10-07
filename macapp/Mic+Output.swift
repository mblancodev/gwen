// Default output helpers: headphones refuse echo-cancelled capture (Mic.swift uses plain instead).
import CoreAudio

func headphonesOut() -> Bool {
    guard let dev = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) else { return false }
    if isBluetooth(dev) { return true }
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource, mScope: kAudioDevicePropertyScopeOutput,
                                          mElement: kAudioObjectPropertyElementMain)
    var source: UInt32 = 0
    var n = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectHasProperty(dev, &addr), AudioObjectGetPropertyData(dev, &addr, 0, nil, &n, &source) == noErr else { return false }
    return source == 0x6864_706E  // 'hdpn'
}

func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var dev = AudioObjectID(0)
    var n = UInt32(MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &n, &dev) == noErr, dev != 0
    else { return nil }
    return dev
}

func isBluetooth(_ dev: AudioObjectID) -> Bool {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var t: UInt32 = 0
    var n = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &n, &t) == noErr else { return false }
    return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
}
