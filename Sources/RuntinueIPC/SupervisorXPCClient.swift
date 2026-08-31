import Foundation

public enum SupervisorXPCClientError: Error, Equatable, Sendable {
  case encodingFailed
  case unavailable
  case protocolMismatch
  case rejected(String)
  case malformedResponse
}

public protocol SupervisorControlClient: Sendable {
  func startTrip(_ request: StartTripWireRequest) async throws -> SupervisorStatusWire
  func stop(expectedSessionID: UUID?) async throws -> SupervisorStatusWire
  func status() async throws -> SupervisorStatusWire
  func enableAdaptive(
    idleGraceSeconds: Double,
    hardCapSeconds: Double,
    safetyProfile: WireSafetyProfile
  ) async throws -> SupervisorStatusWire
  func disableAdaptive() async throws -> SupervisorStatusWire
  func enableDesk(
    allowClosedLid: Bool,
    hardCapSeconds: Double,
    safetyProfile: WireSafetyProfile
  ) async throws -> SupervisorStatusWire
  func disableDesk() async throws -> SupervisorStatusWire
}

extension SupervisorControlClient {
  public func enableAdaptive(
    idleGraceSeconds: Double,
    hardCapSeconds: Double
  ) async throws -> SupervisorStatusWire {
    try await enableAdaptive(
      idleGraceSeconds: idleGraceSeconds,
      hardCapSeconds: hardCapSeconds,
      safetyProfile: .bagSafe
    )
  }

  public func enableDesk(
    allowClosedLid: Bool,
    hardCapSeconds: Double
  ) async throws -> SupervisorStatusWire {
    try await enableDesk(
      allowClosedLid: allowClosedLid,
      hardCapSeconds: hardCapSeconds,
      safetyProfile: .bagSafe
    )
  }
}

