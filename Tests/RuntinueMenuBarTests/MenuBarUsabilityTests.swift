import AppKit
import RuntinueUserSupport
import XCTest

@testable import RuntinueIPC
@testable import RuntinueMenuBar

@MainActor
final class MenuBarUsabilityTests: KoreanInterfaceTestCase {
  func testOpenTimedSessionShowsOnlyStateRemainingTimeAndLidHint() {
    let presentation = MenuBarPresentation(status: status())
    XCTAssertEqual(presentation.headline, "Mac이 잠자지 않도록 하는 중")
    XCTAssertEqual(presentation.guidance, "42분 남음")
    XCTAssertEqual(
      presentation.detail,
      "비활성 상태에서도 디스플레이가 꺼지지 않음 | 덮개 열기 필요")
    XCTAssertNil(presentation.safetyChecklist)
    XCTAssertEqual(presentation.tone, .progress)
    XCTAssertEqual(presentation.statusIndicator, "✓")
    XCTAssertFalse(presentation.summary.contains("덮개 닫기 가능"))
  }

  func testTimedCountdownDoesNotInventAnEndOrConvertInvalidNumbers() {
    for seconds: Double? in [nil, 0, -1, .nan, .infinity, 86_401] {
      let presentation = MenuBarPresentation(status: status(remaining: seconds))
      XCTAssertEqual(presentation.guidance, "남은 시간 확인 불가")
      XCTAssertEqual(presentation.headline, "Mac이 잠자지 않도록 하는 중")
    }
    for seconds in [0.1, 1, 59.9] {
      XCTAssertEqual(
        MenuBarPresentation(status: status(remaining: seconds)).guidance, "1분 미만 남음")
    }
    XCTAssertEqual(MenuBarPresentation(status: status(remaining: 60)).guidance, "1분 남음")
    XCTAssertEqual(
      MenuBarPresentation(status: status(remaining: 5_400)).guidance, "1시간 30분 남음")
  }

  func testTimedSupplementalDetailsAndObservationWarningsRemainVisible() {
    let presentation = MenuBarPresentation(
      status: status(detail: "fixture detail", issues: [.historyUnavailable]))
    XCTAssertTrue(presentation.detail.hasPrefix("비활성 상태에서도 디스플레이가 꺼지지 않음"))
    XCTAssertTrue(presentation.detail.contains("서비스의 추가 상태 정보"))
    XCTAssertTrue(presentation.detail.contains("일부 기록을 저장하지 못했습니다"))
    XCTAssertEqual(presentation.tone, .progress)
  }

  func testTimedFailureAndRecoveryStatesKeepTheirExistingWarnings() {
    for (phase, verdict, indicator) in [
      (WireTripPhase.releasingLease, WireProtectionVerdict.releasing, "!"),
      (.recoveryPending, .recoveryPending, "!"),
      (.ended, .unsafe, "!"),
      (.active, .unknown, "?"),
    ] {
      let presentation = MenuBarPresentation(
        status: status(phase: phase, verdict: verdict, detail: "fixture failure"))
      XCTAssertEqual(presentation.statusIndicator, indicator)
      XCTAssertEqual(presentation.guidance, "덮개를 닫지 마세요.")
      XCTAssertNotEqual(presentation.headline, "Mac이 잠자지 않도록 하는 중")
      XCTAssertTrue(presentation.detail.contains("진단 정보를 확인하세요"))
    }
    XCTAssertEqual(
      MenuBarPresentation(status: status(), isCommandInFlight: true).headline, "요청 처리 중")
    XCTAssertEqual(MenuBarPresentation(status: nil).statusIndicator, "?")
  }

  func testClosedDeskAndOtherModesKeepDetailedPresentation() {
    for mode: WireSessionMode in [.trip, .adaptive, .desk] {
      let presentation = MenuBarPresentation(status: status(mode: mode, closedLidAllowed: true))
      XCTAssertEqual(presentation.guidance, "덮개 닫기 가능")
      XCTAssertTrue(presentation.detail.contains("배터리 78%"))
      XCTAssertTrue(presentation.detail.contains("macOS 열 압력"))
      XCTAssertEqual(presentation.tone, .verified)
    }
    let trip = MenuBarPresentation(status: status(mode: .trip, closedLidAllowed: true))
    XCTAssertEqual(trip.safetyChecklist?.items.count, 4)
  }

