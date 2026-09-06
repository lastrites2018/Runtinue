import Darwin
import Foundation
import IOKit
import RuntinueCore

public protocol TemperatureTelemetrySampling: Sendable {
  func sample() async -> TemperatureTelemetrySnapshot
}

public actor MacTemperatureTelemetrySampler: TemperatureTelemetrySampling {
  static let freshnessInterval: TimeInterval = 15

  private let machineModel: String?
  private let operatingSystemBuild: String?
  private var connection: AppleSMCConnection?
  private var lastSuccessfulAt: Date?

  public init() {
    self.machineModel = Self.readSystemString("hw.model")
    self.operatingSystemBuild = Self.readSystemString("kern.osversion")
  }

  init(machineModel: String?, operatingSystemBuild: String? = nil) {
    self.machineModel = machineModel
    self.operatingSystemBuild = operatingSystemBuild
  }

  public func sample() async -> TemperatureTelemetrySnapshot {
    let sampledAt = Date()
    guard let machineModel else {
      return TemperatureTelemetrySnapshot(
        status: .unsupportedModel,
        source: .appleSMC,
        machineModel: nil,
        operatingSystemBuild: operatingSystemBuild,
        mappingRevision: nil,
        mappingQuality: nil,
        sampledAt: sampledAt,
        validUntil: nil,
        lastSuccessfulAt: nil,
        components: []
      )
    }
    guard MacTemperatureSensorMapping.hasCandidate(for: machineModel) else {
      return TemperatureTelemetrySnapshot(
        status: .unsupportedModel,
        source: .appleSMC,
        machineModel: machineModel,
        operatingSystemBuild: operatingSystemBuild,
        mappingRevision: nil,
        mappingQuality: nil,
        sampledAt: sampledAt,
        validUntil: nil,
        lastSuccessfulAt: nil,
        components: []
      )
    }
    guard let operatingSystemBuild,
      let mapping = MacTemperatureSensorMapping.validatedMapping(
        for: machineModel,
        operatingSystemBuild: operatingSystemBuild
      )
    else {
      return TemperatureTelemetrySnapshot(
        status: .mappingUnverified,
        source: .appleSMC,
        machineModel: machineModel,
        operatingSystemBuild: operatingSystemBuild,
        mappingRevision: nil,
        mappingQuality: nil,
        sampledAt: sampledAt,
        validUntil: nil,
        lastSuccessfulAt: nil,
        components: []
      )
    }

    do {
      let connection: AppleSMCConnection
      if let current = self.connection {
        connection = current
      } else {
        let opened = try AppleSMCConnection()
        self.connection = opened
        connection = opened
      }

      var values: [String: Double] = [:]
      for key in mapping.allKeys {
        if let value = try? connection.readFloat(key: key) {
          values[key] = Double(value)
        }
      }
      let snapshot = Self.makeSnapshot(
        mapping: mapping,
        values: values,
        sampledAt: sampledAt,
        previousSuccessfulAt: lastSuccessfulAt
      )
      if snapshot.status == .available || snapshot.status == .partial {
        lastSuccessfulAt = sampledAt
      } else {
        self.connection = nil
      }
      return snapshot
    } catch {
      connection = nil
      return Self.unavailableSnapshot(
        mapping: mapping,
        sampledAt: sampledAt,
        lastSuccessfulAt: lastSuccessfulAt
      )
    }
  }

  static func makeSnapshot(
    mapping: MacTemperatureSensorMapping,
    values: [String: Double],
    sampledAt: Date,
    previousSuccessfulAt: Date?
  ) -> TemperatureTelemetrySnapshot {
    let cpu = makeObservation(
      component: .cpuInternal,
      keys: mapping.cpuKeys,
      values: values
    )
    let gpu = makeObservation(
      component: .gpuInternal,
      keys: mapping.gpuKeys,
      values: values
    )
    let observations = [cpu, gpu]
    let validCount = observations.reduce(0) { $0 + $1.validSensorCount }
    guard validCount > 0 else {
      return unavailableSnapshot(
        mapping: mapping,
        sampledAt: sampledAt,
        lastSuccessfulAt: previousSuccessfulAt
      )
    }
    let isComplete = observations.allSatisfy {
      $0.validSensorCount == $0.expectedSensorCount
    }
    return TemperatureTelemetrySnapshot(
      status: isComplete ? .available : .partial,
      source: .appleSMC,
      machineModel: mapping.machineModel,
      operatingSystemBuild: mapping.operatingSystemBuild,
      mappingRevision: mapping.revision,
      mappingQuality: mapping.quality,
      sampledAt: sampledAt,
      validUntil: sampledAt.addingTimeInterval(freshnessInterval),
      lastSuccessfulAt: sampledAt,
      components: observations
    )
  }

  private static func makeObservation(
    component: TemperatureComponent,
    keys: [String],
    values: [String: Double]
  ) -> ComponentTemperatureObservation {
    let valid = keys.compactMap { key -> (String, Double)? in
      guard let value = values[key], value.isFinite, value > 0, value <= 150 else {
        return nil
      }
      return (key, value)
    }
    let temperatures = valid.map(\.1)
    return ComponentTemperatureObservation(
      component: component,
      minimumCelsius: temperatures.min(),
      maximumCelsius: temperatures.max(),
      validSensorCount: valid.count,
      expectedSensorCount: keys.count,
      validSensorIDs: valid.map(\.0)
    )
  }

  private static func unavailableSnapshot(
    mapping: MacTemperatureSensorMapping,
    sampledAt: Date,
    lastSuccessfulAt: Date?
  ) -> TemperatureTelemetrySnapshot {
    TemperatureTelemetrySnapshot(
      status: .temporarilyUnavailable,
      source: .appleSMC,
      machineModel: mapping.machineModel,
      operatingSystemBuild: mapping.operatingSystemBuild,
      mappingRevision: mapping.revision,
      mappingQuality: mapping.quality,
      sampledAt: sampledAt,
      validUntil: nil,
      lastSuccessfulAt: lastSuccessfulAt,
      components: [
        ComponentTemperatureObservation(
          component: .cpuInternal,
          minimumCelsius: nil,
          maximumCelsius: nil,
          validSensorCount: 0,
          expectedSensorCount: mapping.cpuKeys.count,
          validSensorIDs: []
        ),
        ComponentTemperatureObservation(
          component: .gpuInternal,
          minimumCelsius: nil,
          maximumCelsius: nil,
          validSensorCount: 0,
          expectedSensorCount: mapping.gpuKeys.count,
          validSensorIDs: []
        ),
      ]
    )
  }

  private static func readSystemString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else {
      return nil
    }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
      return nil
    }
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
  }
}

