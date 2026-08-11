import AppKit
import Combine
import CoreAudio
import CoreMediaIO
import Foundation

/// Watches whether the camera or microphone is live, for the recording indicator.
///
/// This uses the hardware property `…DeviceIsRunningSomewhere`, which reports
/// whether *any* process on the machine has the device open. Reading it needs no
/// Camera or Microphone TCC grant — we never open a stream, we only ask the
/// hardware abstraction layer about its own state — and it is push-based, so the
/// steady-state cost is a sleeping listener block rather than a poll.
///
/// Note: screen recording is deliberately not covered. macOS exposes no public
/// query for "is another process capturing the display", and the private paths for
/// it are both fragile and entitlement-gated. The system's own purple/orange
/// indicators remain the source of truth there.
final class DeviceActivityMonitor: ObservableObject {

    @Published private(set) var cameraActive = false
    @Published private(set) var microphoneActive = false

    var isRecording: Bool { cameraActive }

    private let queue = DispatchQueue(label: "com.qwerty.dynamicisland.deviceactivity", qos: .utility)
    private var cameraListeners: [(CMIOObjectID, CMIOObjectPropertyAddress)] = []
    private var micListeners: [(AudioObjectID, AudioObjectPropertyAddress)] = []

    // MARK: - Lifecycle

    func start() {
        attachCameraListeners()
        attachMicrophoneListeners()
        observeDeviceListChanges()
        refresh()
    }

    func stop() {
        for (id, addr) in cameraListeners {
            var a = addr
            CMIOObjectRemovePropertyListenerBlock(id, &a, queue, { _, _ in })
        }
        cameraListeners.removeAll()
        micListeners.removeAll()
    }

    private func refresh() {
        let camera = Self.anyCameraRunning()
        let mic = Self.anyMicrophoneRunning()
        DispatchQueue.main.async {
            if self.cameraActive != camera { self.cameraActive = camera }
            if self.microphoneActive != mic { self.microphoneActive = mic }
        }
    }

    // MARK: - Camera (CoreMediaIO)

    private func attachCameraListeners() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard)
        )

        for device in Self.cameraDeviceIDs() {
            let status = CMIOObjectAddPropertyListenerBlock(device, &address, queue) { [weak self] _, _ in
                self?.refresh()
            }
            if status == noErr { cameraListeners.append((device, address)) }
        }
    }

    private func observeDeviceListChanges() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        CMIOObjectAddPropertyListenerBlock(
            CMIOObjectID(kCMIOObjectSystemObject), &address, queue
        ) { [weak self] _, _ in
            // A camera was plugged in or removed — rebind and re-evaluate.
            guard let self else { return }
            self.attachCameraListeners()
            self.refresh()
        }
    }

    private static func cameraDeviceIDs() -> [CMIOObjectID] {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &dataSize) == noErr,
            dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        var devices = [CMIOObjectID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil,
            dataSize, &used, &devices) == noErr else { return [] }

        return devices
    }

    private static func anyCameraRunning() -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard)
        )

        for device in cameraDeviceIDs() {
            var running: UInt32 = 0
            var used: UInt32 = 0
            let size = UInt32(MemoryLayout<UInt32>.size)
            if CMIOObjectGetPropertyData(device, &address, 0, nil, size, &used, &running) == noErr,
               running != 0 {
                return true
            }
        }
        return false
    }

    // MARK: - Microphone (CoreAudio)

    private func attachMicrophoneListeners() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        for device in Self.inputDeviceIDs() {
            let status = AudioObjectAddPropertyListenerBlock(device, &address, queue) { [weak self] _, _ in
                self?.refresh()
            }
            if status == noErr { micListeners.append((device, address)) }
        }
    }

    private static func inputDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr,
            dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var devices = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            &dataSize, &devices) == noErr else { return [] }

        return devices.filter { hasInputStreams($0) }
    }

    private static func hasInputStreams(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return false }

        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }

        guard AudioObjectGetPropertyData(device, &address, 0, nil, &dataSize, buffer) == noErr else {
            return false
        }
        let list = buffer.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(list).contains { $0.mNumberChannels > 0 }
    }

    private static func anyMicrophoneRunning() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        for device in inputDeviceIDs() {
            var running: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr,
               running != 0 {
                return true
            }
        }
        return false
    }
}
