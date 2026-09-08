import Foundation

enum PersonDossierProjectionError: Error, Sendable, Equatable {
    case invalidStoredState
}

struct PersonDossierProjectionInput: Sendable {
    let dossier: DossierRecord
    let originDocument: DocumentRecord?
    let currentOrigin: CurrentDocumentDNA?
    let documentsByID: [UUID: DocumentRecord]
    let currentDocumentsByID: [UUID: CurrentDocumentDNA]
    let personCandidates: [CurrentDocumentDNA]
    let relationshipCandidates: [InvoicePaymentCandidate]
    let relationshipDecisionsByKey:
        [InvoicePaymentDecisionKey: InvoicePaymentDecisionRecord]
    let sourceDisplayNames: [UUID: String]
    let confirmations: [DossierMembershipConfirmation]
    let exclusions: [DossierMembershipExclusion]
}

struct PersonDossierProjector: Sendable {
    func project(_ input: PersonDossierProjectionInput) throws -> PersonDossierSnapshot {
        do {
            let anchor = try validatedAnchor(input)
            let origin = try originState(input: input, anchor: anchor)
            let projected = try directProjection(input: input, anchor: anchor)
            let expandedMembers = try expandingConfirmedPayments(
                input: input,
                frozenMembers: projected.members
            )
            let directMembers = expandedMembers
                .filter { $0.section == .directDocuments }
                .sorted(by: presentationOrder)
            let costsAndPayments = expandedMembers
                .filter { $0.section == .costsAndPayments }
                .sorted(by: presentationOrder)
            let suggestions = projected.suggestions.sorted(by: presentationOrder)
            let corrections = try corrections(input).sorted(by: presentationOrder)
            let token = projectionToken(
                input: input,
                anchor: anchor,
                origin: origin,
                directMembers: directMembers,
                costsAndPayments: costsAndPayments,
                suggestions: suggestions,
                corrections: corrections
            )
            return PersonDossierSnapshot(
                dossier: input.dossier,
                anchor: anchor,
                origin: origin,
                directMembers: directMembers,
                costsAndPayments: costsAndPayments,
                suggestions: suggestions,
                corrections: corrections,
                token: token
            )
        } catch {
            throw PersonDossierProjectionError.invalidStoredState
        }
    }

    private struct DirectProjection {
        var members: [PersonDossierMember]
        var suggestions: [PersonDossierSuggestion]
    }

    private struct ConfirmedPaymentPath {
        let candidate: InvoicePaymentCandidate
        let support: PersonDossierPaymentSupportIdentity
        let invoiceMember: PersonDossierMember
    }

    private func validatedAnchor(
        _ input: PersonDossierProjectionInput
    ) throws -> PersonDossierAnchor {
        guard input.dossier.kind == .personMatter,
              case let .person(anchor) = input.dossier.anchor,
              input.originDocument.map({ $0.id == anchor.originDocumentID }) ?? true,
              input.currentOrigin.map({ $0.document.id == anchor.originDocumentID }) ?? true,
              dictionaryKeysMatchValues(input.documentsByID),
              currentDocumentsAreConsistent(input),
              input.sourceDisplayNames.values.allSatisfy({
                  !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }),
              correctionsAreValid(input)
        else {
            throw PersonDossierProjectionError.invalidStoredState
        }
        return anchor
    }

    private func dictionaryKeysMatchValues(
        _ documents: [UUID: DocumentRecord]
    ) -> Bool {
        documents.allSatisfy { $0.key == $0.value.id }
    }

    private func currentDocumentsAreConsistent(
        _ input: PersonDossierProjectionInput
    ) -> Bool {
        if let origin = input.originDocument {
            guard input.documentsByID[origin.id] == origin else { return false }
        }
        if let currentOrigin = input.currentOrigin {
            guard input.originDocument == currentOrigin.document,
                  input.currentDocumentsByID[currentOrigin.document.id] == currentOrigin
            else { return false }
        } else if let origin = input.originDocument,
                  input.currentDocumentsByID[origin.id] != nil {
            return false
        }
        guard input.currentDocumentsByID.allSatisfy({ id, current in
            id == current.document.id && input.documentsByID[id] == current.document
        }) else {
            return false
        }
        return input.personCandidates.allSatisfy { current in
            input.currentDocumentsByID[current.document.id] == current
        }
    }

