//
//  SpeechRecognizer.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 8.02.2026.
//

import AppKit
import Foundation
import Speech
import AVFoundation
import CoreAudio

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String

    static func allInputDevices() -> [AudioInputDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize) == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs) == noErr else { return [] }

        var result: [AudioInputDevice] = []
        for deviceID in deviceIDs {
            // Check if device has input streams
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &streamSize) == noErr, streamSize > 0 else { continue }

            // Get UID
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uid: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            guard AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid) == noErr else { continue }

            // Get name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            guard AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name) == noErr else { continue }

            result.append(AudioInputDevice(id: deviceID, uid: uid as String, name: name as String))
        }
        return result
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allInputDevices().first(where: { $0.uid == uid })?.id
    }
}

@Observable
class SpeechRecognizer {
    var recognizedCharCount: Int = 0
    var isListening: Bool = false
    var error: String?
    var audioLevels: [CGFloat] = Array(repeating: 0, count: 30)
    var lastSpokenText: String = ""
    var shouldDismiss: Bool = false
    var shouldAdvancePage: Bool = false

    /// True when recent audio levels indicate the user is actively speaking
    var isSpeaking: Bool {
        let recent = audioLevels.suffix(10)
        guard !recent.isEmpty else { return false }
        let avg = recent.reduce(0, +) / CGFloat(recent.count)
        return avg > 0.08
    }

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine = AVAudioEngine()
    private var sourceText: String = ""
    private var normalizedSource: String = ""
    private var matchStartOffset: Int = 0  // char offset to start matching from
    private var retryCount: Int = 0
    private let maxRetries: Int = 10
    private var configurationChangeObserver: Any?
    private var pendingRestart: DispatchWorkItem?
    private var sessionGeneration: Int = 0
    private var suppressConfigChange: Bool = false
    private var recognitionWatchdog: Timer?
    private var lastResultAt: Date = .distantPast
    private var lastProgressAt: Date = .distantPast
    private var lastWatchdogRestartAt: Date = .distantPast

    /// Update the source text while preserving the current recognized char count.
    /// Used by Director Mode to live-edit unread text without resetting read progress.
    func updateText(_ text: String, preservingCharCount: Int) {
        let words = splitTextIntoWords(text)
        let collapsed = words.joined(separator: " ")
        sourceText = collapsed
        normalizedSource = Self.normalize(collapsed)
        recognizedCharCount = min(preservingCharCount, collapsed.count)
        matchStartOffset = recognizedCharCount
    }

    /// Jump highlight to a specific char offset (e.g. when user taps a word)
    func jumpTo(charOffset: Int) {
        recognizedCharCount = charOffset
        matchStartOffset = charOffset
        retryCount = 0
        if isListening {
            restartRecognition()
        }
    }

