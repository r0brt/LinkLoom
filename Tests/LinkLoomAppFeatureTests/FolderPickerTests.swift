import Foundation
import LinkLoomAppFeature
import Testing

@Suite("Folder picker")
struct FolderPickerTests {
    @Test @MainActor func injectedSelectionReturnsSpecifiedURLs() {
        let expected = [
            URL(fileURLWithPath: "/tmp/linkloom-source-a", isDirectory: true),
            URL(fileURLWithPath: "/tmp/linkloom-source-b", isDirectory: true),
        ]
        let picker = FolderPicker(selectFolders: { expected })

        #expect(picker.selectFolders() == expected)
    }
}