    private func correctionsAreValid(
        _ input: PersonDossierProjectionInput
    ) -> Bool {
        let confirmationIDs = input.confirmations.map(\.documentID)
        let exclusionIDs = input.exclusions.map(\.documentID)
        return input.confirmations.allSatisfy {
            $0.dossierID == input.dossier.id && input.documentsByID[$0.documentID] != nil
        }
            && input.exclusions.allSatisfy {
                $0.dossierID == input.dossier.id && input.documentsByID[$0.documentID] != nil
            }
            && Set(confirmationIDs).count == confirmationIDs.count
            && Set(exclusionIDs).count == exclusionIDs.count
            && Set(confirmationIDs).isDisjoint(with: exclusionIDs)
    }

    private func originState(
        input: PersonDossierProjectionInput,
        anchor: PersonDossierAnchor
    ) throws -> PersonDossierOriginState {
        guard let document = input.originDocument else {
            return try PersonDossierOriginState(
                validity: .unavailable,
                document: nil,
                sourceDisplayName: nil
            )
        }
        let validity: PersonDossierOriginEvidenceValidity
        if let current = input.currentOrigin, originIsCurrent(current, anchor: anchor) {
            validity = .current
        } else {
            validity = .stale
        }
        return try PersonDossierOriginState(
            validity: validity,
            document: document,
            sourceDisplayName: sourceDisplayName(
                for: document,
                names: input.sourceDisplayNames
            )
        )
    }

    private func directProjection(
        input: PersonDossierProjectionInput,
        anchor: PersonDossierAnchor
    ) throws -> DirectProjection {
        let excludedIDs = Set(input.exclusions.map(\.documentID))
        let confirmationsByID = Dictionary(
            uniqueKeysWithValues: input.confirmations.map { ($0.documentID, $0) }
        )
        var automaticSupportsByID: [UUID: [PersonDossierFindingSupportIdentity]] = [:]
        var suggestionValuesByID: [UUID: (
            kind: PersonDossierCandidateKind,
            conflict: PersonDossierConflictState,
            supports: [PersonDossierCandidateSupportIdentity]
        )] = [:]

        for current in input.personCandidates {
            let documentID = current.document.id
            guard !excludedIDs.contains(documentID), confirmationsByID[documentID] == nil else {
                continue
            }
            switch PersonDossierCandidateClassifier().classify(current, for: anchor) {
            case let .automatic(supports):
                automaticSupportsByID[documentID, default: []].append(contentsOf: supports)
                suggestionValuesByID.removeValue(forKey: documentID)
            case let .suggestion(kind, conflict, supports, _):
                guard automaticSupportsByID[documentID] == nil else { continue }
                if let existing = suggestionValuesByID[documentID] {
                    guard existing.kind == kind, existing.conflict == conflict else {
                        throw PersonDossierProjectionError.invalidStoredState
                    }
                    suggestionValuesByID[documentID] = (
                        kind, conflict, existing.supports + supports
                    )
                } else {
                    suggestionValuesByID[documentID] = (kind, conflict, supports)
                }
            case .hidden:
                break
            }
        }

        var members: [PersonDossierMember] = []
        for confirmation in input.confirmations {
            guard !excludedIDs.contains(confirmation.documentID),
                  let document = input.documentsByID[confirmation.documentID]
            else {
                continue
            }
            let current = input.currentDocumentsByID[document.id]
            let accepted = current.flatMap {
                currentAcceptedCandidate($0, confirmation: confirmation, anchor: anchor)
            }
            members.append(try PersonDossierMember(
                document: document,
                sourceDisplayName: sourceDisplayName(
                    for: document,
                    names: input.sourceDisplayNames
                ),
                documentType: current?.documentType,
                section: section(for: current?.documentType),
                supports: [.manualConfirmation(
                    confirmation: confirmation,
                    currentCandidate: accepted
                )],
                isConfirmationAuthoritative: true,
                preferredPaymentSupport: nil
            ))
        }

        for (documentID, supports) in automaticSupportsByID {
            guard !excludedIDs.contains(documentID),
                  confirmationsByID[documentID] == nil,
                  let document = input.documentsByID[documentID],
                  let current = input.currentDocumentsByID[documentID]
            else {
                throw PersonDossierProjectionError.invalidStoredState
            }
            let canonical = canonicalFindingSupports(supports)
            members.append(try PersonDossierMember(
                document: document,
                sourceDisplayName: sourceDisplayName(
                    for: document,
                    names: input.sourceDisplayNames
                ),
                documentType: current.documentType,
                section: section(for: current.documentType),
                supports: canonical.map(PersonDossierMembershipSupport.exactPrimary),
                isConfirmationAuthoritative: false,
                preferredPaymentSupport: nil
            ))
        }

        let suggestions = try suggestionValuesByID.map { documentID, value in
            guard !excludedIDs.contains(documentID),
                  confirmationsByID[documentID] == nil,
                  let document = input.documentsByID[documentID],
                  let current = input.currentDocumentsByID[documentID]
            else {
                throw PersonDossierProjectionError.invalidStoredState
            }
            let supports = canonicalCandidateSupports(value.supports)
            guard let commandSupport = supports.first else {
                throw PersonDossierProjectionError.invalidStoredState
            }
            return try PersonDossierSuggestion(
                document: document,
                sourceDisplayName: sourceDisplayName(
                    for: document,
                    names: input.sourceDisplayNames
                ),
                documentType: current.documentType,
                section: section(for: current.documentType),
                kind: value.kind,
                conflict: value.conflict,
                currentSupports: supports,
                commandSupport: commandSupport
            )
        }
        return DirectProjection(members: members, suggestions: suggestions)
    }

