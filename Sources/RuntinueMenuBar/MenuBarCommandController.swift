import Foundation
import RuntinueIPC

enum MenuBarCommandUpdate {
  case pending
  case succeeded(SupervisorStatusWire)
  case failed(Error)

  var status: SupervisorStatusWire? {
    if case .succeeded(let status) = self {
      return status
    }
    return nil
  }
}

@MainActor
final class MenuBarCommandController {
  private var task: Task<Void, Never>?

  var isCommandInFlight: Bool {
    task != nil
  }

  @discardableResult
  func perform(
    operation: @escaping @MainActor () async throws -> SupervisorStatusWire,
    didUpdate: @escaping @MainActor (MenuBarCommandUpdate) -> Void
  ) -> Task<Void, Never> {
    if let task {
      return task
    }

    let nextTask = Task { @MainActor [weak self] in
      guard let self else {
        return
      }
      guard !Task.isCancelled else {
        task = nil
        return
      }

      let update: MenuBarCommandUpdate
      do {
        update = .succeeded(try await operation())
      } catch {
        update = .failed(error)
      }
      task = nil
      guard !Task.isCancelled else {
        return
      }
      didUpdate(update)
    }
    task = nextTask
    didUpdate(.pending)
    return nextTask
  }

  func cancel() {
    task?.cancel()
  }
}