struct MacTemperatureSensorMapping: Equatable, Sendable {
  let machineModel: String
  let operatingSystemBuild: String
  let revision: String
  let quality: TemperatureMappingQuality
  let cpuKeys: [String]
  let gpuKeys: [String]

  var allKeys: [String] {
    cpuKeys + gpuKeys
  }

  static func hasCandidate(for machineModel: String) -> Bool {
    machineModel == "Mac17,8"
  }

  static func validatedMapping(
    for machineModel: String,
    operatingSystemBuild: String
  ) -> Self? {
    guard machineModel == "Mac17,8", operatingSystemBuild == "25F84" else {
      return nil
    }
    // Verified on one Mac17,8 by comparing CPU-only and GPU-only load responses.
    // Tg1g was absent on that device and is deliberately not inferred from nearby keys.
    return Self(
      machineModel: machineModel,
      operatingSystemBuild: operatingSystemBuild,
      revision: "Mac17,8-apple-smc-r1",
      quality: .singleDeviceValidated,
      cpuKeys: [
        "Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K",
        "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d",
        "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y",
      ],
      gpuKeys: [
        "Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c",
      ]
    )
  }
}

private enum AppleSMCError: Error {
  case connectionUnavailable
  case invalidKey
  case invalidValueType
  case keyUnavailable
  case requestFailed
}

private final class AppleSMCConnection {
  private static let selector: UInt32 = 2
  private static let readBytesCommand: UInt8 = 5
  private static let readKeyInfoCommand: UInt8 = 9
  private static let floatType = fourCharacterCode("flt ")

  private let connection: io_connect_t
  private var keyInfoCache: [UInt32: SMCKeyInfo] = [:]