    private func expandingConfirmedPayments(
        input: PersonDossierProjectionInput,
        frozenMembers: [PersonDossierMember]
    ) throws -> [PersonDossierMember] {
        let excludedIDs = Set(input.exclusions.map(\.documentID))
        let frozenMembersByID = Dictionary(
            uniqueKeysWithValues: frozenMembers.map { ($0.document.id, $0) }
        )
        var pathsByPaymentID: [UUID: [ConfirmedPaymentPath]] = [:]

        for candidate in input.relationshipCandidates {
            let invoiceID = candidate.invoice.document.id
            let paymentID = candidate.payment.document.id
            guard let invoiceMember = frozenMembersByID[invoiceID],
                  input.currentDocumentsByID[invoiceID]?.documentType == .invoice,
                  let currentInvoice = input.documentsByID[invoiceID],
                  let currentPayment = input.documentsByID[paymentID],
                  !excludedIDs.contains(paymentID),
                  let decisionKey = try? InvoicePaymentDecisionKey(candidate: candidate),
                  let decision = input.relationshipDecisionsByKey[decisionKey],
                  decision.key == decisionKey,
                  decision.decision == .confirmed,
                  binaryEqual(decisionKey.invoiceContentHash, currentInvoice.contentHash),
                  binaryEqual(decisionKey.paymentContentHash, currentPayment.contentHash),
                  let invoiceMembershipBasis = invoiceMembershipBasis(invoiceMember)
            else {
                continue
            }
            let relationship = DossierMembershipSupportIdentity(
                decisionKey: decisionKey,
                decisionUpdatedAt: decision.updatedAt,
                invoiceDNAAnalyzedAt: candidate.invoice.snapshot.analyzedAt,
                paymentDNAAnalyzedAt: candidate.payment.snapshot.analyzedAt,
                resolverVersion: candidate.resolverVersion
            )
            let support = try PersonDossierPaymentSupportIdentity(
                invoiceDocumentID: invoiceID,
                invoiceMembershipBasis: invoiceMembershipBasis,
                relationship: relationship,
                signals: DossierCandidateTieBreakKey.canonicalSignals(candidate.signals)
            )
            pathsByPaymentID[paymentID, default: []].append(ConfirmedPaymentPath(
                candidate: candidate,
                support: support,
                invoiceMember: invoiceMember
            ))
        }

        var membersByID = frozenMembersByID
        for (paymentID, paths) in pathsByPaymentID {
            let canonicalPaths = canonicalPaymentPaths(paths)
            guard let preferredPath = preferredPaymentPath(canonicalPaths),
                  let document = input.documentsByID[paymentID],
                  let current = input.currentDocumentsByID[paymentID]
            else {
                throw PersonDossierProjectionError.invalidStoredState
            }
            let relationshipSupports = canonicalPaths.map {
                PersonDossierMembershipSupport.confirmedPayment($0.support)
            }
            if let existing = membersByID[paymentID] {
                membersByID[paymentID] = try PersonDossierMember(
                    document: existing.document,
                    sourceDisplayName: existing.sourceDisplayName,
                    documentType: existing.documentType,
                    section: existing.section,
                    supports: existing.supports + relationshipSupports,
                    isConfirmationAuthoritative: existing.isConfirmationAuthoritative,
                    preferredPaymentSupport: preferredPath.support
                )
            } else {
                membersByID[paymentID] = try PersonDossierMember(
                    document: document,
                    sourceDisplayName: sourceDisplayName(
                        for: document,
                        names: input.sourceDisplayNames
                    ),
                    documentType: current.documentType,
                    section: section(for: current.documentType),
                    supports: relationshipSupports,
                    isConfirmationAuthoritative: false,
                    preferredPaymentSupport: preferredPath.support
                )
            }
        }
        return Array(membersByID.values)
    }

