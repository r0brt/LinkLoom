import Foundation
import Testing
@testable import LinkLoomCore

@Suite("Person dossier projection quality")
struct PersonDossierMetricTests {
    @Test func metricFormulasCountTrueFalsePositivesAndFalseNegatives() throws {
        let labels = [
            label(101, true, .direct, .resident, nil),
            label(102, false, .direct, .resident, nil),
            label(103, true, .direct, .authorizedPerson, .secondaryRole),
        ]
        let report = try PersonDossierMetricEvaluator.evaluate(
            labels: labels,
            baseline: PersonDossierMetricResultSet(
                memberDocumentIDs: [id(101), id(102)],
                suggestionDocumentIDs: [id(103)],
                correctionDocumentIDs: []
            ),
            corrected: PersonDossierMetricResultSet(
                memberDocumentIDs: [id(101), id(103)],
                suggestionDocumentIDs: [],
                correctionDocumentIDs: [id(102)]
            )
        )

        #expect(report.automatic == quality(truePositive: 1, falsePositive: 1, falseNegative: 1))
        #expect(report.discoverable == quality(truePositive: 2, falsePositive: 1, falseNegative: 0))
        #expect(report.corrected == quality(truePositive: 2, falsePositive: 0, falseNegative: 0))
    }

    @Test func unsupportedDocumentsAndOverlayStatesDoNotEnterDenominator() throws {
        var labels = syntheticLabels()
        let unsupportedHiddenDocument = id(10)
        labels[unsupportedHiddenDocument] = PersonDossierMetricLabel(
            documentID: unsupportedHiddenDocument,
            supportedFormat: false,
            relevant: false,
            membershipClass: .direct,
            role: .resident,
            candidateKind: nil
        )

        let report = try evaluate(labels: Array(labels.values))

        #expect(report.automatic == quality(truePositive: 7, falsePositive: 0, falseNegative: 1))
        #expect(report.corrected == quality(truePositive: 8, falsePositive: 0, falseNegative: 0))
    }

    @Test func discoverableIncludesAutomaticAndSuggestionsWithoutDoubleCounting() throws {
        let report = try evaluate(labels: Array(syntheticLabels().values))

        #expect(report.discoverable == quality(truePositive: 8, falsePositive: 1, falseNegative: 0))
    }

    @Test func correctedUsesFinalMembersAndNotCorrectionRowsAsMembership() throws {
        let report = try evaluate(labels: Array(syntheticLabels().values))

        #expect(report.corrected == quality(truePositive: 8, falsePositive: 0, falseNegative: 0))
    }

    @Test func reportSplitsDirectIndirectRoleAndCandidateKind() throws {
        let report = try evaluate(labels: Array(syntheticLabels().values))

        #expect(report.direct == quality(truePositive: 7, falsePositive: 1, falseNegative: 0))
        #expect(report.indirectPayment == quality(truePositive: 1, falsePositive: 0, falseNegative: 0))
        #expect(report.byRole[.resident] == quality(truePositive: 2, falsePositive: 0, falseNegative: 0))
        #expect(report.byRole[.insuredPerson] == quality(truePositive: 1, falsePositive: 1, falseNegative: 0))
        #expect(report.byRole[.authorizedPerson] == quality(truePositive: 1, falsePositive: 0, falseNegative: 0))
        #expect(report.byCandidateKind[.secondaryRole] == quality(truePositive: 1, falsePositive: 0, falseNegative: 0))
        #expect(report.byCandidateKind[.birthDateConflict] == quality(truePositive: 0, falsePositive: 1, falseNegative: 0))
    }

