import Testing
import AppKit
@testable import CodeEditSourceEditor

/// Geometry rules for the suggestion window, which are easy to get subtly wrong
/// because `NSWindow` anchors a resize to the frame's origin — its *bottom* left
/// — while the window is visually anchored to whichever edge sits against the
/// caret.
@MainActor
struct SuggestionWindowGeometryTests {

    private func makeController(frame: NSRect) throws -> (SuggestionController, NSWindow) {
        let controller = SuggestionController()
        let window = try #require(controller.window)
        window.setFrame(frame, display: false)
        return (controller, window)
    }

    /// A window hanging *below* the caret is anchored by its top edge, so a
    /// smaller reported size must grow the gap at the bottom and leave the top
    /// where it was.
    ///
    /// Without this, `setContentSize` holds the bottom edge and the top drops by
    /// the height difference on every call. The window does not simply end up
    /// shorter in place: the content view's layout then restores the height it
    /// needs, measured down from the new top edge, so the frame comes back the
    /// same size in a lower position. Repeated calls therefore *walk* the window
    /// down the screen rather than resize it.
    @Test
    func aWindowBelowTheCursorKeepsItsTopEdgeWhenTheReportedSizeShrinks() throws {
        let (controller, window) = try makeController(
            frame: NSRect(x: 200, y: 500, width: 256, height: 208))
        controller.isWindowAboveCursor = false
        let topBefore = window.frame.maxY

        controller.updateWindowSize(newSize: NSSize(width: 256, height: 36))

        #expect(window.frame.maxY == topBefore)
    }

    /// The same window, sent the same shrink several times, must not drift. This
    /// is the shape the bug actually took: one call looks like a small
    /// misplacement, and it is the accumulation that carries the window off the
    /// display. A completion request that returns no items reports the empty
    /// size, and typing an identifier the index does not know sends that same
    /// empty size once per keystroke.
    @Test
    func repeatedShrinksDoNotWalkTheWindowDownTheScreen() throws {
        let (controller, window) = try makeController(
            frame: NSRect(x: 200, y: 500, width: 256, height: 208))
        controller.isWindowAboveCursor = false
        let topBefore = window.frame.maxY

        for _ in 0..<10 {
            controller.updateWindowSize(newSize: NSSize(width: 256, height: 36))
        }

        #expect(window.frame.maxY == topBefore)
    }

    /// The complementary rule, unchanged: a window placed *above* the caret is
    /// anchored by its bottom edge.
    @Test
    func aWindowAboveTheCursorKeepsItsBottomEdgeWhenTheReportedSizeShrinks() throws {
        let (controller, window) = try makeController(
            frame: NSRect(x: 200, y: 500, width: 256, height: 208))
        controller.isWindowAboveCursor = true
        let originBefore = window.frame.origin

        controller.updateWindowSize(newSize: NSSize(width: 256, height: 36))

        #expect(window.frame.origin == originBefore)
    }

    /// A window that is already off-screen must still be repositionable.
    ///
    /// `NSWindow.screen` is `nil` for a window that intersects no display, so
    /// deriving the screen from the window made this method return early in
    /// exactly the situation that needs it: once the window was off-screen,
    /// nothing could bring it back for the rest of its life. The caret is always
    /// on a screen, so it is the sound anchor — and the better one when there is
    /// more than one display.
    @Test
    func anOffscreenWindowIsBroughtBackRatherThanLeftWhereItIs() throws {
        let screen = try #require(NSScreen.main)
        let (controller, window) = try makeController(
            frame: NSRect(x: 200, y: -5000, width: 256, height: 208))
        // Precondition, and the whole reason the old guard failed here.
        #expect(window.screen == nil)

        let caret = NSRect(x: screen.frame.midX, y: screen.frame.midY, width: 1, height: 18)
        controller.constrainWindowToScreenEdges(cursorRect: caret, font: .monospacedSystemFont(ofSize: 12, weight: .regular))

        #expect(screen.frame.intersects(window.frame))
    }
}