    private func invoiceMembershipBasis(
        _ member: PersonDossierMember
    ) -> PersonDossierInvoiceMembershipBasis? {
        let exactSupports: [PersonDossierFindingSupportIdentity] = member.supports.compactMap { support in
            guard case let .exactPrimary(value) = support else { return nil }
            return value
        }
        if !exactSupports.isEmpty {
            return .exactPerson(exactSupports)
        }
        let manualBases: [PersonDossierInvoiceMembershipBasis] = member.supports.compactMap { support in
            guard case let .manualConfirmation(confirmation, _) = support else { return nil }
            return PersonDossierInvoiceMembershipBasis.manualConfirmation(
                revisionID: confirmation.revisionID
            )
        }
        return manualBases.first
    }

    private func canonicalPaymentPaths(
        _ paths: [ConfirmedPaymentPath]
    ) -> [ConfirmedPaymentPath] {
        var unique: [ConfirmedPaymentPath] = []
        for path in paths where !unique.contains(where: { $0.support == path.support }) {
            unique.append(path)
        }
        return unique.sorted { lhs, rhs in
            let lhsInvoice = presentationOrder(
                sourceDisplayName: lhs.invoiceMember.sourceDisplayName,
                document: lhs.invoiceMember.document
            )
            let rhsInvoice = presentationOrder(
                sourceDisplayName: rhs.invoiceMember.sourceDisplayName,
                document: rhs.invoiceMember.document
            )
            if lhsInvoice != rhsInvoice { return lhsInvoice < rhsInvoice }
            let lhsKey = DossierCandidateTieBreakKey(lhs.candidate)
            let rhsKey = DossierCandidateTieBreakKey(rhs.candidate)
            if lhsKey != rhsKey { return lhsKey < rhsKey }
            return lhs.support.relationship.decisionUpdatedAt
                < rhs.support.relationship.decisionUpdatedAt
        }
    }

    private func preferredPaymentPath(
        _ paths: [ConfirmedPaymentPath]
    ) -> ConfirmedPaymentPath? {
        paths.max { lhs, rhs in
            let lhsStrength = InvoicePaymentCandidateStrength(lhs.candidate)
            let rhsStrength = InvoicePaymentCandidateStrength(rhs.candidate)
            if lhsStrength != rhsStrength { return lhsStrength < rhsStrength }
            return DossierCandidateTieBreakKey(rhs.candidate)
                < DossierCandidateTieBreakKey(lhs.candidate)
        }
    }

    private func corrections(
        _ input: PersonDossierProjectionInput
    ) throws -> [PersonDossierCorrection] {
        let confirmations = try input.confirmations.map { confirmation in
            try correction(
                input: input,
                documentID: confirmation.documentID,
                decision: .confirmation(confirmation)
            )
        }
        let exclusions = try input.exclusions.map { exclusion in
            try correction(
                input: input,
                documentID: exclusion.documentID,
                decision: .exclusion(exclusion)
            )
        }
        return confirmations + exclusions
    }

    private func correction(
        input: PersonDossierProjectionInput,
        documentID: UUID,
        decision: PersonDossierCorrectionDecision
    ) throws -> PersonDossierCorrection {
        guard let document = input.documentsByID[documentID] else {
            throw PersonDossierProjectionError.invalidStoredState
        }
        return try PersonDossierCorrection(
            document: document,
            sourceDisplayName: sourceDisplayName(
                for: document,
                names: input.sourceDisplayNames
            ),
            documentType: input.currentDocumentsByID[documentID]?.documentType,
            decision: decision
        )
    }

