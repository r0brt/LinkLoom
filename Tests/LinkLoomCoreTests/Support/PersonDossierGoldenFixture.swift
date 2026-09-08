import Foundation
import Testing
@testable import LinkLoomCore

extension DossierKind: Codable {}
extension PersonDossierRole: Codable {}
extension PersonDossierCandidateKind: Codable {}
extension PersonDossierSection: Codable {}
extension PersonDossierOriginEvidenceValidity: Codable {}
extension DocumentRelationshipType: Codable {}
extension InvoicePaymentUserDecision: Codable {}
extension InvoicePaymentCandidateDisposition: Codable {}
extension InvoicePaymentCandidateSignalKind: Codable {}

enum PersonDossierGoldenMembershipClass: String, Decodable, Sendable {
    case direct
    case indirect
    case none
}

enum PersonDossierGoldenInitialClass: String, Decodable, Sendable {
    case automatic
    case suggestion
    case hidden
}

enum PersonDossierGoldenExpectedState: String, Decodable, Sendable {
    case automatic
    case suggestion
    case excluded
    case hidden
}

enum PersonDossierGoldenReasonCode: String, Decodable, Sendable {
    case exactPrimary
    case confirmedPayment
    case secondaryRole
    case birthDateConflict
    case unsupportedName
    case unlabelledOccurrence
    case misleadingMetadata
    case secondHop
}

enum PersonDossierGoldenSection: String, Decodable, Sendable {
    case directDocuments
    case costsAndPayments
}

enum PersonDossierGoldenRelationshipDecision: String, Decodable, Sendable {
    case confirmed
    case excluded
}

struct PersonDossierGoldenEvidenceRange: Decodable, Equatable, Sendable {
    let pageIndex: Int
    let startUTF16: Int
    let lengthUTF16: Int
}

struct PersonDossierGoldenDocumentManifest: Decodable, Sendable {
    let label: String
    let id: UUID
    let purpose: String
    let relativePath: String
    let groundTruthRelevant: Bool
    let membershipClass: PersonDossierGoldenMembershipClass
    let expectedInitialClass: PersonDossierGoldenInitialClass
    let expectedSection: PersonDossierGoldenSection?
    let expectedReasonCodes: [PersonDossierGoldenReasonCode]
    let expectedEvidence: [PersonDossierGoldenEvidenceRange]
    let relationshipDecision: PersonDossierGoldenRelationshipDecision?
    let expectedAfterAccept: PersonDossierGoldenExpectedState
    let expectedAfterReject: PersonDossierGoldenExpectedState
    let expectedAfterRemove: PersonDossierGoldenExpectedState
    let expectedAfterReset: PersonDossierGoldenExpectedState
    let extractionMethod: ExtractionMethod
    let pages: [PersonDossierGoldenPage]
    let record: DocumentRecord
    let dna: DocumentDNA?
}

struct PersonDossierGoldenPage: Decodable, Sendable {
    let pageIndex: Int
    let text: String
    let regions: [PersonDossierGoldenRegion]
}

struct PersonDossierGoldenRegion: Decodable, Sendable {
    let text: String
    let confidence: Float
    let boundingBox: PersonDossierGoldenBoundingBox
}

struct PersonDossierGoldenBoundingBox: Decodable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct PersonDossierGoldenSourceRoot: Decodable, Sendable {
    let id: UUID
    let displayName: String
    let pathHint: String
}

struct PersonDossierGoldenRelationship: Decodable, Sendable {
    let name: String
    let invoiceDocumentID: UUID
    let paymentDocumentID: UUID
    let normalizedReference: String
    let disposition: InvoicePaymentCandidateDisposition
    let resolverVersion: String
}

struct PersonDossierGoldenRelationshipDecisionRecord: Decodable, Sendable {
    let relationshipName: String
    let decision: InvoicePaymentUserDecision
    let updatedAt: Date
}

enum PersonDossierGoldenRelationshipMode: String, Decodable, Sendable {
    case baseline
    case undecided
    case excluded
}

enum PersonDossierGoldenOriginMode: String, Decodable, Sendable {
    case current
    case stale
    case unavailable
}

struct PersonDossierGoldenReanalysis: Decodable, Sendable {
    let documentID: UUID
    let contentHash: String
    let extractionVersion: String
    let analyzedAt: Date
}

struct PersonDossierGoldenAvailabilityChange: Decodable, Sendable {
    let documentID: UUID
    let availability: DocumentAvailability
}

struct PersonDossierGoldenOverlay: Decodable, Sendable {
    let name: String
    let expectedSnapshot: String
    let relationshipMode: PersonDossierGoldenRelationshipMode
    let originMode: PersonDossierGoldenOriginMode
    let confirmations: [DossierMembershipConfirmation]
    let exclusions: [DossierMembershipExclusion]
    let reanalysis: [PersonDossierGoldenReanalysis]
    let availabilityChanges: [PersonDossierGoldenAvailabilityChange]
    let deletedDocumentIDs: [UUID]
    let priorCorrectionRevisionIDs: [UUID]
}

struct PersonDossierGoldenMetricLabels: Decodable, Sendable {
    let relevantDocumentIDs: [UUID]
    let automaticDocumentIDs: [UUID]
    let suggestionDocumentIDs: [UUID]
    let hiddenDocumentIDs: [UUID]
}

