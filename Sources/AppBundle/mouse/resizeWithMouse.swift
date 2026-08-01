import AppKit
import Common

@MainActor
private var resizeWithMouseTask: Task<(), any Error>? = nil

func resizedObs(_: AXObserver, ax: AXUIElement, notif: CFString, _: UnsafeMutableRawPointer?) {
    let notif = notif as String
    let windowId = ax.containingWindowId()
    Task.startUnstructured { @MainActor in
        guard let token: RunSessionGuard = .isServerEnabled else { return }
        guard let windowId, let window = Window.get(byId: windowId), try await isManipulatedWithMouse(window) else {
            scheduleCancellableCompleteRefreshSession(.ax(notif))
            return
        }
        resizeWithMouseTask?.cancel()
        resizeWithMouseTask = Task.startUnstructured {
            try checkCancellation()
            try await runLightSession(.ax(notif), token) {
                try await resizeWithMouse(window)
            }
        }
    }
}

@MainActor
func resetManipulatedWithMouseIfPossible() async throws {
    if clearManipulatedWithMouse("mouseup-reset") {
        for workspace in Workspace.all {
            workspace.resetResizeWeightBeforeResizeRecursive()
        }
        // Landing rides the caller's own uncancellable session (runLightSession's
        // layoutWorkspaces). The schedule that used to live here was dead on
        // arrival - canceled by the caller's next schedule before executing one
        // instruction (project 09 audit). Removed.
    }
}

private let adaptiveWeightBeforeResizeWithMouseKey = TreeNodeUserDataKey<CGFloat>(key: "adaptiveWeightBeforeResizeWithMouseKey")

@MainActor
private func resizeWithMouse(_ window: Window) async throws { // todo cover with tests
    resetClosedWindowsCache()
    switch window.windowParentCases {
        case .unbound: return
        case .floatingWindowsContainer, .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
             .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
            return // Nothing to do for floating, or unconventional windows
        case .tilingContainer:
            guard let rect = try await window.getAxRect(.cancellable) else { return }
            guard let lastAppliedLayoutRect = window.lastAppliedLayoutPhysicalRect else { return }
            let (lParent, lOwnIndex) = window.closestParent(hasChildrenInDirection: .left, withLayout: .tiles) ?? (nil, nil)
            let (dParent, dOwnIndex) = window.closestParent(hasChildrenInDirection: .down, withLayout: .tiles) ?? (nil, nil)
            let (uParent, uOwnIndex) = window.closestParent(hasChildrenInDirection: .up, withLayout: .tiles) ?? (nil, nil)
            let (rParent, rOwnIndex) = window.closestParent(hasChildrenInDirection: .right, withLayout: .tiles) ?? (nil, nil)
            let table: [(CGFloat, TilingContainer?, Int?, Int?)] = [
                (lastAppliedLayoutRect.minX - rect.minX, lParent, 0,                        lOwnIndex),               // Horizontal, to the left of the window
                (rect.maxY - lastAppliedLayoutRect.maxY, dParent, dOwnIndex.map { $0 + 1 }, dParent?.children.count), // Vertical, to the down of the window
                (lastAppliedLayoutRect.minY - rect.minY, uParent, 0,                        uOwnIndex),               // Vertical, to the up of the window
                (rect.maxX - lastAppliedLayoutRect.maxX, rParent, rOwnIndex.map { $0 + 1 }, rParent?.children.count), // Horizontal, to the right of the window
            ]
            for (diff, parent, startIndex, pastTheEndIndex) in table {
                if let parent, let startIndex, let pastTheEndIndex, pastTheEndIndex - startIndex > 0 && abs(diff) > 5 { // 5 pixels should be enough to fight with accumulated floating precision error
                    let siblingDiff = diff.div(pastTheEndIndex - startIndex).orDie()
                    let orientation = parent.orientation

                    window.parentsWithSelf.lazy
                        .prefix(while: { $0 != parent })
                        .filter {
                            let parent = $0.parent as? TilingContainer
                            return parent?.orientation == orientation && parent?.layout == .tiles
                        }
                        .forEach { $0.setWeight(orientation, $0.getWeightBeforeResize(orientation) + diff) }
                    for sibling in parent.children[startIndex ..< pastTheEndIndex] {
                        sibling.setWeight(orientation, sibling.getWeightBeforeResize(orientation) - siblingDiff)
                    }
                }
            }
            _ = claimManipulatedWithMouse(window.windowId)
    }
}

