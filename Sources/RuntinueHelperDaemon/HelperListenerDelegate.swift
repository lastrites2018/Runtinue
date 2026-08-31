import Foundation
import RuntinueHelperCore
import RuntinueIPC

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate,
  @unchecked Sendable
{
  private let leaseActor: LeaseActor
  private let authenticator: CallerAuthenticator
  private let maximumConnections: Int
  private let lock = NSLock()
  private var activeConnections = 0

  init(
    leaseActor: LeaseActor,
    authenticator: CallerAuthenticator,
    maximumConnections: Int = 4
  ) {
    self.leaseActor = leaseActor
    self.authenticator = authenticator
    self.maximumConnections = maximumConnections
  }

  func listener(
    _ listener: NSXPCListener,
    shouldAcceptNewConnection connection: NSXPCConnection
  ) -> Bool {
    guard authenticator.accepts(connection), reserveConnectionSlot() else {
      return false
    }

    let service = PrivilegedLeaseService(
      leaseActor: leaseActor,
      ownerUID: connection.effectiveUserIdentifier
    )
    connection.exportedInterface = NSXPCInterface(
      with: PrivilegedLeaseXPCProtocol.self
    )
    connection.exportedObject = service
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
