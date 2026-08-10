import AppKit
import Combine
import Foundation

struct NowPlaying: Equatable {
    var trackID: String
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var position: TimeInterval
    var isPlaying: Bool
    var artworkURL: URL?

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }
}

/// Abstraction over "what is playing". Implemented here by Spotify; a MediaRemote
/// backend can be dropped in behind the same protocol if the app is ever signed
/// with the private entitlement Apple now requires for it.
protocol NowPlayingSource: AnyObject {
    var current: NowPlaying? { get }
    func start()
    func stop()
    func togglePlayPause()
    func nextTrack()
    func previousTrack()
}

/// Spotify integration.
///
/// **Why not MediaRemote?** `MRMediaRemoteGetNowPlayingInfo` was the usual way to
/// read system-wide Now Playing, but as of macOS 15.4 it is gated behind a private
/// entitlement and returns nothing to third-party apps. Spotify's own scripting
/// interface is supported, documented, and — crucially — pairs with a distributed
/// notification that pushes state changes, so the steady-state cost here is zero
/// polling: we only run AppleScript on track change (for artwork) and on explicit
/// transport commands.
final class SpotifyService: ObservableObject, NowPlayingSource {

    @Published private(set) var current: NowPlaying?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var isRunning = false
    /// True once an Apple Event comes back with errAEEventNotPermitted (-1743),
    /// meaning the user has not granted Automation access.
    @Published private(set) var automationDenied = false

    /// Gates the 1 Hz scrubber timer — it only runs while the card is on screen.
    var isVisible = false { didSet { syncTicker() } }

    private static let bundleID = "com.spotify.client"
    private static let notificationName = Notification.Name("com.spotify.client.PlaybackStateChanged")

    private let scriptQueue = DispatchQueue(label: "com.qwerty.dynamicisland.applescript")
    private var ticker: Timer?
    private var artworkTask: URLSessionDataTask?
    private var loadedArtworkTrackID: String?

    // MARK: - Lifecycle