    @Test func emptySliceUsesDefinedUnitQuality() throws {
        var labels = syntheticLabels()
        labels[id(8)] = PersonDossierMetricLabel(
            documentID: id(8),
            supportedFormat: true,
            relevant: true,
            membershipClass: .direct,
            role: .authorizedPerson,
            candidateKind: nil
        )
        labels[id(9)] = PersonDossierMetricLabel(
            documentID: id(9),
            supportedFormat: true,
            relevant: false,
            membershipClass: .direct,
            role: .insuredPerson,
            candidateKind: nil
        )

        let report = try evaluate(labels: Array(labels.values))

        #expect(report.byCandidateKind[.secondaryRole] == quality(truePositive: 0, falsePositive: 0, falseNegative: 0))
        #expect(report.byCandidateKind[.birthDateConflict] == quality(truePositive: 0, falsePositive: 0, falseNegative: 0))
    }

    @Test func syntheticGoldenCorpusMeetsReleaseGates() throws {
        let manifest = try PersonDossierGoldenFixture.loadManifest()
        let report = try PersonDossierMetricEvaluator.evaluate(
            labels: manifest.metricLabels,
            baseline: try PersonDossierGoldenFixture.loadExpectedSnapshot(named: "baseline-snapshot"),
            corrected: try PersonDossierGoldenFixture.loadExpectedSnapshot(named: "corrected-snapshot")
        )

        printAggregate(report.automatic, named: "synthetic automatic")
        printAggregate(report.discoverable, named: "synthetic discoverable")
        printAggregate(report.corrected, named: "synthetic corrected")
        #expect(report.automatic == quality(truePositive: 7, falsePositive: 0, falseNegative: 1))
        #expect(report.discoverable == quality(truePositive: 8, falsePositive: 1, falseNegative: 0))
        #expect(report.corrected == quality(truePositive: 8, falsePositive: 0, falseNegative: 0))
        #expect(report.automatic.precision == 1.0)
        #expect(report.discoverable.recall == 1.0)
        #expect(report.corrected.precision == 1.0)
        #expect(report.corrected.recall == 1.0)
        #expect(report.direct == quality(truePositive: 7, falsePositive: 1, falseNegative: 0))
        #expect(report.indirectPayment == quality(truePositive: 1, falsePositive: 0, falseNegative: 0))
        #expect(report.byRole[.resident] == quality(truePositive: 2, falsePositive: 0, falseNegative: 0))
        #expect(report.byRole[.insuredPerson] == quality(truePositive: 1, falsePositive: 1, falseNegative: 0))
        #expect(report.byRole[.accountHolder] == quality(truePositive: 1, falsePositive: 0, falseNegative: 0))
        #expect(report.byRole[.invoiceRecipient] == quality(truePositive: 1, falsePositive: 0, falseNegative: 0))
        #expect(report.byRole[.grantor] == quality(truePositive: 1, falsePositive: 0, falseNegative: 0))
        #expect(report.byRole[.authorizedPerson] == quality(truePositive: 1, falsePositive: 0, falseNegative: 0))
        #expect(report.byCandidateKind[.secondaryRole] == quality(truePositive: 1, falsePositive: 0, falseNegative: 0))
        #expect(report.byCandidateKind[.birthDateConflict] == quality(truePositive: 0, falsePositive: 1, falseNegative: 0))
    }