    private func currentAcceptedCandidate(
        _ current: CurrentDocumentDNA,
        confirmation: DossierMembershipConfirmation,
        anchor: PersonDossierAnchor
    ) -> PersonDossierCandidateSupportIdentity? {
        guard current.document.id == confirmation.documentID,
              binaryEqual(current.snapshot.inputContentHash, confirmation.acceptedContentHash),
              binaryEqual(
                current.snapshot.inputExtractionVersion,
                confirmation.acceptedExtractionVersion
              ),
              current.snapshot.schemaVersion == confirmation.acceptedDNASchemaVersion,
              binaryEqual(
                current.snapshot.analyzerIdentifier,
                confirmation.acceptedDNAAnalyzerIdentifier
              ),
              binaryEqual(
                current.snapshot.analyzerVersion,
                confirmation.acceptedDNAAnalyzerVersion
              ),
              current.snapshot.analyzedAt == confirmation.acceptedDNAAnalyzedAt
        else {
            return nil
        }
        guard case let .suggestion(kind, _, supports, _) =
                PersonDossierCandidateClassifier().classify(current, for: anchor),
              kind == confirmation.candidateKind else {
            return nil
        }
        return supports.first { support in
            support.person.role == confirmation.acceptedRole
                && binaryEqual(
                    support.person.normalizedName,
                    confirmation.acceptedNormalizedName
                )
        }
    }

    private func projectionToken(
        input: PersonDossierProjectionInput,
        anchor: PersonDossierAnchor,
        origin: PersonDossierOriginState,
        directMembers: [PersonDossierMember],
        costsAndPayments: [PersonDossierMember],
        suggestions: [PersonDossierSuggestion],
        corrections: [PersonDossierCorrection]
    ) -> PersonDossierProjectionToken {
        let members = directMembers + costsAndPayments
        var documentsByID: [UUID: DocumentRecord] = [:]
        if let originDocument = origin.document {
            documentsByID[originDocument.id] = originDocument
        }
        for document in members.map(\.document)
            + suggestions.map(\.document)
            + corrections.map(\.document) {
            documentsByID[document.id] = document
        }
        let documents = documentsByID.values.sorted {
            presentationOrder(
                sourceDisplayName: sourceDisplayName(
                    for: $0,
                    names: input.sourceDisplayNames
                ),
                document: $0
            ) < presentationOrder(
                sourceDisplayName: sourceDisplayName(
                    for: $1,
                    names: input.sourceDisplayNames
                ),
                document: $1
            )
        }.map { document in
            PersonDossierDocumentProjectionIdentity(
                document: document,
                dnaAnalyzedAt: input.currentDocumentsByID[document.id]?.snapshot.analyzedAt
            )
        }
        return PersonDossierProjectionToken(
            dossierUpdatedAt: input.dossier.updatedAt,
            anchorUpdatedAt: anchor.updatedAt,
            originValidity: origin.validity,
            documents: documents,
            memberSupports: members.map(\.supports),
            suggestionSupports: suggestions.map(\.commandSupport),
            confirmationRevisionIDs: corrections.compactMap { correction in
                guard case let .confirmation(value) = correction.decision else { return nil }
                return value.revisionID
            },
            exclusionRevisionIDs: corrections.compactMap { correction in
                guard case let .exclusion(value) = correction.decision else { return nil }
                return value.revisionID
            }
        )
    }

    private func originIsCurrent(
        _ current: CurrentDocumentDNA,
        anchor: PersonDossierAnchor
    ) -> Bool {
        guard current.document.id == anchor.originDocumentID,
              binaryEqual(current.snapshot.inputContentHash, anchor.originContentHash),
              binaryEqual(
                current.snapshot.inputExtractionVersion,
                anchor.originExtractionVersion
              ),
              current.snapshot.schemaVersion == anchor.originDNASchemaVersion,
              binaryEqual(
                current.snapshot.analyzerIdentifier,
                anchor.originDNAAnalyzerIdentifier
              ),
              binaryEqual(
                current.snapshot.analyzerVersion,
                anchor.originDNAAnalyzerVersion
              ),
              current.snapshot.analyzedAt == anchor.originDNAAnalyzedAt
        else {
            return false
        }
        return current.snapshot.findings.contains { finding in
            finding.kind == .person
                && finding.qualifier == anchor.primaryRole.rawValue
                && binaryEqual(finding.displayValue, anchor.displayName)
                && binaryEqual(finding.normalizedValue, anchor.normalizedName)
                && finding.evidence == anchor.personEvidence
        }
    }

