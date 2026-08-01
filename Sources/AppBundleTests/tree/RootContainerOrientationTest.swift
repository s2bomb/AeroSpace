@testable import AppBundle
import Common
import XCTest

@MainActor
final class RootContainerOrientationTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testAutoOrientationRederivedWhenRootEmpties() async {
        config.defaultRootContainerOrientation = .auto
        let workspace = Workspace.get(byName: name)
        let autoOrientation: Orientation = workspace.workspaceMonitor.then { $0.width >= $0.height } ? .h : .v

        let root = workspace.rootTilingContainer
        assertEquals(root.orientation, autoOrientation)

        let window = TestWindow.new(id: 0, parent: root)
        root.changeOrientation(autoOrientation.opposite)
        assertEquals(root.orientation, autoOrientation.opposite)

        // The root container survives becoming empty. 'auto' must be re-derived on reuse,
        // not frozen at whatever the last explicit orientation was.
        window.unbindFromParent()
        assertEquals(workspace.rootTilingContainer.orientation, autoOrientation)
    }

    func testExplicitOrientationNotRederived() async {
        config.defaultRootContainerOrientation = .vertical
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        assertEquals(root.orientation, .v)

        let window = TestWindow.new(id: 0, parent: root)
        root.changeOrientation(.h)
        window.unbindFromParent()
        assertEquals(workspace.rootTilingContainer.orientation, .h) // only 'auto' re-derives
    }
}
