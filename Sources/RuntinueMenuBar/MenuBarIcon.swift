import AppKit

enum MenuBarIcon {
  @MainActor
  static func load(from bundle: Bundle? = nil) -> NSImage? {
    // 앱 패키지는 자기 Resources만 사용한다. 소스 실행과 테스트는 SwiftPM 자산을 쓴다.
    let resources = bundle ?? (Bundle.main.bundleURL.pathExtension == "app" ? .main : .module)
    guard
      let url = resources.url(forResource: "RuntinueTemplate", withExtension: "png"),
      let image = NSImage(contentsOf: url),
      image.size.width > 0, image.size.height > 0
    else {
      return nil
    }
    let height: CGFloat = 18
    image.size = NSSize(width: height * image.size.width / image.size.height, height: height)
    image.isTemplate = true
    return image
  }
}
