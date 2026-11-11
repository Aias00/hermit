import AVFoundation
import Foundation
import Speech
import UIKit

/// One prepared item, with ownership transferred to the caller on take.
final class SingleSlotWarmCache<Key: Hashable, Item>: @unchecked Sendable {
    private struct Entry {
        let key: Key
        let task: Task<Item, Error>
        let createdAt: Date
        let generation: UInt64
        let expiryTask: Task<Void, Never>
    }

    private let lock = NSLock()
    private let ttl: TimeInterval
    private let now: () -> Date
    private let sleep: (TimeInterval) async throws -> Void
    private let isAllowed: () async -> Bool
    private let discard: (Item) async -> Void
    private var entry: Entry?
    private var generation: UInt64 = 0

    init(ttl: TimeInterval = 60, now: @escaping () -> Date = Date.init,
         sleep: @escaping (TimeInterval) async throws -> Void = {
             try await Task.sleep(for: .seconds($0))
         },
         isAllowed: @escaping () async -> Bool = { true },
         discard: @escaping (Item) async -> Void) {
        self.ttl = ttl
        self.now = now
        self.sleep = sleep
        self.isAllowed = isAllowed
        self.discard = discard
    }

    func warm(key: Key, make: @escaping () async throws -> Item) async {
        let generation = lock.withLock { self.generation }
        guard await isAllowed(), !Task.isCancelled else { return }
        let previous: Entry? = lock.withLock {
            // A drain or take during the policy check must win.
            guard generation == self.generation else { return nil }
            let date = now()
            if let entry, entry.key == key, date.timeIntervalSince(entry.createdAt) < ttl {
                return nil
            }
            let previous = entry
            self.generation &+= 1
            let entryGeneration = self.generation
            entry = Entry(key: key, task: Task {
                try Task.checkCancellation()
                return try await make()
            }, createdAt: date, generation: entryGeneration, expiryTask: Task { [weak self, sleep, ttl] in
                do {
                    try await sleep(ttl)
                } catch {
                    return
                }
                self?.expire(generation: entryGeneration)
            })
            return previous
        }
        dispose(previous)
    }

    func take(key: Key) -> Task<Item, Error>? {
        let previous: Entry? = lock.withLock {
            generation &+= 1
            defer { entry = nil }
            return entry
        }
        guard let previous else { return nil }
        previous.expiryTask.cancel()
        guard previous.key == key, now().timeIntervalSince(previous.createdAt) < ttl else {
            dispose(previous)
            return nil
        }
        return previous.task
    }

    func drain() {
        let previous: Entry? = lock.withLock {
            generation &+= 1
            defer { entry = nil }
            return entry
        }
        dispose(previous)
    }

    private func expire(generation: UInt64) {
        let previous: Entry? = lock.withLock {
            guard let entry, entry.generation == generation else { return nil }
            self.generation &+= 1
            self.entry = nil
            return entry
        }
        dispose(previous)
    }

    private func dispose(_ entry: Entry?) {
        guard let entry else { return }
        entry.expiryTask.cancel()
        entry.task.cancel()
        let discard = discard
        Task {
            // A maker that ignores cancellation may still return an item.
            if case .success(let item) = await entry.task.result { await discard(item) }
        }
    }
}

/// Prepares a fresh analyzer without opening an audio session or microphone.
@available(iOS 26.0, *)
final class SpeechAnalyzerWarmup {
    struct Key: Hashable {
        enum Kind: Hashable { case advanced, dictation }

        let kind: Kind
        let localeIdentifier: String
        let contextualStrings: [String]

        init?(module: ModernDictationEngine.Module, contextualStrings: [String]) {
            let locale: Locale?
            switch module {
            case .advanced(let transcriber):
                kind = .advanced
                locale = transcriber.selectedLocales.first
                self.contextualStrings = []
            case .dictation(let transcriber):
                kind = .dictation
                locale = transcriber.selectedLocales.first
                self.contextualStrings = VoiceVocabulary.normalized(contextualStrings)
            }
            guard let locale else { return nil }
            localeIdentifier = locale.identifier(.bcp47)
        }
    }

    struct Item {
        let module: ModernDictationEngine.Module
        let analyzer: SpeechAnalyzer
        let format: AVAudioFormat?
    }

    static let shared = SpeechAnalyzerWarmup()

    private let cache = SingleSlotWarmCache<Key, Item>(isAllowed: {
        await MainActor.run {
            let process = ProcessInfo.processInfo
            return UIApplication.shared.applicationState == .active
                && !process.isLowPowerModeEnabled
                && process.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue
        }
    }, discard: { item in
        await item.analyzer.cancelAndFinishNow()
    })
    private var observers: [NSObjectProtocol] = []

    private init() {
        let names: [Notification.Name] = [
            UIApplication.didReceiveMemoryWarningNotification,
            UIApplication.didEnterBackgroundNotification,
            .NSProcessInfoPowerStateDidChange,
            ProcessInfo.thermalStateDidChangeNotification,
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                let process = ProcessInfo.processInfo
                if note.name == .NSProcessInfoPowerStateDidChange, !process.isLowPowerModeEnabled { return }
                if note.name == ProcessInfo.thermalStateDidChangeNotification,
                   process.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue { return }
                self?.cache.drain()
            }
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        cache.drain()
    }

    func take(key: Key) -> Task<Item, Error>? { cache.take(key: key) }

    func warm(key: Key) async {
        await cache.warm(key: key) {
            let locale = Locale(identifier: key.localeIdentifier)
            let module: ModernDictationEngine.Module
            switch key.kind {
            case .advanced:
                module = .advanced(SpeechTranscriber(
                    locale: locale, transcriptionOptions: [],
                    reportingOptions: [.volatileResults], attributeOptions: []))
            case .dictation:
                module = .dictation(DictationTranscriber(locale: locale, preset: .progressiveLongDictation))
            }
            let analyzer = SpeechAnalyzer(modules: [module.speechModule])
            do {
                let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module.speechModule])
                try Task.checkCancellation()
                if key.kind == .dictation, !key.contextualStrings.isEmpty {
                    let context = AnalysisContext()
                    context.contextualStrings[.general] = key.contextualStrings
                    try await analyzer.setContext(context)
                }
                try await analyzer.prepareToAnalyze(in: format)
                try Task.checkCancellation()
                return Item(module: module, analyzer: analyzer, format: format)
            } catch {
                await analyzer.cancelAndFinishNow()
                throw error
            }
        }
    }
}
