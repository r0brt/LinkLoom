import Testing
@_spi(UITesting) import LinkLoomAppFeature

@Suite("UI test startup failure gate")
struct UITestStartupFailureGateTests {
    @Test @MainActor func enabledGateFailsOnlyFirstAttempt() {
        let gate = UITestStartupFailureGate(enabled: true)

        #expect(gate.consumeFailure())
        #expect(!gate.consumeFailure())
    }

    @Test @MainActor func disabledGateNeverFails() {
        let gate = UITestStartupFailureGate(enabled: false)

        #expect(!gate.consumeFailure())
        #expect(!gate.consumeFailure())
    }
}
