import Testing
import AppKit
import CodeEditTextView
@testable import CodeEditSourceEditor

/// What happens to cursor updates that arrive while a completion request is
/// still outstanding.
///
/// This matters because the delegate is `async`: typing is comfortably faster
/// than a round trip through it, so in any quick burst every character after
/// the first lands while the first character's request is still in flight.
/// If those updates are discarded, the window ends up showing the list computed
/// for the first character while the text says something else — and the list is
/// live, so applying the selection inserts a completion the user never typed
/// toward.
@MainActor
struct SuggestionRequestCoalescingTests {

    /// A delegate whose request never finishes on its own, so a test can hold a
    /// request "in flight" for as long as it needs and record what it was asked.
    final class BlockingDelegate: CodeSuggestionDelegate {
        var requestedPositions: [Int] = []
        /// One per request, in the order the requests were made, so a test can
        /// finish an *older* request while a newer one is still outstanding —
        /// which is the ordering the bookkeeping bug needs.
        var continuations: [CheckedContinuation<Void, Never>] = []
        /// Stands in for a provider that cannot refine — the state a real one is
        /// in before its first request has ever completed.
        var canRefine = false

        func completionSuggestionsRequested(
            textView: TextViewController,
            cursorPosition: CursorPosition
        ) async -> (windowPosition: CursorPosition, items: [CodeSuggestionEntry])? {
            requestedPositions.append(cursorPosition.range.location)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                continuations.append(continuation)
            }
            return nil
        }

        func releaseAll() {
            let pending = continuations
            continuations = []
            pending.forEach { $0.resume() }
        }

        func completionOnCursorMove(
            textView: TextViewController,
            cursorPosition: CursorPosition
        ) -> [CodeSuggestionEntry]? {
            canRefine ? [] : nil
        }

        func completionWindowApplyCompletion(
            item: CodeSuggestionEntry,
            textView: TextViewController,
            cursorPosition: CursorPosition?
        ) { }
    }

    /// `showCompletions` needs a parent window to attach to, so the text view has
    /// to live in one — otherwise it returns before it ever asks the delegate and
    /// every assertion below passes or fails for the wrong reason.
    private func makeHost() throws -> (SuggestionController, TextViewController, NSWindow) {
        let textController = Mock.textViewController(theme: Mock.theme())
        textController.loadView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = textController.view
        return (SuggestionController(), textController, window)
    }

    /// The defect: the second position was never asked for.
    ///
    /// A `guard itemsRequestTask == nil else { return }` discarded the update
    /// outright — no refinement, no fresh request, and no close. The window kept
    /// the first position's list.
    @Test
    func aCursorUpdateArrivingDuringARequestIsNotDiscarded() async throws {
        let (controller, textController, _window) = try makeHost()
        let delegate = BlockingDelegate()

        controller.cursorsUpdated(
            textView: textController, delegate: delegate,
            position: CursorPosition(range: NSRange(location: 1, length: 0)), presentIfNot: true)

        // Let the request start and block inside the delegate.
        try await Task.sleep(for: .milliseconds(50))
        #expect(delegate.requestedPositions == [1])

        // The next keystroke, while that request is still outstanding.
        controller.cursorsUpdated(
            textView: textController, delegate: delegate,
            position: CursorPosition(range: NSRange(location: 2, length: 0)), presentIfNot: true)
        try await Task.sleep(for: .milliseconds(50))

        #expect(
            delegate.requestedPositions.contains(2),
            "the newer cursor position was dropped, so the window keeps a list built for the older one"
        )

        delegate.releaseAll()
    }

    /// The bookkeeping half, and the ordering it needs: the *older* request has
    /// to finish while the newer one is still outstanding.
    ///
    /// A superseded request must not clear `itemsRequestTask` after a newer
    /// request has been stored there. If it does, the next call finds nothing to
    /// cancel, so two live requests race and whichever finishes last paints —
    /// which may be the one built for the older cursor position.
    ///
    /// Note this only became reachable once the drop in `cursorsUpdated` was
    /// removed: while that guard stood, a second request could not be started in
    /// the first place, so the clobber had nothing to clobber.
    @Test
    func asupersededRequestDoesNotClearTheOneThatReplacedIt() async throws {
        let (controller, textController, _window) = try makeHost()
        let delegate = BlockingDelegate()

        controller.cursorsUpdated(
            textView: textController, delegate: delegate,
            position: CursorPosition(range: NSRange(location: 1, length: 0)), presentIfNot: true)
        try await Task.sleep(for: .milliseconds(50))
        let firstGeneration = controller.model.requestGeneration
        #expect(delegate.continuations.count == 1)

        controller.cursorsUpdated(
            textView: textController, delegate: delegate,
            position: CursorPosition(range: NSRange(location: 2, length: 0)), presentIfNot: true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.model.requestGeneration > firstGeneration)
        #expect(delegate.continuations.count == 2, "the second request never started")

        // Finish the *first* request only. It is cancelled, so it will unwind
        // through its `defer` while the second is still in flight — the moment
        // the bookkeeping either holds or is clobbered.
        delegate.continuations[0].resume()
        delegate.continuations.remove(at: 0)
        try await Task.sleep(for: .milliseconds(80))

        #expect(
            controller.model.itemsRequestTask != nil,
            "the superseded request cleared the task belonging to the one that replaced it"
        )

        delegate.releaseAll()
    }
}
