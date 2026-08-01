import AppKit

// HID system state, not NSEvent.pressedMouseButtons: the latter only reflects
// DELIVERED events. A mouse-down consumed by another process's CGEvent tap
// (or posted synthetically) never updates it, which makes drag detection fail
// while the physical button is genuinely held.
var isLeftMouseButtonDown: Bool { CGEventSource.buttonState(.hidSystemState, button: .left) }

@MainActor private var _manipulatedWindowId: UInt32? = nil

// The mark's AUTHORITY is derived from the live button state instead of being
// stored: an in-flight move task that resumes after mouse-up and re-writes the
// id cannot poison anything - the stale value is inert the moment the button is
// up (layout includes the window again; the next drag's claim overwrites).
@MainActor var currentlyManipulatedWithMouseWindowId: UInt32? {
    isLeftMouseButtonDown ? _manipulatedWindowId : nil
}

// Single writer. No suspension point between check and write.
@MainActor func claimManipulatedWithMouse(_ windowId: UInt32) -> Bool {
    guard isLeftMouseButtonDown, _manipulatedWindowId == nil || _manipulatedWindowId == windowId else { return false }
    _manipulatedWindowId = windowId
    dragLog("MANIP_SET wid=\(windowId)")
    return true
}

@MainActor @discardableResult func clearManipulatedWithMouse(_ reason: String) -> Bool {
    guard let was = _manipulatedWindowId else { return false }
    _manipulatedWindowId = nil
    dragLog("MANIP_CLEAR was=\(was) \(reason)")
    return true
}

// Flight recorder: enabled by the presence of /tmp/aerospace-drag.on.
// mouse= field discriminates the frozen-cursor hypothesis in one physical drag.
func dragLog(_ s: String) {
    guard FileManager.default.fileExists(atPath: "/tmp/aerospace-drag.on") else { return }
    let m = NSEvent.mouseLocation
    let line = "\(Int(Date().timeIntervalSince1970 * 1000) % 100_000_000) \(s) mouse=\(Int(m.x)),\(Int(m.y))\n"
    if let h = FileHandle(forWritingAtPath: "/tmp/aerospace-drag.log") {
        h.seekToEndOfFile()
        if let d = line.data(using: .utf8) { h.write(d) }
        h.closeFile()
    } else {
        try? line.write(toFile: "/tmp/aerospace-drag.log", atomically: false, encoding: .utf8)
    }
}

@MainActor
func isManipulatedWithMouse(_ window: Window) async throws -> Bool {
    try await (!window.isHiddenInCorner && // Don't allow to resize/move windows of hidden workspaces
        isLeftMouseButtonDown &&
        (currentlyManipulatedWithMouseWindowId == nil || window.windowId == currentlyManipulatedWithMouseWindowId))
        .andAsync { @Sendable @MainActor in try await getNativeFocusedWindow(.cancellable) == window }
}

/// Same motivation as in monitorFrameNormalized
var mouseLocation: CGPoint { NSEvent.mouseLocation.withYAxisFlipped }
