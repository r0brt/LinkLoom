import Foundation
import Testing
@_spi(UITesting) import LinkLoomAppFeature

@Suite("UI test launch configuration")
struct UITestLaunchConfigurationTests {
    @Test func parsesRecognizedArgumentsAndIgnoresXcodeArguments() throws {
        let configuration = try UITestLaunchConfiguration(arguments: [
            "LinkLoom",
            "--linkloom-ui-test-database", "/tmp/LinkLoomSmoke/linkloom.sqlite",
            "--linkloom-ui-test-source", "/tmp/LinkLoomSmoke/source",
            "--linkloom-ui-test-disable-watcher",
            "--linkloom-ui-test-fail-startup-once",
            "-ApplePersistenceIgnoreState", "YES",
        ])

        #expect(configuration.databaseURL?.path == "/tmp/LinkLoomSmoke/linkloom.sqlite")
        #expect(configuration.sourceURL?.path == "/tmp/LinkLoomSmoke/source")
        #expect(configuration.disablesWatcher)
        #expect(configuration.failsStartupOnce)
    }

    @Test func noRecognizedArgumentsUsesProductionDefaults() throws {
        let configuration = try UITestLaunchConfiguration(arguments: [
            "LinkLoom",
            "-ApplePersistenceIgnoreState", "YES",
        ])

        #expect(configuration.databaseURL == nil)
        #expect(configuration.sourceURL == nil)
        #expect(!configuration.disablesWatcher)
        #expect(!configuration.failsStartupOnce)
    }

    @Test(arguments: [
        "--linkloom-ui-test-database",
        "--linkloom-ui-test-source",
    ])
    func rejectsMissingValuedArgument(_ argument: String) {
        #expect(throws: UITestLaunchConfigurationError.missingValue(argument)) {
            try UITestLaunchConfiguration(arguments: ["LinkLoom", argument])
        }
    }

    @Test func recognizedSwitchCannotBecomeDatabaseValue() {
        let argument = "--linkloom-ui-test-database"
        #expect(throws: UITestLaunchConfigurationError.missingValue(argument)) {
            try UITestLaunchConfiguration(arguments: [
                "LinkLoom",
                argument,
                "--linkloom-ui-test-disable-watcher",
            ])
        }
    }

    @Test(arguments: [
        "--linkloom-ui-test-database",
        "--linkloom-ui-test-source",
    ])
    func rejectsRelativePath(_ argument: String) {
        #expect(throws: UITestLaunchConfigurationError.nonAbsolutePath(argument)) {
            try UITestLaunchConfiguration(arguments: [
                "LinkLoom", argument, "relative/path",
            ])
        }
    }

    @Test(arguments: [
        "--linkloom-ui-test-database",
        "--linkloom-ui-test-source",
    ])
    func rejectsDuplicateValuedArgument(_ argument: String) {
        #expect(throws: UITestLaunchConfigurationError.duplicateArgument(argument)) {
            try UITestLaunchConfiguration(arguments: [
                "LinkLoom",
                argument, "/tmp/first",
                argument, "/tmp/second",
            ])
        }
    }
}
