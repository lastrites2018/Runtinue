import Foundation
import XCTest

@testable import RuntinueCore
@testable import RuntinueSystem

final class MacTemperatureTelemetrySamplerTests: XCTestCase {
  func testSMCMessageUsesTheExpectedExplicitByteLayout() {
    XCTAssertEqual(SMCMessage.size, 80)
    XCTAssertEqual(SMCMessage.keyOffset, 0)
    XCTAssertEqual(SMCMessage.keyInfoDataSizeOffset, 28)
    XCTAssertEqual(SMCMessage.keyInfoDataTypeOffset, 32)
    XCTAssertEqual(SMCMessage.keyInfoAttributesOffset, 36)
    XCTAssertEqual(SMCMessage.resultOffset, 40)
    XCTAssertEqual(SMCMessage.commandOffset, 42)
    XCTAssertEqual(SMCMessage.payloadOffset, 48)

    var message = SMCMessage.empty()
    SMCMessage.writeUInt32(0x1234_5678, to: &message, at: SMCMessage.keyOffset)
    XCTAssertEqual(Array(message[0..<4]), [0x78, 0x56, 0x34, 0x12])
    XCTAssertEqual(SMCMessage.readUInt32(message, at: SMCMessage.keyOffset), 0x1234_5678)
  }

  func testOnlyExactHardwareValidatedModelHasAMapping() throws {
    let mapping = try XCTUnwrap(
      MacTemperatureSensorMapping.validatedMapping(
        for: "Mac17,8",
        operatingSystemBuild: "25F84"
      )
    )

    XCTAssertEqual(mapping.revision, "Mac17,8-apple-smc-r1")
    XCTAssertEqual(mapping.quality, .singleDeviceValidated)
    XCTAssertEqual(mapping.cpuKeys.count, 18)
    XCTAssertEqual(mapping.gpuKeys.count, 7)
    XCTAssertEqual(mapping.operatingSystemBuild, "25F84")
    XCTAssertNil(
      MacTemperatureSensorMapping.validatedMapping(
        for: "Mac17,8",
        operatingSystemBuild: "25F85"
      )
    )
    XCTAssertNil(
      MacTemperatureSensorMapping.validatedMapping(
        for: "Mac99,1",
        operatingSystemBuild: "25F84"
      )
    )
  }

  func testCompleteValidatedCohortsProduceFreshRangesAndCoverage() throws {
    let mapping = try XCTUnwrap(
      MacTemperatureSensorMapping.validatedMapping(
        for: "Mac17,8",
        operatingSystemBuild: "25F84"
      )
    )
    var values: [String: Double] = [:]
    for (index, key) in mapping.cpuKeys.enumerated() {
      values[key] = 60 + Double(index)
    }
    for (index, key) in mapping.gpuKeys.enumerated() {
      values[key] = 50 + Double(index)
    }
    let sampledAt = Date(timeIntervalSince1970: 1_000)

    let snapshot = MacTemperatureTelemetrySampler.makeSnapshot(
      mapping: mapping,
      values: values,
      sampledAt: sampledAt,
      previousSuccessfulAt: nil
    )

    XCTAssertEqual(snapshot.status, .available)
    XCTAssertEqual(snapshot.validUntil, sampledAt.addingTimeInterval(15))
    XCTAssertEqual(snapshot.lastSuccessfulAt, sampledAt)
    XCTAssertEqual(snapshot.mappingRevision, mapping.revision)
    XCTAssertEqual(snapshot.components.count, 2)
    let cpu = try component(.cpuInternal, in: snapshot)
    XCTAssertEqual(cpu.minimumCelsius, 60)
    XCTAssertEqual(cpu.maximumCelsius, 77)
    XCTAssertEqual(cpu.validSensorCount, 18)
    XCTAssertEqual(cpu.expectedSensorCount, 18)
    let gpu = try component(.gpuInternal, in: snapshot)
    XCTAssertEqual(gpu.minimumCelsius, 50)
    XCTAssertEqual(gpu.maximumCelsius, 56)
    XCTAssertEqual(gpu.validSensorCount, 7)
    XCTAssertEqual(gpu.expectedSensorCount, 7)
  }

