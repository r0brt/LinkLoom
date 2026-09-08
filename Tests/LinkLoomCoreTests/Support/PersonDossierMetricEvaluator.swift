import Foundation
@testable import LinkLoomCore

enum PersonDossierMetricMembershipClass: String, Decodable {
    case direct
    case indirectPayment
}

struct PersonDossierMetricLabel: Decodable, Equatable {
    let documentID: UUID
    let supportedFormat: Bool
    let relevant: Bool
    let membershipClass: PersonDossierMetricMembershipClass
    let role: PersonDossierRole?
    let candidateKind: PersonDossierCandidateKind?
}

struct PersonDossierQualitySlice: Equatable {
    let truePositive: Int
    let falsePositive: Int
    let falseNegative: Int
    let precision: Double
    let recall: Double
}

struct PersonDossierQualityReport: Equatable {
    let automatic: PersonDossierQualitySlice
    let discoverable: PersonDossierQualitySlice
    let corrected: PersonDossierQualitySlice
    let direct: PersonDossierQualitySlice
    let indirectPayment: PersonDossierQualitySlice
    let byRole: [PersonDossierRole: PersonDossierQualitySlice]
    let byCandidateKind: [PersonDossierCandidateKind: PersonDossierQualitySlice]
}

enum PersonDossierMetricFixtureError: Error, Equatable {
    case duplicateLabel
    case missingLabelForVisibleProjectedDocument
    case projectedUnsupportedDocument
    case invalidReferenceSet
}

struct PersonDossierMetricResultSet: Decodable {
    let memberDocumentIDs: [UUID]
    let suggestionDocumentIDs: [UUID]
    let correctionDocumentIDs: [UUID]

    init(snapshot: PersonDossierSnapshot) {
        memberDocumentIDs = (snapshot.directMembers + snapshot.costsAndPayments).map(\.id)
        suggestionDocumentIDs = snapshot.suggestions.map(\.id)
        correctionDocumentIDs = snapshot.corrections.map(\.id)
    }
}

struct PersonDossierMetricReferenceSet: Decodable {
    let labels: [PersonDossierMetricLabel]
    let baseline: PersonDossierMetricResultSet
    let corrected: PersonDossierMetricResultSet

    static func load(from url: URL) throws -> PersonDossierMetricReferenceSet {
        do {
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        } catch {
            throw PersonDossierMetricFixtureError.invalidReferenceSet
        }
    }
}

enum PersonDossierMetricEvaluator {
    static func evaluate(
        labels: [PersonDossierMetricLabel],
        baseline: PersonDossierSnapshot,
        corrected: PersonDossierSnapshot
    ) throws -> PersonDossierQualityReport {
        try evaluate(
            labels: labels,
            baseline: PersonDossierMetricResultSet(snapshot: baseline),
            corrected: PersonDossierMetricResultSet(snapshot: corrected)
        )
    }

    static func evaluate(
        labels: [PersonDossierMetricLabel],
        baseline: PersonDossierMetricResultSet,
        corrected: PersonDossierMetricResultSet
    ) throws -> PersonDossierQualityReport {
        let labelsByID = try labelsByID(labels)
        try validateVisibleDocuments(baseline, labelsByID: labelsByID)
        try validateVisibleDocuments(corrected, labelsByID: labelsByID)

        let denominator = Set(labelsByID.values.lazy.filter(\.supportedFormat).map(\.documentID))
        let relevant = Set(labelsByID.values.lazy.filter {
            $0.supportedFormat && $0.relevant
        }.map(\.documentID))
        let automatic = Set(baseline.memberDocumentIDs)
        let discoverable = automatic.union(baseline.suggestionDocumentIDs)
        let correctedMembers = Set(corrected.memberDocumentIDs)

        let byRole = Dictionary(uniqueKeysWithValues: PersonDossierRole.allCases.map { role in
            (role, threeStates(
                automatic: automatic,
                discoverable: discoverable,
                corrected: correctedMembers,
                relevant: relevant,
                denominator: denominator.filter { labelsByID[$0]?.role == role }
            ).discoverable)
        })
        let byCandidateKind = Dictionary(uniqueKeysWithValues: PersonDossierCandidateKind.allCases.map { kind in
            (kind, threeStates(
                automatic: automatic,
                discoverable: discoverable,
                corrected: correctedMembers,
                relevant: relevant,
                denominator: denominator.filter { labelsByID[$0]?.candidateKind == kind }
            ).discoverable)
        })

        return PersonDossierQualityReport(
            automatic: quality(predicted: automatic, relevant: relevant),
            discoverable: quality(predicted: discoverable, relevant: relevant),
            corrected: quality(predicted: correctedMembers, relevant: relevant),
            direct: threeStates(
                automatic: automatic,
                discoverable: discoverable,
                corrected: correctedMembers,
                relevant: relevant,
                denominator: denominator.filter { labelsByID[$0]?.membershipClass == .direct }
            ).discoverable,
            indirectPayment: threeStates(
                automatic: automatic,
                discoverable: discoverable,
                corrected: correctedMembers,
                relevant: relevant,
                denominator: denominator.filter { labelsByID[$0]?.membershipClass == .indirectPayment }
            ).discoverable,
            byRole: byRole,
            byCandidateKind: byCandidateKind
        )
    }

    private static func labelsByID(
        _ labels: [PersonDossierMetricLabel]
    ) throws -> [UUID: PersonDossierMetricLabel] {
        var result: [UUID: PersonDossierMetricLabel] = [:]
        for label in labels {
            guard result.updateValue(label, forKey: label.documentID) == nil else {
                throw PersonDossierMetricFixtureError.duplicateLabel
            }
        }
        return result
    }

    private static func validateVisibleDocuments(
        _ result: PersonDossierMetricResultSet,
        labelsByID: [UUID: PersonDossierMetricLabel]
    ) throws {
        let visible = Set(
            result.memberDocumentIDs
                + result.suggestionDocumentIDs
                + result.correctionDocumentIDs
        )
        for documentID in visible {
            guard let label = labelsByID[documentID] else {
                throw PersonDossierMetricFixtureError.missingLabelForVisibleProjectedDocument
            }
            guard label.supportedFormat else {
                throw PersonDossierMetricFixtureError.projectedUnsupportedDocument
            }
        }
    }

    private static func threeStates(
        automatic: Set<UUID>,
        discoverable: Set<UUID>,
        corrected: Set<UUID>,
        relevant: Set<UUID>,
        denominator: Set<UUID>
    ) -> (automatic: PersonDossierQualitySlice, discoverable: PersonDossierQualitySlice, corrected: PersonDossierQualitySlice) {
        let relevant = relevant.intersection(denominator)
        return (
            quality(predicted: automatic.intersection(denominator), relevant: relevant),
            quality(predicted: discoverable.intersection(denominator), relevant: relevant),
            quality(predicted: corrected.intersection(denominator), relevant: relevant)
        )
    }

    private static func quality(
        predicted: Set<UUID>,
        relevant: Set<UUID>
    ) -> PersonDossierQualitySlice {
        let truePositive = predicted.intersection(relevant).count
        let falsePositive = predicted.subtracting(relevant).count
        let falseNegative = relevant.subtracting(predicted).count
        let predictedCount = truePositive + falsePositive
        let relevantCount = truePositive + falseNegative
        return PersonDossierQualitySlice(
            truePositive: truePositive,
            falsePositive: falsePositive,
            falseNegative: falseNegative,
            precision: predictedCount == 0 ? 1 : Double(truePositive) / Double(predictedCount),
            recall: relevantCount == 0 ? 1 : Double(truePositive) / Double(relevantCount)
        )
    }
}
