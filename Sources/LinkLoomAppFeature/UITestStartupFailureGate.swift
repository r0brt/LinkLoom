@_spi(UITesting)
@MainActor
public final class UITestStartupFailureGate {
    private var shouldFail: Bool

    public init(enabled: Bool) {
        shouldFail = enabled
    }

    public func consumeFailure() -> Bool {
        guard shouldFail else { return false }
        shouldFail = false
        return true
    }
}