  init() throws {
    guard let matching = IOServiceMatching("AppleSMC") else {
      throw AppleSMCError.connectionUnavailable
    }
    var iterator: io_iterator_t = 0
    let matchingResult = IOServiceGetMatchingServices(
      kIOMainPortDefault,
      matching,
      &iterator
    )
    guard matchingResult == KERN_SUCCESS, iterator != IO_OBJECT_NULL else {
      throw AppleSMCError.connectionUnavailable
    }
    defer { IOObjectRelease(iterator) }

    while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
      var openedConnection: io_connect_t = 0
      let result = IOServiceOpen(service, mach_task_self_, 0, &openedConnection)
      IOObjectRelease(service)
      if result == KERN_SUCCESS, openedConnection != IO_OBJECT_NULL {
        self.connection = openedConnection
        return
      }
      if openedConnection != IO_OBJECT_NULL {
        IOServiceClose(openedConnection)
      }
    }
    throw AppleSMCError.connectionUnavailable
  }

  deinit {
    IOServiceClose(connection)
  }

  func readFloat(key name: String) throws -> Float {
    let key = try Self.keyCode(name)
    let keyInfo = try readKeyInfo(key: key)
    guard keyInfo.dataSize == 4, keyInfo.dataType == Self.floatType else {
      throw AppleSMCError.invalidValueType
    }
    var request = SMCMessage.empty()
    SMCMessage.writeUInt32(key, to: &request, at: SMCMessage.keyOffset)
    SMCMessage.writeUInt32(
      keyInfo.dataSize,
      to: &request,
      at: SMCMessage.keyInfoDataSizeOffset
    )
    SMCMessage.writeUInt32(
      keyInfo.dataType,
      to: &request,
      at: SMCMessage.keyInfoDataTypeOffset
    )
    request[SMCMessage.keyInfoAttributesOffset] = keyInfo.dataAttributes
    request[SMCMessage.commandOffset] = Self.readBytesCommand
    let response = try call(request)
    let bits = SMCMessage.readUInt32(response, at: SMCMessage.payloadOffset)
    return Float(bitPattern: bits)
  }

  private func readKeyInfo(key: UInt32) throws -> SMCKeyInfo {
    if let cached = keyInfoCache[key] {
      return cached
    }
    var request = SMCMessage.empty()
    SMCMessage.writeUInt32(key, to: &request, at: SMCMessage.keyOffset)
    request[SMCMessage.commandOffset] = Self.readKeyInfoCommand
    let response = try call(request)
    let keyInfo = SMCKeyInfo(
      dataSize: SMCMessage.readUInt32(response, at: SMCMessage.keyInfoDataSizeOffset),
      dataType: SMCMessage.readUInt32(response, at: SMCMessage.keyInfoDataTypeOffset),
      dataAttributes: response[SMCMessage.keyInfoAttributesOffset]
    )
    keyInfoCache[key] = keyInfo
    return keyInfo
  }

  private func call(_ request: [UInt8]) throws -> [UInt8] {
    var output = SMCMessage.empty()
    var outputSize = SMCMessage.size
    let result = request.withUnsafeBytes { inputBuffer in
      output.withUnsafeMutableBytes { outputBuffer in
        IOConnectCallStructMethod(
          connection,
          Self.selector,
          inputBuffer.baseAddress!,
          request.count,
          outputBuffer.baseAddress!,
          &outputSize
        )
      }
    }
    guard result == KERN_SUCCESS else {
      throw AppleSMCError.requestFailed
    }
    guard outputSize >= SMCMessage.payloadOffset + 4 else {
      throw AppleSMCError.requestFailed
    }
    guard output[SMCMessage.resultOffset] != 132 else {
      throw AppleSMCError.keyUnavailable
    }
    guard output[SMCMessage.resultOffset] == 0 else {
      throw AppleSMCError.requestFailed
    }
    return output
  }

  private static func keyCode(_ key: String) throws -> UInt32 {
    let bytes = Array(key.utf8)
    guard bytes.count == 4 else {
      throw AppleSMCError.invalidKey
    }
    return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
  }
}

private func fourCharacterCode(_ value: String) -> UInt32 {
  value.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
}

private struct SMCKeyInfo {
  let dataSize: UInt32
  let dataType: UInt32
  let dataAttributes: UInt8
}

enum SMCMessage {
  static let size = 80
  static let keyOffset = 0
  static let keyInfoDataSizeOffset = 28
  static let keyInfoDataTypeOffset = 32
  static let keyInfoAttributesOffset = 36
  static let resultOffset = 40
  static let commandOffset = 42
  static let payloadOffset = 48

  static func empty() -> [UInt8] {
    [UInt8](repeating: 0, count: size)
  }

  static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    UInt32(bytes[offset])
      | UInt32(bytes[offset + 1]) << 8
      | UInt32(bytes[offset + 2]) << 16
      | UInt32(bytes[offset + 3]) << 24
  }

  static func writeUInt32(_ value: UInt32, to bytes: inout [UInt8], at offset: Int) {
    bytes[offset] = UInt8(truncatingIfNeeded: value)
    bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
    bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
  }
}
