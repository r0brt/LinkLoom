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
    func testPersonDossierWorkflowPersistsAndPreservesSourceFiles() throws {
        let fixture = try SmokeFixture.personDossier()
        self.fixture = fixture
        let initialSnapshot = try fixture.snapshot()
        let app = launch(fixture: fixture, accessibilityText: true)

        try XCTContext.runActivity(named: "Create the costs dossier before opening a person dossier") { _ in
            let addButton = element("source.add", in: app)
            requireExists(addButton, timeout: 20, description: "source.add")
            addButton.click()
            requireExists(sourceRow(in: app), timeout: 20, description: "source row")

            let scan = element("scan.start", in: app)
            requireExists(scan, timeout: 20, description: "scan.start")
            scan.click()

            let invoice = element("documents.table", in: app)
                .staticTexts["invoices/care-home-invoice.pdf"]
                .firstMatch
            requireExists(invoice, timeout: 90, description: "care invoice")
            invoice.click()

            let inspector = element("document-dna.inspector", in: app)
            requireExists(inspector, description: "Document DNA inspector")
            let confirm = element("invoice-payment-candidates.0.confirm", in: app)
            requireExists(confirm, timeout: 90, description: "payment candidate confirmation")
            confirm.click()
            requireValue(
                "Bestätigt",
                for: element("invoice-payment-candidates.0.decision", in: app)
            )

            let costsEntry = element("document-dna.costs-dossier", in: app)
            requireExists(costsEntry, timeout: 30, description: "costs dossier action")
            let inspectorScroll = inspector.scrollViews.firstMatch
            let splitterCount = app.splitters.count
            XCTAssertGreaterThan(splitterCount, 0, "Document inspector splitter is unavailable")
            requireFullyVisibleInInspector(
                costsEntry,
                scrollingIn: inspectorScroll,
                splitter: app.splitters.element(boundBy: splitterCount - 1),
                window: app.windows.firstMatch,
                description: "costs dossier action"
            )
            XCTAssertTrue(
                inspectorScroll.frame.contains(costsEntry.frame),
                "Costs entry must be inside inspector viewport before clicking: entry=\(costsEntry.frame), viewport=\(inspectorScroll.frame), window=\(app.windows.firstMatch.frame)"
            )
            costsEntry.click()
            requireExists(element("dossier.workspace", in: app), timeout: 20, description: "costs dossier workspace")
            XCTAssertEqual(try fixture.snapshot(), initialSnapshot)
        }

        let probe = try SQLiteProbe(databaseURL: fixture.databaseURL)
        let anchorID = try probe.documentID(relativePath: "anchor-care.pdf")
        let insuranceID = try probe.documentID(relativePath: "insurance.pdf")
        let ocrID = try probe.documentID(relativePath: "scan.png")
        let invoiceID = try probe.documentID(relativePath: "invoices/care-home-invoice.pdf")
        let paymentID = try probe.documentID(relativePath: "payments/payment-confirmation.pdf")
        let authorizationID = try probe.documentID(relativePath: "power-of-attorney.pdf")
        let conflictID = try probe.documentID(relativePath: "conflicting-insurance.pdf")
        let costsDossierID = try probe.onlyDossierID(kind: "costsAndPayments")

        let personDossierID = try XCTContext.runActivity(
            named: "Create one person dossier from its primary anchor finding"
        ) { _ in
            sourceRow(in: app).click()
            let anchorCare = element("documents.table", in: app)
                .staticTexts["anchor-care.pdf"]
                .firstMatch
            requireExists(anchorCare, timeout: 20, description: "person anchor document")
            anchorCare.click()

            let personEntry = element("document-dna.person-dossier.0", in: app)
            requireExists(personEntry, timeout: 60, description: "person dossier entry action")
            requireLabel(
                "Hauptdossier erstellen für Elise Muster Rolle Bewohnerin",
                for: personEntry
            )
            personEntry.click()

            let dossierID = try waitForOnlyDossierID(
                fixture: fixture,
                kind: "personMatter"
            )
            requireExists(
                element("dossier.row.\(dossierID)", in: app),
                timeout: 20,
                description: "persisted person dossier row"
            )

            requireExists(
                element("dossier.person.workspace", in: app),
                timeout: 20,
                description: "person dossier workspace"
            )
            requireExists(
                app.staticTexts["Meine Mutter im Pflegeheim"].firstMatch,
                description: "fixed person dossier title"
            )
            requireExists(
                element("dossier.person.anchor", in: app),
                description: "person dossier anchor"
            )
            let anchorElement = element("dossier.person.anchor", in: app)
            let expectedAnchorLabel = "Elise Muster Rolle: Bewohnerin. Ursprungsnachweis aktuell Verfügbar"
            let requiredChildIDs = [
                "dossier.person.member.\(anchorID)",
                "dossier.person.member.\(anchorID).reason.0",
                "dossier.person.member.remove.\(insuranceID)",
                "dossier.person.member.\(paymentID).counterpart",
                "dossier.person.suggestion.\(authorizationID)",
                "dossier.person.suggestion.accept.\(authorizationID)",
                "dossier.person.suggestion.reject.\(authorizationID)",
            ]
            let missingChildIDs = requiredChildIDs.filter { !element($0, in: app).exists }
            XCTAssertTrue(
                anchorElement.elementType == .other
                    && anchorElement.label == expectedAnchorLabel
                    && missingChildIDs.isEmpty,
                "Person accessibility contract: anchor type=\(anchorElement.elementType.rawValue), label=\(anchorElement.label), value=\(String(describing: anchorElement.value)); missing individual IDs=\(missingChildIDs)"
            )
            requireLabel("Elise Muster Rolle: Bewohnerin. Ursprungsnachweis aktuell Verfügbar", for: element("dossier.person.anchor", in: app))
            requireExists(
                element("dossier.person.direct-members", in: app),
                description: "direct person dossier members"
            )
            requireExists(
                element("dossier.person.costs", in: app),
                description: "person dossier costs and payments"
            )

            let personRow = element("dossier.row.\(dossierID)", in: app)
            requireExists(
                personRow.staticTexts["Meine Mutter im Pflegeheim"].firstMatch,
                description: "fixed person dossier sidebar title"
            )
            let expectedReasons = [
                (anchorID, [
                    "Der Name ‹Elise Muster› stimmt exakt mit dem Personenanker überein. Rolle: Bewohnerin.",
                ]),
                (insuranceID, [
                    "Der Name ‹Elise Muster› stimmt exakt mit dem Personenanker überein. Rolle: Versicherte Person.",
                ]),
                (ocrID, [
                    "Der Name ‹Elise Muster› stimmt exakt mit dem Personenanker überein. Rolle: Bewohnerin.",
                ]),
                (invoiceID, [
                    "Der Name ‹Elise Muster› stimmt exakt mit dem Personenanker überein. Rolle: Rechnungsempfängerin.",
                ]),
                (paymentID, [
                    "Zahlung über die Rechnung ‹invoices/care-home-invoice.pdf›. Der Name der Rechnung stimmt exakt mit dem Personenanker überein.",
                    "Referenz: PFLEGE-2026-001 ↔ PFLEGE-2026-001",
                    "Betrag und Währung: CHF 1250 ↔ CHF 1250",
                    "Organisation: Pflegeheim Sonnengarten ↔ Pflegeheim Sonnengarten",
                ]),
            ]
            let memberSummaries = [
                anchorID: "anchor-care.pdf. Dokumenttyp: Medizin- oder Pflegedokument. Verfügbar. Direktes Dokument",
                insuranceID: "insurance.pdf. Dokumenttyp: Versicherungsabrechnung. Verfügbar. Direktes Dokument",
                ocrID: "scan.png. Dokumenttyp: Unbekannt. Verfügbar. Direktes Dokument",
                invoiceID: "invoices/care-home-invoice.pdf. Dokumenttyp: Rechnung. Verfügbar. Kosten oder Zahlung",
                paymentID: "payments/payment-confirmation.pdf. Dokumenttyp: Zahlungsbestätigung. Verfügbar. Kosten oder Zahlung",
            ]
            for (documentID, reasons) in expectedReasons {
                let member = element("dossier.person.member.\(documentID)", in: app)
                requireExists(member, description: "person dossier member \(documentID)")
                requireLabel(try XCTUnwrap(memberSummaries[documentID]) + ". " + reasons.joined(separator: " "), for: member)
                for (ordinal, reason) in reasons.enumerated() {
                    let reasonElement = element(
                        "dossier.person.member.\(documentID).reason.\(ordinal)",
                        in: app
                    )
                    requireLabel(
                        reason,
                        for: reasonElement,
                        timeout: 20
                    )
                }
            }

            let window = app.windows.firstMatch
            resizeWindow(window, toWidth: 900)
            let workspaceBeforeInspector = element("dossier.person.workspace", in: app)
            let workspaceScrollView = requireDossierScrollView(
                containing: workspaceBeforeInspector,
                in: app
            )
            requireHittable(
                element("dossier.person.member.\(paymentID)", in: app),
                scrollingIn: workspaceScrollView,
                description: "payment member at 900-point width"
            )
            for candidate in app.staticTexts.allElementsBoundByIndex.filter({
                $0.identifier.contains(".reason.")
            }) {
                requireContained(candidate, scrollingIn: workspaceScrollView, in: app)
            }
            for documentID in [anchorID, insuranceID, ocrID, invoiceID, paymentID] {
                requireContained(element("dossier.person.member.\(documentID)", in: app), scrollingIn: workspaceScrollView, in: app)
            }
            let longReason = element("dossier.person.member.\(paymentID).reason.0", in: app)
            let shortReason = element("dossier.person.member.\(paymentID).reason.1", in: app)
            XCTAssertGreaterThan(longReason.frame.height, shortReason.frame.height, "The relationship reason must wrap at accessibility text size")
            requireContained(element("dossier.person.anchor", in: app), scrollingIn: workspaceScrollView, in: app)
            attachPersonScreenshot("Initial person projection", in: app)

            let ocrMember = requirePersonDossierMember(
                containing: "scan.png",
                in: app
            )
            let paymentMember = requirePersonDossierMember(
                containing: "payments/payment-confirmation.pdf",
                in: app
            )
            for member in [ocrMember, paymentMember] {
                requireExists(
                    element("\(member.identifier).reason.0", in: app),
                    description: "first membership reason for \(member.identifier)"
                )
            }

            requireKeyboardReachable(ocrMember, in: app)
            ocrMember.click()
            requireExists(
                element("document-dna.inspector", in: app),
                timeout: 20,
                description: "OCR member evidence inspector"
            )
            requireExists(
                app.staticTexts["Elise Muster"].firstMatch,
                description: "exact OCR person evidence"
            )
            let workspaceWithInspector = element("dossier.person.workspace", in: app)
            let workspaceWidthWithInspector = workspaceWithInspector.frame.width
            closeInspector(byReselecting: personRow, in: app)
            XCTAssertEqual(try fixture.snapshot(), initialSnapshot)
            requireExists(
                element("dossier.person.workspace", in: app),
                description: "person workspace after OCR navigation"
            )
            XCTAssertGreaterThan(
                element("dossier.person.workspace", in: app).frame.width,
                workspaceWidthWithInspector,
                "Closing the inspector must return width to the person workspace"
            )
            let expandedWorkspaceScrollView = requireDossierScrollView(
                containing: element("dossier.person.workspace", in: app),
                in: app
            )
            requireHittable(
                element("dossier.person.member.\(paymentID)", in: app),
                scrollingIn: expandedWorkspaceScrollView,
                description: "payment member after inspector dismissal"
            )

            paymentMember.click()
            requireExists(
                element("document-dna.inspector", in: app),
                timeout: 20,
                description: "payment member inspector"
            )
            closeInspector(byReselecting: personRow, in: app)
            XCTAssertEqual(try fixture.snapshot(), initialSnapshot)
            let reloadedPayment = requirePersonDossierMember(
                containing: "payments/payment-confirmation.pdf",
                in: app
            )
            let counterpart = element("\(reloadedPayment.identifier).counterpart", in: app)
            requireExists(counterpart, description: "payment counterpart navigation")
            requireCompletePersonRowContained(
                summary: reloadedPayment,
                actions: [counterpart, element("dossier.person.member.remove.\(paymentID)", in: app)],
                in: app
            )
            requireKeyboardReachable(counterpart, in: app)
            counterpart.click()
            requireExists(
                element("document-dna.inspector", in: app),
                timeout: 20,
                description: "invoice counterpart inspector"
            )
            requireExists(
                app.staticTexts["invoices/care-home-invoice.pdf"].firstMatch,
                description: "invoice counterpart document"
            )
            closeInspector(byReselecting: personRow, in: app)
            requireExists(
                element("dossier.person.workspace", in: app),
                description: "person workspace after counterpart navigation"
            )
            XCTAssertEqual(try fixture.snapshot(), initialSnapshot)
            return dossierID
        }

        try XCTContext.runActivity(named: "Choose the existing same-name dossier explicitly") { _ in
            sourceRow(in: app).click()
            let invoice = element("documents.table", in: app)
                .staticTexts["invoices/care-home-invoice.pdf"]
                .firstMatch
            requireExists(invoice, timeout: 20, description: "care invoice after person dossier creation")
            invoice.click()

            let entry = element("document-dna.person-dossier.0", in: app)
            requireExists(entry, timeout: 30, description: "invoice person dossier entry action")
            requireLabel(
                "Hauptdossier erstellen für Elise Muster Rolle Rechnungsempfängerin",
                for: entry
            )
            entry.click()

            let existingChoice = element("person-dossier.choice.\(personDossierID)", in: app)
            requireExists(existingChoice, timeout: 20, description: "offered same-name person dossier")
            let createNewChoice = app.buttons["Neues Hauptdossier erstellen"].firstMatch
            requireExists(createNewChoice, description: "new person dossier alternative")
            existingChoice.click()
            requireDisappearance(
                existingChoice,
                timeout: 20,
                description: "resolved same-name person dossier choice"
            )

            XCTAssertEqual(try fixture.snapshot(), initialSnapshot)
        }

        func mutate(_ identifier: String, in application: XCUIApplication) throws {
            let button = element(identifier, in: application)
            let scroll = requireDossierScrollView(containing: element("dossier.person.workspace", in: application), in: application)
            requireContained(button, scrollingIn: scroll, in: application)
            requireKeyboardReachable(button, in: application)
            button.click()
            XCTAssertEqual(try fixture.snapshot(), initialSnapshot)
        }
        try XCTContext.runActivity(named: "Accept and reject suggestions, then remove and reset an automatic member") { _ in
            let authorization = element("dossier.person.suggestion.\(authorizationID)", in: app)
            requireExists(authorization, description: "secondary-role suggestion")
            requireLabel("power-of-attorney.pdf. Dokumenttyp: Vollmacht. Verfügbar. Elise Muster, Rolle: Bevollmächtigte. Der Name stimmt exakt, erscheint aber nur in der Rolle Bevollmächtigte. Aufnehmen oder ablehnen.", for: authorization)
            requirePersonSuggestionContained(authorizationID, in: app)
            requireKeyboardReachable(authorization, in: app)
            authorization.click()
            requireExists(element("document-dna.inspector", in: app), description: "suggestion navigation")
            closeInspector(byReselecting: element("dossier.row.\(personDossierID)", in: app), in: app)
            XCTAssertEqual(try fixture.snapshot(), initialSnapshot)
            requirePersonSuggestionContained(authorizationID, in: app)
            try mutate("dossier.person.suggestion.accept.\(authorizationID)", in: app)
            requireDisappearance(authorization, timeout: 20, description: "accepted suggestion")
            requireExists(element("dossier.person.member.\(authorizationID)", in: app), description: "accepted member")
            requireExists(element("dossier.person.correction.\(authorizationID)", in: app), description: "confirmation correction")
            let correction = element("dossier.person.correction.\(authorizationID)", in: app)
            requireLabel("power-of-attorney.pdf. Dokumenttyp: Vollmacht. Verfügbar. Von dir aufgenommen. Aufnahme zurücksetzen.", for: correction)
            requirePersonCorrectionContained(authorizationID, in: app)
            requireKeyboardReachable(correction, in: app)
            correction.click()
            requireExists(element("document-dna.inspector", in: app), description: "correction navigation")
            closeInspector(byReselecting: element("dossier.row.\(personDossierID)", in: app), in: app)
            XCTAssertEqual(try fixture.snapshot(), initialSnapshot)
            requireLabel("Aufnahme zurücksetzen für power-of-attorney.pdf", for: element("dossier.person.correction.reset.\(authorizationID)", in: app))
            requirePersonCorrectionContained(authorizationID, in: app)

            let conflict = element("dossier.person.suggestion.\(conflictID)", in: app)
            requireLabel("conflicting-insurance.pdf. Dokumenttyp: Versicherungsabrechnung. Verfügbar. Elise Muster, Rolle: Versicherte Person. Der Name stimmt, aber dieses Dokument nennt ein anderes Geburtsdatum. Aufnehmen oder ablehnen.", for: conflict)
            requirePersonSuggestionContained(conflictID, in: app)
            try mutate("dossier.person.suggestion.reject.\(conflictID)", in: app)
            requireDisappearance(conflict, timeout: 20, description: "rejected suggestion")
            requireExists(element("dossier.person.correction.\(conflictID)", in: app), description: "exclusion correction")
            requirePersonCorrectionContained(conflictID, in: app)

            requireCompletePersonRowContained(
                summary: element("dossier.person.member.\(insuranceID)", in: app),
                actions: [element("dossier.person.member.remove.\(insuranceID)", in: app)],
                in: app
            )
            try mutate("dossier.person.member.remove.\(insuranceID)", in: app)
            requireDisappearance(element("dossier.person.member.\(insuranceID)", in: app), timeout: 20, description: "removed insurance member")
            requireExists(element("dossier.person.correction.\(insuranceID)", in: app), description: "removed member correction")
            requireLabel("Ausschluss zurücksetzen für insurance.pdf", for: element("dossier.person.correction.reset.\(insuranceID)", in: app))
            requirePersonCorrectionContained(insuranceID, in: app)
            try mutate("dossier.person.correction.reset.\(insuranceID)", in: app)
            requireDisappearance(element("dossier.person.correction.\(insuranceID)", in: app), timeout: 20, description: "reset exclusion")
            requireExists(element("dossier.person.member.\(insuranceID)", in: app), description: "restored automatic member")
            requireCompletePersonProjection(in: app, members: [anchorID, insuranceID, ocrID, invoiceID, paymentID, authorizationID], corrections: [authorizationID, conflictID])
            attachPersonScreenshot("Person decisions", in: app)
            XCTAssertEqual(try fixture.snapshot(), initialSnapshot)
        }

        terminateAndWait(app)
        let persisted = try SQLiteProbe(databaseURL: fixture.databaseURL).personDossierEvidence()
        XCTAssertEqual(persisted.sourceCount, 1)
        XCTAssertEqual(persisted.documentCount, 8)
        XCTAssertEqual(persisted.personAnchorCount, 1)
        XCTAssertEqual(persisted.personAnchorEvidenceCount, 2)
        XCTAssertEqual(persisted.personDossierCount, 1)
        XCTAssertEqual(persisted.costsDossierCount, 1)
        XCTAssertEqual(persisted.confirmationCount, 1)
        XCTAssertEqual(persisted.exclusionCount, 1)
        XCTAssertEqual(persisted.confirmedRelationshipCount, 1)
        XCTAssertEqual(persisted.originDocumentStillCatalogued, 1)
        XCTAssertEqual(try SQLiteProbe(databaseURL: fixture.databaseURL).personAnchorOriginDocumentID(), anchorID)
        XCTAssertEqual(try fixture.snapshot(), initialSnapshot)

        let restarted = launch(fixture: fixture, accessibilityText: true)
        let restoredRow = element("dossier.row.\(personDossierID)", in: restarted)
        requireExists(restoredRow, timeout: 20, description: "person dossier after restart")
        restoredRow.click()
        requireCompletePersonProjection(in: restarted, members: [anchorID, insuranceID, ocrID, invoiceID, paymentID, authorizationID], corrections: [authorizationID, conflictID])
        attachPersonScreenshot("Person projection after restart", in: restarted)
        XCTAssertEqual(try fixture.snapshot(), initialSnapshot)
        terminateAndWait(restarted)

        try SQLiteTestDatabaseMutator.makeDocumentDNAFailureRetryable(databaseURL: fixture.databaseURL, relativePath: "anchor-care.pdf")
        XCTAssertEqual(try fixture.snapshot(), initialSnapshot)
        let reanalyzed = launch(fixture: fixture, accessibilityText: true)
        let reanalyzedRow = element("dossier.row.\(personDossierID)", in: reanalyzed)
        requireExists(reanalyzedRow, timeout: 20, description: "person dossier before reanalysis")
        reanalyzedRow.click()
        requireExists(reanalyzed.staticTexts["Ursprungsnachweis veraltet"].firstMatch, description: "stale origin before retry")
        sourceRow(in: reanalyzed).click()
        let origin = element("documents.table", in: reanalyzed).staticTexts["anchor-care.pdf"].firstMatch
        requireExists(origin, description: "catalogued origin before retry")
        origin.click()
        let retry = reanalyzed.buttons["Erneut analysieren"].firstMatch
        requireExists(retry, timeout: 20, description: "retry failed anchor DNA")
        requireExists(reanalyzed.staticTexts["Document DNA nicht verfügbar"].firstMatch, description: "safe analysis failure title")
        requireExists(reanalyzed.staticTexts["Das Originaldokument bleibt unverändert."].firstMatch, description: "safe analysis failure explanation")
        XCTAssertEqual(try fixture.snapshot(), initialSnapshot)
        retry.click()
        requireDisappearance(retry, timeout: 60, description: "completed anchor reanalysis")
        closeInspector(byReselecting: reanalyzedRow, in: reanalyzed)
        requireCompletePersonProjection(in: reanalyzed, members: [anchorID, insuranceID, ocrID, invoiceID, paymentID, authorizationID], corrections: [authorizationID, conflictID])
        XCTAssertEqual(try fixture.snapshot(), initialSnapshot)

        sourceRow(in: reanalyzed).rightClick()
        let removeSource = reanalyzed.menuItems["Quelle entfernen"]
        requireExists(removeSource, description: "visible source removal")
        removeSource.click()
        requireDisappearance(sourceRow(in: reanalyzed), timeout: 20, description: "removed source")
        requireDisappearance(element("dossier.row.\(costsDossierID)", in: reanalyzed), timeout: 20, description: "removed costs dossier")
        requireExists(reanalyzedRow, description: "durable person dossier after source removal")
        requireExists(element("dossier.person.workspace", in: reanalyzed), description: "durable person workspace")
        requireExists(reanalyzed.staticTexts["Ursprungsnachweis nicht verfügbar"].firstMatch, description: "unavailable origin")
        requireCompletePersonProjection(in: reanalyzed, members: [], corrections: [])
        attachPersonScreenshot("Person projection with unavailable origin", in: reanalyzed)
        terminateAndWait(reanalyzed)
        let finalProbe = try SQLiteProbe(databaseURL: fixture.databaseURL)
        let removed = try finalProbe.personDossierEvidence()
        XCTAssertEqual(removed.sourceCount, 0)
        XCTAssertEqual(removed.documentCount, 0)
        XCTAssertEqual(removed.personAnchorCount, 1)
        XCTAssertEqual(removed.personAnchorEvidenceCount, 2)
        XCTAssertEqual(removed.personDossierCount, 1)
        XCTAssertEqual(removed.costsDossierCount, 0)
        XCTAssertEqual(removed.confirmationCount, 0)
        XCTAssertEqual(removed.exclusionCount, 0)
        XCTAssertEqual(removed.confirmedRelationshipCount, 0)
        XCTAssertEqual(removed.originDocumentStillCatalogued, 0)
        XCTAssertEqual(try finalProbe.personAnchorOriginDocumentID(), anchorID)
        let catalog = try finalProbe.collectEvidence()
        for count in [catalog.documentCount, catalog.extractionCount, catalog.extractedPageCount, catalog.ftsCount, catalog.dnaSnapshotCount, catalog.dnaFindingCount, catalog.dnaEvidenceCount, catalog.dnaAnalysisStateCount, catalog.invoicePaymentDecisionCount, catalog.dossierExclusionCount] {
            XCTAssertEqual(count, 0)
        }
        XCTAssertEqual(try fixture.snapshot(), initialSnapshot)
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

    func testPersonDossierFixtureIntegritySnapshotIncludesEveryEntryKind() throws {
        let fixture = try SmokeFixture.personDossier()
        self.fixture = fixture

        let snapshot = try fixture.snapshot()
        let entries = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.relativePath, $0) })

        let regularFiles = [
            "anchor-care.pdf",
            "invoices/care-home-invoice.pdf",
            "payments/payment-confirmation.pdf",
            "insurance.pdf",
            "power-of-attorney.pdf",
            "conflicting-insurance.pdf",
            "scan.png",
            "corrupt.pdf",
        ]
        for path in regularFiles {
            let entry = try XCTUnwrap(entries[path], "Missing fixture entry: \(path)")
            XCTAssertEqual(entry.kind, .regularFile, "Unexpected kind for \(path)")
            XCTAssertNotNil(entry.sha256, "Missing SHA-256 for \(path)")
            XCTAssertNotNil(entry.byteCount, "Missing byte count for \(path)")
            XCTAssertNotNil(entry.modificationDate, "Missing modification date for \(path)")
            XCTAssertNotEqual(entry.posixMode, -1, "Missing POSIX mode for \(path)")
        }

        XCTAssertEqual(entries["invoices"]?.kind, .directory)
        XCTAssertEqual(entries["payments"]?.kind, .directory)
        XCTAssertEqual(entries[".hidden-evidence"]?.kind, .regularFile)
        XCTAssertEqual(entries[".hidden-directory"]?.kind, .directory)
        XCTAssertEqual(entries["anchor-link"]?.kind, .symbolicLink)
        XCTAssertEqual(entries["anchor-link"]?.symbolicLinkDestination, "anchor-care.pdf")
        for entry in snapshot where entry.kind == .regularFile {
            XCTAssertNotNil(entry.sha256, "Missing SHA-256 for \(entry.relativePath)")
            XCTAssertNotNil(entry.byteCount, "Missing byte count for \(entry.relativePath)")
            XCTAssertNotNil(entry.modificationDate, "Missing modification date for \(entry.relativePath)")
            XCTAssertNotEqual(entry.posixMode, -1, "Missing POSIX mode for \(entry.relativePath)")
        }
        XCTAssertEqual(try fixture.snapshot(), snapshot)
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
    private func launch(fixture: SmokeFixture, failsStartupOnce: Bool = false, accessibilityText: Bool = false) -> XCUIApplication {
        let application = XCUIApplication()
        application.launchArguments = [
            "--linkloom-ui-test-database", fixture.databaseURL.path,
            "--linkloom-ui-test-source", fixture.sourceURL.path,
            "--linkloom-ui-test-disable-watcher",
        ]
        if failsStartupOnce {
            application.launchArguments.append("--linkloom-ui-test-fail-startup-once")
        }
        if accessibilityText {
            application.launchArguments.append("--linkloom-ui-test-accessibility-text")
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

    private func resizeWindow(_ window: XCUIElement, toWidth width: CGFloat) {
        requireExists(window, description: "application window for resize")
        let resizeHandle = window.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.99))
        let delta = width - window.frame.width
        resizeHandle.press(
            forDuration: 0.1,
            thenDragTo: resizeHandle.withOffset(CGVector(dx: delta, dy: 0))
        )
        XCTAssertEqual(window.frame.width, width, accuracy: 12, "window width")
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func sourceRow(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "source.row."))
            .firstMatch
    }

    private func requirePersonDossierMember(
        containing path: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        let candidates = app.buttons.matching(
            NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "identifier BEGINSWITH %@", "dossier.person.member."),
                NSPredicate(format: "identifier NOT CONTAINS %@", ".counterpart"),
                NSPredicate(format: "identifier NOT CONTAINS %@", ".remove"),
            ])
        ).allElementsBoundByIndex
        guard let member = candidates.first(where: { $0.label.contains(path) }) else {
            XCTFail("Missing person dossier member for \(path). Hierarchy:\n\(app.debugDescription)")
            return candidates.first ?? app.buttons.firstMatch
        }
        return member
    }

    private func requireDossierScrollView(
        containing workspace: XCUIElement,
        in app: XCUIApplication
    ) -> XCUIElement {
        let candidates = app.scrollViews.allElementsBoundByIndex
        guard let scrollView = candidates.first(where: {
            $0.frame.intersects(workspace.frame) && $0.frame.width >= 300
        }) else {
            XCTFail("Missing dossier scroll view. Hierarchy:\n\(app.debugDescription)")
            return app.scrollViews.firstMatch
        }
        return scrollView
    }

    private func closeInspector(
        byReselecting dossierRow: XCUIElement,
        in app: XCUIApplication
    ) {
        dossierRow.click()
        requireDisappearance(
            element("document-dna.inspector", in: app),
            timeout: 20,
            description: "document inspector after dossier reselection"
        )
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

    private func attachPersonScreenshot(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func requireCompletePersonProjection(in app: XCUIApplication, members: [String], corrections: [String]) {
        let memberRows = app.buttons.matching(NSPredicate(format: "identifier MATCHES %@", "dossier\\.person\\.member\\.[0-9a-f-]{36}"))
        let correctionRows = app.buttons.matching(NSPredicate(format: "identifier MATCHES %@", "dossier\\.person\\.correction\\.[0-9a-f-]{36}"))
        let suggestionRows = app.buttons.matching(NSPredicate(format: "identifier MATCHES %@", "dossier\\.person\\.suggestion\\.[0-9a-f-]{36}"))
        let expectedMembers = Set(members.map { "dossier.person.member.\($0)" })
        let expectedCorrections = Set(corrections.map { "dossier.person.correction.\($0)" })
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            Set(memberRows.allElementsBoundByIndex.map { $0.identifier }) == expectedMembers
                && Set(correctionRows.allElementsBoundByIndex.map { $0.identifier }) == expectedCorrections
                && suggestionRows.count == 0
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 60), .completed, "Incomplete person projection: \(app.debugDescription)")
    }

    private func requireKeyboardReachable(_ target: XCUIElement, in app: XCUIApplication) {
        requireExists(target, description: "keyboard target \(target.identifier)")
        let scroll = requireDossierScrollView(containing: element("dossier.person.workspace", in: app), in: app)
        requireHittable(target, scrollingIn: scroll, description: "keyboard target \(target.identifier)")
        let bound = app.buttons.allElementsBoundByIndex.filter { $0.isHittable }.count
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        for _ in 0..<max(1, bound) {
            app.typeKey(.tab, modifierFlags: [])
            let expectation = XCTNSPredicateExpectation(predicate: focused, object: target)
            if XCTWaiter.wait(for: [expectation], timeout: 0.2) == .completed { return }
        }
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = "Keyboard traversal failure"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTFail("\(target.identifier) was not keyboard reachable in \(bound) visible buttons")
    }

    private func requireContained(_ target: XCUIElement, scrollingIn scroll: XCUIElement, in app: XCUIApplication) {
        requireExists(target, description: "layout target \(target.identifier)")
        scrollVerticallyUntilVisible(target, in: scroll, description: target.identifier)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(target.frame), "Outside window: \(target.identifier), \(target.frame)")
        XCTAssertTrue(scroll.frame.contains(target.frame), "Outside viewport: \(target.identifier), \(target.frame)")
    }

    private func requirePersonSuggestionContained(_ id: String, in app: XCUIApplication) {
        requireCompletePersonRowContained(
            summary: element("dossier.person.suggestion.\(id)", in: app),
            actions: [
                element("dossier.person.suggestion.accept.\(id)", in: app),
                element("dossier.person.suggestion.reject.\(id)", in: app),
            ],
            in: app
        )
    }

    private func requirePersonCorrectionContained(_ id: String, in app: XCUIApplication) {
        requireCompletePersonRowContained(
            summary: element("dossier.person.correction.\(id)", in: app),
            actions: [element("dossier.person.correction.reset.\(id)", in: app)],
            in: app
        )
    }

    private func requireCompletePersonRowContained(
        summary: XCUIElement,
        actions: [XCUIElement],
        in app: XCUIApplication
    ) {
        let window = app.windows.firstMatch
        XCTAssertEqual(window.frame.width, 900, accuracy: 12, "Person row layout requires the minimum window width")
        let scroll = requireDossierScrollView(containing: element("dossier.person.workspace", in: app), in: app)
        let parts = [summary] + actions
        for part in parts { requireExists(part, description: "complete row component \(part.identifier)") }
        // The summary button encloses its path, role/status and all reason text.
        // Check the union at one scroll position so sequential scrolling cannot
        // conceal a clipped summary while making only its final action visible.
        for _ in 0..<12 {
            let bounds = parts.reduce(CGRect.null) { $0.union($1.frame) }
            if scroll.frame.contains(bounds) { break }
            scroll.scroll(byDeltaX: 0, deltaY: bounds.maxY > scroll.frame.maxY ? -180 : 180)
        }
        let bounds = parts.reduce(CGRect.null) { $0.union($1.frame) }
        XCTAssertTrue(window.frame.contains(bounds), "Complete row extends outside window: \(summary.identifier), \(bounds)")
        XCTAssertTrue(scroll.frame.contains(bounds), "Complete row extends outside viewport: \(summary.identifier), \(bounds)")
        for part in parts {
            XCTAssertTrue(scroll.frame.contains(part.frame), "Clipped row component: \(part.identifier)")
            XCTAssertTrue(part.isHittable, "Unreachable row component: \(part.identifier)")
        }
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

    private func waitForOnlyDossierID(
        fixture: SmokeFixture,
        kind: String,
        timeout: TimeInterval = 20
    ) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?
        repeat {
            do {
                return try SQLiteProbe(databaseURL: fixture.databaseURL).onlyDossierID(kind: kind)
            } catch {
                lastError = error
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
        } while Date() < deadline
        throw lastError ?? NSError(
            domain: "LinkLoomUITests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(kind) dossier"]
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
