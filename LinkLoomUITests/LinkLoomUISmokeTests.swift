import CoreGraphics
import XCTest

final class LinkLoomUISmokeTests: XCTestCase {
    private enum ExpectedFixtureError: Error {
        case constructionFailed
    }

    private var app: XCUIApplication?
    private var fixture: SmokeFixture?

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        let failed = testRun?.failureCount ?? 0 > 0
        if failed {
            attachFailureDiagnostics()
        }
        if let app, app.state != .notRunning {
            app.terminate()
        }
        if failed, let fixture {
            attachDatabaseDiagnostics(fixture: fixture)
        }
        if let fixture {
            do {
                try fixture.remove()
            } catch {
                XCTFail("Temporary fixture cleanup failed: \(error)")
            }
        }
        app = nil
        fixture = nil
        super.tearDown()
    }

    @MainActor
    func testProductWorkflowPersistsAndPreservesSourceFiles() throws {
        let fixture = try SmokeFixture()
        self.fixture = fixture
        let initialSnapshot = try fixture.snapshot()

        let app = launch(fixture: fixture)

        XCTContext.runActivity(named: "Add temporary source through the UI") { _ in
            let addButton = element("source.add", in: app)
            requireExists(addButton, timeout: 20, description: "source.add")
            addButton.click()
            requireExists(sourceRow(in: app), timeout: 20, description: "source.row.<UUID>")
            requireExists(element("scan.start", in: app), timeout: 20, description: "scan.start")
        }

        XCTContext.runActivity(named: "Scan and extract generated documents") { _ in
            element("scan.start", in: app).click()
            requireLabel("Entdeckt: 0", for: element("status.discovered", in: app), timeout: 90)
            requireLabel("Extraktion: 0", for: element("status.extracting", in: app), timeout: 90)
            requireLabel("Bereit: 2", for: element("status.ready", in: app), timeout: 90)
            requireLabel("Fehler: 1", for: element("status.failed", in: app), timeout: 90)
            requireExists(element("documents.table", in: app), description: "documents.table")
            for text in ["selectable.pdf", "scan.png", "corrupt.pdf", "failed", "unreadableDocument"] {
                requireExists(app.staticTexts[text], description: text)
            }
            XCTAssertFalse(app.staticTexts["unsupported.txt"].exists)
        }

        terminateAndWait(app)

        try XCTContext.runActivity(named: "Verify durable extraction read-only") { _ in
            let evidence = try SQLiteProbe(databaseURL: fixture.databaseURL).collectEvidence()
            XCTAssertTrue(evidence.matchesCompletedWorkflow, "Unexpected database evidence: \(evidence)")
        }

        let relaunchedApp = launch(fixture: fixture)

        XCTContext.runActivity(named: "Verify persistence after process restart") { _ in
            requireExists(sourceRow(in: relaunchedApp), timeout: 20, description: "persisted source row")
            requireLabel("Entdeckt: 0", for: element("status.discovered", in: relaunchedApp))
            requireLabel("Extraktion: 0", for: element("status.extracting", in: relaunchedApp))
            requireLabel("Bereit: 2", for: element("status.ready", in: relaunchedApp))
            requireLabel("Fehler: 1", for: element("status.failed", in: relaunchedApp))
            requireExists(element("documents.table", in: relaunchedApp), description: "persisted table")
            for text in ["selectable.pdf", "scan.png", "corrupt.pdf", "unreadableDocument"] {
                requireExists(relaunchedApp.staticTexts[text], description: "persisted \(text)")
            }
        }

        XCTContext.runActivity(named: "Remove source through its context menu") { _ in
            let row = sourceRow(in: relaunchedApp)
            row.rightClick()
            let removeItem = relaunchedApp.menuItems["Quelle entfernen"]
            requireExists(removeItem, description: "Quelle entfernen")
            removeItem.click()
            requireDisappearance(row, timeout: 20, description: "source row")
            requireDisappearance(
                element("documents.table", in: relaunchedApp),
                timeout: 20,
                description: "selected-source dashboard"
            )
        }

        terminateAndWait(relaunchedApp)

        try XCTContext.runActivity(named: "Verify cascade removal and exact source integrity") { _ in
            let evidence = try SQLiteProbe(databaseURL: fixture.databaseURL).collectEvidence()
            XCTAssertTrue(evidence.matchesRemovedWorkflow, "Removal left database rows: \(evidence)")
            XCTAssertEqual(try fixture.snapshot(), initialSnapshot)
        }
    }

    @MainActor
    func testStartupFailureCanRetry() throws {
        let fixture = try SmokeFixture()
        self.fixture = fixture
        let initialSnapshot = try fixture.snapshot()
        let app = launch(fixture: fixture, failsStartupOnce: true)

        XCTContext.runActivity(named: "Present recoverable startup failure") { _ in
            requireExists(element("startup.failure", in: app), timeout: 20, description: "startup.failure")
            let retry = element("startup.retry", in: app)
            requireExists(retry, description: "startup.retry")
            requireExists(
                app.staticTexts["Der lokale Katalog konnte nicht geöffnet werden. Deine Quelldokumente wurden nicht verändert."],
                description: "recoverable startup copy"
            )
            retry.click()
            requireExists(element("source.add", in: app), timeout: 20, description: "source.add after retry")
        }

        XCTAssertEqual(try fixture.snapshot(), initialSnapshot)
    }

    func testIntegritySnapshotIncludesHiddenAndNonRegularEntries() throws {
        let fixture = try SmokeFixture()
        self.fixture = fixture

        let hiddenFile = fixture.sourceURL.appendingPathComponent(".hidden-evidence")
        try Data("hidden".utf8).write(to: hiddenFile)
        let nestedDirectory = fixture.sourceURL.appendingPathComponent(
            "nested",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: nestedDirectory,
            withIntermediateDirectories: false
        )
        let symbolicLink = fixture.sourceURL.appendingPathComponent("hidden-link")
        try FileManager.default.createSymbolicLink(
            at: symbolicLink,
            withDestinationURL: hiddenFile
        )

        let entries = Dictionary(
            uniqueKeysWithValues: try fixture.snapshot().map { ($0.relativePath, $0) }
        )
        XCTAssertEqual(entries[".hidden-evidence"]?.kind, .regularFile)
        XCTAssertEqual(entries["nested"]?.kind, .directory)
        XCTAssertEqual(entries["hidden-link"]?.kind, .symbolicLink)
        XCTAssertEqual(entries["hidden-link"]?.symbolicLinkDestination, hiddenFile.path)
    }

    func testFailedFixtureConstructionRemovesTemporaryRoot() {
        var temporaryRoot: URL?
        defer {
            if let temporaryRoot,
               FileManager.default.fileExists(atPath: temporaryRoot.path)
            {
                try? FileManager.default.removeItem(at: temporaryRoot)
            }
        }

        XCTAssertThrowsError(try SmokeFixture(prepareSource: { sourceURL in
            temporaryRoot = sourceURL.deletingLastPathComponent()
            throw ExpectedFixtureError.constructionFailed
        })) { error in
            XCTAssertTrue(error is ExpectedFixtureError)
        }
        XCTAssertNotNil(temporaryRoot)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: temporaryRoot?.path ?? ""),
            "A failed fixture construction left its temporary root behind"
        )
    }

    @discardableResult
    private func launch(fixture: SmokeFixture, failsStartupOnce: Bool = false) -> XCUIApplication {
        let application = XCUIApplication()
        application.launchArguments = [
            "--linkloom-ui-test-database", fixture.databaseURL.path,
            "--linkloom-ui-test-source", fixture.sourceURL.path,
            "--linkloom-ui-test-disable-watcher",
        ]
        if failsStartupOnce {
            application.launchArguments.append("--linkloom-ui-test-fail-startup-once")
        }
        application.launch()
        application.activate()
        positionWindowForAutomation(in: application)
        app = application
        return application
    }

    private func positionWindowForAutomation(in application: XCUIApplication) {
        let window = application.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "LinkLoom window is unavailable")
        let titleBar = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.04))
        titleBar.press(
            forDuration: 0.1,
            thenDragTo: titleBar.withOffset(CGVector(dx: 0, dy: -100))
        )
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func sourceRow(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "source.row."))
            .firstMatch
    }

    private func requireExists(
        _ element: XCUIElement,
        timeout: TimeInterval = 10,
        description: String
    ) {
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "Timed out waiting for \(description). Hierarchy:\n\(app?.debugDescription ?? "unavailable")"
        )
    }

    private func requireLabel(
        _ label: String,
        for element: XCUIElement,
        timeout: TimeInterval = 20
    ) {
        requireExists(element, timeout: timeout, description: element.identifier)
        let predicate = NSPredicate(format: "label == %@", label)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout),
            .completed,
            "Timed out waiting for label \(label); actual label was \(element.label)"
        )
    }

    private func requireDisappearance(
        _ element: XCUIElement,
        timeout: TimeInterval,
        description: String
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout),
            .completed,
            "Timed out waiting for \(description) to disappear"
        )
    }

    private func terminateAndWait(_ app: XCUIApplication) {
        app.terminate()
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "state == %d", XCUIApplication.State.notRunning.rawValue),
            object: app
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
    }

    private func attachFailureDiagnostics() {
        guard let app else { return }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "LinkLoom failure screenshot"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let hierarchy = XCTAttachment(
            data: Data(app.debugDescription.utf8),
            uniformTypeIdentifier: "public.plain-text"
        )
        hierarchy.name = "LinkLoom accessibility hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    private func attachDatabaseDiagnostics(fixture: SmokeFixture) {
        let diagnostic: String
        do {
            diagnostic = try SQLiteProbe(databaseURL: fixture.databaseURL)
                .collectEvidence()
                .description
        } catch {
            diagnostic = "Database evidence unavailable: \(error)"
        }
        print("LinkLoom UI smoke failure database evidence: \(diagnostic)")

        let attachment = XCTAttachment(
            data: Data(diagnostic.utf8),
            uniformTypeIdentifier: "public.plain-text"
        )
        attachment.name = "LinkLoom database evidence"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
