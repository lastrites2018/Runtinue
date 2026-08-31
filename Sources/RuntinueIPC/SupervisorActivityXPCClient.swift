import Foundation

public enum SupervisorActivityXPCClientError: Error, Equatable, Sendable {
  case encodingFailed
  case unavailable
  case protocolMismatch
  case malformedResponse
  case rejected(String)
}

public actor SupervisorActivityXPCClient {
  private let machServiceName: String
  private let requestTimeout: TimeInterval

  public init(
    machServiceName: String = RuntinueIPCContract.supervisorActivityMachServiceName,
    requestTimeout: TimeInterval = 5
  ) {
    self.machServiceName = machServiceName
    self.requestTimeout = requestTimeout
  }

  public func ping(
    source: String,
    namedSession: String? = nil
  ) async throws {
    let request = ActivityPingWireRequest(
      source: source,
      namedSession: namedSession
    )
    guard let data = try? JSONEncoder().encode(request) else {
      throw SupervisorActivityXPCClientError.encodingFailed
    }
    guard let responseData = await send(data) else {
      throw SupervisorActivityXPCClientError.unavailable
    }
    guard
      let response = try? JSONDecoder().decode(
        ActivityPingWireResponse.self,
        from: responseData
      )
    else {
      throw SupervisorActivityXPCClientError.malformedResponse
    }
    guard response.protocolVersion == RuntinueIPCContract.protocolVersion else {
      throw SupervisorActivityXPCClientError.protocolMismatch
    }
    guard response.accepted else {
      throw SupervisorActivityXPCClientError.rejected(
        response.detail ?? "activity ping was rejected"
      )
    }
  }

  private func send(_ request: Data) async -> Data? {
    await withCheckedContinuation { continuation in
      let connection = NSXPCConnection(
        machServiceName: machServiceName,
        options: []
      )
      connection.remoteObjectInterface = NSXPCInterface(
        with: SupervisorActivityXPCProtocol.self
      )
      let gate = ActivityXPCResponseGate(
        connection: connection,
        continuation: continuation
      )
      connection.invalidationHandler = {
        gate.resolve(nil)
      }
      connection.interruptionHandler = {
        gate.resolve(nil)
      }
      connection.resume()

      guard
        let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
          gate.resolve(nil)
        }) as? SupervisorActivityXPCProtocol
      else {
        gate.resolve(nil)
        return
      }
      proxy.activityPing(request) { response in
        gate.resolve(response)
      }
      gate.scheduleTimeout(after: requestTimeout)
    }
  }
}

private final class ActivityXPCResponseGate: @unchecked Sendable {
  private let lock = NSLock()
  private let connection: NSXPCConnection
  private var continuation: CheckedContinuation<Data?, Never>?

  init(
    connection: NSXPCConnection,
    continuation: CheckedContinuation<Data?, Never>
  ) {
    self.connection = connection
    self.continuation = continuation
  }

  func resolve(_ data: Data?) {
    lock.lock()
    guard let continuation else {
      lock.unlock()
      return
    }
    self.continuation = nil
    lock.unlock()
    connection.invalidate()
    continuation.resume(returning: data)
  }

  func scheduleTimeout(after timeout: TimeInterval) {
    DispatchQueue.global(qos: .utility).asyncAfter(
      deadline: .now() + timeout
    ) { [weak self] in
      self?.resolve(nil)
    }
  }
}
