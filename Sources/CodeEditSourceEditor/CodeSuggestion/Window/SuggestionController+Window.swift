//
//  SuggestionController+Window.swift
//  CodeEditTextView
//
//  Created by Abe Malla on 12/22/24.
//

import AppKit

extension SuggestionController {
    /// Will constrain the window's frame to be within the visible screen
    public func constrainWindowToScreenEdges(cursorRect: NSRect, font: NSFont) {
        guard let window = self.window else { return }

        // The screen is chosen from the cursor, not from the window. `window.screen` is
        // `nil` whenever the window does not intersect a display, so reading it first
        // makes this method unable to act in exactly the case that needs it most: a
        // window that has ended up off-screen can never be brought back, because the
        // one call that would reposition it returns early. The cursor rect is always
        // on a screen, and it is also the more correct anchor on a multi-display setup
        // — the suggestions belong beside the caret, not beside a stray window.
        let screen = NSScreen.screens.first { $0.frame.intersects(cursorRect) }
            ?? window.screen
            ?? NSScreen.main
        guard let screenFrame = screen?.visibleFrame else { return }

        let windowSize = window.frame.size
        let padding: CGFloat = 22
        var newWindowOrigin = NSPoint(
            x: cursorRect.origin.x - Self.WINDOW_PADDING
            - CodeSuggestionLabelView.HORIZONTAL_PADDING - font.pointSize,
            y: cursorRect.origin.y
        )

        // Keep the horizontal position within the screen and some padding
        let minX = screenFrame.minX + padding
        let maxX = screenFrame.maxX - windowSize.width - padding

        if newWindowOrigin.x < minX {
            newWindowOrigin.x = minX
        } else if newWindowOrigin.x > maxX {
            newWindowOrigin.x = maxX
        }

        // Check if the window will go below the screen
        // We determine whether the window drops down or upwards by choosing which
        // corner of the window we will position: `setFrameOrigin` or `setFrameTopLeftPoint`
        if newWindowOrigin.y - windowSize.height < screenFrame.minY {
            // If the cursor itself is below the screen, then position the window
            // at the bottom of the screen with some padding
            if newWindowOrigin.y < screenFrame.minY {
                newWindowOrigin.y = screenFrame.minY + padding
            } else {
                // Place above the cursor
                newWindowOrigin.y += cursorRect.height
            }

            isWindowAboveCursor = true
            window.setFrameOrigin(newWindowOrigin)
        } else {
            // If the window goes above the screen, position it below the screen with padding
            let maxY = screenFrame.maxY - padding
            if newWindowOrigin.y > maxY {
                newWindowOrigin.y = maxY
            }

            isWindowAboveCursor = false
            window.setFrameTopLeftPoint(newWindowOrigin)
        }
    }

    func updateWindowSize(newSize: NSSize) {
        if let popover {
            popover.contentSize = newSize
            return
        }

        guard let window else { return }
        let oldFrame = window.frame
        let oldTopLeft = NSPoint(x: oldFrame.minX, y: oldFrame.maxY)

        window.minSize = newSize
        window.maxSize = NSSize(width: CGFloat.infinity, height: newSize.height)

        window.setContentSize(newSize)

        // Re-anchor the edge the window is attached to. `setContentSize` keeps the
        // frame's origin — its *bottom* left — fixed, so a window hanging below the
        // cursor drops by the height difference every time this is called. That was
        // only corrected for the above-cursor case, which meant the common case walked.
        //
        // It walks rather than merely jumping once because the content view's layout
        // restores the height it actually needs from the new top edge, so the frame
        // ends up the same size in a new place: each call translates the window down
        // by `oldHeight - newHeight` and nothing brings it back. A run of completion
        // requests that return no items — an ordinary thing while typing an
        // identifier the index does not know — sends the same shrink repeatedly and
        // marches the window off the bottom of the screen a few hundred points at a
        // time, still taking key events where it cannot be seen.
        if isWindowAboveCursor {
            window.setFrameOrigin(oldFrame.origin)
        } else {
            window.setFrameTopLeftPoint(oldTopLeft)
        }
    }

    // MARK: - Private Methods

    static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.resizable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isExcludedFromWindowsMenu = true
        window.isReleasedWhenClosed = false
        window.level = .popUpMenu
        window.hasShadow = true
        window.isOpaque = false
        window.tabbingMode = .disallowed
        window.hidesOnDeactivate = true
        window.backgroundColor = .clear

        return window
    }
}
