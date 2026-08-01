@testable import AppBundle
import Common
import XCTest

@MainActor
final class NewWindowPlacementTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testAppendIsDefault() async {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 0, parent: $0)
            assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
        }

        let data = unbindAndGetBindingDataForNewTilingWindow(workspace, window: nil)
        assertEquals(data.parent === root, true)
        assertEquals(data.index, 2)
        assertEquals(root.layoutDescription, .h_tiles([.window(0), .window(1)]))
    }

    func testSplitMru_secondWindowAppends() async {
        config.defaultNewWindowPlacement = .splitMru
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer.apply {
            assertEquals(TestWindow.new(id: 0, parent: $0).focusWindow(), true)
        }

        // The parent container with a single child IS the split of the workspace.
        // Appending is already the correct dwindle placement.
        let data = unbindAndGetBindingDataForNewTilingWindow(workspace, window: nil)
        assertEquals(data.parent === root, true)
        assertEquals(root.layoutDescription, .h_tiles([.window(0)]))
    }

    func testSplitMru_thirdWindowSplitsMruCell() async {
        config.defaultNewWindowPlacement = .splitMru
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer.apply {
            TestWindow.new(id: 0, parent: $0)
            assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
        }

        let data = unbindAndGetBindingDataForNewTilingWindow(workspace, window: nil)
        TestWindow.new(id: 2, parent: data.parent)
        assertEquals(root.layoutDescription, .h_tiles([
            .window(0),
            .v_tiles([
                .window(1),
                .window(2),
            ]),
        ]))
    }

    func testSplitMru_deepSplitAlternates() async {
        config.defaultNewWindowPlacement = .splitMru
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        TestWindow.new(id: 0, parent: root)
        let nested = TilingContainer.newVTiles(parent: root, adaptiveWeight: 1, index: INDEX_BIND_LAST)
        TestWindow.new(id: 1, parent: nested)
        assertEquals(TestWindow.new(id: 2, parent: nested).focusWindow(), true)

        let data = unbindAndGetBindingDataForNewTilingWindow(workspace, window: nil)
        TestWindow.new(id: 3, parent: data.parent)
        assertEquals(root.layoutDescription, .h_tiles([
            .window(0),
            .v_tiles([
                .window(1),
                .h_tiles([
                    .window(2),
                    .window(3),
                ]),
            ]),
        ]))
    }

    func testSplitMru_accordionAppends() async {
        config.defaultNewWindowPlacement = .splitMru
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let accordion = TilingContainer(parent: root, adaptiveWeight: 1, .v, .accordion, index: INDEX_BIND_LAST)
        TestWindow.new(id: 0, parent: accordion)
        assertEquals(TestWindow.new(id: 1, parent: accordion).focusWindow(), true)

        let data = unbindAndGetBindingDataForNewTilingWindow(workspace, window: nil)
        assertEquals(data.parent === accordion, true)
        assertEquals(data.index, 2)
    }
}
