import SwiftUI
import Testing
import UIKit

@testable import Heeler

/// The Blocked card as Chat draws it, read through its accessibility
/// elements and its height.
@MainActor
@Suite("Blocked card view", .timeLimit(.minutes(1)))
struct BlockedCardViewTests {
    /// Before a subagent starts, Grok Build's card asks `Allow
    /// <description>?`, and the card's title is that question. Where Grok
    /// cut the question at the card's edge, its `?` is gone; either way the
    /// card shows the words once.
    @Test(arguments: [
        ("grok-35-permission-subagent-62", "Allow Sleep 60 then reply done"),
        ("synthetic-subagent-permission-40", "Allow Sleep 60 then reply d…"),
    ])
    func aSubagentsQuestionShowsOnce(stem: String, title: String) async throws {
        let screen = try GrokCards.screen(stem)
        let store = BlockedCardStore(
            program: .grok, io: BlockedScreenIO(readScreen: { screen }, sendKeys: { _ in }, paste: { _ in }),
            clock: ManualClock().clock)
        store.update(activity: .blocked)
        await store.refresh()
        guard case .card(let card) = store.content else {
            Issue.record("Expected a card, got \(store.content)")
            return
        }
        #expect(card.dialog.title == title)

        let labels = try await Self.labels(
            of: BlockedCardView(store: store, maxHeight: 600, openTerminal: {}), showing: title)

        #expect(labels.filter { $0 == title || $0 == "\(title)?" } == [title], "\(labels)")
    }

    /// A subagent's question titles its card with every line it wraps to:
    /// at a phone's width a fourth line adds as much height as a third. A
    /// second adds less, since a one-line header is as tall as its
    /// Minimize button. A title that isn't the card's own question, here a
    /// tool's name too long for two lines, stops at its second.
    @Test func aSubagentsQuestionShowsEveryLine() async throws {
        var heights: [CGFloat] = []
        for count in 1...4 {
            heights.append(try await Self.height(asking: Self.subagentQuestion(lines: count), sendsOnce: true))
        }
        let second = heights[1] - heights[0]
        let line = heights[2] - heights[1]
        #expect(second > 0, "a second line should show: \(heights)")
        #expect(line > 8, "a third line should add one to the title: \(heights)")
        #expect(
            abs(heights[3] - heights[2] - line) < 1, "the title should show its fourth line as its third: \(heights)")

        let tool = String(repeating: "LongToolName", count: 8)
        let short = try await Self.height(asking: "Allow Edit to notes.txt?", sendsOnce: false)
        let long = try await Self.height(asking: "Allow \(tool) to notes.txt?", sendsOnce: false)
        #expect(abs(long - short - second) < 1, "a tool's title should stop at its second line: \([short, long])")
    }

    // MARK: Helpers

    /// The narrowest iPhone's width, where a title wraps to the most lines.
    private static let phoneWidth: CGFloat = 375

    /// A subagent's question that wraps to `count` lines at `phoneWidth` in
    /// the default text size: each word after `Allow` is too wide to share
    /// its line.
    private static func subagentQuestion(lines count: Int) -> String {
        "Allow " + (1...count).map { "Line\($0)OfTheQuestionText" }.joined(separator: " ") + "?"
    }

    /// The height at `phoneWidth`, in the default text size, of a Grok
    /// Build permission's card asking `question`: before a subagent starts
    /// when `sendsOnce`, as grok-35 does, else before a tool runs.
    private static func height(asking question: String, sendsOnce: Bool) async throws -> CGFloat {
        let labels = [
            "Yes, and don't ask again for anything (always-approve mode)", sendsOnce ? "Yes, send once" : "Yes",
            "No, reject (type to add feedback)",
        ]
        let screen = GrokCardBuilder(
            columns: 160, status: sendsOnce ? "Waiting for subagent…" : nil,
            rows: [GrokCardBuilder.Row("›  \(question)", boldFrom: 3), .blank]
                + labels.enumerated().map { offset, label in
                    GrokCardBuilder.Row.option(
                        "\(offset + 1) (\(offset == 1 ? "●" : "○")) \(label)", cursor: offset == 1)
                },
            hints: ["1/3:select", "Tab:next option", "Ctrl+o:always-approve", "Ctrl+c:cancel", "Esc:scrollback"]
        ).screen
        let dialog = try #require(GrokDialogParser.parse(screen).dialog)
        try #require(dialog.body.first == question && dialog.asksInTitle == sendsOnce, "\(dialog)")
        let store = BlockedCardStore(
            program: .grok, io: BlockedScreenIO(readScreen: { screen }, sendKeys: { _ in }, paste: { _ in }),
            clock: ManualClock().clock)
        store.update(activity: .blocked)
        await store.refresh()
        try #require(store.content == .card(BlockedCard(dialog: dialog, request: nil)))
        let controller = UIHostingController(rootView: BlockedCardView(store: store, maxHeight: 600, openTerminal: {}))
        controller.safeAreaRegions = []
        controller.traitOverrides.preferredContentSizeCategory = .large
        var height: CGFloat = 0
        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: phoneWidth, height: 812), rootViewController: controller
        ) { _ in
            controller.view.layoutIfNeeded()
            height = controller.sizeThatFits(in: CGSize(width: phoneWidth, height: .greatestFiniteMagnitude)).height
        }
        return height
    }

    /// The accessibility labels `view` shows at a phone's width, once one
    /// reads `expected`.
    private static func labels(of view: some View, showing expected: String) async throws -> [String] {
        let controller = UIHostingController(rootView: view)
        var labels: [String] = []
        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: phoneWidth, height: 812), rootViewController: controller
        ) { _ in
            for attempt in 0..<40 {
                controller.view.layoutIfNeeded()
                labels = Self.labels(in: controller.view)
                if labels.contains(expected) { return }
                if attempt < 39 { try await Task.sleep(for: .milliseconds(50)) }
            }
        }
        return labels
    }

    /// Every accessibility label under `root`. SwiftUI containers can
    /// expose an empty or incomplete array while their indexed
    /// accessibility API owns the live elements.
    private static func labels(in root: UIView) -> [String] {
        var visited = Set<ObjectIdentifier>()
        var labels: [String] = []
        func visit(_ node: NSObject) {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return }
            if let label = node.accessibilityLabel, !label.isEmpty { labels.append(label) }
            for element in node.accessibilityElements ?? [] {
                if let object = element as? NSObject { visit(object) }
            }
            let count = node.accessibilityElementCount()
            if count > 0, count != NSNotFound {
                for index in 0..<count {
                    if let object = node.accessibilityElement(at: index) as? NSObject { visit(object) }
                }
            }
            if let view = node as? UIView {
                for subview in view.subviews { visit(subview) }
            }
        }
        visit(root)
        return labels
    }
}
