import XCTest
@testable import SynapseCore

final class MarkdownBlocksTests: XCTestCase {
    func testTypicalModelReply() {
        let reply = """
        ## Zebra stripes

        Stripes **deter flies**:
        - they break up *landing* cues
          - nested detail
        2. heat regulation

        > A quoted line
        > continues here

        ```swift
        let x = 1

        print(x)
        ```
        ---
        Done.
        """
        XCTAssertEqual(MarkdownBlock.parse(reply), [
            .heading(level: 2, text: "Zebra stripes"),
            .paragraph("Stripes **deter flies**:"),
            .listItem(marker: "•", text: "they break up *landing* cues", depth: 0),
            .listItem(marker: "•", text: "nested detail", depth: 1),
            .listItem(marker: "2.", text: "heat regulation", depth: 0),
            .quote("A quoted line\ncontinues here"),
            .code(language: "swift", text: "let x = 1\n\nprint(x)"),
            .rule,
            .paragraph("Done."),
        ])
    }

    func testStreamingUnclosedFenceAndPlainText() {
        XCTAssertEqual(MarkdownBlock.parse("Here:\n```\npartial"), [.paragraph("Here:"), .code(language: nil, text: "partial")])
        XCTAssertEqual(MarkdownBlock.parse("Today is **October 25, 2024**."), [.paragraph("Today is **October 25, 2024**.")])
        XCTAssertEqual(MarkdownBlock.parse("#hashtag is not a heading"), [.paragraph("#hashtag is not a heading")])
        XCTAssertEqual(MarkdownBlock.parse(""), [])
    }
}
