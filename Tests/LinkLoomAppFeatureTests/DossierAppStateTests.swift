import Foundation
import Testing
@testable import LinkLoomAppFeature
@testable import LinkLoomCore

@Suite("Dossier app state")
struct DossierAppStateTests {
    @Test func detailStateRetainsOnlyCompletePreviousSnapshots() throws {
        let snapshot = try CostsAndPaymentsDossierAppModelValues.make().snapshot
        let workspace = DossierWorkspaceSnapshot.costsAndPayments(snapshot)
        let loading = DossierDetailState.loading(
            dossierID: snapshot.dossier.id,
            previous: workspace
        )
        let available = DossierDetailState.available(workspace)
        let failed = DossierDetailState.failed(
            dossierID: snapshot.dossier.id,
            previous: workspace
        )

        #expect(DossierDetailState.none.snapshot == nil)
        #expect(loading.workspaceSnapshot == workspace)
        #expect(available.workspaceSnapshot == workspace)
        #expect(failed.workspaceSnapshot == workspace)
        #expect(loading.snapshot == snapshot)
        #expect(available.snapshot == snapshot)
        #expect(failed.snapshot == snapshot)
        #expect(loading.personSnapshot == nil)
        #expect(available.personSnapshot == nil)
        #expect(failed.personSnapshot == nil)
        #expect(workspace.dossier == snapshot.dossier)
        #expect(workspace.projectionIdentity == .costsAndPayments(snapshot.token))
        #expect(workspace.costsAndPayments == snapshot)
        #expect(workspace.personMatter == nil)
    }

    @Test func detailStateRetainsACompleteTypedPersonSnapshot() throws {
        let person = try PersonDossierAppModelValues.make().snapshot
        let workspace = DossierWorkspaceSnapshot.personMatter(person)

        let loading = DossierDetailState.loading(
            dossierID: person.dossier.id,
            previous: workspace
        )
        let failed = DossierDetailState.failed(
            dossierID: person.dossier.id,
            previous: workspace
        )
        let available = DossierDetailState.available(workspace)

        #expect(loading.workspaceSnapshot == workspace)
        #expect(available.workspaceSnapshot == workspace)
        #expect(failed.workspaceSnapshot == workspace)
        #expect(loading.personSnapshot == person)
        #expect(available.personSnapshot == person)
        #expect(failed.personSnapshot == person)
        #expect(loading.snapshot == nil)
        #expect(available.snapshot == nil)
        #expect(failed.snapshot == nil)
        #expect(workspace.dossier == person.dossier)
        #expect(workspace.projectionIdentity == .personMatter(person.token))
        #expect(workspace.costsAndPayments == nil)
        #expect(workspace.personMatter == person)
    }

    @Test func staleDossierInputHasStablePrivacySafeReason() {
        let diagnostic = AppRuntimeDiagnostic(
            category: .dossierMutation,
            error: DossierRepositoryError.staleInput
        )

        #expect(diagnostic.reason == .staleDocument)
    }
}
