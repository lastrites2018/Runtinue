import Foundation
import SafeClamIPC

struct MenuBarWiFiObservation: Equatable, Sendable {
  let ssid: String?
  let interfaceName: String?
}

@MainActor
final class MenuBarRefreshController {
  private var task: Task<Void, Never>?

  @discardableResult
  func refresh(
    observeWiFi: @escaping @MainActor () async -> MenuBarWiFiObservation,
    submitWiFi: @escaping @MainActor (MenuBarWiFiObservation) async throws -> Void,
    readStatus: @escaping @MainActor () async throws -> SupervisorStatusWire,
    render: @escaping @MainActor (SupervisorStatusWire?) -> Void
  ) -> Task<Void, Never> {
    if let task {
      return task
    }
    let nextTask = Task { @MainActor [weak self] in
      defer { self?.task = nil }
      guard !Task.isCancelled else {
        return
      }
      let observation = await observeWiFi()
      guard !Task.isCancelled else {
        return
      }
      try? await submitWiFi(observation)
      guard !Task.isCancelled else {
        return
      }
      do {
        let status = try await readStatus()
        guard !Task.isCancelled else {
          return
        }
        render(status)
      } catch {
        guard !Task.isCancelled else {
          return
        }
        render(nil)
      }
    }
    task = nextTask
    return nextTask
  }

  func cancel() {
    task?.cancel()
  }
}