struct PersonDossierGoldenManifest: Decodable, Sendable {
    let schemaVersion: Int
    let sourceRoots: [PersonDossierGoldenSourceRoot]
    let dossier: DossierRecord
    let anchor: PersonDossierAnchor
    let documents: [PersonDossierGoldenDocumentManifest]
    let relationships: [PersonDossierGoldenRelationship]
    let baselineRelationshipDecisions: [PersonDossierGoldenRelationshipDecisionRecord]
    let baselineConfirmations: [DossierMembershipConfirmation]
    let baselineExclusions: [DossierMembershipExclusion]
    let metricLabels: PersonDossierGoldenMetricLabels
    let specificationCases: [String]
    let overlays: [PersonDossierGoldenOverlay]
}

enum PersonDossierGoldenFixture {
    static let baselineScenario = "baseline"

    static func loadManifest() throws -> PersonDossierGoldenManifest {
        let url = Bundle.module.url(
            forResource: "manifest",
            withExtension: "json",
            subdirectory: "PersonDossier/v1"
        ) ?? Bundle.module.url(forResource: "manifest", withExtension: "json")
        guard let url else {
            throw PersonDossierGoldenFixtureError.missingResource(
                "PersonDossier/v1/manifest.json"
            )
        }
        return try decoder.decode(
            PersonDossierGoldenManifest.self,
            from: Data(contentsOf: url)
        )
    }

    static func loadExpectedSnapshot(named resource: String) throws -> PersonDossierSnapshot {
        try decoder.decode(
            PersonDossierSnapshot.self,
            from: expectedSnapshotData(named: resource)
        )
    }

    static func expectedSnapshotData(named resource: String) throws -> Data {
        let url = Bundle.module.url(
            forResource: resource,
            withExtension: "json",
            subdirectory: "PersonDossier/v1"
        ) ?? Bundle.module.url(forResource: resource, withExtension: "json")
        guard let url else {
            throw PersonDossierGoldenFixtureError.missingResource(
                "PersonDossier/v1/\(resource).json"
            )
        }
        return try Data(contentsOf: url)
    }

    static func input(
        manifest: PersonDossierGoldenManifest,
        scenario: String
    ) throws -> PersonDossierProjectionInput {
        let overlay = scenario == baselineScenario
            ? nil
            : try manifest.overlays.first { $0.name == scenario }
                .unwrap(or: PersonDossierGoldenFixtureError.unknownOverlay(scenario))

        var documentsByID = Dictionary(
            uniqueKeysWithValues: manifest.documents.map { ($0.id, $0.record) }
        )
        var currentDocumentsByID: [UUID: CurrentDocumentDNA] = try Dictionary(
            uniqueKeysWithValues: manifest.documents.compactMap { document -> (UUID, CurrentDocumentDNA)? in
                guard let dna = document.dna else { return nil }
                return (document.id, try CurrentDocumentDNA(document: document.record, snapshot: dna))
            }
        )

        for change in overlay?.availabilityChanges ?? [] {
            guard var document = documentsByID[change.documentID],
                  let current = currentDocumentsByID[change.documentID]
            else { throw PersonDossierGoldenFixtureError.invalidManifest }
            document.availability = change.availability
            documentsByID[change.documentID] = document
            currentDocumentsByID[change.documentID] = try CurrentDocumentDNA(
                document: document,
                snapshot: current.snapshot
            )
        }

        for change in overlay?.reanalysis ?? [] {
            guard var document = documentsByID[change.documentID],
                  let current = currentDocumentsByID[change.documentID]
            else { throw PersonDossierGoldenFixtureError.invalidManifest }
            document.contentHash = change.contentHash
            let snapshot = try DocumentDNA(
                documentID: document.id,
                schemaVersion: current.snapshot.schemaVersion,
                analyzerIdentifier: current.snapshot.analyzerIdentifier,
                analyzerVersion: current.snapshot.analyzerVersion,
                inputContentHash: change.contentHash,
                inputExtractionVersion: change.extractionVersion,
                findings: current.snapshot.findings,
                analyzedAt: change.analyzedAt
            )
            documentsByID[document.id] = document
            currentDocumentsByID[document.id] = try CurrentDocumentDNA(
                document: document,
                snapshot: snapshot
            )
        }

        for documentID in overlay?.deletedDocumentIDs ?? [] {
            documentsByID.removeValue(forKey: documentID)
            currentDocumentsByID.removeValue(forKey: documentID)
        }
        if overlay?.originMode == .unavailable {
            documentsByID.removeValue(forKey: manifest.anchor.originDocumentID)
            currentDocumentsByID.removeValue(forKey: manifest.anchor.originDocumentID)
        }

        let relationshipCandidates: [InvoicePaymentCandidate] = try manifest.relationships.compactMap { relationship -> InvoicePaymentCandidate? in
            guard let invoice = currentDocumentsByID[relationship.invoiceDocumentID],
                  let payment = currentDocumentsByID[relationship.paymentDocumentID]
            else { return nil }
            guard let resolved = InvoicePaymentCandidateResolver().candidates(
                matching: relationship.normalizedReference,
                in: [invoice, payment]
            ).first else { throw PersonDossierGoldenFixtureError.invalidManifest }
            return InvoicePaymentCandidate(
                invoice: invoice,
                payment: payment,
                disposition: relationship.disposition,
                resolverVersion: relationship.resolverVersion,
                signals: resolved.signals
            )
        }
        let relationshipMode = overlay?.relationshipMode ?? .baseline
        let decisions: [(InvoicePaymentDecisionKey, InvoicePaymentDecisionRecord)]
        switch relationshipMode {
        case .undecided:
            decisions = []
        case .baseline, .excluded:
            decisions = try manifest.baselineRelationshipDecisions.compactMap { stored in
                guard let relationship = manifest.relationships.first(where: {
                    $0.name == stored.relationshipName
                }), let candidate = relationshipCandidates.first(where: {
                    $0.invoice.document.id == relationship.invoiceDocumentID
                        && $0.payment.document.id == relationship.paymentDocumentID
                }) else { return nil }
                let key = try InvoicePaymentDecisionKey(candidate: candidate)
                let decision: InvoicePaymentUserDecision = relationshipMode == .excluded
                    ? .excluded
                    : stored.decision
                return (key, InvoicePaymentDecisionRecord(
                    key: key,
                    decision: decision,
                    updatedAt: stored.updatedAt
                ))
            }
        }

        let originDocument = documentsByID[manifest.anchor.originDocumentID]
        let currentOrigin: CurrentDocumentDNA?
        switch overlay?.originMode ?? .current {
        case .current:
            currentOrigin = currentDocumentsByID[manifest.anchor.originDocumentID]
        case .stale:
            guard let current = currentDocumentsByID[manifest.anchor.originDocumentID] else {
                throw PersonDossierGoldenFixtureError.invalidManifest
            }
            let staleSnapshot = try DocumentDNA(
                documentID: current.snapshot.documentID,
                schemaVersion: current.snapshot.schemaVersion,
                analyzerIdentifier: current.snapshot.analyzerIdentifier,
                analyzerVersion: current.snapshot.analyzerVersion,
                inputContentHash: current.snapshot.inputContentHash,
                inputExtractionVersion: "text-v2",
                findings: current.snapshot.findings,
                analyzedAt: current.snapshot.analyzedAt
            )
            let stale = try CurrentDocumentDNA(document: current.document, snapshot: staleSnapshot)
            currentDocumentsByID[current.document.id] = stale
            currentOrigin = stale
        case .unavailable:
            currentOrigin = nil
        }

        return PersonDossierProjectionInput(
            dossier: manifest.dossier,
            originDocument: originDocument,
            currentOrigin: currentOrigin,
            documentsByID: documentsByID,
            currentDocumentsByID: currentDocumentsByID,
            personCandidates: currentDocumentsByID.values.sorted {
                $0.document.id.uuidString < $1.document.id.uuidString
            },
            relationshipCandidates: relationshipCandidates,
            relationshipDecisionsByKey: Dictionary(uniqueKeysWithValues: decisions),
            sourceDisplayNames: Dictionary(uniqueKeysWithValues: manifest.sourceRoots.map {
                ($0.id, $0.displayName)
            }),
            confirmations: overlay?.confirmations ?? manifest.baselineConfirmations,
            exclusions: overlay?.exclusions ?? manifest.baselineExclusions
        )
    }