// ============================================================================
// Project 04: lease-driven resize. rigd owns the ⌥+RMB gesture end-to-end and
// sends explicit socket messages (the project-09 architecture; Hyprland uses
// the same lease-flag shape). Deltas are CUMULATIVE from grab; weights are
// written ABSOLUTE from the resize latch => idempotent and drop-tolerant.
// NO manipulation mark here: layout must keep writing the target's frame.
// ============================================================================

@MainActor
func applyLeaseResize(windowId: UInt32, hDir: CardinalDirection?, vDir: CardinalDirection?, cumDx: CGFloat, cumDy: CGFloat) {
    guard let window = Window.get(byId: windowId) else { return }
    var work: [(CGFloat, CardinalDirection)] = []
    // growth convention matches the observation table above: positive = window
    // grows on that side. Right edge follows +dx; left edge: +dx shrinks.
    if let hDir { work.append((hDir == .left ? -cumDx : cumDx, hDir)) }
    if let vDir { work.append((vDir == .up ? -cumDy : cumDy, vDir)) }
    for (growth, dir) in work {
        guard let (parent, ownIndex) = window.closestParent(hasChildrenInDirection: dir, withLayout: .tiles) else { continue }
        let orientation = parent.orientation
        // Adjacent neighbor ONLY (Hyprland pins far neighbors; upstream's
        // observation path spreads over all siblings on that side - documented
        // divergence fix, one index change).
        let nIdx = (dir == .left || dir == .up) ? ownIndex - 1 : ownIndex + 1
        guard parent.children.indices.contains(nIdx) else { continue }
        let neighbor = parent.children[nIdx]
        // Safety floor ~20pt per side (approximates Hyprland's ratio clamp;
        // upstream has no clamp at all).
        let selfBase = (window.parentsWithSelf.lazy.first(where: { $0.parent === parent }) ?? window).getWeightBeforeResize(orientation)
        let nBase = neighbor.getWeightBeforeResize(orientation)
        let g = max(min(growth, nBase - 20), 20 - selfBase)
        window.parentsWithSelf.lazy
            .prefix(while: { $0 != parent })
            .filter {
                let p = $0.parent as? TilingContainer
                return p?.orientation == orientation && p?.layout == .tiles
            }
            .forEach { $0.setWeight(orientation, $0.getWeightBeforeResize(orientation) + g) }
        neighbor.setWeight(orientation, nBase - g)
    }
}

@MainActor
func endLeaseResize() {
    for workspace in Workspace.all {
        workspace.resetResizeWeightBeforeResizeRecursive()
    }
}

extension TreeNode {
    @MainActor
    func getWeightBeforeResize(_ orientation: Orientation) -> CGFloat {
        let currentWeight = getWeight(orientation) // Check assertions
        return getUserData(key: adaptiveWeightBeforeResizeWithMouseKey)
            ?? (lastAppliedLayoutVirtualRect?.getDimension(orientation) ?? currentWeight)
            .also { putUserData(key: adaptiveWeightBeforeResizeWithMouseKey, data: $0) }
    }

    func resetResizeWeightBeforeResizeRecursive() {
        cleanUserData(key: adaptiveWeightBeforeResizeWithMouseKey)
        for child in children {
            child.resetResizeWeightBeforeResizeRecursive()
        }
    }
}
