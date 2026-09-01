import Foundation
import RuntinueIPC
import RuntinueSupervisorSystem

final class SupervisorListenerDelegate: NSObject, NSXPCListenerDelegate,
  @unchecked Sendable
{
  private let role: SupervisorCallerRole
  private let runtime: SupervisorRuntime
  private let authenticator: SupervisorCallerAuthenticator
  private let maximumConnections: Int
  private let lock = NSLock()
  private var activeConnections = 0

  init(
    role: SupervisorCallerRole,
    runtime: SupervisorRuntime,
    authenticator: SupervisorCallerAuthenticator,
    maximumConnections: Int = 8
  ) {
    self.role = role
    self.runtime = runtime
    self.authenticator = authenticator
    self.maximumConnections = maximumConnections
  }

  func listener(
    _ listener: NSXPCListener,
    shouldAcceptNewConnection connection: NSXPCConnection
  ) -> Bool {
    guard authenticator.configureAuthentication(on: connection) else {
      Task { await runtime.recordEvent(.authorizationRejected, attemptID: UUID()) }
      return false
    }
    guard reserveConnectionSlot() else {
      return false
    }

    switch role {
    case .control:
      connection.exportedInterface = NSXPCInterface(
        with: SupervisorControlXPCProtocol.self
      )
      connection.exportedObject = SupervisorControlService(runtime: runtime)
    case .activity:
      connection.exportedInterface = NSXPCInterface(
        with: SupervisorActivityXPCProtocol.self
      )
      connection.exportedObject = SupervisorActivityService(runtime: runtime)
    }
    connection.invalidationHandler = { [weak self] in
      self?.releaseConnectionSlot()
    }
    connection.resume()
    return true
  }

  private func reserveConnectionSlot() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard activeConnections < maximumConnections else {
      return false
    }
    activeConnections += 1
    return true
  }

  private func releaseConnectionSlot() {
    lock.lock()
    activeConnections = max(0, activeConnections - 1)
    lock.unlock()
  }
}
