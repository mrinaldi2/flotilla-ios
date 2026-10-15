import AVFoundation
import Observation
import Speech

/// Speech to text for the composer and the screen: listens to the
/// microphone and keeps a live transcript. Recognition runs on the phone
/// whenever iOS can do it on-device for the language.
@MainActor
@Observable
final class Dictation {
    enum Phase: Equatable {
        case idle
        case listening
        case failed(String)
    }

    private(set) var phase = Phase.idle
    /// What was heard so far; it changes while listening as recognition settles.
    private(set) var transcript = ""

    var isListening: Bool { phase == .listening }

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let recognizer = SFSpeechRecognizer()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?

    func start() async {
        guard !isListening else { return }
        transcript = ""
        guard await Self.authorized() else {
            phase = .failed("Allow the microphone and Speech Recognition for The Hermes in the iPhone's Settings.")
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            phase = .failed("Speech recognition is not available right now.")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            // Keep the voice on the phone when the language allows it.
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            self.request = request

            let input = engine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let done = error != nil || (result?.isFinal ?? false)
                Task { @MainActor in
                    guard let self else { return }
                    if let text { self.transcript = text }
                    if done, self.isListening { self.finish() }
                }
            }
            phase = .listening
        } catch {
            finish()
            phase = .failed("Couldn’t start listening.\n\(error.localizedDescription)")
        }
    }

    /// Stops listening and returns what was heard.
    @discardableResult
    func stop() -> String {
        finish()
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stops and forgets what was heard.
    func cancel() {
        finish()
        transcript = ""
    }

    func clearError() {
        if case .failed = phase { phase = .idle }
    }

    private func finish() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        phase = .idle
    }

    private static func authorized() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}
