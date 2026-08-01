import AppKit

@MainActor var currentlyManipulatedWithMouseWindowId: UInt32? = nil
// HID system state, not NSEvent.pressedMouseButtons: the latter only reflects
// DELIVERED events. A mouse-down consumed by another process's CGEvent tap
// (or posted synthetically) never updates it, which makes drag detection fail
// while the physical button is genuinely held.
var isLeftMouseButtonDown: Bool { CGEventSource.buttonState(.hidSystemState, button: .left) }

@MainActor
func isManipulatedWithMouse(_ window: Window) async throws -> Bool {
    try await (!window.isHiddenInCorner && // Don't allow to resize/move windows of hidden workspaces
        isLeftMouseButtonDown &&
        (currentlyManipulatedWithMouseWindowId == nil || window.windowId == currentlyManipulatedWithMouseWindowId))
        .andAsync { @Sendable @MainActor in try await getNativeFocusedWindow(.cancellable) == window }
}

/// Same motivation as in monitorFrameNormalized
var mouseLocation: CGPoint { NSEvent.mouseLocation.withYAxisFlipped }
