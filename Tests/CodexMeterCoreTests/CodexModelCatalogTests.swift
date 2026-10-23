import XCTest
@testable import CodexMeterCore

final class CodexModelCatalogTests: XCTestCase {
    func testPageReadsSlugDisplayNameAndEfforts() {
        let page = CodexModelCatalogParser.page(fromResult: [
            "data": [
                [
                    "id": "catalog-key",
                    "model": "gpt-5",
                    "displayName": "GPT-5",
                    "defaultReasoningEffort": "medium",
                    "isDefault": true,
                    "hidden": false,
                    "supportedReasoningEfforts": [
                        ["reasoningEffort": "low", "description": "Fast"],
                        ["reasoningEffort": "medium", "description": "Balanced"]
                    ]
                ]
            ]
        ])

        XCTAssertEqual(page.models.count, 1)
        let model = page.models[0]
        XCTAssertEqual(model.id, "gpt-5")
        XCTAssertEqual(model.displayName, "GPT-5")
        XCTAssertEqual(model.supportedReasoningEfforts, ["low", "medium"])
        XCTAssertEqual(model.defaultReasoningEffort, "medium")
        XCTAssertTrue(model.isDefault)
        XCTAssertFalse(model.isHidden)
        XCTAssertNil(page.nextCursor)
    }

    func testMissingModelFieldFallsBackToTheCatalogId() {
        let page = CodexModelCatalogParser.page(fromResult: [
            "data": [["id": "gpt-5-mini", "displayName": "Mini"]]
        ])
        XCTAssertEqual(page.models.first?.id, "gpt-5-mini")
        XCTAssertTrue(page.models.first?.supportedReasoningEfforts.isEmpty ?? false)
    }

    func testRowsWithoutAnIdentifierAreDropped() {
        let page = CodexModelCatalogParser.page(fromResult: [
            "data": [["displayName": "No identifier"], ["model": "", "id": ""]]
        ])
        XCTAssertTrue(page.models.isEmpty)
    }

    func testMissingDisplayNameUsesTheSlugAndMissingFlagsDefault() {
        let page = CodexModelCatalogParser.page(fromResult: [
            "data": [["model": "gpt-5"]]
        ])
        let model = page.models[0]
        XCTAssertEqual(model.displayName, "gpt-5")
        XCTAssertFalse(model.isDefault)
        XCTAssertFalse(model.isHidden)
    }

    func testEmptyEffortNamesAreIgnored() {
        let page = CodexModelCatalogParser.page(fromResult: [
            "data": [[
                "model": "gpt-5",
                "supportedReasoningEfforts": [
                    ["reasoningEffort": "low"],
                    ["reasoningEffort": ""],
                    ["description": "no value"]
                ]
            ]]
        ])
        XCTAssertEqual(page.models[0].supportedReasoningEfforts, ["low"])
    }

    func testNextCursorIsReadAndEmptyCursorMeansDone() {
        let withCursor = CodexModelCatalogParser.page(fromResult: [
            "data": [],
            "nextCursor": "page-2"
        ])
        let withoutCursor = CodexModelCatalogParser.page(fromResult: [
            "data": [],
            "nextCursor": ""
        ])
        let nullCursor = CodexModelCatalogParser.page(fromResult: [
            "data": [],
            "nextCursor": NSNull()
        ])

        XCTAssertEqual(withCursor.nextCursor, "page-2")
        XCTAssertNil(withoutCursor.nextCursor)
        XCTAssertNil(nullCursor.nextCursor)
    }

    func testMergedKeepsFirstOccurrenceAcrossPages() {
        let first = CodexModelCatalogParser.Page(
            models: [model("gpt-5", display: "GPT-5")],
            nextCursor: "2"
        )
        let second = CodexModelCatalogParser.Page(
            models: [model("gpt-5", display: "Duplicate"), model("gpt-6", display: "GPT-6")],
            nextCursor: nil
        )

        let merged = CodexModelCatalogParser.merged([first, second])

        XCTAssertEqual(merged.map(\.id), ["gpt-5", "gpt-6"])
        XCTAssertEqual(merged.first?.displayName, "GPT-5")
    }

    // MARK: - Reasoning effort preference

    func testPreferencePicksTheCheapestSupportedEffort() {
        XCTAssertEqual(
            UsageWindowReasoningPreference.preferred(from: ["high", "medium", "low"]),
            "low"
        )
        XCTAssertEqual(
            UsageWindowReasoningPreference.preferred(from: ["high", "xhigh"]),
            "high"
        )
        XCTAssertNil(UsageWindowReasoningPreference.preferred(from: ["ultra", "max"]))
        XCTAssertNil(UsageWindowReasoningPreference.preferred(from: []))
    }

    func testStoredEffortIsKeptOnlyWhileStillSupported() {
        let model = self.model("gpt-5", efforts: ["low", "medium"])

        XCTAssertEqual(
            UsageWindowReasoningPreference.resolved(stored: "medium", model: model),
            "medium"
        )
        // A removed effort returns nil rather than silently switching.
        XCTAssertNil(UsageWindowReasoningPreference.resolved(stored: "ultra", model: model))
        XCTAssertNil(UsageWindowReasoningPreference.resolved(stored: nil, model: model))
    }

    func testSuggestedEffortFallsBackToTheModelDefault() {
        let allUnknown = model("gpt-5", efforts: ["ultra", "max"], defaultEffort: "max")
        XCTAssertEqual(UsageWindowReasoningPreference.suggested(for: allUnknown), "max")

        let noDefault = model("gpt-5", efforts: ["ultra"], defaultEffort: nil)
        XCTAssertEqual(UsageWindowReasoningPreference.suggested(for: noDefault), "ultra")

        let empty = model("gpt-5", efforts: [], defaultEffort: nil)
        XCTAssertNil(UsageWindowReasoningPreference.suggested(for: empty))
    }

    // MARK: - Helpers

    private func model(
        _ id: String,
        display: String = "",
        efforts: [String] = ["low"],
        defaultEffort: String? = "low"
    ) -> CodexModelSummary {
        CodexModelSummary(
            id: id,
            displayName: display.isEmpty ? id : display,
            supportedReasoningEfforts: efforts,
            defaultReasoningEffort: defaultEffort,
            isDefault: false,
            isHidden: false
        )
    }
}
