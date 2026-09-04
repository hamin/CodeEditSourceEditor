//
//  SuggestionViewModel.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 7/22/25.
//

import AppKit

@MainActor
final class SuggestionViewModel: ObservableObject {
    /// The items to be displayed in the window
    @Published var items: [CodeSuggestionEntry] = []
    var itemsRequestTask: Task<Void, Never>?
    /// Incremented for every request issued, so a task can tell whether it is
    /// still the current one by the time it finishes.
    private(set) var requestGeneration: Int = 0
    weak var activeTextView: TextViewController?

    weak var delegate: CodeSuggestionDelegate?

    private var cursorPosition: CursorPosition?
    private var syntaxHighlightedCache: [Int: NSAttributedString] = [:]

    func showCompletions(
        textView: TextViewController,
        delegate: CodeSuggestionDelegate,
        cursorPosition: CursorPosition,
        showWindowOnParent: @escaping @MainActor (NSWindow, NSRect) -> Void
    ) {
        self.activeTextView = nil
        self.delegate = nil
        itemsRequestTask?.cancel()

        guard let targetParentWindow = textView.view.window else { return }

        self.activeTextView = textView
        self.delegate = delegate

        // Where the caret was when this was asked. Checked again before the
        // answer is shown — see the guard in the task below.
        let requestedLocation = cursorPosition.range.location

        // Each request carries the generation it was issued in, so a request
        // that outlives its usefulness cannot clear the bookkeeping for the one
        // that replaced it. Without this, an older task's `defer` nils
        // `itemsRequestTask` after a newer task has been stored there, and the
        // next call finds nothing to cancel — leaving two live requests racing
        // to paint, with the slower one winning.
        requestGeneration &+= 1
        let generation = requestGeneration

        itemsRequestTask = Task {
            defer {
                if generation == requestGeneration {
                    itemsRequestTask = nil
                }
            }

            do {
                guard let completionItems = await delegate.completionSuggestionsRequested(
                    textView: textView,
                    cursorPosition: cursorPosition
                ) else {
                    return
                }

                try Task.checkCancellation()
                try await MainActor.run {
                    try Task.checkCancellation()

                    // The caret may have moved while this was in flight, and
                    // moving does not cancel the request: `cursorsUpdated`'s
                    // refine path answers those keystrokes synchronously from
                    // the list already in hand, without issuing a new one. So
                    // this answer can arrive *after* several refinements and
                    // describe a caret position that no longer exists —
                    // replacing a narrowed list with the wider one it was
                    // narrowed from, which reads as the window ignoring
                    // everything typed after the first character.
                    //
                    // Cancellation cannot cover this. A refinement is not a new
                    // request, so there is nothing to cancel it from; the
                    // position is the only thing that says whether this answer
                    // is still about the present.
                    // The caret may have moved while this was in flight, and
                    // moving does not cancel the request: `cursorsUpdated`'s
                    // refine path answers those keystrokes synchronously from
                    // the list already in hand, without issuing a new one. So
                    // this answer can arrive *after* several refinements and
                    // describe a caret position that no longer exists —
                    // replacing a narrowed list with the wider one it was
                    // narrowed from, which reads as the window ignoring
                    // everything typed after the first character.
                    //
                    // Cancellation cannot cover this. A refinement is not a new
                    // request, so there is nothing to cancel it from; the
                    // position is the only thing that says whether this answer
                    // is still about the present.
                    guard textView.cursorPositions.first?.range.location == requestedLocation else {
                        return
                    }

                    guard let cursorPosition = textView.resolveCursorPosition(completionItems.windowPosition),
                          let cursorRect = textView.textView.layoutManager.rectForOffset(
                            cursorPosition.range.location
                          ),
                          let cursorRect = textView.view.window?.convertToScreen(
                            textView.textView.convert(cursorRect, to: nil)
                          ) else {
                        return
                    }

                    self.items = completionItems.items
                    self.syntaxHighlightedCache = [:]
                    showWindowOnParent(targetParentWindow, cursorRect)
                }
            } catch {
                return
            }
        }
    }

    func cursorsUpdated(
        textView: TextViewController,
        delegate: CodeSuggestionDelegate,
        position: CursorPosition,
        close: () -> Void
    ) {
        // A cursor update that lands while a request is outstanding must not be
        // dropped. The outstanding request was made for an *earlier* position,
        // so discarding the newer one leaves the window showing a list that no
        // longer matches the text — and that list stays live, so applying the
        // selection inserts something the user never typed toward.
        //
        // Typing is faster than the round trip through an async delegate, so
        // this is the common case rather than a rare race: every character
        // after the first in a quick burst arrived while the first character's
        // request was still in flight, and every one of them was discarded.
        //
        // Falling through handles it: either the delegate refines the list it
        // already has, or this closes and asks again for the current position.
        // `showCompletions` cancels whatever was in flight, and a cancelled
        // request cannot paint — it checks for cancellation before it does.

        if activeTextView !== textView {
            close()
            return
        }

        guard let newItems = delegate.completionOnCursorMove(
            textView: textView,
            cursorPosition: position
        ),
              !newItems.isEmpty else {
            close()
            return
        }

        items = newItems
    }

    func didSelect(item: CodeSuggestionEntry) {
        delegate?.completionWindowDidSelect(item: item)
    }

    func applySelectedItem(item: CodeSuggestionEntry, window: NSWindow?) {
        guard let activeTextView else {
            return
        }
        self.delegate?.completionWindowApplyCompletion(
            item: item,
            textView: activeTextView,
            cursorPosition: activeTextView.cursorPositions.first
        )
        window?.close()
    }

    func willClose() {
        items.removeAll()
        activeTextView = nil
    }

    func syntaxHighlights(forIndex index: Int) -> NSAttributedString? {
        if let cached = syntaxHighlightedCache[index] {
            return cached
        }

        if let sourcePreview = items[index].sourcePreview,
           let theme = activeTextView?.theme,
           let font = activeTextView?.font,
           let language = activeTextView?.language {
            let string = TreeSitterClient.quickHighlight(
                string: sourcePreview,
                theme: theme,
                font: font,
                language: language
            )
            syntaxHighlightedCache[index] = string
            return string
        }

        return nil
    }
}