    static func scenarioResources(
        in manifest: PersonDossierGoldenManifest
    ) -> [(scenario: String, resource: String)] {
        [(baselineScenario, "baseline-snapshot")] + manifest.overlays.map {
            ($0.name, $0.expectedSnapshot)
        }
    }

    static func verifyEvidence(in manifest: PersonDossierGoldenManifest) throws {
        let documentsByID = Dictionary(uniqueKeysWithValues: manifest.documents.map {
            ($0.id, $0)
        })
        for document in manifest.documents {
            guard document.id == document.record.id,
                  document.relativePath == document.record.relativePath,
                  document.dna?.documentID == document.id
            else { throw PersonDossierGoldenFixtureError.invalidManifest }
            let pages = Dictionary(uniqueKeysWithValues: document.pages.map {
                ($0.pageIndex, $0)
            })
            for finding in document.dna?.findings ?? [] {
                try verify(
                    evidence: finding.evidence,
                    pages: pages,
                    isOCR: document.extractionMethod != .embeddedPDFText,
                    label: document.label
                )
            }
        }
        guard let origin = documentsByID[manifest.anchor.originDocumentID] else {
            throw PersonDossierGoldenFixtureError.invalidManifest
        }
        let originPages = Dictionary(uniqueKeysWithValues: origin.pages.map {
            ($0.pageIndex, $0)
        })
        try verify(
            evidence: manifest.anchor.personEvidence,
            pages: originPages,
            isOCR: origin.extractionMethod != .embeddedPDFText,
            label: "anchor"
        )
        if let birthDate = manifest.anchor.birthDate {
            try verify(
                evidence: birthDate.evidence,
                pages: originPages,
                isOCR: origin.extractionMethod != .embeddedPDFText,
                label: "anchor birth date"
            )
        }
        guard let ocr = manifest.documents.first(where: { $0.label == "D06" }),
              ocr.extractionMethod != .embeddedPDFText,
              ocr.dna?.findings.flatMap(\.evidence).contains(where: {
                  !$0.ocrRegionIndexes.isEmpty
              }) == true
        else { throw PersonDossierGoldenFixtureError.invalidManifest }
    }

