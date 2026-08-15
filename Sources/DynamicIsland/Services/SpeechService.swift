import AVFoundation
import Combine
import Foundation
import Speech

/// Microphone capture plus speech-to-text.
///
/// Recognition is forced **on-device** (`requiresOnDeviceRecognition`). This Mac
/// reports `supportsOnDeviceRecognition == true`, so nothing about a spoken
/// command — which may name a calendar event or a private vault — leaves the
/// machine. If on-device support were unavailable the request would fall back to
/// Apple's servers, so the flag is set explicitly rather than left to default.
final class SpeechService: ObservableObject {

    enum Phase: Equatable {
        case idle
        case listening
        case finished(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// Live partial transcript, for on-screen feedback while speaking.
    @Published private(set) var transcript = ""
    /// Rough input level, 0–1, for the waveform.
    @Published private(set) var level: Double = 0

    /// Called once with the final transcript when capture ends successfully.
    var onFinalTranscript: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    /// Built fresh for every capture, never held as a `let`.
    ///
    /// `AVAudioEngine` resolves `inputNode` against the hardware the moment it is
    /// created. Constructed once at init — before the microphone grant exists —
    /// it binds to a null input device, and *keeps* that binding after permission
    /// is later granted: the tap then runs forever on silence and every transcript
    /// comes back empty. Creating it per session is the fix.
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Counts buffers reaching the tap, so "heard nothing" can be distinguished
    /// from "no audio ever arrived" — very different faults, identical symptom.
    private(set) var bufferCount = 0
    /// Description of the input format the engine bound to, for diagnostics.
    private(set) var inputDescription: String?
    /// Loudest level seen this session.
    private(set) var peakLevel: Double = 0

    /// Ends capture once the user stops talking, so there's no "stop" gesture.
    private var silenceTimer: Timer?
    private let silenceGrace: TimeInterval = 1.4
    /// Longer grace before the *first* word — there's a beat between the hotkey
    /// firing and the user actually starting to speak.
    private let openingGrace: TimeInterval = 4.0
    /// Hard ceiling — a stuck stream shouldn't hold the microphone open forever.
    private var maxDurationTimer: Timer?
    private let maxDuration: TimeInterval = 15

    var isListening: Bool { phase == .listening }

    // MARK: - Authorisation

    /// Both grants are needed: Speech Recognition *and* Microphone.
    func requestAuthorization(_ completion: @escaping (Bool, String?) -> Void) {
        SFSpeechRecognizer.requestAuthorization { speechStatus in
            guard speechStatus == .authorized else {
                DispatchQueue.main.async {
                    completion(false, "Speech Recognition access was denied")
                }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { micGranted in
                DispatchQueue.main.async {
                    completion(micGranted, micGranted ? nil : "Microphone access was denied")
                }
            }
        }
    }

    // MARK: - Capture

    func start() {
        guard !isListening else { return }

        guard let recognizer, recognizer.isAvailable else {
            fail("Speech recognition is unavailable")
            return
        }

        transcript = ""
        level = 0
        bufferCount = 0
        peakLevel = 0
        inputDescription = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Keep the audio on this machine. See the type comment.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        self.request = request

        let engine = AVAudioEngine()
        self.engine = engine

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        inputDescription = "\(Int(format.sampleRate))Hz \(format.channelCount)ch"
        Log.debug("speech: input format \(inputDescription!)")

        guard format.sampleRate > 0, format.channelCount > 0 else {
            fail("No audio input available — check the microphone in System Settings → Sound")
            return
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            self?.noteBuffer(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.engine = nil
            fail("Couldn't start audio engine: \(error.localizedDescription)")
            return
        }

        phase = .listening
        armMaxDuration()
        armSilenceTimer(grace: openingGrace)

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    self.transcript = text
                    self.armSilenceTimer(grace: self.silenceGrace)
                }
                if result.isFinal {
                    DispatchQueue.main.async { self.finish(with: text) }
                }
                return
            }

            if let error {
                // A cancelled task after a successful finish is not an error.
                DispatchQueue.main.async {
                    guard self.isListening else { return }
                    let nsError = error as NSError
                    if nsError.code == 301 || nsError.code == 216 {
                        self.finish(with: self.transcript)
                    } else {
                        self.fail(error.localizedDescription)
                    }
                }
            }
        }
    }

    /// Ends capture and reports whatever was heard.
    func stop() {
        guard isListening else { return }
        finish(with: transcript)
    }

    func reset() {
        teardown()
        phase = .idle
        transcript = ""
        level = 0
    }

    // MARK: - Internals

    private func finish(with text: String) {
        guard isListening else { return }
        teardown()

        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            // Naming the actual fault beats a generic shrug: no buffers means the
            // input device never delivered audio, which is a different problem
            // from speech that simply wasn't recognised.
            phase = .failed(bufferCount == 0
                ? "No audio from the microphone — check System Settings → Sound → Input"
                : "Didn't catch that — try again")
            Log.debug("speech: empty transcript after \(bufferCount) buffers")
            return
        }
        phase = .finished(cleaned)
        Log.debug("speech: \"\(cleaned)\"")
        onFinalTranscript?(cleaned)
    }

    private func fail(_ message: String) {
        teardown()
        phase = .failed(message)
        Log.debug("speech failed: \(message)")
    }

    private func teardown() {
        silenceTimer?.invalidate(); silenceTimer = nil
        maxDurationTimer?.invalidate(); maxDurationTimer = nil

        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil

        if let engine {
            if engine.isRunning { engine.stop() }
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        level = 0
    }

    private func armSilenceTimer(grace: TimeInterval) {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: grace, repeats: false) { [weak self] _ in
            guard let self, self.isListening else { return }
            self.finish(with: self.transcript)
        }
    }

    private func armMaxDuration() {
        maxDurationTimer?.invalidate()
        maxDurationTimer = Timer.scheduledTimer(withTimeInterval: maxDuration, repeats: false) { [weak self] _ in
            guard let self, self.isListening else { return }
            self.finish(with: self.transcript)
        }
    }

    private func noteBuffer(_ buffer: AVAudioPCMBuffer) {
        if bufferCount == 0 { Log.debug("speech: first audio buffer received") }
        bufferCount += 1
        updateLevel(from: buffer)
    }

    /// Cheap RMS off the mic buffer, smoothed, purely to drive the waveform.
    private func updateLevel(from buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        var sum: Float = 0
        for i in 0..<count { sum += channel[i] * channel[i] }
        let rms = (sum / Float(count)).squareRoot()
        // Map roughly -50..0 dB onto 0..1.
        let db = 20 * log10(max(rms, 1e-7))
        let normalised = Double(max(0, min(1, (db + 50) / 50)))

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.level += (normalised - self.level) * 0.3
            self.peakLevel = max(self.peakLevel, normalised)
        }
    }
}
