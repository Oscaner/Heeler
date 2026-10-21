import SwiftUI
import Testing
import UIKit

@testable import Heeler

/// The Blocked card as Chat draws it, read through its accessibility
/// elements.
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

    /// The accessibility labels `view` shows at a phone's width, once one
    /// reads `expected`.
    private static func labels(of view: some View, showing expected: String) async throws -> [String] {
        let controller = UIHostingController(rootView: view)
        var labels: [String] = []
        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: 375, height: 812), rootViewController: controller
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