    private static func verify(
        evidence: [DocumentDNAEvidence],
        pages: [Int: PersonDossierGoldenPage],
        isOCR: Bool,
        label: String
    ) throws {
        for value in evidence {
            guard let page = pages[value.pageIndex] else {
                Issue.record("Missing evidence page for \(label)")
                throw PersonDossierGoldenFixtureError.invalidEvidence
            }
            let source = page.text as NSString
            let range = NSRange(location: value.startUTF16, length: value.lengthUTF16)
            #expect(NSMaxRange(range) <= source.length, "Out-of-range evidence for \(label)")
            guard NSMaxRange(range) <= source.length else {
                throw PersonDossierGoldenFixtureError.invalidEvidence
            }
            #expect(source.substring(with: range) == value.exactText)
            #expect(value.ocrRegionIndexes.allSatisfy { page.regions.indices.contains($0) })
            if !isOCR { #expect(value.ocrRegionIndexes.isEmpty) }
        }
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum PersonDossierGoldenFixtureError: Error, Equatable {
    case missingResource(String)
    case unknownOverlay(String)
    case invalidManifest
    case invalidEvidence
}

private extension Optional {
    func unwrap(or error: @autoclosure () -> any Error) throws -> Wrapped {
        guard let self else { throw error() }
        return self
    }
}

extension DossierAnchor: Codable {
    private enum CodingKeys: String, CodingKey { case type, documentID, person }
    private enum Kind: String, Codable { case document, person }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .type) {
        case .document:
            self = .document(try values.decode(UUID.self, forKey: .documentID))
        case .person:
            self = .person(try values.decode(PersonDossierAnchor.self, forKey: .person))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .document(id):
            try values.encode(Kind.document, forKey: .type)
            try values.encode(id, forKey: .documentID)
        case let .person(anchor):
            try values.encode(Kind.person, forKey: .type)
            try values.encode(anchor, forKey: .person)
        }
    }
}

extension DossierRecord: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, kind, displayName, anchor, createdAt, updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(UUID.self, forKey: .id),
            kind: values.decode(DossierKind.self, forKey: .kind),
            displayName: values.decode(String.self, forKey: .displayName),
            anchor: values.decode(DossierAnchor.self, forKey: .anchor),
            createdAt: values.decode(Date.self, forKey: .createdAt),
            updatedAt: values.decode(Date.self, forKey: .updatedAt)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(kind, forKey: .kind)
        try values.encode(displayName, forKey: .displayName)
        try values.encode(anchor, forKey: .anchor)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(updatedAt, forKey: .updatedAt)
    }
}

extension PersonDossierBirthDate: Codable {
    private enum CodingKeys: String, CodingKey {
        case displayValue, normalizedValue, evidence
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            displayValue: values.decode(String.self, forKey: .displayValue),
            normalizedValue: values.decode(String.self, forKey: .normalizedValue),
            evidence: values.decode([DocumentDNAEvidence].self, forKey: .evidence)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(displayValue, forKey: .displayValue)
        try values.encode(normalizedValue, forKey: .normalizedValue)
        try values.encode(evidence, forKey: .evidence)
    }
}

extension PersonDossierAnchor: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, displayName, normalizedName, primaryRole, originDocumentID
        case originContentHash, originExtractionVersion, originDNASchemaVersion
        case originDNAAnalyzerIdentifier, originDNAAnalyzerVersion, originDNAAnalyzedAt
        case personEvidence, birthDate, createdAt, updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(UUID.self, forKey: .id),
            displayName: values.decode(String.self, forKey: .displayName),
            normalizedName: values.decode(String.self, forKey: .normalizedName),
            primaryRole: values.decode(PersonDossierRole.self, forKey: .primaryRole),
            originDocumentID: values.decode(UUID.self, forKey: .originDocumentID),
            originContentHash: values.decode(String.self, forKey: .originContentHash),
            originExtractionVersion: values.decode(String.self, forKey: .originExtractionVersion),
            originDNASchemaVersion: values.decode(Int.self, forKey: .originDNASchemaVersion),
            originDNAAnalyzerIdentifier: values.decode(String.self, forKey: .originDNAAnalyzerIdentifier),
            originDNAAnalyzerVersion: values.decode(String.self, forKey: .originDNAAnalyzerVersion),
            originDNAAnalyzedAt: values.decode(Date.self, forKey: .originDNAAnalyzedAt),
            personEvidence: values.decode([DocumentDNAEvidence].self, forKey: .personEvidence),
            birthDate: values.decodeIfPresent(PersonDossierBirthDate.self, forKey: .birthDate),
            createdAt: values.decode(Date.self, forKey: .createdAt),
            updatedAt: values.decode(Date.self, forKey: .updatedAt)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(displayName, forKey: .displayName)
        try values.encode(normalizedName, forKey: .normalizedName)
        try values.encode(primaryRole, forKey: .primaryRole)
        try values.encode(originDocumentID, forKey: .originDocumentID)
        try values.encode(originContentHash, forKey: .originContentHash)
        try values.encode(originExtractionVersion, forKey: .originExtractionVersion)
        try values.encode(originDNASchemaVersion, forKey: .originDNASchemaVersion)
        try values.encode(originDNAAnalyzerIdentifier, forKey: .originDNAAnalyzerIdentifier)
        try values.encode(originDNAAnalyzerVersion, forKey: .originDNAAnalyzerVersion)
        try values.encode(originDNAAnalyzedAt, forKey: .originDNAAnalyzedAt)
        try values.encode(personEvidence, forKey: .personEvidence)
        try values.encodeIfPresent(birthDate, forKey: .birthDate)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(updatedAt, forKey: .updatedAt)
    }
}