  func testSupportGroupingRetainsActionsAndRemainsAccessibleWithoutSessionStatus() throws {
    _ = NSApplication.shared
    let target = SupportActionTarget()
    let items = (0..<4).map { index in
      let item = NSMenuItem(
        title: "Item \(index)", action: #selector(SupportActionTarget.invoke(_:)),
        keyEquivalent: index == 3 ? "r" : "")
      item.target = target
      item.tag = index
      return item
    }
    let parent = MenuBarSupportMenu.make(
      history: items[0], events: items[1], diagnostics: items[2], refresh: items[3])
    let menu = try XCTUnwrap(parent.submenu)
    XCTAssertEqual(parent.title, "기록과 진단")
    XCTAssertEqual(menu.numberOfItems, 5)
    XCTAssertFalse(menu.autoenablesItems)
    XCTAssertTrue(try XCTUnwrap(menu.item(at: 3)).isSeparatorItem)
    for (offset, item) in items.enumerated() {
      let index = offset == 3 ? 4 : offset
      XCTAssertTrue(menu.item(at: index) === item)
      menu.performActionForItem(at: index)
    }
    XCTAssertEqual(target.tags, [0, 1, 2, 3])
    XCTAssertFalse(MenuBarActionAvailability(status: nil, isCommandInFlight: false).canStart)
    items[0].isEnabled = false
    items[1].isEnabled = false
    items[2].isEnabled = false
    menu.update()
    XCTAssertTrue(parent.isEnabled)
    XCTAssertTrue(items[3].isEnabled)
    XCTAssertEqual(items[3].keyEquivalent, "r")

    UserDefaults.standard.set("en", forKey: InterfaceLanguage.preferenceKey)
    let rebuilt = MenuBarSupportMenu.make(
      history: items[0], events: items[1], diagnostics: items[2], refresh: items[3])
    XCTAssertEqual(rebuilt.title, "History and Diagnostics")
    XCTAssertTrue(rebuilt.submenu?.item(at: 0) === items[0])
    XCTAssertFalse(items[0].isEnabled)
    XCTAssertTrue(items[3].isEnabled)
  }

  func testVersionMetadataKeepsVersionBuildAndSourceIdentitySeparate() {
    let information = AppBuildInformation(dictionary: metadata())
    XCTAssertEqual(information.versionLine, "버전 0.4.0, 빌드 1")
    XCTAssertEqual(information.sourceLine, "소스 커밋: abcdef12")
    XCTAssertEqual(information.sourceStateText, "커밋 이후 추가 변경 없음")
    XCTAssertTrue(information.copyText.contains(String(repeating: "abcdef12", count: 5)))
    XCTAssertEqual(information.copyText.components(separatedBy: "\n").count, 5)
    XCTAssertFalse(information.copyText.contains("ignored-private-data"))
    var changed = metadata()
    changed["RuntinueSourceCommit"] = String(repeating: "b", count: 40)
    XCTAssertNotEqual(information.sourceCommit, AppBuildInformation(dictionary: changed).sourceCommit)
    changed["RuntinueSourceDirty"] = true
    XCTAssertEqual(AppBuildInformation(dictionary: changed).sourceStateText, "커밋되지 않은 변경 포함")
  }

  func testMissingAndPlaceholderMetadataIsNeverPresentedAsARelease() {
    for dictionary: [String: Any] in [
      [:],
      ["CFBundleShortVersionString": "VERSION_FROM_BUILD", "CFBundleVersion": "unknown",
       "RuntinueSourceCommit": "COMMIT_FROM_BUILD", "RuntinueSourceDirty": "false"],
      ["CFBundleShortVersionString": "0.4.0\n", "CFBundleVersion": true,
       "RuntinueSourceCommit": "abcdef12", "RuntinueSourceDirty": 1],
    ] {
      let information = AppBuildInformation(dictionary: dictionary)
      XCTAssertNil(information.version)
      XCTAssertNil(information.buildNumber)
      XCTAssertNil(information.sourceCommit)
      XCTAssertNil(information.sourceDirty)
      XCTAssertEqual(information.versionLine, "버전 정보 없음, 빌드 정보 없음")
      XCTAssertEqual(information.sourceStateText, "빌드 시 변경 여부 확인 불가")
      XCTAssertFalse(information.copyText.contains("최신"))
      XCTAssertFalse(information.copyText.contains("정식"))
    }
  }

