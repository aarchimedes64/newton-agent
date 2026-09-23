import AVFoundation
import Speech
import Observation
import NewtonCore

@MainActor @Observable final class SpeechTranscriber {
    var isRecording = false
    var isStarting = false
    var transcript = ""
    var error: String?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapInstalled = false
    private var generation = UUID()

    func start() async {
        guard !isRecording, !isStarting else { return }
        isStarting = true
        let run = UUID(); generation = run
        defer { isStarting = false }
        do {
            let speech = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
            guard generation == run else { return }
            guard speech == .authorized else { throw HarnessError("Allow Speech Recognition in iOS Settings to dictate.") }
            let microphone = await AVAudioApplication.requestRecordPermission()
            guard generation == run else { return }
            guard microphone else { throw HarnessError("Allow microphone access in iOS Settings to dictate.") }
            guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
                throw HarnessError("On-device dictation is unavailable for this device or language. Use the keyboard instead.")
            }
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true
            self.request = request; transcript = ""; error = nil
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw HarnessError("No microphone input is available.") }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            tapInstalled = true
            task = recognizer.recognitionTask(with: request) { [weak self] result, failure in
                Task { @MainActor in
                    guard let self, self.generation == run else { return }
                    if let result { self.transcript = result.bestTranscription.formattedString }
                    if let failure { self.error = failure.localizedDescription }
                    if result?.isFinal == true || failure != nil { self.stop() }
                }
            }
            engine.prepare(); try engine.start(); isRecording = true
        } catch { stop(); self.error = error.localizedDescription }
    }
    func stop() {
        generation = UUID()
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        request?.endAudio(); task?.cancel(); task = nil; request = nil; isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