    private func sourceDisplayName(
        for document: DocumentRecord,
        names: [UUID: String]
    ) -> String {
        names[document.sourceRootID] ?? document.sourceRootID.uuidString.lowercased()
    }

    private func section(for documentType: DocumentType?) -> PersonDossierSection {
        switch documentType {
        case .invoice, .paymentConfirmation:
            .costsAndPayments
        default:
            .directDocuments
        }
    }

    private func presentationOrder(_ lhs: PersonDossierMember, _ rhs: PersonDossierMember) -> Bool {
        presentationOrder(sourceDisplayName: lhs.sourceDisplayName, document: lhs.document)
            < presentationOrder(sourceDisplayName: rhs.sourceDisplayName, document: rhs.document)
    }

    private func presentationOrder(
        _ lhs: PersonDossierSuggestion,
        _ rhs: PersonDossierSuggestion
    ) -> Bool {
        presentationOrder(sourceDisplayName: lhs.sourceDisplayName, document: lhs.document)
            < presentationOrder(sourceDisplayName: rhs.sourceDisplayName, document: rhs.document)
    }

    private func presentationOrder(
        _ lhs: PersonDossierCorrection,
        _ rhs: PersonDossierCorrection
    ) -> Bool {
        presentationOrder(sourceDisplayName: lhs.sourceDisplayName, document: lhs.document)
            < presentationOrder(sourceDisplayName: rhs.sourceDisplayName, document: rhs.document)
    }

    private func presentationOrder(
        sourceDisplayName: String,
        document: DocumentRecord
    ) -> (String, String, String) {
        (sourceDisplayName, document.relativePath, document.id.uuidString.lowercased())
    }

    private func canonicalFindingSupports(
        _ supports: [PersonDossierFindingSupportIdentity]
    ) -> [PersonDossierFindingSupportIdentity] {
        deduplicated(supports).sorted { lhs, rhs in
            let lhsRole = roleOrder(lhs.role)
            let rhsRole = roleOrder(rhs.role)
            if lhsRole != rhsRole { return lhsRole < rhsRole }
            return findingSupportKey(lhs) < findingSupportKey(rhs)
        }
    }

    private func canonicalCandidateSupports(
        _ supports: [PersonDossierCandidateSupportIdentity]
    ) -> [PersonDossierCandidateSupportIdentity] {
        deduplicated(supports).sorted {
            findingSupportKey($0.person) < findingSupportKey($1.person)
        }
    }

    private func deduplicated<Value: Equatable>(_ values: [Value]) -> [Value] {
        values.reduce(into: []) { result, value in
            if !result.contains(value) { result.append(value) }
        }
    }

    private func roleOrder(_ role: PersonDossierRole) -> Int {
        switch role {
        case .resident: 0
        case .insuredPerson: 1
        case .accountHolder: 2
        case .invoiceRecipient: 3
        case .grantor: 4
        case .authorizedPerson: 5
        }
    }

    private func findingSupportKey(_ support: PersonDossierFindingSupportIdentity) -> String {
        component(support.documentID.uuidString.lowercased())
            + component(support.contentHash)
            + component(support.extractionVersion)
            + component(String(support.dnaSchemaVersion))
            + component(support.dnaAnalyzerIdentifier)
            + component(support.dnaAnalyzerVersion)
            + component(String(support.dnaAnalyzedAt.timeIntervalSinceReferenceDate.bitPattern))
            + component(support.role.rawValue)
            + component(support.normalizedName)
            + findingKey(support.finding)
    }

    private func findingKey(_ finding: DocumentDNAFinding) -> String {
        component(finding.kind.rawValue)
            + component(finding.qualifier)
            + component(finding.displayValue)
            + component(finding.normalizedValue)
            + component(finding.secondaryNormalizedValue)
            + component(String(finding.confidence.bitPattern))
            + finding.evidence.map(evidenceKey).joined()
    }

    private func evidenceKey(_ evidence: DocumentDNAEvidence) -> String {
        component(String(evidence.pageIndex))
            + component(String(evidence.startUTF16))
            + component(String(evidence.lengthUTF16))
            + component(evidence.exactText)
            + component(evidence.ocrRegionIndexes.map(String.init).joined(separator: ","))
    }

    private func component(_ value: String?) -> String {
        guard let value else { return "-" }
        return "\(value.utf8.count):\(value)"
    }

    private func binaryEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }
}
