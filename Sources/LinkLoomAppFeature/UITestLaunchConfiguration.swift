import Foundation

@_spi(UITesting)
public enum UITestLaunchConfigurationError: Error, Sendable, Equatable {
    case missingValue(String)
    case nonAbsolutePath(String)
    case duplicateArgument(String)
}

@_spi(UITesting)
public struct UITestLaunchConfiguration: Sendable, Equatable {
    public let databaseURL: URL?
    public let sourceURL: URL?
    public let disablesWatcher: Bool
    public let failsStartupOnce: Bool

    public init(arguments: [String]) throws {
        var databaseURL: URL?
        var sourceURL: URL?
        var disablesWatcher = false
        var failsStartupOnce = false
        var valuedArguments = Set<String>()
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case Self.databaseArgument, Self.sourceArgument:
                guard valuedArguments.insert(argument).inserted else {
                    throw UITestLaunchConfigurationError.duplicateArgument(argument)
                }
                let valueIndex = arguments.index(after: index)
                guard valueIndex < arguments.endIndex else {
                    throw UITestLaunchConfigurationError.missingValue(argument)
                }
                let value = arguments[valueIndex]
                guard !Self.recognizedArguments.contains(value) else {
                    throw UITestLaunchConfigurationError.missingValue(argument)
                }
                guard (value as NSString).isAbsolutePath else {
                    throw UITestLaunchConfigurationError.nonAbsolutePath(argument)
                }
                if argument == Self.databaseArgument {
                    databaseURL = URL(fileURLWithPath: value, isDirectory: false)
                } else {
                    sourceURL = URL(fileURLWithPath: value, isDirectory: true)
                }
                index = valueIndex
            case Self.disableWatcherArgument:
                disablesWatcher = true
            case Self.failStartupOnceArgument:
                failsStartupOnce = true
            default:
                break
            }
            index = arguments.index(after: index)
        }

        self.databaseURL = databaseURL
        self.sourceURL = sourceURL
        self.disablesWatcher = disablesWatcher
        self.failsStartupOnce = failsStartupOnce
    }

    private static let databaseArgument = "--linkloom-ui-test-database"
    private static let sourceArgument = "--linkloom-ui-test-source"
    private static let disableWatcherArgument = "--linkloom-ui-test-disable-watcher"
    private static let failStartupOnceArgument = "--linkloom-ui-test-fail-startup-once"
    private static let recognizedArguments: Set<String> = [
        databaseArgument,
        sourceArgument,
        disableWatcherArgument,
        failStartupOnceArgument,
    ]
}