    func start() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(playbackStateChanged(_:)),
            name: Self.notificationName,
            object: nil
        )

        // Spotify launching/quitting changes whether we should show the card at all.
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self, selector: #selector(appsChanged),
            name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        workspaceCenter.addObserver(
            self, selector: #selector(appsChanged),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        refreshRunningState()
        if isRunning { fetchFullState() }
    }

    func stop() {
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        ticker?.invalidate()
        ticker = nil
    }

    // MARK: - State

    @objc private func appsChanged() {
        let wasRunning = isRunning
        refreshRunningState()
        if isRunning && !wasRunning {
            fetchFullState()
        } else if !isRunning {
            current = nil
            artwork = nil
            loadedArtworkTrackID = nil
        }
    }

    private func refreshRunningState() {
        let running = !NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
        if running != isRunning { isRunning = running }
    }

    /// Spotify pushes the full track payload with every state change, so this is
    /// the hot path and it costs us no IPC at all.
    @objc private func playbackStateChanged(_ note: Notification) {
        guard let info = note.userInfo else { return }
        refreshRunningState()

        let state = info["Player State"] as? String ?? "Paused"
        let trackID = info["Track ID"] as? String ?? ""
        // Spotify reports Duration in milliseconds and Playback Position in seconds.
        let durationMS = (info["Duration"] as? NSNumber)?.doubleValue ?? 0
        let position = (info["Playback Position"] as? NSNumber)?.doubleValue ?? 0

        var snapshot = NowPlaying(
            trackID: trackID,
            title: info["Name"] as? String ?? "Unknown",
            artist: info["Artist"] as? String ?? "",
            album: info["Album"] as? String ?? "",
            duration: durationMS / 1000.0,
            position: position,
            isPlaying: state == "Playing",
            artworkURL: current?.trackID == trackID ? current?.artworkURL : nil
        )

        // "Stopped" means nothing is loaded at all.
        if state == "Stopped" && trackID.isEmpty {
            current = nil
            artwork = nil
            return
        }

        if snapshot.artworkURL == nil { snapshot.artworkURL = nil }
        current = snapshot
        syncTicker()

        if trackID != loadedArtworkTrackID {
            fetchArtworkURL(for: trackID)
        }
    }

    /// Full read via AppleScript. Used once at launch (the notification only fires
    /// on *change*, so a track already playing would otherwise be invisible).
    func fetchFullState() {
        runScript(Self.readStateScript) { [weak self] output in
            guard let self, let output else { return }
            guard output != "NOTRUNNING", output != "NOTRACK" else { return }

            let parts = output.components(separatedBy: "\t")
            guard parts.count >= 8 else { return }

            let durationMS = Double(parts[4]) ?? 0
            let snapshot = NowPlaying(
                trackID: parts[0],
                title: parts[1],
                artist: parts[2],
                album: parts[3],
                duration: durationMS / 1000.0,
                position: Double(parts[5]) ?? 0,
                isPlaying: parts[6].lowercased().contains("playing"),
                artworkURL: URL(string: parts[7])
            )
            self.current = snapshot
            self.syncTicker()
            self.loadArtwork(from: snapshot.artworkURL, trackID: snapshot.trackID)
        }
    }

    private func fetchArtworkURL(for trackID: String) {
        runScript(Self.artworkScript) { [weak self] output in
            guard let self, let output, let url = URL(string: output) else { return }
            if self.current?.trackID == trackID {
                self.current?.artworkURL = url
            }
            self.loadArtwork(from: url, trackID: trackID)
        }
    }

    private func loadArtwork(from url: URL?, trackID: String) {
        guard let url, trackID != loadedArtworkTrackID else { return }
        artworkTask?.cancel()
        loadedArtworkTrackID = trackID

        artworkTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            // Decode on the URLSession delegate queue, downsampled to the largest
            // size the island ever draws (78 pt @2x). Spotify serves art up to
            // 640², so handing the raw image to SwiftUI would resample a 400 KB
            // bitmap on the main thread on every redraw of the card.
            guard let data, let image = Self.decodeArtwork(data, pixels: 160) else { return }
            DispatchQueue.main.async {
                guard let self, self.current?.trackID == trackID else { return }
                self.artwork = image
            }
        }
        artworkTask?.resume()
    }

    private static func decodeArtwork(_ data: Data, pixels: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: pixels, height: pixels))
    }

    // MARK: - Local scrubber

    private func syncTicker() {
        let shouldRun = isVisible && (current?.isPlaying ?? false)
        if shouldRun, ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self, var snapshot = self.current, snapshot.isPlaying else { return }
                snapshot.position = min(snapshot.position + 1.0, snapshot.duration)
                self.current = snapshot
            }
            ticker.map { RunLoop.main.add($0, forMode: .common) }
        } else if !shouldRun {
            ticker?.invalidate()
            ticker = nil
        }
    }

    // MARK: - Transport

    func togglePlayPause() { command("playpause"); optimisticToggle() }
    func nextTrack()       { command("next track") }
    func previousTrack()   { command("previous track") }

    private func optimisticToggle() {
        // Flip immediately; the distributed notification corrects us milliseconds later.
        current?.isPlaying.toggle()
        syncTicker()
    }

    private func command(_ verb: String) {
        guard isRunning else { return }
        runScript("tell application \"Spotify\" to \(verb)") { _ in }
    }

    // MARK: - AppleScript plumbing

    private static let readStateScript = """
    tell application "Spotify"
        if it is not running then return "NOTRUNNING"
        try
            set t to current track
            set out to (id of t) & tab & (name of t) & tab & (artist of t) & tab & \
    (album of t) & tab & (duration of t) & tab & (player position) & tab & \
    (player state as text) & tab & (artwork url of t)
            return out
        on error
            return "NOTRACK"
        end try
    end tell
    """

    private static let artworkScript = """
    tell application "Spotify"
        if it is not running then return ""
        try
            return artwork url of current track
        on error
            return ""
        end try
    end tell
    """

    /// NSAppleScript instances are not thread-safe *shared*, but constructing and
    /// executing one entirely inside a single serial queue is safe and keeps Apple
    /// Event round-trips (which can block for 100 ms+ against a busy Spotify) off
    /// the main thread.
    private func runScript(_ source: String, completion: @escaping (String?) -> Void) {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty == false else {
            completion(nil)
            return
        }

        scriptQueue.async { [weak self] in
            var error: NSDictionary?
            let script = NSAppleScript(source: source)
            let result = script?.executeAndReturnError(&error)

            if let error {
                let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
                // -1743: user has not granted Automation access to Spotify.
                if code == -1743 {
                    DispatchQueue.main.async { self?.automationDenied = true }
                }
                DispatchQueue.main.async { completion(nil) }
                return
            }

            DispatchQueue.main.async {
                self?.automationDenied = false
                completion(result?.stringValue)
            }
        }
    }

    /// Opens the exact pane the user needs if Automation was denied.
    static func openAutomationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
        NSWorkspace.shared.open(url)
    }
}
