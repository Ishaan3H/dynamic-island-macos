import AppKit
import Combine
import CoreWLAN
import Foundation
import IOKit.ps
import Network

struct BatteryState: Equatable {
    var percent: Int
    var isCharging: Bool
    var isPlugged: Bool
    /// Minutes remaining, when the system has a confident estimate.
    var minutesRemaining: Int?

    var symbol: String {
        if isCharging { return "battery.100.bolt" }
        switch percent {
        case ..<13:  return "battery.0"
        case ..<38:  return "battery.25"
        case ..<63:  return "battery.50"
        case ..<88:  return "battery.75"
        default:     return "battery.100"
        }
    }
}

struct NetworkState: Equatable {
    var isOnline: Bool = false
    var isWiFi: Bool = false
    var isWired: Bool = false
    /// dBm. Typically −30 (excellent) to −90 (unusable).
    var rssi: Int?
    /// Requires Location authorisation on macOS 14+; `nil` without it.
    var ssid: String?

    /// 0–3, from RSSI. Thresholds follow the conventional Wi-Fi quality bands.
    var bars: Int {
        guard isOnline else { return 0 }
        guard let rssi else { return isWired ? 3 : 2 }
        switch rssi {
        case (-55)...:   return 3
        case (-67)...:   return 2
        case (-80)...:   return 1
        default:         return 0
        }
    }

    var symbol: String {
        if !isOnline { return "wifi.slash" }
        if isWired { return "cable.connector" }
        return "wifi"
    }
}

/// Clock, battery, and network for the expanded status header.
///
/// Every source here is push-based except Wi-Fi signal strength, which has no
/// notification API. The design consequence: nothing polls while the island is
/// collapsed. `isVisible` gates the only two timers in the app, so an idle island
/// costs zero wakeups from this service.
final class SystemStatusService: ObservableObject {

    @Published private(set) var time: String = ""
    @Published private(set) var battery: BatteryState?
    @Published private(set) var network = NetworkState()

    /// Set by the model when the status header is on screen.
    var isVisible: Bool = false {
        didSet {
            guard isVisible != oldValue else { return }
            isVisible ? resumeTimers() : suspendTimers()
        }
    }

    private var clockTimer: Timer?
    private var rssiTimer: Timer?
    private var pathMonitor: NWPathMonitor?
    private var powerSource: CFRunLoopSource?

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("j:mm")
        return f
    }()

    private let wifiQueue = DispatchQueue(label: "com.qwerty.dynamicisland.wifi", qos: .utility)

    // MARK: - Lifecycle

    func start() {
        updateClock()
        refreshBattery()
        startBatteryNotifications()
        startPathMonitor()
    }

    func stop() {
        suspendTimers()
        pathMonitor?.cancel()
        pathMonitor = nil
        if let powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .defaultMode)
            self.powerSource = nil
        }
    }

    // MARK: - Clock
    //
    // Aligned to the next minute boundary rather than ticking at 1 Hz. The header
    // shows H:MM, so 59 of every 60 wakeups would redraw nothing.

    private func scheduleClockTick() {
        clockTimer?.invalidate()
        let now = Date()
        let nextMinute = Calendar.current.nextDate(
            after: now,
            matching: DateComponents(second: 0),
            matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(60)

        let timer = Timer(fire: nextMinute, interval: 60, repeats: true) { [weak self] _ in
            self?.updateClock()
        }
        timer.tolerance = 1.0        // let the OS coalesce this with other wakeups
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    private func updateClock() {
        let next = formatter.string(from: Date())
        if next != time { time = next }
    }

    private func resumeTimers() {
        updateClock()
        scheduleClockTick()
        refreshBattery()
        refreshWiFiSignal()

        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshWiFiSignal()
        }
        timer.tolerance = 1.5
        RunLoop.main.add(timer, forMode: .common)
        rssiTimer = timer
    }

    private func suspendTimers() {
        clockTimer?.invalidate(); clockTimer = nil
        rssiTimer?.invalidate();  rssiTimer = nil
    }

    // MARK: - Battery (IOKit, push-based)

    private func startBatteryNotifications() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<SystemStatusService>.fromOpaque(ctx)
                .takeUnretainedValue()
                .refreshBattery()
        }, context)?.takeRetainedValue() else { return }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        powerSource = source
    }

    private func refreshBattery() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return }

        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }

            let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            guard max > 0 else { continue }

            let remaining = desc[kIOPSTimeToEmptyKey] as? Int ?? -1
            let next = BatteryState(
                percent: Int((Double(current) / Double(max) * 100).rounded()),
                isCharging: desc[kIOPSIsChargingKey] as? Bool ?? false,
                isPlugged: (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue,
                minutesRemaining: remaining > 0 ? remaining : nil
            )
            if battery != next { battery = next }
            return
        }
        // No internal battery (desktop Mac) — the header omits the section.
        if battery != nil { battery = nil }
    }

    // MARK: - Network

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let wifi = path.usesInterfaceType(.wifi)
            let wired = path.usesInterfaceType(.wiredEthernet)

            DispatchQueue.main.async {
                guard let self else { return }
                var next = self.network
                next.isOnline = online
                next.isWiFi = wifi
                next.isWired = wired
                if !wifi { next.rssi = nil; next.ssid = nil }
                if self.network != next { self.network = next }
            }
            if wifi { self?.refreshWiFiSignal() }
        }
        monitor.start(queue: DispatchQueue(label: "com.qwerty.dynamicisland.netpath", qos: .utility))
        pathMonitor = monitor
    }

    /// The one genuine poll in the app. CoreWLAN has no signal-change callback, so
    /// this runs at 0.2 Hz and only while the header is visible.
    ///
    /// `rssiValue()` works without authorisation; `ssid()` returns nil unless the
    /// user has granted Location access, so the header falls back to bars alone.
    private func refreshWiFiSignal() {
        wifiQueue.async { [weak self] in
            guard let interface = CWWiFiClient.shared().interface(), interface.powerOn() else { return }
            let rssi = interface.rssiValue()
            let ssid = interface.ssid()

            DispatchQueue.main.async {
                guard let self else { return }
                var next = self.network
                next.rssi = rssi == 0 ? nil : rssi
                next.ssid = ssid
                if self.network != next { self.network = next }
            }
        }
    }
}
