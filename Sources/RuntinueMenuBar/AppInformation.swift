import AppKit
import CoreFoundation
import RuntinueUserSupport

struct AppBuildInformation: Equatable {
  let version: String?
  let buildNumber: String?
  let sourceCommit: String?
  let sourceDirty: Bool?

  init(bundle: Bundle = .main) {
    self.init(dictionary: bundle.infoDictionary ?? [:])
  }

  init(dictionary: [String: Any]) {
    version = Self.validatedString(
      dictionary["CFBundleShortVersionString"], pattern: "^[0-9]+\\.[0-9]+\\.[0-9]+$", limit: 32)
    buildNumber = Self.validatedString(
      dictionary["CFBundleVersion"], pattern: "^[1-9][0-9]*$", limit: 32)
    sourceCommit = Self.validatedString(
      dictionary["RuntinueSourceCommit"], pattern: "^[0-9a-fA-F]{40}$", limit: 40)?.lowercased()
    if let value = dictionary["RuntinueSourceDirty"] as? NSNumber,
      CFGetTypeID(value) == CFBooleanGetTypeID()
    {
      sourceDirty = value.boolValue
    } else {
      sourceDirty = nil
    }
  }

  var versionLine: String {
    let versionText = version.map { L("버전 \($0)", "Version \($0)") }
      ?? L("버전 정보 없음", "Version unavailable")
    let buildText = buildNumber.map { L("빌드 \($0)", "Build \($0)") }
      ?? L("빌드 정보 없음", "Build unavailable")
    return "\(versionText), \(buildText)"
  }

  var sourceStateText: String {
    guard let sourceDirty else {
      return L("빌드 시 변경 여부 확인 불가", "Build-time source changes unknown")
    }
    return sourceDirty
      ? L("커밋되지 않은 변경 포함", "Includes uncommitted changes")
      : L("커밋 이후 추가 변경 없음", "No uncommitted changes at build time")
  }

  var sourceLine: String {
    let value = sourceCommit.map { String($0.prefix(8)) } ?? L("확인 불가", "Unavailable")
    return L("소스 커밋: \(value)", "Source commit: \(value)")
  }

  var copyText: String {
    [
      "Runtinue",
      L("버전: \(version ?? "확인 불가")", "Version: \(version ?? "Unavailable")"),
      L("빌드: \(buildNumber ?? "확인 불가")", "Build: \(buildNumber ?? "Unavailable")"),
      L("소스 커밋: \(sourceCommit ?? "확인 불가")", "Source commit: \(sourceCommit ?? "Unavailable")"),
      L("빌드 시 변경: \(sourceStateText)", "Source changes at build: \(sourceStateText)"),
    ].joined(separator: "\n")
  }

  private static func validatedString(_ value: Any?, pattern: String, limit: Int) -> String? {
    guard let value = value as? String, !value.isEmpty, value.utf8.count <= limit,
      !value.contains(where: { $0.isNewline }),
      value.range(of: pattern, options: .regularExpression) != nil
    else { return nil }
    return value
  }
}

@MainActor
enum MenuBarSupportMenu {
  static func make(
    history: NSMenuItem, events: NSMenuItem, diagnostics: NSMenuItem, refresh: NSMenuItem
  ) -> NSMenuItem {
    let title = L("기록과 진단", "History and Diagnostics")
    let menu = NSMenu(title: title)
    menu.autoenablesItems = false
    // Language changes reuse the same action items, even if an old submenu is still retained.
    for item in [history, events, diagnostics, refresh] { item.menu?.removeItem(item) }
    for item in [history, events, diagnostics] { menu.addItem(item) }
    menu.addItem(.separator())
    menu.addItem(refresh)
    let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    parent.identifier = NSUserInterfaceItemIdentifier("runtinue.support")
    parent.submenu = menu
    return parent
  }
}

@MainActor
final class AppInformationWindowController: NSWindowController {
  static let releasesURL = URL(string: "https://github.com/lastrites2018/Runtinue/releases")!
  let information: AppBuildInformation

  init(information: AppBuildInformation = AppBuildInformation()) {
    self.information = information
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 310),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    super.init(window: panel)
    reloadLabels()
    panel.center()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func reloadLabels() {
    guard let window else { return }
    window.title = L("Runtinue 정보", "About Runtinue")
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 310))
    let icon = NSImageView()
    icon.image = NSApplication.shared.applicationIconImage
    icon.imageScaling = .scaleProportionallyDown
    icon.setAccessibilityLabel("Runtinue")
    icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
    icon.heightAnchor.constraint(equalToConstant: 64).isActive = true

    let title = label("Runtinue", identifier: "runtinue.about.name")
    title.font = .systemFont(ofSize: 17, weight: .semibold)
    let version = label(information.versionLine, identifier: "runtinue.about.version")
    let commit = label(information.sourceLine, identifier: "runtinue.about.commit")
    commit.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    let source = label(information.sourceStateText, identifier: "runtinue.about.sourceState")
    source.textColor = .secondaryLabelColor
    let scope = label(
      L("현재 메뉴바 앱의 빌드 정보입니다.", "Build information for this menu bar app."),
      identifier: "runtinue.about.scope")
    scope.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    scope.textColor = .secondaryLabelColor

    let copy = NSButton(
      title: L("버전 정보 복사", "Copy Version Info"), target: self,
      action: #selector(copyInformation(_:)))
    copy.bezelStyle = .rounded
    copy.setAccessibilityIdentifier("runtinue.about.copy")
    let releases = NSButton(
      title: L("GitHub 릴리스 보기", "View GitHub Releases"), target: self,
      action: #selector(openReleases(_:)))
    releases.bezelStyle = .rounded
    releases.setAccessibilityIdentifier("runtinue.about.releases")
    let buttons = NSStackView(views: [copy, releases])
    buttons.orientation = .horizontal
    buttons.spacing = 8
    let stack = NSStackView(views: [icon, title, version, commit, source, scope, buttons])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
      stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
      stack.widthAnchor.constraint(equalToConstant: 352),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
    ])
    window.contentView = content
  }

  @discardableResult
  func copyInformation(to pasteboard: NSPasteboard) -> Bool {
    pasteboard.clearContents()
    return pasteboard.setString(information.copyText, forType: .string)
  }

  @objc private func copyInformation(_ sender: Any?) {
    if !copyInformation(to: .general) { NSSound.beep() }
  }

  @objc private func openReleases(_ sender: Any?) {
    if !NSWorkspace.shared.open(Self.releasesURL) { NSSound.beep() }
  }

  private func label(_ text: String, identifier: String) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.alignment = .center
    field.preferredMaxLayoutWidth = 352
    field.isSelectable = true
    field.setAccessibilityIdentifier(identifier)
    return field
  }
}
