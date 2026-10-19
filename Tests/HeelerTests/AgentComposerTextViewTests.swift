import UIKit
import Testing

@testable import Heeler

// SPDX-License-Identifier: Apache-2.0
//
// The open Composer grows to five lines and scrolls past them. Chinese
// lays out taller than the body font's own line height, so a cap counted
// in body lines cut the last line off, and the caret's line stopped short
// of the bottom inset, under the edge fade.

@MainActor
@Suite("Agent Composer text view")
struct AgentComposerTextViewTests {
    private static let width: CGFloat = 300
    private static let lineLimit = 5

    private static func makeEditor() -> AgentComposerUITextView {
        let editor = AgentComposerUITextView(
            frame: CGRect(x: 0, y: 0, width: width, height: 100))
        editor.font = .preferredFont(forTextStyle: .body)
        editor.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        return editor
    }

    private static func cap(_ editor: AgentComposerUITextView) -> CGFloat {
        editor.draftLineHeight * CGFloat(lineLimit)
            + editor.textContainerInset.top + editor.textContainerInset.bottom
    }

    @Test(arguments: ["第一行：检查配对步骤", "first line of the draft"])
    func fiveLinesOfDraftFitTheCap(line: String) {
        let editor = Self.makeEditor()
        editor.text = Array(repeating: line, count: Self.lineLimit).joined(separator: "\n")

        let measured = editor.sizeThatFits(
            CGSize(width: Self.width, height: .greatestFiniteMagnitude))

        #expect(measured.height <= Self.cap(editor) + 0.01)
    }

    @Test func caretOnTheLastLineClearsTheBottomInset() {
        let editor = Self.makeEditor()
        editor.text = (1...7).map { "第\($0)行：检查配对步骤" }.joined(separator: "\n")
        editor.frame.size.height = Self.cap(editor)
        editor.layoutIfNeeded()
        let overflow = editor.contentSize.height - editor.bounds.height
        #expect(overflow > 0)

        editor.scrollRectToVisible(editor.caretRect(for: editor.endOfDocument), animated: false)

        #expect(abs(editor.contentOffset.y - overflow) < 0.5)
    }
}
