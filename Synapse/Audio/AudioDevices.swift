import CoreAudio
import SwiftUI

/// The Mac's audio devices, from Core Audio. Choices are stored by UID, which survives reconnects and reboots
/// (device IDs do not).
struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum AudioDevices {
    /// The app-wide choices (UIDs, "" for the system default), set in Live and Clone Voice.
    static let inputKey = "liveInputDevice", outputKey = "liveOutputDevice"
    static func list(input: Bool) -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard channels(id, input: input) > 0, let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return AudioDevice(id: id, uid: uid, name: name)
        }
    }

    /// The device with this UID, if it is connected.
    static func device(uid: String, input: Bool) -> AudioDeviceID? {
        uid.isEmpty ? nil : list(input: input).first { $0.uid == uid }?.id
    }

    /// Calls `change` on the main queue whenever a device is connected or removed. Keep the returned token alive.
    static func observe(_ change: @escaping @Sendable () -> Void) -> AnyObject {
        let token = Observer(change)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, token.block)
        return token
    }

    private final class Observer {
        let block: AudioObjectPropertyListenerBlock
        init(_ change: @escaping @Sendable () -> Void) { block = { _, _ in change() } }
        deinit {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                     mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
    }

    private static func channels(_ id: AudioDeviceID, input: Bool) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

/// The microphone or speaker menu: the system default first, then each connected device. A saved device that is
/// unplugged stays listed so the choice is not silently lost.
struct AudioDevicePicker: View {
    let title: String
    let input: Bool
    @AppStorage private var uid: String
    @State private var devices: [AudioDevice] = []
    @State private var watch: AnyObject?

    init(_ title: String, input: Bool) {
        self.title = title
        self.input = input
        _uid = AppStorage(wrappedValue: "", input ? AudioDevices.inputKey : AudioDevices.outputKey)
    }

    var body: some View {
        Picker(title, selection: $uid) {
            Text("System Default").tag("")
            Divider()
            ForEach(devices) { Text($0.name).tag($0.uid) }
            if !uid.isEmpty && !devices.contains(where: { $0.uid == uid }) { Text("Disconnected device").tag(uid) }
        }
        .onAppear {
            devices = AudioDevices.list(input: input)
            let input = input
            watch = AudioDevices.observe { Task { @MainActor in devices = AudioDevices.list(input: input) } }
        }
    }
}