  func testVersionReaderUsesTheProvidedAppBundleRatherThanRepositoryVersion() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
    defer { try? FileManager.default.removeItem(at: url) }
    let contents = url.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    var dictionary = metadata()
    dictionary["CFBundleIdentifier"] = "invalid.example.runtinue-fixture"
    dictionary["CFBundlePackageType"] = "APPL"
    dictionary["CFBundleShortVersionString"] = "9.8.7"
    let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))
    let bundle = try XCTUnwrap(Bundle(url: url))
    XCTAssertEqual(AppBuildInformation(bundle: bundle).version, "9.8.7")
  }

  func testAboutWindowLocalizesAndCopiesOnlyLocalVersionMetadata() throws {
    _ = NSApplication.shared
    let controller = AppInformationWindowController(information: AppBuildInformation(dictionary: metadata()))
    defer { controller.close() }
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("RuntinueFixture-" + UUID().uuidString))
    defer { pasteboard.releaseGlobally() }
    for (language, title, headline, countdown, scopeText) in [
      (
        "ko", "Runtinue 정보", "Mac이 잠자지 않도록 하는 중", "42분 남음",
        "현재 메뉴 막대 앱의 빌드 정보입니다."
      ),
      (
        "en", "About Runtinue", "Keeping Mac awake", "42m remaining",
        "Build information for this menu bar app."
      ),
    ] {
      UserDefaults.standard.set(language, forKey: InterfaceLanguage.preferenceKey)
      controller.reloadLabels()
      let window = try XCTUnwrap(controller.window)
      XCTAssertEqual(window.title, title)
      let content = try XCTUnwrap(window.contentView)
      content.layoutSubtreeIfNeeded()
      let version: NSTextField = try control("runtinue.about.version", in: content)
      XCTAssertEqual(version.stringValue, controller.information.versionLine)
      XCTAssertTrue(version.isSelectable)
      let scope: NSTextField = try control("runtinue.about.scope", in: content)
      XCTAssertEqual(scope.stringValue, scopeText)
      for identifier in ["runtinue.about.copy", "runtinue.about.releases"] {
        let button: NSButton = try control(identifier, in: content)
        XCTAssertTrue(button.isEnabled)
        XCTAssertNotNil(button.action)
        let rect = button.convert(button.bounds, to: content)
        XCTAssertGreaterThanOrEqual(rect.minX, 0)
        XCTAssertLessThanOrEqual(rect.maxX, content.bounds.width)
        XCTAssertGreaterThanOrEqual(rect.minY, 0)
        XCTAssertLessThanOrEqual(rect.maxY, content.bounds.height)
      }
      XCTAssertTrue(controller.copyInformation(to: pasteboard))
      XCTAssertEqual(pasteboard.string(forType: .string), controller.information.copyText)
      let presentation = MenuBarPresentation(status: status())
      XCTAssertEqual(presentation.headline, headline)
      XCTAssertEqual(presentation.guidance, countdown)
    }
    XCTAssertEqual(
      AppInformationWindowController.releasesURL.absoluteString,
      "https://github.com/lastrites2018/Runtinue/releases")
  }

  private func metadata() -> [String: Any] {
    [
      "CFBundleShortVersionString": "0.4.0", "CFBundleVersion": "1",
      "RuntinueSourceCommit": String(repeating: "abcdef12", count: 5),
      "RuntinueSourceDirty": false, "Ignored": "ignored-private-data",
    ]
  }

  private func status(
    mode: WireSessionMode = .desk, phase: WireTripPhase = .active,
    verdict: WireProtectionVerdict = .protected, closedLidAllowed: Bool = false,
    remaining: Double? = 2_520, detail: String? = nil, issues: [WireObservationIssue] = []
  ) -> SupervisorStatusWire {
    SupervisorStatusWire(
      phase: phase, mode: mode, sessionID: UUID(), verdict: verdict,
      closedLidAllowed: closedLidAllowed, remainingSeconds: remaining,
      batteryPercent: 78, thermalLevel: "nominal", lidState: closedLidAllowed ? "closed" : "open",
      observation: WireObservationStatus(buildID: nil, issues: issues),
      detail: detail, updatedAt: Date(timeIntervalSince1970: 100))
  }

  private func control<T: NSView>(_ identifier: String, in view: NSView) throws -> T {
    if view.accessibilityIdentifier() == identifier, let control = view as? T { return control }
    for child in view.subviews {
      if let result: T = try? control(identifier, in: child) { return result }
    }
    throw NSError(domain: "MissingUIControl", code: 1)
  }
}

@MainActor
private final class SupportActionTarget: NSObject {
  var tags: [Int] = []
  @objc func invoke(_ sender: NSMenuItem) { tags.append(sender.tag) }
}