public actor SupervisorXPCClient {
  private let machServiceName: String
  private let requestTimeout: TimeInterval

  public init(
    machServiceName: String = RuntinueIPCContract.supervisorMachServiceName,
    requestTimeout: TimeInterval = 10
  ) {
    self.machServiceName = machServiceName
    self.requestTimeout = requestTimeout
  }

  public func startTrip(
    _ request: StartTripWireRequest
  ) async throws -> SupervisorStatusWire {
    guard let data = try? JSONEncoder().encode(request) else {
      throw SupervisorXPCClientError.encodingFailed
    }
    return try await perform { proxy, reply in
      proxy.startTrip(data, withReply: reply)
    }
  }

  public func stop(
    expectedSessionID: UUID? = nil
  ) async throws -> SupervisorStatusWire {
    guard
      let data = try? JSONEncoder().encode(
        StopSessionWireRequest(expectedSessionID: expectedSessionID)
      )
    else {
      throw SupervisorXPCClientError.encodingFailed
    }
    return try await perform { proxy, reply in
      proxy.stop(data, withReply: reply)
    }
  }

  public func enableAdaptive(
    idleGraceSeconds: Double,
    hardCapSeconds: Double,
    safetyProfile: WireSafetyProfile
  ) async throws -> SupervisorStatusWire {
    guard
      let data = try? JSONEncoder().encode(
        EnableAdaptiveWireRequest(
          idleGraceSeconds: idleGraceSeconds,
          hardCapSeconds: hardCapSeconds,
          safetyProfile: safetyProfile
        )
      )
    else {
      throw SupervisorXPCClientError.encodingFailed
    }
    return try await perform { proxy, reply in
      proxy.enableAdaptive(data, withReply: reply)
    }
  }

  public func disableAdaptive() async throws -> SupervisorStatusWire {
    guard let data = try? JSONEncoder().encode(DisableAdaptiveWireRequest()) else {
      throw SupervisorXPCClientError.encodingFailed
    }
    return try await perform { proxy, reply in
      proxy.disableAdaptive(data, withReply: reply)
    }
  }

  public func enableDesk(
    allowClosedLid: Bool,
    hardCapSeconds: Double,
    safetyProfile: WireSafetyProfile
  ) async throws -> SupervisorStatusWire {
    guard
      let data = try? JSONEncoder().encode(
        EnableDeskWireRequest(
          allowClosedLid: allowClosedLid,
          hardCapSeconds: hardCapSeconds,
          safetyProfile: safetyProfile
        )
      )
    else {
      throw SupervisorXPCClientError.encodingFailed
    }
    return try await perform { proxy, reply in
      proxy.enableDesk(data, withReply: reply)
    }
  }

  public func disableDesk() async throws -> SupervisorStatusWire {
    guard let data = try? JSONEncoder().encode(DisableDeskWireRequest()) else {
      throw SupervisorXPCClientError.encodingFailed
    }
    return try await perform { proxy, reply in
      proxy.disableDesk(data, withReply: reply)
    }
  }

  public func status() async throws -> SupervisorStatusWire {
    try await perform { proxy, reply in
      proxy.status(withReply: reply)
    }
  }

  public func submitWiFiObservation(
    ssid: String?,
    interfaceName: String?
  ) async throws {
    guard
      let data = try? JSONEncoder().encode(
        WiFiObservationWireRequest(
          ssid: ssid,
          interfaceName: interfaceName
        )
      ),
      let responseData = await send({ proxy, reply in
        proxy.submitWiFiObservation(data, withReply: reply)
      }),
      let response = try? JSONDecoder().decode(
        WiFiObservationWireResponse.self,
        from: responseData
      )
    else {
      throw SupervisorXPCClientError.unavailable
    }
    guard response.protocolVersion == RuntinueIPCContract.protocolVersion else {
      throw SupervisorXPCClientError.protocolMismatch
    }
    guard response.accepted else {
      throw SupervisorXPCClientError.rejected(
        response.detail ?? "supervisor rejected the Wi-Fi observation"
      )
    }
  }

  private func perform(
    _ operation:
      @escaping (
        SupervisorControlXPCProtocol,
        @escaping (Data) -> Void
      ) -> Void
  ) async throws -> SupervisorStatusWire {
    guard let responseData = await send(operation) else {
      throw SupervisorXPCClientError.unavailable
    }
    guard
      let response = try? JSONDecoder().decode(
        SupervisorCommandWireResponse.self,
        from: responseData
      )
    else {
      throw SupervisorXPCClientError.malformedResponse
    }
    guard response.protocolVersion == RuntinueIPCContract.protocolVersion else {
      throw SupervisorXPCClientError.protocolMismatch
    }
    guard response.outcome == .success, let status = response.status else {
      throw SupervisorXPCClientError.rejected(
        response.error ?? "supervisor rejected the request"
      )
    }
    guard status.protocolVersion == RuntinueIPCContract.protocolVersion else {
      throw SupervisorXPCClientError.protocolMismatch
    }
    return status
  }

  private func send(
    _ operation:
      @escaping (
        SupervisorControlXPCProtocol,
        @escaping (Data) -> Void
      ) -> Void
  ) async -> Data? {
    await withCheckedContinuation { continuation in
      let connection = NSXPCConnection(
        machServiceName: machServiceName,
        options: []
      )
      connection.remoteObjectInterface = NSXPCInterface(
        with: SupervisorControlXPCProtocol.self
      )
      let gate = SupervisorXPCResponseGate(
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
        }) as? SupervisorControlXPCProtocol
      else {
        gate.resolve(nil)
        return
      }
      operation(proxy) { data in
        gate.resolve(data)
      }
      gate.scheduleTimeout(after: requestTimeout)
    }
  }
}

extension SupervisorXPCClient: SupervisorControlClient {}

private final class SupervisorXPCResponseGate: @unchecked Sendable {
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
    DispatchQueue.global(qos: .userInitiated).asyncAfter(
      deadline: .now() + timeout
    ) { [weak self] in
      self?.resolve(nil)
    }
  }
}