    @Test func evaluatorRejectsInvalidVisibleFixtureLabels() throws {
        let baseline = try PersonDossierGoldenFixture.loadExpectedSnapshot(named: "baseline-snapshot")
        let corrected = try PersonDossierGoldenFixture.loadExpectedSnapshot(named: "corrected-snapshot")
        let labels = Array(syntheticLabels().values)

        #expect(throws: PersonDossierMetricFixtureError.duplicateLabel) {
            try PersonDossierMetricEvaluator.evaluate(
                labels: labels + [labels[0]], baseline: baseline, corrected: corrected
            )
        }
        #expect(throws: PersonDossierMetricFixtureError.missingLabelForVisibleProjectedDocument) {
            try PersonDossierMetricEvaluator.evaluate(
                labels: labels.filter { $0.documentID != id(1) }, baseline: baseline, corrected: corrected
            )
        }
        var unsupported = syntheticLabels()
        unsupported[id(1)] = PersonDossierMetricLabel(
            documentID: id(1), supportedFormat: false, relevant: true,
            membershipClass: .direct, role: .resident, candidateKind: nil
        )
        #expect(throws: PersonDossierMetricFixtureError.projectedUnsupportedDocument) {
            try PersonDossierMetricEvaluator.evaluate(
                labels: Array(unsupported.values), baseline: baseline, corrected: corrected
            )
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LINKLOOM_PERSON_REFERENCE_MANIFEST"] != nil))
    func optionalLocalReferenceSetMeetsAggregateQualityGates() throws {
        let path = try #require(ProcessInfo.processInfo.environment["LINKLOOM_PERSON_REFERENCE_MANIFEST"])
        let reference = try PersonDossierMetricReferenceSet.load(from: URL(fileURLWithPath: path))
        let report = try PersonDossierMetricEvaluator.evaluate(
            labels: reference.labels,
            baseline: reference.baseline,
            corrected: reference.corrected
        )

        printAggregate(report.automatic, named: "local reference automatic")
        printAggregate(report.discoverable, named: "local reference discoverable")
        printAggregate(report.corrected, named: "local reference corrected")
        #expect(report.automatic.precision >= 0.90)
        #expect(report.discoverable.recall >= 0.80)
    }

    private func evaluate(labels: [PersonDossierMetricLabel]) throws -> PersonDossierQualityReport {
        try PersonDossierMetricEvaluator.evaluate(
            labels: labels,
            baseline: try PersonDossierGoldenFixture.loadExpectedSnapshot(named: "baseline-snapshot"),
            corrected: try PersonDossierGoldenFixture.loadExpectedSnapshot(named: "corrected-snapshot")
        )
    }

    private func syntheticLabels() -> [UUID: PersonDossierMetricLabel] {
        Dictionary(uniqueKeysWithValues: [
            label(1, true, .direct, .resident, nil),
            label(2, true, .direct, .insuredPerson, nil),
            label(3, true, .direct, .accountHolder, nil),
            label(4, true, .direct, .invoiceRecipient, nil),
            label(5, true, .direct, .grantor, nil),
            label(6, true, .direct, .resident, nil),
            label(7, true, .indirectPayment, nil, nil),
            label(8, true, .direct, .authorizedPerson, .secondaryRole),
            label(9, false, .direct, .insuredPerson, .birthDateConflict),
            label(10, false, .direct, .resident, nil),
            label(11, false, .direct, .resident, nil),
            label(12, false, .direct, .resident, nil),
            label(13, false, .direct, nil, nil),
            label(14, false, .direct, nil, nil),
            label(15, false, .direct, nil, nil),
        ].map { ($0.documentID, $0) })
    }

    private func label(
        _ suffix: Int,
        _ relevant: Bool,
        _ membershipClass: PersonDossierMetricMembershipClass,
        _ role: PersonDossierRole?,
        _ candidateKind: PersonDossierCandidateKind?
    ) -> PersonDossierMetricLabel {
        PersonDossierMetricLabel(
            documentID: id(suffix),
            supportedFormat: true,
            relevant: relevant,
            membershipClass: membershipClass,
            role: role,
            candidateKind: candidateKind
        )
    }

    private func quality(
        truePositive: Int,
        falsePositive: Int,
        falseNegative: Int
    ) -> PersonDossierQualitySlice {
        PersonDossierQualitySlice(
            truePositive: truePositive,
            falsePositive: falsePositive,
            falseNegative: falseNegative,
            precision: truePositive + falsePositive == 0 ? 1 : Double(truePositive) / Double(truePositive + falsePositive),
            recall: truePositive + falseNegative == 0 ? 1 : Double(truePositive) / Double(truePositive + falseNegative)
        )
    }

    private func printAggregate(_ slice: PersonDossierQualitySlice, named name: String) {
        print("\(name): tp=\(slice.truePositive) fp=\(slice.falsePositive) fn=\(slice.falseNegative) precision=\(slice.precision) recall=\(slice.recall)")
    }

    private func id(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "83000000-0000-0000-0000-%012d", suffix))!
    }
}