  func testMissingAndImplausibleValuesArePartialInsteadOfNormal() throws {
    let mapping = try XCTUnwrap(
      MacTemperatureSensorMapping.validatedMapping(
        for: "Mac17,8",
        operatingSystemBuild: "25F84"
      )
    )
    let values = [
      mapping.cpuKeys[0]: 71,
      mapping.cpuKeys[1]: .nan,
      mapping.cpuKeys[2]: 0,
      mapping.gpuKeys[0]: 62,
      mapping.gpuKeys[1]: 151,
    ]

    let snapshot = MacTemperatureTelemetrySampler.makeSnapshot(
      mapping: mapping,
      values: values,
      sampledAt: Date(timeIntervalSince1970: 2_000),
      previousSuccessfulAt: nil
    )

    XCTAssertEqual(snapshot.status, .partial)
    let cpu = try component(.cpuInternal, in: snapshot)
    XCTAssertEqual(cpu.maximumCelsius, 71)
    XCTAssertEqual(cpu.validSensorCount, 1)
    XCTAssertEqual(cpu.validSensorIDs, [mapping.cpuKeys[0]])
    let gpu = try component(.gpuInternal, in: snapshot)
    XCTAssertEqual(gpu.maximumCelsius, 62)
    XCTAssertEqual(gpu.validSensorCount, 1)
    XCTAssertEqual(gpu.validSensorIDs, [mapping.gpuKeys[0]])
  }

  func testNoValidValuesBecomesUnavailableAndKeepsOnlyLastSuccessTime() throws {
    let mapping = try XCTUnwrap(
      MacTemperatureSensorMapping.validatedMapping(
        for: "Mac17,8",
        operatingSystemBuild: "25F84"
      )
    )
    let previous = Date(timeIntervalSince1970: 900)

    let snapshot = MacTemperatureTelemetrySampler.makeSnapshot(
      mapping: mapping,
      values: [mapping.cpuKeys[0]: -300_000_000],
      sampledAt: Date(timeIntervalSince1970: 1_000),
      previousSuccessfulAt: previous
    )

    XCTAssertEqual(snapshot.status, .temporarilyUnavailable)
    XCTAssertNil(snapshot.validUntil)
    XCTAssertEqual(snapshot.lastSuccessfulAt, previous)
    XCTAssertTrue(snapshot.components.allSatisfy { $0.maximumCelsius == nil })
    XCTAssertTrue(snapshot.components.allSatisfy { $0.validSensorCount == 0 })
  }

  func testUnsupportedModelDoesNotAttemptToGuessASensorMapping() async {
    let snapshot = await MacTemperatureTelemetrySampler(
      machineModel: "Mac99,1",
      operatingSystemBuild: "25F84"
    ).sample()

    XCTAssertEqual(snapshot.status, .unsupportedModel)
    XCTAssertEqual(snapshot.machineModel, "Mac99,1")
    XCTAssertNil(snapshot.mappingRevision)
    XCTAssertNil(snapshot.mappingQuality)
    XCTAssertTrue(snapshot.components.isEmpty)
  }

  func testKnownModelOnAnUntestedOSBuildIsMappingUnverified() async {
    let snapshot = await MacTemperatureTelemetrySampler(
      machineModel: "Mac17,8",
      operatingSystemBuild: "25F85"
    ).sample()

    XCTAssertEqual(snapshot.status, .mappingUnverified)
    XCTAssertEqual(snapshot.machineModel, "Mac17,8")
    XCTAssertEqual(snapshot.operatingSystemBuild, "25F85")
    XCTAssertNil(snapshot.mappingRevision)
    XCTAssertTrue(snapshot.components.isEmpty)
  }

  private func component(
    _ component: TemperatureComponent,
    in snapshot: TemperatureTelemetrySnapshot
  ) throws -> ComponentTemperatureObservation {
    try XCTUnwrap(snapshot.components.first { $0.component == component })
  }
}