extension DossierMembershipConfirmation: Codable {
    private enum CodingKeys: String, CodingKey {
        case dossierID, documentID, revisionID, confirmedAt, candidateKind
        case acceptedContentHash, acceptedExtractionVersion, acceptedDNASchemaVersion
        case acceptedDNAAnalyzerIdentifier, acceptedDNAAnalyzerVersion, acceptedDNAAnalyzedAt
        case acceptedRole, acceptedNormalizedName
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            dossierID: values.decode(UUID.self, forKey: .dossierID),
            documentID: values.decode(UUID.self, forKey: .documentID),
            revisionID: values.decode(UUID.self, forKey: .revisionID),
            confirmedAt: values.decode(Date.self, forKey: .confirmedAt),
            candidateKind: values.decode(PersonDossierCandidateKind.self, forKey: .candidateKind),
            acceptedContentHash: values.decode(String.self, forKey: .acceptedContentHash),
            acceptedExtractionVersion: values.decode(String.self, forKey: .acceptedExtractionVersion),
            acceptedDNASchemaVersion: values.decode(Int.self, forKey: .acceptedDNASchemaVersion),
            acceptedDNAAnalyzerIdentifier: values.decode(String.self, forKey: .acceptedDNAAnalyzerIdentifier),
            acceptedDNAAnalyzerVersion: values.decode(String.self, forKey: .acceptedDNAAnalyzerVersion),
            acceptedDNAAnalyzedAt: values.decode(Date.self, forKey: .acceptedDNAAnalyzedAt),
            acceptedRole: values.decode(PersonDossierRole.self, forKey: .acceptedRole),
            acceptedNormalizedName: values.decode(String.self, forKey: .acceptedNormalizedName)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(dossierID, forKey: .dossierID)
        try values.encode(documentID, forKey: .documentID)
        try values.encode(revisionID, forKey: .revisionID)
        try values.encode(confirmedAt, forKey: .confirmedAt)
        try values.encode(candidateKind, forKey: .candidateKind)
        try values.encode(acceptedContentHash, forKey: .acceptedContentHash)
        try values.encode(acceptedExtractionVersion, forKey: .acceptedExtractionVersion)
        try values.encode(acceptedDNASchemaVersion, forKey: .acceptedDNASchemaVersion)
        try values.encode(acceptedDNAAnalyzerIdentifier, forKey: .acceptedDNAAnalyzerIdentifier)
        try values.encode(acceptedDNAAnalyzerVersion, forKey: .acceptedDNAAnalyzerVersion)
        try values.encode(acceptedDNAAnalyzedAt, forKey: .acceptedDNAAnalyzedAt)
        try values.encode(acceptedRole, forKey: .acceptedRole)
        try values.encode(acceptedNormalizedName, forKey: .acceptedNormalizedName)
    }
}

extension DossierMembershipExclusion: Codable {
    private enum CodingKeys: String, CodingKey {
        case dossierID, documentID, revisionID, excludedAt
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            dossierID: try values.decode(UUID.self, forKey: .dossierID),
            documentID: try values.decode(UUID.self, forKey: .documentID),
            revisionID: try values.decode(UUID.self, forKey: .revisionID),
            excludedAt: try values.decode(Date.self, forKey: .excludedAt)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(dossierID, forKey: .dossierID)
        try values.encode(documentID, forKey: .documentID)
        try values.encode(revisionID, forKey: .revisionID)
        try values.encode(excludedAt, forKey: .excludedAt)
    }
}

extension PersonDossierOriginState: Codable {
    private enum CodingKeys: String, CodingKey { case validity, document, sourceDisplayName }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            validity: values.decode(PersonDossierOriginEvidenceValidity.self, forKey: .validity),
            document: values.decodeIfPresent(DocumentRecord.self, forKey: .document),
            sourceDisplayName: values.decodeIfPresent(String.self, forKey: .sourceDisplayName)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(validity, forKey: .validity)
        try values.encodeIfPresent(document, forKey: .document)
        try values.encodeIfPresent(sourceDisplayName, forKey: .sourceDisplayName)
    }
}

extension PersonDossierFindingSupportIdentity: Codable {
    private enum CodingKeys: String, CodingKey {
        case documentID, contentHash, extractionVersion, dnaSchemaVersion
        case dnaAnalyzerIdentifier, dnaAnalyzerVersion, dnaAnalyzedAt
        case role, normalizedName, finding
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let documentID = try values.decode(UUID.self, forKey: .documentID)
        let contentHash = try values.decode(String.self, forKey: .contentHash)
        let extractionVersion = try values.decode(String.self, forKey: .extractionVersion)
        let schemaVersion = try values.decode(Int.self, forKey: .dnaSchemaVersion)
        let analyzerIdentifier = try values.decode(String.self, forKey: .dnaAnalyzerIdentifier)
        let analyzerVersion = try values.decode(String.self, forKey: .dnaAnalyzerVersion)
        let analyzedAt = try values.decode(Date.self, forKey: .dnaAnalyzedAt)
        let role = try values.decode(PersonDossierRole.self, forKey: .role)
        let finding = try values.decode(DocumentDNAFinding.self, forKey: .finding)
        let document = DocumentRecord(
            id: documentID,
            sourceRootID: UUID(uuidString: "83000000-0000-0000-0000-000000009999")!,
            relativePath: "support-only.pdf",
            contentHash: contentHash,
            byteCount: 1,
            modifiedAt: analyzedAt,
            mediaType: .pdf,
            status: .ready,
            availability: .available,
            pageCount: 1,
            lastSeenAt: analyzedAt,
            lastFingerprintAt: analyzedAt
        )
        let snapshot = try DocumentDNA(
            documentID: documentID,
            schemaVersion: schemaVersion,
            analyzerIdentifier: analyzerIdentifier,
            analyzerVersion: analyzerVersion,
            inputContentHash: contentHash,
            inputExtractionVersion: extractionVersion,
            findings: [
                try DocumentDNAFinding(
                    kind: .documentType,
                    qualifier: nil,
                    displayValue: "",
                    normalizedValue: DocumentType.unknown.rawValue,
                    secondaryNormalizedValue: nil,
                    confidence: 0,
                    evidence: []
                ),
                finding,
            ],
            analyzedAt: analyzedAt
        )
        let current = try CurrentDocumentDNA(document: document, snapshot: snapshot)
        try self.init(current: current, role: role, finding: finding)
        let encodedNormalizedName = try values.decode(String.self, forKey: .normalizedName)
        guard normalizedName == encodedNormalizedName else {
            throw PersonDossierGoldenFixtureError.invalidManifest
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(documentID, forKey: .documentID)
        try values.encode(contentHash, forKey: .contentHash)
        try values.encode(extractionVersion, forKey: .extractionVersion)
        try values.encode(dnaSchemaVersion, forKey: .dnaSchemaVersion)
        try values.encode(dnaAnalyzerIdentifier, forKey: .dnaAnalyzerIdentifier)
        try values.encode(dnaAnalyzerVersion, forKey: .dnaAnalyzerVersion)
        try values.encode(dnaAnalyzedAt, forKey: .dnaAnalyzedAt)
        try values.encode(role, forKey: .role)
        try values.encode(normalizedName, forKey: .normalizedName)
        try values.encode(finding, forKey: .finding)
    }
}

extension PersonDossierConflictState: Codable {
    private enum CodingKeys: String, CodingKey { case type, anchor, candidate }
    private enum Kind: String, Codable { case none, hardBirthDateConflict }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .type) {
        case .none:
            self = .none
        case .hardBirthDateConflict:
            self = .hardBirthDateConflict(
                anchor: try values.decode(PersonDossierBirthDate.self, forKey: .anchor),
                candidate: try values.decode(DocumentDNAFinding.self, forKey: .candidate)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try values.encode(Kind.none, forKey: .type)
        case let .hardBirthDateConflict(anchor, candidate):
            try values.encode(Kind.hardBirthDateConflict, forKey: .type)
            try values.encode(anchor, forKey: .anchor)
            try values.encode(candidate, forKey: .candidate)
        }
    }
}

