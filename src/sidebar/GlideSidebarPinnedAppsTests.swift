import XCTest

final class GlideSidebarPinnedAppsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: GlideSidebarPinnedAppsStore!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "GlideSidebarPinnedAppsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        store = GlideSidebarPinnedAppsStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testPinPersistsInsertionOrder() {
        XCTAssertTrue(store.pin(bundleIdentifier: "com.example.one", displayName: "One",
            bundlePath: "/Applications/One.app"))
        XCTAssertTrue(store.pin(bundleIdentifier: "com.example.two", displayName: "Two",
            bundlePath: nil))

        XCTAssertEqual(store.applications(), [
            GlideSidebarPinnedApp(bundleIdentifier: "com.example.one", displayName: "One",
                bundlePath: "/Applications/One.app"),
            GlideSidebarPinnedApp(bundleIdentifier: "com.example.two", displayName: "Two",
                bundlePath: nil),
        ])
    }

    func testPinUpdatesMetadataWithoutMovingTheApp() {
        store.pin(bundleIdentifier: "com.example.one", displayName: "Old", bundlePath: nil)
        store.pin(bundleIdentifier: "com.example.two", displayName: "Two", bundlePath: nil)

        XCTAssertTrue(store.pin(bundleIdentifier: "com.example.one", displayName: "New",
            bundlePath: "/Applications/One.app"))
        XCTAssertEqual(store.applications().map(\.bundleIdentifier), ["com.example.one", "com.example.two"])
        XCTAssertEqual(store.applications().first?.displayName, "New")
        XCTAssertEqual(store.applications().first?.bundlePath, "/Applications/One.app")
    }

    func testDuplicatePinWithIdenticalMetadataDoesNotRewrite() {
        XCTAssertTrue(store.pin(bundleIdentifier: "com.example.one", displayName: "One", bundlePath: nil))
        XCTAssertFalse(store.pin(bundleIdentifier: "com.example.one", displayName: "One", bundlePath: nil))
    }

    func testUnpinRemovesOnlyTheRequestedApp() {
        store.pin(bundleIdentifier: "com.example.one", displayName: "One", bundlePath: nil)
        store.pin(bundleIdentifier: "com.example.two", displayName: "Two", bundlePath: nil)

        XCTAssertTrue(store.unpin(bundleIdentifier: "com.example.one"))
        XCTAssertFalse(store.unpin(bundleIdentifier: "com.example.missing"))
        XCTAssertEqual(store.applications().map(\.bundleIdentifier), ["com.example.two"])
    }

    func testMalformedPreferenceFallsBackToAnEmptyList() {
        defaults.set("not-json", forKey: GlideSidebarPinnedAppsStore.preferenceKey)

        XCTAssertEqual(store.applications(), [])
    }

    func testLoadDropsInvalidAndDuplicateEntries() throws {
        let encoded = try JSONEncoder().encode([
            GlideSidebarPinnedApp(bundleIdentifier: "", displayName: "Invalid", bundlePath: nil),
            GlideSidebarPinnedApp(bundleIdentifier: "com.example.one", displayName: "", bundlePath: ""),
            GlideSidebarPinnedApp(bundleIdentifier: "com.example.one", displayName: "Duplicate", bundlePath: nil),
        ])
        defaults.set(String(data: encoded, encoding: .utf8),
            forKey: GlideSidebarPinnedAppsStore.preferenceKey)

        XCTAssertEqual(store.applications(), [
            GlideSidebarPinnedApp(bundleIdentifier: "com.example.one", displayName: "com.example.one",
                bundlePath: nil),
        ])
    }

    func testMoveEarlierPersistsOrderAndMetadata() {
        store.pin(bundleIdentifier: "com.example.one", displayName: "One", bundlePath: nil)
        store.pin(bundleIdentifier: "com.example.two", displayName: "Two", bundlePath: nil)
        store.pin(bundleIdentifier: "com.example.three", displayName: "Three",
            bundlePath: "/Applications/Three.app")

        XCTAssertTrue(store.move(bundleIdentifier: "com.example.three", to: 0))
        store = GlideSidebarPinnedAppsStore(defaults: defaults)

        XCTAssertEqual(store.applications(), [
            GlideSidebarPinnedApp(bundleIdentifier: "com.example.three", displayName: "Three",
                bundlePath: "/Applications/Three.app"),
            GlideSidebarPinnedApp(bundleIdentifier: "com.example.one", displayName: "One",
                bundlePath: nil),
            GlideSidebarPinnedApp(bundleIdentifier: "com.example.two", displayName: "Two",
                bundlePath: nil),
        ])
    }

    func testMoveLaterUsesTheFinalIndex() {
        store.pin(bundleIdentifier: "com.example.one", displayName: "One", bundlePath: nil)
        store.pin(bundleIdentifier: "com.example.two", displayName: "Two", bundlePath: nil)
        store.pin(bundleIdentifier: "com.example.three", displayName: "Three", bundlePath: nil)

        XCTAssertTrue(store.move(bundleIdentifier: "com.example.one", to: 2))

        XCTAssertEqual(store.applications().map(\.bundleIdentifier), [
            "com.example.two", "com.example.three", "com.example.one",
        ])
    }

    func testMoveRejectsMissingInvalidAndUnchangedDestinationsWithoutRewriting() {
        store.pin(bundleIdentifier: "com.example.one", displayName: "One", bundlePath: nil)
        store.pin(bundleIdentifier: "com.example.two", displayName: "Two", bundlePath: nil)
        let originalJSON = defaults.string(forKey: GlideSidebarPinnedAppsStore.preferenceKey)

        XCTAssertFalse(store.move(bundleIdentifier: "com.example.missing", to: 0))
        XCTAssertFalse(store.move(bundleIdentifier: "com.example.one", to: -1))
        XCTAssertFalse(store.move(bundleIdentifier: "com.example.one", to: 2))
        XCTAssertFalse(store.move(bundleIdentifier: "com.example.one", to: 0))
        XCTAssertEqual(defaults.string(forKey: GlideSidebarPinnedAppsStore.preferenceKey), originalJSON)
    }

    func testReorderConvertsOriginalInsertionSlotsToFinalIndexes() {
        XCTAssertEqual(GlideSidebarPinnedReorder.finalIndex(
            itemCount: 4, sourceIndex: 0, insertionIndex: 4), 3)
        XCTAssertEqual(GlideSidebarPinnedReorder.finalIndex(
            itemCount: 4, sourceIndex: 3, insertionIndex: 0), 0)
        XCTAssertEqual(GlideSidebarPinnedReorder.finalIndex(
            itemCount: 4, sourceIndex: 1, insertionIndex: 2), 1)
        XCTAssertEqual(GlideSidebarPinnedReorder.finalIndex(
            itemCount: 4, sourceIndex: 1, insertionIndex: 3), 2)
    }

    func testReorderRejectsInvalidIndexes() {
        XCTAssertNil(GlideSidebarPinnedReorder.finalIndex(
            itemCount: 0, sourceIndex: 0, insertionIndex: 0))
        XCTAssertNil(GlideSidebarPinnedReorder.finalIndex(
            itemCount: 3, sourceIndex: -1, insertionIndex: 0))
        XCTAssertNil(GlideSidebarPinnedReorder.finalIndex(
            itemCount: 3, sourceIndex: 3, insertionIndex: 0))
        XCTAssertNil(GlideSidebarPinnedReorder.finalIndex(
            itemCount: 3, sourceIndex: 0, insertionIndex: 4))
    }

    func testDidSaveRunsOnlyWhenPersistenceChanges() {
        var saveCount = 0
        let observedStore = GlideSidebarPinnedAppsStore(defaults: defaults) {
            saveCount += 1
        }

        XCTAssertTrue(observedStore.pin(
            bundleIdentifier: "com.example.one", displayName: "One", bundlePath: nil))
        XCTAssertEqual(saveCount, 1)
        XCTAssertFalse(observedStore.pin(
            bundleIdentifier: "com.example.one", displayName: "One", bundlePath: nil))
        XCTAssertFalse(observedStore.move(bundleIdentifier: "com.example.one", to: 0))
        XCTAssertFalse(observedStore.unpin(bundleIdentifier: "com.example.missing"))
        XCTAssertEqual(saveCount, 1)
        XCTAssertTrue(observedStore.unpin(bundleIdentifier: "com.example.one"))
        XCTAssertEqual(saveCount, 2)
    }
}
