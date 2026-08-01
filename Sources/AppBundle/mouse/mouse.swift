import AppKit

// HID system state, not NSEvent.pressedMouseButtons: the latter only reflects
// DELIVERED events. A mouse-down consumed by another process's CGEvent tap
// (or posted synthetically) never updates it, which makes drag detection fail
// while the physical button is genuinely held.
var isLeftMouseButtonDown: Bool { CGEventSource.buttonState(.hidSystemState, button: .left) }

@MainActor private var _manipulatedWindowId: UInt32? = nil
@MainActor private var _manipulatedClaimTime: Double = 0
// HID buttonState FLICKERS false mid-hold when the down was tap-consumed
// (flight-recorder: refresh-hygiene clears during held drags). A live drag
// re-claims at ~30 Hz, so claim freshness is the reliable authority signal.
private let manipulatedFreshnessS = 0.25

// The mark's AUTHORITY is derived from the live button state instead of being
// stored: an in-flight move task that resumes after mouse-up and re-writes the
// id cannot poison anything - the stale value is inert the moment the button is
// up (layout includes the window again; the next drag's claim overwrites).
@MainActor var currentlyManipulatedWithMouseWindowId: UInt32? {
    isLeftMouseButtonDown || CFAbsoluteTimeGetCurrent() - _manipulatedClaimTime < manipulatedFreshnessS
        ? _manipulatedWindowId : nil
}

// Single writer. No suspension point between check and write.
@MainActor func claimManipulatedWithMouse(_ windowId: UInt32) -> Bool {
    guard isLeftMouseButtonDown || CFAbsoluteTimeGetCurrent() - _manipulatedClaimTime < manipulatedFreshnessS,
          _manipulatedWindowId == nil || _manipulatedWindowId == windowId else { return false }
    _manipulatedWindowId = windowId
    _manipulatedClaimTime = CFAbsoluteTimeGetCurrent()
    armManipWatchdog()
    dragLog("MANIP_SET wid=\(windowId)")
    return true
}

@MainActor private var manipWatchdog: Task<Void, Never>? = nil

// Gesture end = claim SILENCE. The OS button state lies in both directions for
// tap-consumed chords (flight recorder: false mid-hold, true post-release), and
// the release event itself is not guaranteed to be delivered. A live drag claims
// at ~30 Hz; 350 ms of silence means the hand let go - clear and LAND, here,
// unconditionally.
@MainActor func armManipWatchdog() {
    manipWatchdog?.cancel()
    manipWatchdog = Task { @MainActor in
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard !Task.isCancelled, _manipulatedWindowId != nil,
              CFAbsoluteTimeGetCurrent() - _manipulatedClaimTime >= 0.35 else { return }
        clearManipulatedWithMouse("watchdog")
        try? await layoutWorkspaces()
    }
}

@MainActor @discardableResult func clearManipulatedWithMouse(_ reason: String) -> Bool {
    manipWatchdog?.cancel()
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