extension PersonDossierCandidateSupportIdentity: Codable {
    private enum CodingKeys: String, CodingKey { case kind, person, conflict }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: values.decode(PersonDossierCandidateKind.self, forKey: .kind),
            person: values.decode(PersonDossierFindingSupportIdentity.self, forKey: .person),
            conflict: values.decode(PersonDossierConflictState.self, forKey: .conflict)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(kind, forKey: .kind)
        try values.encode(person, forKey: .person)
        try values.encode(conflict, forKey: .conflict)
    }
}

extension InvoicePaymentDecisionKey: Codable {
    private enum CodingKeys: String, CodingKey {
        case relationshipType, invoiceDocumentID, paymentDocumentID
        case invoiceContentHash, paymentContentHash
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            relationshipType: values.decode(DocumentRelationshipType.self, forKey: .relationshipType),
            invoiceDocumentID: values.decode(UUID.self, forKey: .invoiceDocumentID),
            paymentDocumentID: values.decode(UUID.self, forKey: .paymentDocumentID),
            invoiceContentHash: values.decode(String.self, forKey: .invoiceContentHash),
            paymentContentHash: values.decode(String.self, forKey: .paymentContentHash)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(relationshipType, forKey: .relationshipType)
        try values.encode(invoiceDocumentID, forKey: .invoiceDocumentID)
        try values.encode(paymentDocumentID, forKey: .paymentDocumentID)
        try values.encode(invoiceContentHash, forKey: .invoiceContentHash)
        try values.encode(paymentContentHash, forKey: .paymentContentHash)
    }
}

extension DossierMembershipSupportIdentity: Codable {
    private enum CodingKeys: String, CodingKey {
        case decisionKey, decisionUpdatedAt, invoiceDNAAnalyzedAt
        case paymentDNAAnalyzedAt, resolverVersion
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            decisionKey: try values.decode(InvoicePaymentDecisionKey.self, forKey: .decisionKey),
            decisionUpdatedAt: try values.decode(Date.self, forKey: .decisionUpdatedAt),
            invoiceDNAAnalyzedAt: try values.decode(Date.self, forKey: .invoiceDNAAnalyzedAt),
            paymentDNAAnalyzedAt: try values.decode(Date.self, forKey: .paymentDNAAnalyzedAt),
            resolverVersion: try values.decode(String.self, forKey: .resolverVersion)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(decisionKey, forKey: .decisionKey)
        try values.encode(decisionUpdatedAt, forKey: .decisionUpdatedAt)
        try values.encode(invoiceDNAAnalyzedAt, forKey: .invoiceDNAAnalyzedAt)
        try values.encode(paymentDNAAnalyzedAt, forKey: .paymentDNAAnalyzedAt)
        try values.encode(resolverVersion, forKey: .resolverVersion)
    }
}

extension InvoicePaymentCandidateSignal: Codable {
    private enum CodingKeys: String, CodingKey { case kind, invoiceFinding, paymentFinding }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try values.decode(InvoicePaymentCandidateSignalKind.self, forKey: .kind),
            invoiceFinding: try values.decode(DocumentDNAFinding.self, forKey: .invoiceFinding),
            paymentFinding: try values.decode(DocumentDNAFinding.self, forKey: .paymentFinding)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(kind, forKey: .kind)
        try values.encode(invoiceFinding, forKey: .invoiceFinding)
        try values.encode(paymentFinding, forKey: .paymentFinding)
    }
}

extension PersonDossierInvoiceMembershipBasis: Codable {
    private enum CodingKeys: String, CodingKey { case type, supports, revisionID }
    private enum Kind: String, Codable { case exactPerson, manualConfirmation }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .type) {
        case .exactPerson:
            self = .exactPerson(try values.decode(
                [PersonDossierFindingSupportIdentity].self,
                forKey: .supports
            ))
        case .manualConfirmation:
            self = .manualConfirmation(revisionID: try values.decode(UUID.self, forKey: .revisionID))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .exactPerson(supports):
            try values.encode(Kind.exactPerson, forKey: .type)
            try values.encode(supports, forKey: .supports)
        case let .manualConfirmation(revisionID):
            try values.encode(Kind.manualConfirmation, forKey: .type)
            try values.encode(revisionID, forKey: .revisionID)
        }
    }
}

