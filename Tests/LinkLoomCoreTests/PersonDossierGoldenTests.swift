import Foundation
import Testing
@testable import LinkLoomCore

@Suite("Person dossier synthetic goldens")
struct PersonDossierGoldenTests {
    @Test func manifestCoversEveryRequiredSpecificationCase() throws {
        let manifest = try PersonDossierGoldenFixture.loadManifest()
        #expect(manifest.schemaVersion == 1)

        let expected: [(String, UUID, String, Bool, PersonDossierGoldenInitialClass)] = [
            ("D01", Self.id(1), "selected resident origin", true, .automatic),
            ("D02", Self.id(2), "insuredPerson", true, .automatic),
            ("D03", Self.id(3), "accountHolder", true, .automatic),
            ("D04", Self.id(4), "invoiceRecipient invoice A", true, .automatic),
            ("D05", Self.id(5), "grantor", true, .automatic),
            ("D06", Self.id(6), "OCR-backed resident invoice B", true, .automatic),
            ("D07", Self.id(7), "payment with no person finding, confirmed from D04 and D06", true, .automatic),
            ("D08", Self.id(8), "authorizedPerson only", true, .suggestion),
            ("D09", Self.id(9), "exact primary homonym with hard birth-date conflict", false, .suggestion),
            ("D10", Self.id(10), "accent variant", false, .hidden),
            ("D11", Self.id(11), "abbreviated name", false, .hidden),
            ("D12", Self.id(12), "partial name", false, .hidden),
            ("D13", Self.id(13), "unlabelled text occurrence", false, .hidden),
            ("D14", Self.id(14), "misleading organization/reference/filename/directory similarity", false, .hidden),
            ("D15", Self.id(15), "second-hop invoice/payment shape", false, .hidden),
        ]
        #expect(manifest.documents.count == expected.count)
        for (label, documentID, purpose, relevant, initialClass) in expected {
            let document = try #require(manifest.documents.first { $0.label == label })
            #expect(document.id == documentID)
            #expect(document.purpose == purpose)
            #expect(document.groundTruthRelevant == relevant)
            #expect(document.expectedInitialClass == initialClass)
        }
        for suffix in 1...6 {
            let document = try #require(manifest.documents.first { $0.id == Self.id(suffix) })
            #expect(document.membershipClass == .direct)
            #expect(document.expectedReasonCodes == [.exactPrimary])
            #expect(document.expectedAfterReject == .excluded)
            #expect(document.expectedAfterReset == .automatic)
        }
        let payment = try #require(manifest.documents.first { $0.label == "D07" })
        #expect(payment.membershipClass == .indirect)
        #expect(payment.expectedSection == .costsAndPayments)
        #expect(payment.expectedReasonCodes == [.confirmedPayment])
        #expect(payment.relationshipDecision == .confirmed)
        let secondary = try #require(manifest.documents.first { $0.label == "D08" })
        #expect(secondary.expectedReasonCodes == [.secondaryRole])
        #expect(secondary.expectedAfterAccept == .automatic)
        #expect(secondary.expectedAfterReset == .suggestion)
        #expect(manifest.documents.first { $0.label == "D09" }?.expectedReasonCodes
            == [.birthDateConflict])
        #expect(manifest.documents.first { $0.label == "D10" }?.expectedReasonCodes
            == [.unsupportedName])
        #expect(manifest.documents.first { $0.label == "D11" }?.expectedReasonCodes
            == [.unsupportedName])
        #expect(manifest.documents.first { $0.label == "D12" }?.expectedReasonCodes
            == [.unsupportedName])
        #expect(manifest.documents.first { $0.label == "D13" }?.expectedReasonCodes
            == [.unlabelledOccurrence])
        #expect(manifest.documents.first { $0.label == "D14" }?.expectedReasonCodes
            == [.misleadingMetadata])
        #expect(manifest.documents.first { $0.label == "D15" }?.expectedReasonCodes
            == [.secondHop])

        let requiredCases: Set<String> = [
            "five-primary-roles", "ocr-evidence", "no-person-payment",
            "relationship-undecided", "relationship-excluded", "secondary-role",
            "birth-date-conflict", "accent-boundary", "abbreviated-boundary",
            "partial-boundary", "unlabelled-boundary", "misleading-metadata",
            "second-hop", "multiple-confirmed-paths", "reanalysis-decisions",
            "origin-lifecycle", "member-availability-deletion",
        ]
        #expect(Set(manifest.specificationCases) == requiredCases)

        let requiredOverlays: Set<String> = [
            "relationship-undecided", "relationship-excluded", "accepted-secondary",
            "rejected-secondary", "corrected", "removed-primary",
            "reset-corrections", "reanalysis", "origin-stale",
            "origin-unavailable", "member-availability",
        ]
        #expect(Set(manifest.overlays.map(\.name)) == requiredOverlays)
        let reset = try #require(manifest.overlays.first { $0.name == "reset-corrections" })
        #expect(Set(reset.priorCorrectionRevisionIDs) == Set([
            Self.id(301), Self.id(307),
        ]))
    }

    @Test func allEvidenceRangesMatchSyntheticInput() throws {
        try PersonDossierGoldenFixture.verifyEvidence(
            in: PersonDossierGoldenFixture.loadManifest()
        )
    }

    @Test func declaredEvidenceRangesCannotDriftFromPersonFindings() throws {
        let manifest = try mutatedManifest { root in
            var documents = try #require(root["documents"] as? [[String: Any]])
            var document = documents[0]
            var expectedEvidence = try #require(
                document["expectedEvidence"] as? [[String: Any]]
            )
            expectedEvidence[0]["lengthUTF16"] = 11
            document["expectedEvidence"] = expectedEvidence
            documents[0] = document
            root["documents"] = documents
        }

        #expect(throws: PersonDossierGoldenFixtureError.invalidManifest) {
            try PersonDossierGoldenFixture.verifyEvidence(in: manifest)
        }
    }

    @Test func copiedDossierAnchorCannotDriftFromTopLevelAnchor() throws {
        let manifest = try mutatedManifest { root in
            var dossier = try #require(root["dossier"] as? [String: Any])
            var anchor = try #require(dossier["anchor"] as? [String: Any])
            var person = try #require(anchor["person"] as? [String: Any])
            person["displayName"] = "Lina Fontana Copy"
            anchor["person"] = person
            dossier["anchor"] = anchor
            root["dossier"] = dossier
        }

        #expect(throws: PersonDossierGoldenFixtureError.invalidManifest) {
            try PersonDossierGoldenFixture.verifyEvidence(in: manifest)
        }
    }

    @Test func snapshotResourcesEncodeEveryPublicField() throws {
        let manifest = try PersonDossierGoldenFixture.loadManifest()
        let resources = Set(
            PersonDossierGoldenFixture.scenarioResources(in: manifest).map(\.resource)
        )
        for resource in resources {
            let value = try JSONSerialization.jsonObject(
                with: PersonDossierGoldenFixture.expectedSnapshotData(named: resource)
            )
            let root = try #require(value as? [String: Any])
            #expect(Set(root.keys) == Set([
                "dossier", "anchor", "origin", "directMembers", "costsAndPayments",
                "suggestions", "corrections", "token",
            ]))
            let origin = try #require(root["origin"] as? [String: Any])
            #expect(Set(origin.keys) == Set(["validity", "document", "sourceDisplayName"]))
            assertCompleteOptionalFields(in: root, resource: resource)
        }
    }

    @Test func completeVersionedSnapshotsMatch() throws {
        let manifest = try PersonDossierGoldenFixture.loadManifest()
        for item in PersonDossierGoldenFixture.scenarioResources(in: manifest) {
            let actual = try PersonDossierProjector().project(
                PersonDossierGoldenFixture.input(
                    manifest: manifest,
                    scenario: item.scenario
                )
            )
            let expected = try PersonDossierGoldenFixture.loadExpectedSnapshot(
                named: item.resource
            )
            #expect(actual == expected, "Complete snapshot mismatch for \(item.scenario)")
        }
    }

    @Test func baselineProjectsAllRequiredDirectAndIndirectCases() throws {
        let manifest = try PersonDossierGoldenFixture.loadManifest()
        let snapshot = try project(PersonDossierGoldenFixture.baselineScenario, manifest)
        let memberIDs = Set((snapshot.directMembers + snapshot.costsAndPayments).map(\.id))
        #expect(memberIDs == Set((1...7).map(Self.id)))
        #expect(snapshot.suggestions.map(\.id) == [Self.id(8), Self.id(9)])
        #expect(manifest.documents.first { $0.label == "D07" }?.dna?.findings.contains {
            $0.kind == .person
        } == false)

        let roles = Set((snapshot.directMembers + snapshot.costsAndPayments).flatMap {
            $0.supports.compactMap { support -> PersonDossierRole? in
                guard case let .exactPrimary(value) = support else { return nil }
                return value.role
            }
        })
        #expect(roles == Set([
            .resident, .insuredPerson, .accountHolder, .invoiceRecipient, .grantor,
        ]))

        let payment = try #require(snapshot.costsAndPayments.first { $0.id == Self.id(7) })
        #expect(payment.supports.count == 2)
        #expect(payment.preferredPaymentSupport?.invoiceDocumentID == Self.id(4))
        #expect(!memberIDs.contains(Self.id(15)))
    }

    @Test func decisionOverlaysRemainAuthoritativeAndKeepOneDenominator() throws {
        let manifest = try PersonDossierGoldenFixture.loadManifest()
        #expect(Set(manifest.metricLabels.relevantDocumentIDs) == Set((1...8).map(Self.id)))

        let accepted = try project("accepted-secondary", manifest)
        let acceptedMember = try #require(accepted.directMembers.first { $0.id == Self.id(8) })
        #expect(acceptedMember.isConfirmationAuthoritative)
        #expect(accepted.corrections.contains { $0.id == Self.id(8) })

        let rejected = try project("rejected-secondary", manifest)
        #expect(!rejected.directMembers.contains { $0.id == Self.id(8) })
        #expect(rejected.corrections.contains { correction in
            guard correction.id == Self.id(8), case .exclusion = correction.decision else {
                return false
            }
            return true
        })

        let corrected = try project("corrected", manifest)
        #expect(Set((corrected.directMembers + corrected.costsAndPayments).map(\.id))
            == Set(manifest.metricLabels.relevantDocumentIDs))
        #expect(corrected.suggestions.isEmpty)

        let removed = try project("removed-primary", manifest)
        #expect(!removed.directMembers.contains { $0.id == Self.id(2) })
        #expect(removed.corrections.contains { $0.id == Self.id(2) })

        let reset = try project("reset-corrections", manifest)
        #expect(reset.directMembers.contains { $0.id == Self.id(2) })
        #expect(reset.suggestions.contains { $0.id == Self.id(8) })
        #expect(reset.corrections.isEmpty)

        let reanalysis = try project("reanalysis", manifest)
        let reanalyzedMember = try #require(reanalysis.directMembers.first {
            $0.id == Self.id(8)
        })
        #expect(reanalyzedMember.isConfirmationAuthoritative)
        #expect(reanalyzedMember.supports.contains { support in
            guard case let .manualConfirmation(_, currentCandidate) = support else {
                return false
            }
            return currentCandidate == nil
        })
        #expect(!reanalysis.directMembers.contains { $0.id == Self.id(2) })
        #expect(Set(reanalysis.corrections.map(\.id)) == Set([Self.id(2), Self.id(8)]))
    }

    @Test func relationshipAbsenceSnapshotRequiresExactDistinctDecisionStates() throws {
        let manifest = try PersonDossierGoldenFixture.loadManifest()
        let expectedKeys: Set<InvoicePaymentDecisionKey> = try Set([
            InvoicePaymentDecisionKey(
                relationshipType: .paymentSettlesInvoice,
                invoiceDocumentID: Self.id(4),
                paymentDocumentID: Self.id(7),
                invoiceContentHash: "synthetic-hash-d04",
                paymentContentHash: "synthetic-hash-d07"
            ),
            InvoicePaymentDecisionKey(
                relationshipType: .paymentSettlesInvoice,
                invoiceDocumentID: Self.id(6),
                paymentDocumentID: Self.id(7),
                invoiceContentHash: "synthetic-hash-d06",
                paymentContentHash: "synthetic-hash-d07"
            ),
            InvoicePaymentDecisionKey(
                relationshipType: .paymentSettlesInvoice,
                invoiceDocumentID: Self.id(15),
                paymentDocumentID: Self.id(7),
                invoiceContentHash: "synthetic-hash-d15",
                paymentContentHash: "synthetic-hash-d07"
            ),
        ])
        let undecided = try PersonDossierGoldenFixture.input(
            manifest: manifest,
            scenario: "relationship-undecided"
        )
        let excluded = try PersonDossierGoldenFixture.input(
            manifest: manifest,
            scenario: "relationship-excluded"
        )

        #expect(undecided.relationshipDecisionsByKey.isEmpty)
        #expect(Set(excluded.relationshipDecisionsByKey.keys) == expectedKeys)
        #expect(excluded.relationshipDecisionsByKey.allSatisfy { key, value in
            value.key == key && value.decision == .excluded
        })

        let expected = try PersonDossierGoldenFixture.loadExpectedSnapshot(
            named: "relationship-absent-snapshot"
        )
        #expect(try PersonDossierProjector().project(undecided) == expected)
        #expect(try PersonDossierProjector().project(excluded) == expected)
    }

    @Test func originAndAvailabilityOverlaysPreserveTheDossier() throws {
        let manifest = try PersonDossierGoldenFixture.loadManifest()
        let stale = try project("origin-stale", manifest)
        #expect(stale.origin.validity == .stale)
        #expect(stale.origin.document?.id == Self.id(1))

        let unavailable = try project("origin-unavailable", manifest)
        #expect(unavailable.origin.validity == .unavailable)
        #expect(unavailable.origin.document == nil)
        #expect(unavailable.dossier.id == manifest.dossier.id)

        let availability = try project("member-availability", manifest)
        let members = availability.directMembers + availability.costsAndPayments
        #expect(members.first { $0.id == Self.id(1) }?.document.availability == .available)
        #expect(members.first { $0.id == Self.id(2) }?.document.availability == .unavailable)
        #expect(members.first { $0.id == Self.id(3) }?.document.availability == .missing)
        #expect(!members.contains { $0.id == Self.id(5) })
        #expect(!availability.suggestions.contains { $0.id == Self.id(5) })
        #expect(!availability.corrections.contains { $0.id == Self.id(5) })
    }

    private func project(
        _ scenario: String,
        _ manifest: PersonDossierGoldenManifest
    ) throws -> PersonDossierSnapshot {
        try PersonDossierProjector().project(
            PersonDossierGoldenFixture.input(manifest: manifest, scenario: scenario)
        )
    }

    private func assertCompleteOptionalFields(in value: Any, resource: String) {
        if let array = value as? [Any] {
            for child in array { assertCompleteOptionalFields(in: child, resource: resource) }
            return
        }
        guard let object = value as? [String: Any] else { return }
        let keys = Set(object.keys)
        if keys.isSuperset(of: ["id", "sourceRootID", "relativePath", "contentHash", "byteCount"]) {
            #expect(keys.contains("failureCode"), "Missing DocumentRecord.failureCode in \(resource)")
            #expect(keys.contains("pageCount"), "Missing DocumentRecord.pageCount in \(resource)")
            #expect(keys.contains("lastFingerprintAt"), "Missing DocumentRecord.lastFingerprintAt in \(resource)")
        }
        if keys.isSuperset(of: ["kind", "displayValue", "normalizedValue", "confidence", "evidence"]) {
            #expect(keys.contains("qualifier"), "Missing finding qualifier in \(resource)")
            #expect(keys.contains("secondaryNormalizedValue"), "Missing finding secondary value in \(resource)")
        }
        if keys.contains("validity") && keys.contains("sourceDisplayName") {
            #expect(keys.contains("document"), "Missing origin document in \(resource)")
        }
        if keys.isSuperset(of: ["document", "sourceDisplayName", "section", "supports"]) {
            #expect(keys.contains("documentType"), "Missing member documentType in \(resource)")
            #expect(keys.contains("preferredPaymentSupport"), "Missing preferred payment support in \(resource)")
        }
        if object["type"] as? String == "manualConfirmation" {
            #expect(keys.contains("currentCandidate"), "Missing current candidate in \(resource)")
        }
        for child in object.values {
            assertCompleteOptionalFields(in: child, resource: resource)
        }
    }

    private func mutatedManifest(
        _ mutate: (inout [String: Any]) throws -> Void
    ) throws -> PersonDossierGoldenManifest {
        let url = Bundle.module.url(
            forResource: "manifest",
            withExtension: "json",
            subdirectory: "PersonDossier/v1"
        ) ?? Bundle.module.url(forResource: "manifest", withExtension: "json")
        let resource = try #require(url)
        var root = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: resource))
                as? [String: Any]
        )
        try mutate(&root)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            PersonDossierGoldenManifest.self,
            from: JSONSerialization.data(withJSONObject: root)
        )
    }

    private static func id(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "83000000-0000-0000-0000-%012d", suffix))!
    }
}
