import XCTest
@testable import CodexMeterCore

final class PopoverContentConfigurationTests: XCTestCase {
    func testDefaultsShowEverySectionWhileKeepingReserveQuotaHidden() {
        let configuration = PopoverContentConfiguration.defaultValue
        let fiveHour = makeWindow(id: "codex-primary", name: "5h", duration: 300, used: 20)
        let weekly = makeWindow(
            id: "codex-secondary",
            name: "Weekly quota",
            duration: 10_080,
            used: 30
        )
        let reserve = makeWindow(
            id: "base_model_inference-primary",
            name: "Gpt-Reserve · Weekly quota",
            duration: 10_080,
            used: 0
        )

        XCTAssertTrue(configuration.isSectionVisible(.quotaWindows))
        XCTAssertTrue(configuration.isSectionVisible(.resetCredits))
        XCTAssertTrue(configuration.isSectionVisible(.usageWindowStart))
        XCTAssertTrue(configuration.isSectionVisible(.quotaHistory))
        XCTAssertTrue(configuration.isSectionVisible(.tokenActivity))
        XCTAssertEqual(
            configuration.sectionOrder,
            [.quotaWindows, .usageWindowStart, .resetCredits, .quotaHistory, .tokenActivity]
        )
        XCTAssertTrue(configuration.isQuotaWindowVisible(fiveHour))
        XCTAssertTrue(configuration.isQuotaWindowVisible(weekly))
        XCTAssertFalse(configuration.isQuotaWindowVisible(reserve))
        XCTAssertNil(configuration.menuBarQuotaWindowID)
    }

    func testQuotaWindowsCanBeHiddenIndependentlyByStableIdentity() {
        var configuration = PopoverContentConfiguration.defaultValue
        let fiveHour = makeWindow(id: "codex-primary", name: "5h", duration: 300, used: 20)
        let weekly = makeWindow(id: "codex-secondary", name: "Weekly", duration: 10_080, used: 30)

        configuration.setQuotaWindow(fiveHour, visible: false)

        XCTAssertFalse(configuration.isQuotaWindowVisible(fiveHour))
        XCTAssertTrue(configuration.isQuotaWindowVisible(weekly))
        XCTAssertEqual(configuration.visibleQuotaWindows(from: [fiveHour, weekly]), [weekly])
    }

    func testSelectedMenuBarWindowUsesPersistedStableIdentity() {
        var configuration = PopoverContentConfiguration.defaultValue
        let fiveHour = makeWindow(id: "codex-primary", name: "5h", duration: 300, used: 80)
        let weekly = makeWindow(id: "codex-secondary", name: "Weekly", duration: 10_080, used: 20)

        configuration.menuBarQuotaWindowID = weekly.historyID

        XCTAssertEqual(configuration.selectedMenuBarWindow(from: [fiveHour, weekly]), weekly)
    }

    func testMissingMenuBarSelectionFallsBackToLowestRemainingQuota() {
        var configuration = PopoverContentConfiguration.defaultValue
        configuration.menuBarQuotaWindowID = "duration:999:missing"
        let fiveHour = makeWindow(id: "codex-primary", name: "5h", duration: 300, used: 80)
        let weekly = makeWindow(id: "codex-secondary", name: "Weekly", duration: 10_080, used: 20)

        XCTAssertEqual(configuration.selectedMenuBarWindow(from: [weekly, fiveHour]), fiveHour)
    }

    func testAutomaticSelectionUsesWeeklyQuotaWhenItHasLessRemaining() {
        let configuration = PopoverContentConfiguration.defaultValue
        let fiveHour = makeWindow(id: "codex-primary", name: "5h", duration: 300, used: 20)
        let weekly = makeWindow(
            id: "codex-secondary",
            name: "Weekly quota",
            duration: 10_080,
            used: 90
        )

        XCTAssertEqual(configuration.selectedMenuBarWindow(from: [fiveHour, weekly]), weekly)
    }

    func testAutomaticSelectionUsesLowestRemainingAcrossWeeklyBuckets() {
        let configuration = PopoverContentConfiguration.defaultValue
        let reserve = makeWindow(
            id: "base_model_inference-primary",
            name: "Gpt-Reserve · Weekly quota",
            duration: 10_080,
            used: 90
        )
        let weekly = makeWindow(
            id: "codex-secondary",
            name: "Weekly quota",
            duration: 10_080,
            used: 76
        )

        XCTAssertEqual(configuration.selectedMenuBarWindow(from: [reserve, weekly]), reserve)
    }