extension PersonDossierPaymentSupportIdentity: Codable {
    private enum CodingKeys: String, CodingKey {
        case invoiceDocumentID, invoiceMembershipBasis, relationship, signals
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            invoiceDocumentID: values.decode(UUID.self, forKey: .invoiceDocumentID),
            invoiceMembershipBasis: values.decode(PersonDossierInvoiceMembershipBasis.self, forKey: .invoiceMembershipBasis),
            relationship: values.decode(DossierMembershipSupportIdentity.self, forKey: .relationship),
            signals: values.decode([InvoicePaymentCandidateSignal].self, forKey: .signals)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(invoiceDocumentID, forKey: .invoiceDocumentID)
        try values.encode(invoiceMembershipBasis, forKey: .invoiceMembershipBasis)
        try values.encode(relationship, forKey: .relationship)
        try values.encode(signals, forKey: .signals)
    }
}

extension PersonDossierMembershipSupport: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, exactPrimary, confirmation, currentCandidate, confirmedPayment
    }
    private enum Kind: String, Codable {
        case exactPrimary, manualConfirmation, confirmedPayment
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .type) {
        case .exactPrimary:
            self = .exactPrimary(try values.decode(
                PersonDossierFindingSupportIdentity.self,
                forKey: .exactPrimary
            ))
        case .manualConfirmation:
            self = .manualConfirmation(
                confirmation: try values.decode(DossierMembershipConfirmation.self, forKey: .confirmation),
                currentCandidate: try values.decodeIfPresent(PersonDossierCandidateSupportIdentity.self, forKey: .currentCandidate)
            )
        case .confirmedPayment:
            self = .confirmedPayment(try values.decode(
                PersonDossierPaymentSupportIdentity.self,
                forKey: .confirmedPayment
            ))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .exactPrimary(support):
            try values.encode(Kind.exactPrimary, forKey: .type)
            try values.encode(support, forKey: .exactPrimary)
        case let .manualConfirmation(confirmation, currentCandidate):
            try values.encode(Kind.manualConfirmation, forKey: .type)
            try values.encode(confirmation, forKey: .confirmation)
            try values.encodeIfPresent(currentCandidate, forKey: .currentCandidate)
        case let .confirmedPayment(support):
            try values.encode(Kind.confirmedPayment, forKey: .type)
            try values.encode(support, forKey: .confirmedPayment)
        }
    }
}

extension PersonDossierMember: Codable {
    private enum CodingKeys: String, CodingKey {
        case document, sourceDisplayName, documentType, section, supports
        case isConfirmationAuthoritative, preferredPaymentSupport
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            document: values.decode(DocumentRecord.self, forKey: .document),
            sourceDisplayName: values.decode(String.self, forKey: .sourceDisplayName),
            documentType: values.decodeIfPresent(DocumentType.self, forKey: .documentType),
            section: values.decode(PersonDossierSection.self, forKey: .section),
            supports: values.decode([PersonDossierMembershipSupport].self, forKey: .supports),
            isConfirmationAuthoritative: values.decode(Bool.self, forKey: .isConfirmationAuthoritative),
            preferredPaymentSupport: values.decodeIfPresent(PersonDossierPaymentSupportIdentity.self, forKey: .preferredPaymentSupport)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(document, forKey: .document)
        try values.encode(sourceDisplayName, forKey: .sourceDisplayName)
        try values.encodeIfPresent(documentType, forKey: .documentType)
        try values.encode(section, forKey: .section)
        try values.encode(supports, forKey: .supports)
        try values.encode(isConfirmationAuthoritative, forKey: .isConfirmationAuthoritative)
        try values.encodeIfPresent(preferredPaymentSupport, forKey: .preferredPaymentSupport)
    }
}

extension PersonDossierSuggestion: Codable {
    private enum CodingKeys: String, CodingKey {
        case document, sourceDisplayName, documentType, section, kind, conflict
        case currentSupports, commandSupport
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            document: values.decode(DocumentRecord.self, forKey: .document),
            sourceDisplayName: values.decode(String.self, forKey: .sourceDisplayName),
            documentType: values.decodeIfPresent(DocumentType.self, forKey: .documentType),
            section: values.decode(PersonDossierSection.self, forKey: .section),
            kind: values.decode(PersonDossierCandidateKind.self, forKey: .kind),
            conflict: values.decode(PersonDossierConflictState.self, forKey: .conflict),
            currentSupports: values.decode([PersonDossierCandidateSupportIdentity].self, forKey: .currentSupports),
            commandSupport: values.decode(PersonDossierCandidateSupportIdentity.self, forKey: .commandSupport)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(document, forKey: .document)
        try values.encode(sourceDisplayName, forKey: .sourceDisplayName)
        try values.encodeIfPresent(documentType, forKey: .documentType)
        try values.encode(section, forKey: .section)
        try values.encode(kind, forKey: .kind)
        try values.encode(conflict, forKey: .conflict)
        try values.encode(currentSupports, forKey: .currentSupports)
        try values.encode(commandSupport, forKey: .commandSupport)
    }
}

extension PersonDossierCorrectionDecision: Codable {
    private enum CodingKeys: String, CodingKey { case type, confirmation, exclusion }
    private enum Kind: String, Codable { case confirmation, exclusion }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .type) {
        case .confirmation:
            self = .confirmation(try values.decode(DossierMembershipConfirmation.self, forKey: .confirmation))
        case .exclusion:
            self = .exclusion(try values.decode(DossierMembershipExclusion.self, forKey: .exclusion))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .confirmation(confirmation):
            try values.encode(Kind.confirmation, forKey: .type)
            try values.encode(confirmation, forKey: .confirmation)
        case let .exclusion(exclusion):
            try values.encode(Kind.exclusion, forKey: .type)
            try values.encode(exclusion, forKey: .exclusion)
        }
    }
}

