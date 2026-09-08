import Foundation
import RuntinueUserSupport
import XCTest

class KoreanInterfaceTestCase: XCTestCase {
  private var previousLanguage: Any?

  override func setUp() {
    super.setUp()
    previousLanguage = UserDefaults.standard.object(forKey: InterfaceLanguage.preferenceKey)
    UserDefaults.standard.set("ko", forKey: InterfaceLanguage.preferenceKey)
  }

  override func tearDown() {
    if let previousLanguage {
      UserDefaults.standard.set(previousLanguage, forKey: InterfaceLanguage.preferenceKey)
    } else {
      UserDefaults.standard.removeObject(forKey: InterfaceLanguage.preferenceKey)
    }
    super.tearDown()
  }
}