    func start(with text: String) {
        // Clean up any previous session immediately so pending restarts
        // and stale taps are removed before the async auth callback fires.
        cleanupRecognition()

        let words = splitTextIntoWords(text)
        let collapsed = words.joined(separator: " ")
        sourceText = collapsed
        normalizedSource = Self.normalize(collapsed)
        recognizedCharCount = 0
        matchStartOffset = 0
        retryCount = 0
        lastResultAt = Date()
        lastProgressAt = Date()
        lastWatchdogRestartAt = .distantPast
        error = nil
        sessionGeneration += 1

        // Check microphone permission first
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            error = "Microphone access denied. Open System Settings → Privacy & Security → Microphone to allow Textream."
            openMicrophoneSettings()
            return
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.requestSpeechAuthAndBegin()
                    } else {
                        self?.error = "Microphone access denied. Open System Settings → Privacy & Security → Microphone to allow Textream."
                    }
                }
            }
            return
        case .authorized:
            break
        @unknown default:
            break
        }

        requestSpeechAuthAndBegin()
    }

    private func requestSpeechAuthAndBegin() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                switch status {
                case .authorized:
                    self?.beginRecognition()
                default:
                    self?.error = "Speech recognition not authorized. Open System Settings → Privacy & Security → Speech Recognition to allow Textream."
                    self?.openSpeechRecognitionSettings()
                }
            }
        }
    }

    private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openSpeechRecognitionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") {
            NSWorkspace.shared.open(url)
        }
    }

    func stop() {
        isListening = false
        cleanupRecognition()
    }

    func forceStop() {
        isListening = false
        sourceText = ""
        retryCount = maxRetries
        cleanupRecognition()
    }

    func resume() {
        retryCount = 0
        matchStartOffset = recognizedCharCount
        shouldDismiss = false
        beginRecognition()
    }

    private func cleanupRecognition() {
        // Cancel any pending restart to prevent overlapping beginRecognition calls
        pendingRestart?.cancel()
        pendingRestart = nil
        recognitionWatchdog?.invalidate()
        recognitionWatchdog = nil

        if let observer = configurationChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationChangeObserver = nil
        }
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    /// Coalesces all delayed beginRecognition() calls into a single pending work item.
    /// Any previously scheduled restart is cancelled before the new one is queued.
    private func scheduleBeginRecognition(after delay: TimeInterval) {
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRestart = nil
            self.beginRecognition()
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func beginRecognition() {
        // Ensure clean state
        cleanupRecognition()

        // Create a fresh engine so it picks up the current hardware format.
        // AVAudioEngine caches the device format internally and reset() alone
        // does not reliably flush it after a mic switch.
        audioEngine = AVAudioEngine()

        // Set selected microphone if configured
        let micUID = NotchSettings.shared.selectedMicUID
        if !micUID.isEmpty, let deviceID = AudioInputDevice.deviceID(forUID: micUID) {
            // Suppress config-change observer during our own device switch
            suppressConfigChange = true
            let inputUnit = audioEngine.inputNode.audioUnit
            if let audioUnit = inputUnit {
                var devID = deviceID
                AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &devID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                // Re-initialize audio unit so it picks up the new device's format
                AudioUnitUninitialize(audioUnit)
                AudioUnitInitialize(audioUnit)
            }
            // Allow config changes again after a settle period
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.suppressConfigChange = false
            }
        }

        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: NotchSettings.shared.speechLocale))
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            error = "Speech recognizer not available"
            return
        }

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest else { return }
        recognitionRequest.shouldReportPartialResults = true

        let inputNode = audioEngine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        // Guard against invalid format during device transitions (e.g. mic switch)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            // Retry after a longer delay to let the audio system settle
            if retryCount < maxRetries {
                retryCount += 1
                scheduleBeginRecognition(after: 0.5)
            } else {
                error = "Audio input unavailable"
                isListening = false
            }
            return
        }

        // SFSpeechRecognizer requires mono audio. Multi-channel devices (e.g.
        // RODECaster Pro II at 2ch/48kHz) cause the recognition task to silently
        // return no results. Request a mono tap and let AVAudioEngine downmix.
        let monoFormat = AVAudioFormat(
            commonFormat: hardwareFormat.commonFormat,
            sampleRate: hardwareFormat.sampleRate,
            channels: 1,
            interleaved: hardwareFormat.isInterleaved
        )
        let tapFormat = (hardwareFormat.channelCount > 1) ? monoFormat : hardwareFormat

        // Observe audio configuration changes (e.g. mic switched externally) to restart gracefully
        configurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.suppressConfigChange, !self.sourceText.isEmpty else { return }
            self.restartRecognition()
        }

        // Belt-and-suspenders: ensure no stale tap exists before installing
        inputNode.removeTap(onBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] buffer, _ in
            recognitionRequest.append(buffer)

            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frameLength {
                sum += channelData[i] * channelData[i]
            }
            let rms = sqrt(sum / Float(max(frameLength, 1)))
            let level = CGFloat(min(rms * 5, 1.0))

            DispatchQueue.main.async {
                self?.audioLevels.append(level)
                if (self?.audioLevels.count ?? 0) > 30 {
                    self?.audioLevels.removeFirst()
                }
            }
        }

        let currentGeneration = sessionGeneration
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let spoken = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    // Ignore stale results from a previous session
                    guard self.sessionGeneration == currentGeneration else { return }
                    self.retryCount = 0 // Reset on success
                    if spoken != self.lastSpokenText {
                        self.lastResultAt = Date()
                    }
                    self.lastSpokenText = spoken
                    self.matchCharacters(spoken: spoken)
                }
            }
            if error != nil {
                DispatchQueue.main.async {
                    // If recognitionRequest is nil, cleanup already ran (intentional cancel) — don't retry
                    guard self.recognitionRequest != nil else { return }
                    if self.isListening && !self.shouldDismiss && !self.sourceText.isEmpty && self.retryCount < self.maxRetries {
                        self.retryCount += 1
                        self.matchStartOffset = min(self.recognizedCharCount, self.sourceText.count)
                        self.sessionGeneration += 1
                        let delay = min(Double(self.retryCount) * 0.5, 1.5)
                        self.scheduleBeginRecognition(after: delay)
                    } else {
                        self.isListening = false
                    }
                }
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isListening = true
            lastResultAt = Date()
            lastProgressAt = Date()
            startRecognitionWatchdog()
        } catch {
            // Transient failure after a device switch — retry with longer delay
            if retryCount < maxRetries {
                retryCount += 1
                scheduleBeginRecognition(after: 0.5)
            } else {
                self.error = "Audio engine failed: \(error.localizedDescription)"
                isListening = false
            }
        }
    }

    private func restartRecognition() {
        // Reset retries so the fresh engine gets a full set of attempts
        retryCount = 0
        matchStartOffset = min(recognizedCharCount, sourceText.count)
        sessionGeneration += 1
        isListening = true
        // Longer delay to let the audio system fully settle after a device change
        cleanupRecognition()
        scheduleBeginRecognition(after: 0.5)
    }

    private func startRecognitionWatchdog() {
        recognitionWatchdog?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.checkRecognitionHealth()
            }
        }
        recognitionWatchdog = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func checkRecognitionHealth() {
        guard isListening,
              recognitionRequest != nil,
              !sourceText.isEmpty,
              !shouldDismiss else { return }

        let now = Date()
        guard now.timeIntervalSince(lastWatchdogRestartAt) > Self.watchdogRestartCooldown else {
            return
        }

        if isSpeaking && now.timeIntervalSince(lastResultAt) > Self.recognitionResultStallInterval {
            lastWatchdogRestartAt = now
            restartRecognition()
        }
    }

    // MARK: - Script matching

    private func matchCharacters(spoken: String) {
        let newCount = strictWordLevelAdvance(spoken: spoken)
        if newCount > recognizedCharCount {
            recognizedCharCount = min(newCount, sourceText.count)
            lastProgressAt = Date()
        }
    }

    private static func isAnnotationWord(_ word: String) -> Bool {
        if word.hasPrefix("[") && word.hasSuffix("]") { return true }
        let stripped = word.filter { $0.isLetter || $0.isNumber }
        return stripped.isEmpty
    }

    private struct SourceToken {
        let value: String
        let advanceOffset: Int
    }

    private struct PrefixMatch {
        let sourceIndex: Int
        let spokenIndex: Int
        let matchedCount: Int
        let advanceOffset: Int
        let lastMatchedToken: SourceToken?
    }

    private struct ResyncAnchor {
        let advanceOffset: Int
    }

    private struct ResyncCandidate {
        let sourceIndex: Int
        let sourceTokens: [SourceToken]
        let advanceOffset: Int
    }

    private static let fillerTokens: Set<String> = [
        "euh", "heu", "hum", "hmm", "mm", "ben", "bah"
    ]

    private static let localResyncBands = [8, 20, 32]
    private static let maxDistantResyncLookahead = 180
    private static let minDistantResyncTailTokens = 7
    private static let maxResyncTailTokens = 10
    private static let recognitionResultStallInterval: TimeInterval = 5
    private static let watchdogRestartCooldown: TimeInterval = 6

    private func strictWordLevelAdvance(spoken: String) -> Int {
        let allSourceTokens = Self.sourceTokens(in: sourceText)
        let spokenTokens = Self.tokenValues(in: spoken)
            .filter { !Self.fillerTokens.contains($0) }

        guard !allSourceTokens.isEmpty else {
            return sourceText.count
        }
        guard !spokenTokens.isEmpty else { return recognizedCharCount }

        let sessionAdvance = Self.matchAdvance(
            sourceTokens: allSourceTokens,
            sourceStartOffset: matchStartOffset,
            spokenTokens: spokenTokens,
            allowPrefixMatch: true,
            allowResync: false
        )

        let recoveryAdvance = Self.matchAdvance(
            sourceTokens: allSourceTokens,
            sourceStartOffset: recognizedCharCount,
            spokenTokens: spokenTokens,
            allowPrefixMatch: false,
            allowResync: true
        )

        return max(recognizedCharCount, sessionAdvance, recoveryAdvance)
    }

    private static func matchAdvance(
        sourceTokens allSourceTokens: [SourceToken],
        sourceStartOffset: Int,
        spokenTokens: [String],
        allowPrefixMatch: Bool,
        allowResync: Bool
    ) -> Int {
        let sourceTokens = allSourceTokens.filter { $0.advanceOffset > sourceStartOffset }

        guard !sourceTokens.isEmpty else {
            return sourceStartOffset
        }

        let prefix = allowPrefixMatch
            ? prefixMatch(sourceTokens: sourceTokens, spokenTokens: spokenTokens)
            : PrefixMatch(
                sourceIndex: 0,
                spokenIndex: 0,
                matchedCount: 0,
                advanceOffset: sourceStartOffset,
                lastMatchedToken: nil
            )

        var bestAdvanceOffset = sourceStartOffset

        if let lastMatchedToken = prefix.lastMatchedToken,
           Self.shouldCommitMatch(
               matchedCount: prefix.matchedCount,
               lastMatchedToken: lastMatchedToken,
               reachedEnd: prefix.sourceIndex >= sourceTokens.count
           ) {
            bestAdvanceOffset = max(bestAdvanceOffset, prefix.advanceOffset)
        }

        if allowResync,
           prefix.sourceIndex < sourceTokens.count,
           prefix.spokenIndex < spokenTokens.count,
           let anchor = Self.findResyncAnchor(
               sourceTokens: sourceTokens,
               sourceStartIndex: prefix.sourceIndex,
               spokenTokens: spokenTokens,
               spokenStartIndex: prefix.spokenIndex
           ) {
            bestAdvanceOffset = max(bestAdvanceOffset, anchor.advanceOffset)
        }

        return bestAdvanceOffset
    }

    private static func prefixMatch(sourceTokens: [SourceToken], spokenTokens: [String]) -> PrefixMatch {
        var sourceIndex = 0
        var spokenIndex = 0
        var matchedTokenCount = 0
        var lastAdvanceOffset = 0
        var lastMatchedToken: SourceToken?

        while sourceIndex < sourceTokens.count && spokenIndex < spokenTokens.count {
            let sourceToken = sourceTokens[sourceIndex]
            let spokenToken = spokenTokens[spokenIndex]

            if Self.isStrictMatch(sourceToken.value, spokenToken) {
                matchedTokenCount += 1
                lastAdvanceOffset = sourceToken.advanceOffset
                lastMatchedToken = sourceToken
                sourceIndex += 1
                spokenIndex += 1
            } else {
                break
            }
        }

        return PrefixMatch(
            sourceIndex: sourceIndex,
            spokenIndex: spokenIndex,
            matchedCount: matchedTokenCount,
            advanceOffset: lastAdvanceOffset,
            lastMatchedToken: lastMatchedToken
        )
    }

    private static func shouldCommitMatch(
        matchedCount: Int,
        lastMatchedToken: SourceToken,
        reachedEnd: Bool
    ) -> Bool {
        let distinctiveSingleWord = lastMatchedToken.value.count >= 5

        // Avoid committing progress on a single short French word such as
        // "je", "de", "le", or "un"; these are too common and cause false starts
        // when the speaker goes off-script.
        guard matchedCount >= 2 || distinctiveSingleWord || reachedEnd else {
            return false
        }

        return true
    }

    private static func findResyncAnchor(
        sourceTokens: [SourceToken],
        sourceStartIndex: Int,
        spokenTokens: [String],
        spokenStartIndex: Int
    ) -> ResyncAnchor? {
        let availableSpokenTokens = spokenTokens.count - spokenStartIndex
        guard availableSpokenTokens >= 2 else { return nil }

        let maxTailLength = min(maxResyncTailTokens, availableSpokenTokens)

        for bandSize in localResyncBands {
            let bandEnd = min(sourceTokens.count, sourceStartIndex + bandSize)
            guard sourceStartIndex < bandEnd else { continue }

            for tailLength in stride(from: maxTailLength, through: 2, by: -1) {
                let tailStart = spokenTokens.count - tailLength
                guard tailStart >= spokenStartIndex else { continue }

                let spokenTail = Array(spokenTokens[tailStart..<spokenTokens.count])
                let candidates = resyncCandidates(
                    sourceTokens: sourceTokens,
                    sourceRange: sourceStartIndex..<bandEnd,
                    spokenTail: spokenTail
                )

                if let candidate = candidates.first(where: {
                    isStrongLocalResyncAnchor(
                        sourceTokens: $0.sourceTokens,
                        spokenTokens: spokenTail,
                        skippedTokens: $0.sourceIndex - sourceStartIndex
                    )
                }) {
                    return ResyncAnchor(advanceOffset: candidate.advanceOffset)
                }
            }
        }

        for tailLength in stride(from: maxTailLength, through: minDistantResyncTailTokens, by: -1) {
            let tailStart = spokenTokens.count - tailLength
            guard tailStart >= spokenStartIndex else { continue }

            let spokenTail = Array(spokenTokens[tailStart..<spokenTokens.count])
            let distantEnd = min(sourceTokens.count, sourceStartIndex + maxDistantResyncLookahead)
            let candidates = resyncCandidates(
                sourceTokens: sourceTokens,
                sourceRange: sourceStartIndex..<distantEnd,
                spokenTail: spokenTail
            ).filter {
                isVeryStrongDistantResyncAnchor(sourceTokens: $0.sourceTokens, spokenTokens: spokenTail)
            }

            if candidates.count == 1, let candidate = candidates.first {
                return ResyncAnchor(advanceOffset: candidate.advanceOffset)
            }
        }

        return nil
    }

    private static func resyncCandidates(
        sourceTokens: [SourceToken],
        sourceRange: Range<Int>,
        spokenTail: [String]
    ) -> [ResyncCandidate] {
        guard !spokenTail.isEmpty, sourceRange.lowerBound < sourceRange.upperBound else {
            return []
        }

        var candidates: [ResyncCandidate] = []
        let searchEnd = min(sourceRange.upperBound, sourceTokens.count)
        guard sourceRange.lowerBound < searchEnd else { return [] }

        for sourceIndex in sourceRange.lowerBound..<searchEnd {
            let sourceEndIndex = sourceIndex + spokenTail.count
            guard sourceEndIndex <= sourceTokens.count else { continue }

            let sourceSlice = Array(sourceTokens[sourceIndex..<sourceEndIndex])
            guard zip(sourceSlice, spokenTail).allSatisfy({ sourceToken, spokenToken in
                isStrictMatch(sourceToken.value, spokenToken)
            }) else {
                continue
            }

            candidates.append(ResyncCandidate(
                sourceIndex: sourceIndex,
                sourceTokens: sourceSlice,
                advanceOffset: sourceSlice[sourceSlice.count - 1].advanceOffset
            ))
        }

        return candidates
    }

    private static func isStrongLocalResyncAnchor(
        sourceTokens: [SourceToken],
        spokenTokens: [String],
        skippedTokens: Int
    ) -> Bool {
        let stats = resyncStats(sourceTokens: sourceTokens, spokenTokens: spokenTokens)

        if skippedTokens <= 8 {
            return isStrongResyncAnchor(sourceTokens: sourceTokens, spokenTokens: spokenTokens)
        }

        if skippedTokens <= 20 {
            return stats.matchCount >= 4 && stats.exactCount >= 2 && stats.distinctiveCount >= 1
        }

        return stats.matchCount >= 5 && stats.exactCount >= 3 && stats.distinctiveCount >= 2
    }

    private static func isVeryStrongDistantResyncAnchor(
        sourceTokens: [SourceToken],
        spokenTokens: [String]
    ) -> Bool {
        let stats = resyncStats(sourceTokens: sourceTokens, spokenTokens: spokenTokens)
        return stats.matchCount >= minDistantResyncTailTokens
            && stats.exactCount >= 5
            && stats.distinctiveCount >= 3
    }

    private static func isStrongResyncAnchor(sourceTokens: [SourceToken], spokenTokens: [String]) -> Bool {
        let stats = resyncStats(sourceTokens: sourceTokens, spokenTokens: spokenTokens)

        if stats.matchCount >= 4 {
            return stats.exactCount >= 2 || stats.distinctiveCount >= 1
        }

        if stats.matchCount == 3 {
            let allUsefulWords = sourceTokens.allSatisfy { $0.value.count >= 3 }
            return stats.exactCount >= 2 && (stats.distinctiveCount >= 1 || allUsefulWords)
        }

        if stats.matchCount == 2 {
            return stats.distinctiveCount == 2 && stats.exactCount >= 1
        }

        return false
    }

    private static func resyncStats(
        sourceTokens: [SourceToken],
        spokenTokens: [String]
    ) -> (matchCount: Int, exactCount: Int, distinctiveCount: Int) {
        let exactCount = zip(sourceTokens, spokenTokens).filter { sourceToken, spokenToken in
            sourceToken.value == spokenToken
        }.count
        let distinctiveCount = sourceTokens.filter { $0.value.count >= 5 }.count
        return (sourceTokens.count, exactCount, distinctiveCount)
    }

    private static func isStrictMatch(_ source: String, _ spoken: String) -> Bool {
        if source.isEmpty || spoken.isEmpty { return false }
        if source == spoken { return true }

        let shorter = min(source.count, spoken.count)
        let longer = max(source.count, spoken.count)
        guard shorter >= 4 else { return false }

        let sourceChars = Array(source)
        let spokenChars = Array(spoken)
        guard sourceChars.first == spokenChars.first else { return false }

        let distance = editDistance(source, spoken)
        if shorter <= 7 {
            return longer - shorter <= 1 && distance <= 1
        }

        guard sourceChars.dropFirst().first == spokenChars.dropFirst().first else {
            return false
        }
        return longer - shorter <= 2 && distance <= 2
    }

    private static func sourceTokens(in text: String) -> [SourceToken] {
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var tokens: [SourceToken] = []
        var wordOffset = 0

        for word in words {
            defer { wordOffset += word.count + 1 }
            guard !isAnnotationWord(word) else { continue }

            let ranges = tokenRanges(in: word)
            for (index, range) in ranges.enumerated() {
                let isLastTokenInWord = index == ranges.count - 1
                let wordEnd = wordOffset + word.count
                let advanceOffset = isLastTokenInWord
                    ? min(wordEnd + 1, text.count)
                    : wordOffset + range.end

                tokens.append(SourceToken(
                    value: range.value,
                    advanceOffset: advanceOffset
                ))
            }
        }

        return tokens
    }

    private static func tokenValues(in text: String) -> [String] {
        tokenRanges(in: text).map(\.value)
    }

    private static func tokenRanges(in text: String) -> [(value: String, start: Int, end: Int)] {
        var ranges: [(value: String, start: Int, end: Int)] = []
        var buffer = ""
        var tokenStart: Int?
        var charOffset = 0

        func flush(at end: Int) {
            guard let start = tokenStart, !buffer.isEmpty else { return }
            ranges.append((value: buffer, start: start, end: end))
            buffer = ""
            tokenStart = nil
        }

        for character in text {
            let normalized = normalizeToken(String(character))
            if normalized.isEmpty {
                flush(at: charOffset)
            } else {
                if tokenStart == nil {
                    tokenStart = charOffset
                }
                buffer += normalized
            }
            charOffset += 1
        }

        flush(at: charOffset)
        return ranges
    }

    private static func normalizeToken(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: NotchSettings.shared.speechLocale))
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var dp = Array(0...b.count)
        for i in 1...a.count {
            var prev = dp[0]
            dp[0] = i
            for j in 1...b.count {
                let temp = dp[j]
                dp[j] = a[i-1] == b[j-1] ? prev : min(prev, dp[j], dp[j-1]) + 1
                prev = temp
            }
        }
        return dp[b.count]
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
    }
}