extension PersonDossierCorrection: Codable {
    private enum CodingKeys: String, CodingKey {
        case document, sourceDisplayName, documentType, decision
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            document: values.decode(DocumentRecord.self, forKey: .document),
            sourceDisplayName: values.decode(String.self, forKey: .sourceDisplayName),
            documentType: values.decodeIfPresent(DocumentType.self, forKey: .documentType),
            decision: values.decode(PersonDossierCorrectionDecision.self, forKey: .decision)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(document, forKey: .document)
        try values.encode(sourceDisplayName, forKey: .sourceDisplayName)
        try values.encodeIfPresent(documentType, forKey: .documentType)
        try values.encode(decision, forKey: .decision)
    }
}

extension PersonDossierDocumentProjectionIdentity: Codable {
    private enum CodingKeys: String, CodingKey {
        case documentID, sourceRootID, relativePath, contentHash, availability, dnaAnalyzedAt
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let dnaAnalyzedAt = try values.decodeIfPresent(Date.self, forKey: .dnaAnalyzedAt)
        let document = DocumentRecord(
            id: try values.decode(UUID.self, forKey: .documentID),
            sourceRootID: try values.decode(UUID.self, forKey: .sourceRootID),
            relativePath: try values.decode(String.self, forKey: .relativePath),
            contentHash: try values.decode(String.self, forKey: .contentHash),
            byteCount: 1,
            modifiedAt: dnaAnalyzedAt ?? Date(timeIntervalSince1970: 0),
            mediaType: .pdf,
            status: .ready,
            availability: try values.decode(DocumentAvailability.self, forKey: .availability),
            pageCount: 1,
            lastSeenAt: dnaAnalyzedAt ?? Date(timeIntervalSince1970: 0),
            lastFingerprintAt: dnaAnalyzedAt
        )
        self.init(document: document, dnaAnalyzedAt: dnaAnalyzedAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(documentID, forKey: .documentID)
        try values.encode(sourceRootID, forKey: .sourceRootID)
        try values.encode(relativePath, forKey: .relativePath)
        try values.encode(contentHash, forKey: .contentHash)
        try values.encode(availability, forKey: .availability)
        try values.encodeIfPresent(dnaAnalyzedAt, forKey: .dnaAnalyzedAt)
    }
}

extension PersonDossierProjectionToken: Codable {
    private enum CodingKeys: String, CodingKey {
        case dossierUpdatedAt, anchorUpdatedAt, originValidity, documents
        case memberSupports, suggestionSupports, confirmationRevisionIDs, exclusionRevisionIDs
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            dossierUpdatedAt: try values.decode(Date.self, forKey: .dossierUpdatedAt),
            anchorUpdatedAt: try values.decode(Date.self, forKey: .anchorUpdatedAt),
            originValidity: try values.decode(PersonDossierOriginEvidenceValidity.self, forKey: .originValidity),
            documents: try values.decode([PersonDossierDocumentProjectionIdentity].self, forKey: .documents),
            memberSupports: try values.decode([[PersonDossierMembershipSupport]].self, forKey: .memberSupports),
            suggestionSupports: try values.decode([PersonDossierCandidateSupportIdentity].self, forKey: .suggestionSupports),
            confirmationRevisionIDs: try values.decode([UUID].self, forKey: .confirmationRevisionIDs),
            exclusionRevisionIDs: try values.decode([UUID].self, forKey: .exclusionRevisionIDs)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(dossierUpdatedAt, forKey: .dossierUpdatedAt)
        try values.encode(anchorUpdatedAt, forKey: .anchorUpdatedAt)
        try values.encode(originValidity, forKey: .originValidity)
        try values.encode(documents, forKey: .documents)
        try values.encode(memberSupports, forKey: .memberSupports)
        try values.encode(suggestionSupports, forKey: .suggestionSupports)
        try values.encode(confirmationRevisionIDs, forKey: .confirmationRevisionIDs)
        try values.encode(exclusionRevisionIDs, forKey: .exclusionRevisionIDs)
    }
}

extension PersonDossierSnapshot: Codable {
    private enum CodingKeys: String, CodingKey {
        case dossier, anchor, origin, directMembers, costsAndPayments
        case suggestions, corrections, token
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            dossier: try values.decode(DossierRecord.self, forKey: .dossier),
            anchor: try values.decode(PersonDossierAnchor.self, forKey: .anchor),
            origin: try values.decode(PersonDossierOriginState.self, forKey: .origin),
            directMembers: try values.decode([PersonDossierMember].self, forKey: .directMembers),
            costsAndPayments: try values.decode([PersonDossierMember].self, forKey: .costsAndPayments),
            suggestions: try values.decode([PersonDossierSuggestion].self, forKey: .suggestions),
            corrections: try values.decode([PersonDossierCorrection].self, forKey: .corrections),
            token: try values.decode(PersonDossierProjectionToken.self, forKey: .token)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(dossier, forKey: .dossier)
        try values.encode(anchor, forKey: .anchor)
        try values.encode(origin, forKey: .origin)
        try values.encode(directMembers, forKey: .directMembers)
        try values.encode(costsAndPayments, forKey: .costsAndPayments)
        try values.encode(suggestions, forKey: .suggestions)
        try values.encode(corrections, forKey: .corrections)
        try values.encode(token, forKey: .token)
    }
}
