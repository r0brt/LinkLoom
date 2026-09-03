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
        var invoiceDocumentID = ""
        var paymentDocumentID = ""
        var dossierID = ""

        let app = launch(fixture: fixture)

        XCTContext.runActivity(named: "Add temporary source through the UI") { _ in
            let addButton = element("source.add", in: app)
            requireExists(addButton, timeout: 20, description: "source.add")
            addButton.click()
            requireExists(sourceRow(in: app), timeout: 20, description: "source.row.<UUID>")
            requireExists(element("scan.start", in: app), timeout: 20, description: "scan.start")
        }

        try XCTContext.runActivity(named: "Scan, relate, and create a dossier") { _ in
            element("scan.start", in: app).click()
            requireLabel("Entdeckt: 0", for: element("status.discovered", in: app), timeout: 90)
            requireLabel("Extraktion: 0", for: element("status.extracting", in: app), timeout: 90)
            requireLabel("Bereit: 3", for: element("status.ready", in: app), timeout: 90)
            requireLabel("Fehler: 1", for: element("status.failed", in: app), timeout: 90)
            requireLabel("Document DNA Bereit: 3", for: element("dna-status.ready", in: app), timeout: 90)
            requireLabel("Document DNA Fehler: 0", for: element("dna-status.failed", in: app), timeout: 90)
            requireExists(element("documents.table", in: app), description: "documents.table")
            for text in [
                "selectable.pdf", "payments/payment-confirmation.pdf", "scan.png", "corrupt.pdf", "failed",
                "unreadableDocument",
            ] {
                requireExists(app.staticTexts[text], description: text)
            }
            XCTAssertFalse(app.staticTexts["unsupported.txt"].exists)
            let selectableDocument = element("documents.table", in: app)
                .staticTexts["selectable.pdf"]
                .firstMatch
            requireExists(selectableDocument, description: "selectable document row")
            selectableDocument.click()
            let inspector = element("document-dna.inspector", in: app)
            requireExists(inspector, description: "document-dna.inspector")
            let splitterCount = app.splitters.count
            XCTAssertGreaterThan(splitterCount, 0, "Document inspector splitter is unavailable")
            let inspectorSplitter = app.splitters.element(boundBy: splitterCount - 1)
            let inspectorTitle = inspector.staticTexts["Document DNA"].firstMatch
            requireExists(inspectorTitle, description: "Document DNA inspector title")
            requireFullyVisibleInInspector(
                inspectorTitle,
                splitter: inspectorSplitter,
                window: app.windows.firstMatch,
                description: "Document DNA inspector title"
            )
            requireLabel(
                "Dokumenttyp: Rechnung",
                for: element("document-dna.document-type", in: app)
            )
            requireLabel(
                "Seite 1: Rechnung",
                for: element("document-dna.document-type.evidence.0", in: app)
            )
            let candidateHeader = element("invoice-payment-candidates.header", in: app)
            requireExists(candidateHeader, description: "invoice-payment-candidates.header")
            let inspectorScroll = inspector.scrollViews.firstMatch
            requireExists(inspectorScroll, description: "Document DNA inspector scroll view")
            requireFullyVisibleInInspector(
                candidateHeader,
                scrollingIn: inspectorScroll,
                splitter: inspectorSplitter,
                window: app.windows.firstMatch,
                description: "Verknüpfungskandidaten header"
            )
            let headerScreenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            headerScreenshot.name = "PR33 candidate inspector header"
            headerScreenshot.lifetime = .keepAlways
            add(headerScreenshot)
            let candidateCard = element("invoice-payment-candidates.0", in: app)
            requireExists(candidateCard, description: "invoice-payment-candidates.0")
            let candidateDetails: [(XCUIElement, String, String)] = [
                (
                    element("invoice-payment-candidates.0.counterpart", in: app),
                    "payments/payment-confirmation.pdf",
                    "candidate counterpart"
                ),
                (
                    element("invoice-payment-candidates.0.disposition", in: app),
                    "Hohe Übereinstimmung",
                    "candidate confidence label"
                ),
                (
                    element("invoice-payment-candidates.0.signal.0.title", in: app),
                    "Referenz",
                    "reference signal"
                ),
                (
                    element("invoice-payment-candidates.0.signal.0.comparison", in: app),
                    "INV-2026-001 ↔ INV-2026-001",
                    "reference comparison"
                ),
                (
                    element("invoice-payment-candidates.0.signal.0.invoice.0", in: app),
                    "Rechnung · Seite 1: INV-2026-001",
                    "reference invoice evidence"
                ),
                (
                    element("invoice-payment-candidates.0.signal.0.payment.0", in: app),
                    "Zahlung · Seite 1: INV-2026-001",
                    "reference payment evidence"
                ),
                (
                    element("invoice-payment-candidates.0.signal.1.title", in: app),
                    "Betrag und Währung",
                    "amount and currency signal"
                ),
                (
                    element("invoice-payment-candidates.0.signal.1.comparison", in: app),
                    "CHF 1250 ↔ CHF 1250",
                    "amount and currency comparison"
                ),
                (
                    element("invoice-payment-candidates.0.signal.1.invoice.0", in: app),
                    "Rechnung · Seite 1: CHF 1250",
                    "amount and currency invoice evidence"
                ),
                (
                    element("invoice-payment-candidates.0.signal.1.payment.0", in: app),
                    "Zahlung · Seite 1: CHF 1250",
                    "amount and currency payment evidence"
                ),
                (
                    element("invoice-payment-candidates.0.signal.2.title", in: app),
                    "Organisation",
                    "organization signal"
                ),
                (
                    element("invoice-payment-candidates.0.signal.2.comparison", in: app),
                    "Beispiel AG ↔ Beispiel AG",
                    "organization comparison"
                ),
                (
                    element("invoice-payment-candidates.0.signal.2.invoice.0", in: app),
                    "Rechnung · Seite 1: Beispiel AG",
                    "organization invoice evidence"
                ),
                (
                    element("invoice-payment-candidates.0.signal.2.payment.0", in: app),
                    "Zahlung · Seite 1: Beispiel AG",
                    "organization payment evidence"
                ),
            ]
            for (detail, label, description) in candidateDetails {
                requireValue(label, for: detail)
                requireFullyVisibleInInspector(
                    detail,
                    scrollingIn: inspectorScroll,
                    splitter: inspectorSplitter,
                    window: app.windows.firstMatch,
                    description: description
                )
            }
            let decision = element("invoice-payment-candidates.0.decision", in: app)
            requireValue("Unentschieden", for: decision)
            let confirm = element("invoice-payment-candidates.0.confirm", in: app)
            requireFullyVisibleInInspector(
                confirm,
                scrollingIn: inspectorScroll,
                splitter: inspectorSplitter,
                window: app.windows.firstMatch,
                description: "candidate confirm action"
            )
            confirm.click()
            requireValue("Bestätigt", for: decision)
            requireExists(
                element("invoice-payment-candidates.0.reset", in: app),
                description: "candidate reset action"
            )
            let probe = try SQLiteProbe(databaseURL: fixture.databaseURL)
            invoiceDocumentID = try probe.documentID(relativePath: "selectable.pdf")
            paymentDocumentID = try probe.documentID(
                relativePath: "payments/payment-confirmation.pdf"
            )

            let dossierEntry = element("document-dna.costs-dossier", in: app)
            requireFullyVisibleInInspector(
                dossierEntry,
                scrollingIn: inspectorScroll,
                splitter: inspectorSplitter,
                window: app.windows.firstMatch,
                description: "dossier entry action"
            )
            dossierEntry.click()

            let workspace = element("dossier.workspace", in: app)
            requireExists(workspace, timeout: 20, description: "dossier.workspace")
            requireExists(
                element("dossier.member.\(invoiceDocumentID)", in: app),
                description: "dossier anchor"
            )
            let paymentMember = element("dossier.member.\(paymentDocumentID)", in: app)
            requireExists(paymentMember, description: "dossier payment member")
            dossierID = try SQLiteProbe(databaseURL: fixture.databaseURL).onlyDossierID()

            paymentMember.click()
            requireExists(
                inspector.staticTexts["payments/payment-confirmation.pdf"],
                description: "payment dossier member inspector title"
            )
            let showCounterpart = element(
                "invoice-payment-candidates.0.show-counterpart",
                in: app
            )
            requireFullyVisibleInInspector(
                showCounterpart,
                scrollingIn: inspectorScroll,
                splitter: inspectorSplitter,
                window: app.windows.firstMatch,
                description: "show counterpart action"
            )
            showCounterpart.click()
            requireExists(
                inspector.staticTexts["selectable.pdf"],
                description: "invoice counterpart inspector title"
            )
            requireExists(
                element("dossier.workspace", in: app),
                description: "dossier workspace after counterpart navigation"
            )

            let removePayment = element(
                "dossier.member.remove.\(paymentDocumentID)",
                in: app
            )
            requireHittable(
                removePayment,
                scrollingIn: workspace,
                description: "remove payment from dossier"
            )
            removePayment.click()
            requireDisappearance(
                paymentMember,
                timeout: 20,
                description: "excluded dossier payment member"
            )
            requireExists(
                element("dossier.correction.\(paymentDocumentID)", in: app),
                description: "dossier payment correction"
            )
            let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            screenshot.name = "Dossier correction after counterpart navigation"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }

        terminateAndWait(app)

        try XCTContext.runActivity(named: "Verify durable dossier correction") { _ in
            let evidence = try SQLiteProbe(databaseURL: fixture.databaseURL).collectEvidence()
            XCTAssertTrue(
                evidence.matchesCompletedWorkflowWithCorrection,
                "Unexpected database evidence: \(evidence)"
            )
        }

        try XCTContext.runActivity(named: "Prepare a retryable DNA failure in the test database") { _ in
            try SQLiteTestDatabaseMutator.makeSelectableDocumentDNAFailureRetryable(
                databaseURL: fixture.databaseURL
            )
            XCTAssertEqual(try fixture.snapshot(), initialSnapshot)
        }

        let relaunchedApp = launch(fixture: fixture)

        XCTContext.runActivity(named: "Verify persistence after process restart") { _ in
            requireExists(sourceRow(in: relaunchedApp), timeout: 20, description: "persisted source row")
            let dossierRow = element("dossier.row.\(dossierID)", in: relaunchedApp)
            requireExists(dossierRow, timeout: 20, description: "persisted dossier row")
            dossierRow.click()
            requireExists(
                element("dossier.workspace", in: relaunchedApp),
                description: "persisted dossier workspace"
            )
            requireExists(
                element("dossier.correction.\(paymentDocumentID)", in: relaunchedApp),
                description: "persisted dossier correction"
            )

            sourceRow(in: relaunchedApp).click()
            requireLabel("Entdeckt: 0", for: element("status.discovered", in: relaunchedApp))
            requireLabel("Extraktion: 0", for: element("status.extracting", in: relaunchedApp))
            requireLabel("Bereit: 3", for: element("status.ready", in: relaunchedApp))
            requireLabel("Fehler: 1", for: element("status.failed", in: relaunchedApp))
            requireLabel("Document DNA Bereit: 2", for: element("dna-status.ready", in: relaunchedApp))
            requireLabel("Document DNA Fehler: 1", for: element("dna-status.failed", in: relaunchedApp))
            requireExists(element("documents.table", in: relaunchedApp), description: "persisted table")
            for text in [
                "selectable.pdf", "payments/payment-confirmation.pdf", "scan.png", "corrupt.pdf",
                "unreadableDocument",
            ] {
                requireExists(relaunchedApp.staticTexts[text], description: "persisted \(text)")
            }
            let selectableDocument = element("documents.table", in: relaunchedApp)
                .staticTexts["selectable.pdf"]
                .firstMatch
            requireExists(selectableDocument, description: "selectable document row")
            selectableDocument.click()
            requireExists(
                element("document-dna.inspector", in: relaunchedApp),
                description: "persisted document-dna.inspector"
            )
            requireLabel(
                "Fehlergrund: Lokale Analyse fehlgeschlagen",
                for: element("document-dna.failure-reason", in: relaunchedApp)
            )
            let retry = element("document-dna.retry", in: relaunchedApp)
            requireExists(retry, description: "document-dna.retry")
            retry.click()
            requireLabel(
                "Document DNA Bereit: 3",
                for: element("dna-status.ready", in: relaunchedApp),
                timeout: 90
            )
            requireLabel(
                "Document DNA Fehler: 0",
                for: element("dna-status.failed", in: relaunchedApp),
                timeout: 90
            )
            requireDisappearance(
                retry,
                timeout: 20,
                description: "document-dna.retry"
            )
            requireLabel(
                "Dokumenttyp: Rechnung",
                for: element("document-dna.document-type", in: relaunchedApp)
            )
            requireLabel(
                "Seite 1: Rechnung",
                for: element("document-dna.document-type.evidence.0", in: relaunchedApp)
            )
            requireValue(
                "Bestätigt",
                for: element("invoice-payment-candidates.0.decision", in: relaunchedApp)
            )

            dossierRow.click()
            let workspace = element("dossier.workspace", in: relaunchedApp)
            requireExists(workspace, description: "restored dossier workspace")
            let reset = element(
                "dossier.correction.reset.\(paymentDocumentID)",
                in: relaunchedApp
            )
            requireHittable(
                reset,
                scrollingIn: workspace,
                description: "reset dossier correction"
            )
            reset.click()
            requireDisappearance(
                element("dossier.correction.\(paymentDocumentID)", in: relaunchedApp),
                timeout: 20,
                description: "reset dossier correction"
            )
            requireExists(
                element("dossier.member.\(paymentDocumentID)", in: relaunchedApp),
                description: "restored dossier payment member"
            )
            let screenshot = XCTAttachment(
                screenshot: relaunchedApp.windows.firstMatch.screenshot()
            )
            screenshot.name = "Persistent dossier after correction reset"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }

        try XCTContext.runActivity(named: "Verify retry restored coherent DNA state") { _ in
            let evidence = try SQLiteProbe(databaseURL: fixture.databaseURL).collectEvidence()
            XCTAssertTrue(evidence.matchesRestoredWorkflow, "Retry left incoherent DNA: \(evidence)")
            XCTAssertEqual(try fixture.snapshot(), initialSnapshot)
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

    func testIntegritySnapshotIncludesHiddenFile() throws {
        let fixture = try SmokeFixture()
        self.fixture = fixture

        let hiddenFile = fixture.sourceURL.appendingPathComponent(".hidden-evidence")
        try Data("hidden".utf8).write(to: hiddenFile)

        let entries = Dictionary(
            uniqueKeysWithValues: try fixture.snapshot().map { ($0.relativePath, $0) }
        )
        XCTAssertEqual(entries[".hidden-evidence"]?.kind, .regularFile)
    }

    func testIntegritySnapshotIncludesDirectory() throws {
        let fixture = try SmokeFixture()
        self.fixture = fixture

        let nestedDirectory = fixture.sourceURL.appendingPathComponent(
            "nested",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: nestedDirectory,
            withIntermediateDirectories: false
        )

        let entries = Dictionary(
            uniqueKeysWithValues: try fixture.snapshot().map { ($0.relativePath, $0) }
        )
        XCTAssertEqual(entries["nested"]?.kind, .directory)
    }

    func testIntegritySnapshotIncludesSymbolicLink() throws {
        let fixture = try SmokeFixture()
        self.fixture = fixture

        let destination = fixture.sourceURL.appendingPathComponent("selectable.pdf")
        let symbolicLink = fixture.sourceURL.appendingPathComponent("selectable-link")
        try FileManager.default.createSymbolicLink(
            at: symbolicLink,
            withDestinationURL: destination
        )

        let entries = Dictionary(
            uniqueKeysWithValues: try fixture.snapshot().map { ($0.relativePath, $0) }
        )
        XCTAssertEqual(entries["selectable-link"]?.kind, .symbolicLink)
        XCTAssertEqual(entries["selectable-link"]?.symbolicLinkDestination, destination.path)
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

    private func requireValue(
        _ value: String,
        for element: XCUIElement,
        timeout: TimeInterval = 20
    ) {
        requireExists(element, timeout: timeout, description: element.identifier)
        let predicate = NSPredicate(format: "value == %@", value)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout),
            .completed,
            "Timed out waiting for value \(value); actual value was \(String(describing: element.value))"
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

    private func requireFullyVisibleInInspector(
        _ element: XCUIElement,
        scrollingIn scrollView: XCUIElement? = nil,
        splitter: XCUIElement,
        window: XCUIElement,
        description: String
    ) {
        if let scrollView {
            scrollVerticallyUntilVisible(
                element,
                in: scrollView,
                description: description
            )
        }
        XCTAssertTrue(element.isHittable, "\(description) is not hittable")
        XCTAssertGreaterThanOrEqual(
            element.frame.minX,
            splitter.frame.maxX,
            "\(description) extends left of the inspector divider"
        )
        XCTAssertLessThanOrEqual(
            element.frame.maxX,
            window.frame.maxX,
            "\(description) extends beyond the window's right edge"
        )
    }

    private func requireHittable(
        _ element: XCUIElement,
        scrollingIn scrollView: XCUIElement,
        description: String
    ) {
        requireExists(element, description: description)
        scrollVerticallyUntilVisible(
            element,
            in: scrollView,
            description: description
        )
        XCTAssertTrue(element.isHittable, "\(description) is not hittable")
    }

    private func scrollVerticallyUntilVisible(
        _ element: XCUIElement,
        in scrollView: XCUIElement,
        description: String
    ) {
        let maximumAttempts = 12
        for _ in 0..<maximumAttempts {
            let elementFrame = element.frame
            let viewportFrame = scrollView.frame
            if elementFrame.minY >= viewportFrame.minY,
               elementFrame.maxY <= viewportFrame.maxY
            {
                return
            }
            let deltaY: CGFloat = elementFrame.maxY > viewportFrame.maxY ? -180 : 180
            scrollView.scroll(byDeltaX: 0, deltaY: deltaY)
        }
        XCTFail("\(description) did not become vertically visible after bounded scrolling")
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
