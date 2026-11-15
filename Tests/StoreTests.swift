import XCTest
import Combine
import UIKit
@testable import FenShen

final class StoreTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "FenShenTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    @MainActor func testMemoryFirstSaveAndReplacementSurviveReload() async throws {
        let directory = try temporaryDirectory()
        let store = MemoryStore(directory: directory)
        store.append(role: "user", content: "第一条", maxHistory: 40)
        XCTAssertEqual(MemoryStore(directory: directory).record.entries.map(\.content), ["第一条"])
        store.append(role: "assistant", content: "回复", maxHistory: 40)
        store.updateSummary("长期记忆")
        let reloaded = MemoryStore(directory: directory)
        XCTAssertEqual(reloaded.record.entries.map(\.content), ["第一条", "回复"])
        XCTAssertEqual(reloaded.record.summary, "长期记忆")
        XCTAssertGreaterThan(store.fileByteSize, 0)
    }

    @MainActor func testUsageFirstSaveAndReplacementSurviveReload() async throws {
        let directory = try temporaryDirectory()
        let store = UsageStore(directory: directory)
        store.append(promptTokens: 11, completionTokens: 7)
        XCTAssertEqual(UsageStore(directory: directory).stats.totalTokens, 18)
        store.append(promptTokens: 5, completionTokens: 3)
        let reloaded = UsageStore(directory: directory)
        XCTAssertEqual(reloaded.stats.totalTokens, 26)
        XCTAssertEqual(reloaded.stats.totalMessages, 2)
        XCTAssertEqual(reloaded.recentDays(1).first?.usage.total, 26)
        XCTAssertTrue(reloaded.recentDays(-1).isEmpty)
    }

    @MainActor func testRepeatedCorruptionPreservesEachBackup() async throws {
        let directory = try temporaryDirectory()
        let file = directory.appendingPathComponent("default.json")
        for text in ["broken-one", "broken-two"] {
            try Data(text.utf8).write(to: file)
            XCTAssertTrue(MemoryStore(directory: directory).record.entries.isEmpty)
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let backups = files.filter { $0.lastPathComponent.hasSuffix(".corrupt.json") }
        XCTAssertEqual(backups.count, 2)
        let contents = try Set(backups.map { try String(contentsOf: $0, encoding: .utf8) })
        XCTAssertEqual(contents, ["broken-one", "broken-two"])
    }

    @MainActor func testReverseDeletionRemovesDisplayedEntries() async throws {
        let store = MemoryStore(directory: try temporaryDirectory())
        for text in ["oldest", "middle", "newest"] {
            store.append(role: "user", content: text, maxHistory: 40)
        }
        store.removeEntriesInReverseOrder(at: IndexSet([0, 2]))
        XCTAssertEqual(store.record.entries.map(\.content), ["middle"])
    }

    @MainActor func testHistoryCompactionPreservesExistingBehavior() async throws {
        let store = MemoryStore(directory: try temporaryDirectory())
        for index in 0..<5 { store.append(role: "user", content: "\(index)", maxHistory: 4) }
        XCTAssertEqual(store.record.entries.map(\.content), ["3", "4"])
        XCTAssertEqual(store.record.summary, "user: 0\nuser: 1\nuser: 2")
        XCTAssertEqual(store.contextMessages(persona: "persona").count, 3)
        store.append(role: "user", content: "current", maxHistory: -10)
        XCTAssertEqual(store.record.entries.last?.content, "current")
        XCTAssertLessThanOrEqual(store.record.entries.count, 2)
    }

    @MainActor func testSettingsPublishAndKeepPersistedValuesIncludingZeroAndFalse() async {
        let defaults = isolatedDefaults()
        let store = SettingsStore(defaults: defaults)
        var changes = 0
        let subscription = store.objectWillChange.sink { changes += 1 }
        store.temperature = 0
        store.autoSearch = false
        store.apiKey = "test-only"
        store.maxHistory = 80
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.temperature, 0)
        XCTAssertFalse(reloaded.autoSearch)
        XCTAssertEqual(reloaded.apiKey, "test-only")
        XCTAssertEqual(reloaded.maxHistory, 80)
        XCTAssertEqual(changes, 4)
        withExtendedLifetime(subscription) {}
    }

    @MainActor func testBackgroundSameFilenameSaveInvalidatesImage() async throws {
        let store = ChatBackgroundStore(defaults: isolatedDefaults(), directory: try temporaryDirectory())
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        store.saveCroppedImage(image)
        let filename = store.customFile
        let revision = store.imageRevision
        store.saveCroppedImage(image)
        XCTAssertEqual(store.customFile, filename)
        XCTAssertEqual(store.imageRevision, revision + 1)
        XCTAssertEqual(store.style, .custom)
        store.clearCustomImage()
        XCTAssertEqual(store.style, .system)
        XCTAssertTrue(store.customFile.isEmpty)
        XCTAssertEqual(store.imageRevision, revision + 2)
    }

    @MainActor func testAppStateForwardsNestedStoreChanges() async {
        let app = AppState()
        var changes = 0
        let subscription = app.objectWillChange.sink { changes += 1 }
        app.settings.objectWillChange.send()
        app.memory.objectWillChange.send()
        app.persona.objectWillChange.send()
        app.usage.objectWillChange.send()
        app.chatBackground.objectWillChange.send()
        XCTAssertEqual(changes, 5)
        withExtendedLifetime(subscription) {}
    }
}