    func testHistoryDefaultIgnoresOtherWeeklyBuckets() {
        let reserve = QuotaHistoryWindow(
            id: "duration:10080:base_model_inference",
            name: "Gpt-Reserve · Weekly quota",
            windowDurationMins: 10_080,
            resetsAt: nil
        )
        let weekly = QuotaHistoryWindow(
            id: "duration:10080:codex",
            name: "Weekly quota",
            windowDurationMins: 10_080,
            resetsAt: nil
        )

        XCTAssertEqual(QuotaWindowSelection.preferredDefault(from: [reserve, weekly]), weekly)
    }

    func testMovingSectionChangesOnlyItsStoredOrder() {
        var configuration = PopoverContentConfiguration.defaultValue

        configuration.moveSection(.tokenActivity, by: -1)

        XCTAssertEqual(
            configuration.sectionOrder,
            [.quotaWindows, .usageWindowStart, .resetCredits, .tokenActivity, .quotaHistory]
        )
        XCTAssertTrue(configuration.isSectionVisible(.resetCredits))
        XCTAssertTrue(configuration.isSectionVisible(.tokenActivity))
    }

    func testDecodingAnOlderOrderAddsTheWindowStartSectionExactlyOnce() throws {
        // A configuration saved before the window-start section existed, with a
        // custom order and one hidden section.
        let stored = """
        {
          "sectionOrder" : ["tokenActivity", "quotaWindows"],
          "hiddenSections" : ["quotaHistory"],
          "hiddenQuotaWindowIDs" : [],
          "menuBarQuotaWindowID" : null
        }
        """

        let configuration = try JSONDecoder().decode(
            PopoverContentConfiguration.self,
            from: Data(stored.utf8)
        )

        XCTAssertEqual(configuration.sectionOrder.filter { $0 == .usageWindowStart }.count, 1)
        XCTAssertEqual(configuration.sectionOrder.prefix(2), [.tokenActivity, .quotaWindows])
        XCTAssertTrue(configuration.isSectionVisible(.usageWindowStart))
        XCTAssertFalse(configuration.isSectionVisible(.quotaHistory))
        XCTAssertEqual(
            configuration.sectionOrder.sorted { $0.rawValue < $1.rawValue },
            PopoverContentSection.allCases.sorted { $0.rawValue < $1.rawValue }
        )
    }

    func testDecodingOlderEmptyPreferencesUsesCurrentDefaults() throws {
        let configuration = try JSONDecoder().decode(
            PopoverContentConfiguration.self,
            from: Data("{}".utf8)
        )

        XCTAssertEqual(configuration, .defaultValue)
    }

    func testPreIntegrationPreferencesInsertPanelImmediatelyAfterQuota() throws {
        let stored = Data(#"{"sectionOrder":["quotaWindows","resetCredits","quotaHistory","tokenActivity"]}"#.utf8)
        let configuration = try JSONDecoder().decode(PopoverContentConfiguration.self, from: stored)
        XCTAssertEqual(configuration.sectionOrder, [.quotaWindows, .usageWindowStart, .resetCredits, .quotaHistory, .tokenActivity])
    }

    func testLegacyDefaultPanelPositionMigratesWithoutChangingVisibility() throws {
        let stored = Data(#"{"sectionOrder":["quotaWindows","resetCredits","usageWindowStart","quotaHistory","tokenActivity"],"hiddenSections":["usageWindowStart"]}"#.utf8)
        let configuration = try JSONDecoder().decode(PopoverContentConfiguration.self, from: stored)
        XCTAssertEqual(configuration.sectionOrder, PopoverContentConfiguration.defaultValue.sectionOrder)
        XCTAssertFalse(configuration.isSectionVisible(.usageWindowStart))
    }

    func testNewExplicitOrderSurvivesRoundTripEvenAtOriginalPosition() throws {
        var configuration = PopoverContentConfiguration.defaultValue
        configuration.moveSection(.usageWindowStart, by: 1)
        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(PopoverContentConfiguration.self, from: data)
        XCTAssertEqual(decoded, configuration)
        XCTAssertEqual(decoded.sectionOrder, [.quotaWindows, .resetCredits, .usageWindowStart, .quotaHistory, .tokenActivity])
    }

    private func makeWindow(
        id: String,
        name: String,
        duration: Int,
        used: Int
    ) -> CodexUsageWindow {
        CodexUsageWindow(
            id: id,
            name: name,
            usedPercent: used,
            windowDurationMins: duration,
            resetsAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
    }
}
