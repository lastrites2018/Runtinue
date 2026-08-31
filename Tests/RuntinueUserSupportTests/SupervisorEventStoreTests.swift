import Foundation
import XCTest

@testable import RuntinueIPC
@testable import RuntinueUserSupport

@MainActor
final class SupervisorEventStoreTests: XCTestCase {
  private let buildID = String(repeating: "a", count: 64)

  func testMissingLogReadHasNoFilesystemSideEffect() async throws {
    let directory = temporaryDirectory()
    let store = FileSupervisorEventStore(fileURL: directory.appendingPathComponent("events.jsonl"))
    let events = try await store.read()
    XCTAssertTrue(events.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
  }

  func testPrivateBoundedLogKeepsSequenceAndDeduplicatesEventIDs() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("events.jsonl")
    let store = FileSupervisorEventStore(fileURL: url, maximumEntries: 2)
    let request = event(.commandRequested, attemptID: UUID(), command: .startTrip)
    try await store.record(request)
    try await store.record(request)
    try await store.record(
      event(.commandAccepted, attemptID: request.attemptID, command: .startTrip))
    try await store.record(event(.supervisorStarted))
    let events = try await store.read()
    XCTAssertEqual(events.map(\.sequence), [2, 3])
    let summary = SupervisorEventSummary(events: events, buildID: buildID)
    XCTAssertTrue(summary.prefixWasTrimmed)
    XCTAssertEqual(summary.incompleteAttempts, 1)
    XCTAssertEqual(summary.acceptedTrips, 0)
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }

  func testCorruptLogFailsWithoutDiscardingEvidence() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("events.jsonl")
    let store = FileSupervisorEventStore(fileURL: url)
    try await store.record(event(.supervisorStarted))
    let corrupt = Data("not-json\n".utf8)
    try corrupt.write(to: url)
    do {
      try await store.record(event(.supervisorStarted))
      XCTFail("corrupt evidence must not be silently overwritten")
    } catch {}
    XCTAssertEqual(try Data(contentsOf: url), corrupt)
  }

  func testSymlinkLogIsRejectedWithoutChangingItsTarget() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
    )
    let target = directory.appendingPathComponent("target")
    try Data("preserve".utf8).write(to: target)
    let url = directory.appendingPathComponent("events.jsonl")
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
    do {
      try await FileSupervisorEventStore(fileURL: url).record(event(.supervisorStarted))
      XCTFail("symlink must be rejected")
    } catch {}
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "preserve")
  }

  func testAttemptDenominatorsDistinguishReplyProtectionAndRestoration() {
    let accepted = UUID()
    let rejected = UUID()
    let unanswered = UUID()
    let session = UUID()
    let release = UUID()
    let otherRelease = UUID()
    let events = [
      event(.commandRequested, attemptID: accepted, command: .startTrip),
      event(.commandAccepted, attemptID: accepted, sessionID: session, command: .startTrip),
      event(.commandRequested, attemptID: rejected, command: .startTrip),
      event(.commandRejected, attemptID: rejected, command: .startTrip),
      event(.commandRequested, attemptID: unanswered, command: .startTrip),
      event(.protectionConfirmed, sessionID: session),
      event(.protectionConfirmed, sessionID: session),
      event(.releaseRequested, attemptID: release, sessionID: session),
      event(.sleepRestored, attemptID: release, sessionID: session),
      event(.releaseRequested, attemptID: otherRelease, sessionID: session),
      event(.recoveryPending, attemptID: otherRelease, sessionID: session),
      event(.recoveryCompleted, sessionID: session),
      event(.sessionEnded, sessionID: session),
    ]
    let summary = SupervisorEventSummary(events: events + [events[0]], buildID: buildID)
    XCTAssertEqual(summary.requestedTrips, 3)
    XCTAssertEqual(summary.acceptedTrips, 1)
    XCTAssertEqual(summary.rejectedTrips, 1)
    XCTAssertEqual(summary.unresolvedTripRequests, 1)
    XCTAssertEqual(summary.protectedTrips, 1)
    XCTAssertEqual(summary.endedTrips, 1)
    XCTAssertEqual(summary.requestedReleases, 2)
    XCTAssertEqual(summary.restoredReleases, 1)
    XCTAssertEqual(summary.pendingReleases, 1)
    XCTAssertEqual(summary.recoveredSessions, 1)
    XCTAssertEqual(summary.unconfirmedReleaseRate, 0.5)
  }

  func testEmptyOrOtherBuildEvidenceIsNotReportedAsZeroFailureRate() {
    let summary = SupervisorEventSummary(
      events: [event(.commandRequested, attemptID: UUID(), command: .startTrip)],
      buildID: String(repeating: "b", count: 64)
    )
    XCTAssertEqual(summary.requestedTrips, 0)
    XCTAssertNil(summary.tripRejectionRate)
    XCTAssertNil(summary.unconfirmedReleaseRate)
  }

  func testMissingCurrentBuildCannotCombinePreviousBuildSuccesses() {
    let attempt = UUID()
    let summary = SupervisorEventSummary(
      events: [
        event(.commandRequested, attemptID: attempt, command: .startTrip),
        event(.commandAccepted, attemptID: attempt, command: .startTrip),
      ], buildID: nil)
    XCTAssertTrue(summary.containsUnknownBuild)
    XCTAssertEqual(summary.requestedTrips, 0)
    XCTAssertNil(summary.tripRejectionRate)
  }

  func testUnlinkedRecoveryCompletionIsEvidenceGapInsteadOfSuccess() {
    let summary = SupervisorEventSummary(
      events: [event(.recoveryCompleted, sessionID: UUID())], buildID: buildID
    )
    XCTAssertEqual(summary.recoveredSessions, 0)
    XCTAssertEqual(summary.incompleteAttempts, 1)
  }

  func testWriteFailureRemainsVisibleAfterLaterSuccess() async {
    let sink = EventTestSink()
    let recorder = SupervisorEventRecorder(sink: sink, buildID: buildID)
    await sink.failNextWrite()
    await recorder.record(.supervisorStarted)
    await recorder.record(.normalSleepObserved)
    let issues = await recorder.issues()
    XCTAssertEqual(issues, [.eventsUnavailable])
    let events = await sink.events
    XCTAssertEqual(events.map(\.kind), [.normalSleepObserved])
  }

  func testStatusPollingDoesNotInventStartsOrRepeatedProtectionEvents() async {
    let sink = EventTestSink()
    let recorder = SupervisorEventRecorder(sink: sink, buildID: buildID)
    let session = UUID()
    let status = makeStatus(sessionID: session, phase: .active, verdict: .protected)
    await recorder.observe(status)
    await recorder.observe(status)
    let events = await sink.events
    XCTAssertEqual(events.map(\.kind), [.protectionConfirmed])
    XCTAssertEqual(SupervisorEventSummary(events: events, buildID: buildID).requestedTrips, 0)
  }

  func testUnknownBuildCannotPersistArbitraryText() async throws {
    let value = event(.supervisorStarted, buildID: "private-name")
    XCTAssertNil(value.buildID)
    XCTAssertFalse(
      String(decoding: try JSONEncoder().encode(value), as: UTF8.self).contains("private"))
    let recorder = SupervisorEventRecorder(sink: EventTestSink(), buildID: nil)
    let issues = await recorder.issues()
    XCTAssertEqual(issues, [.buildIdentityUnavailable])
  }

  private func event(
    _ kind: SupervisorEventKind, attemptID: UUID? = nil, sessionID: UUID? = nil,
    command: SupervisorCommandKind? = nil, buildID: String? = nil
  ) -> SupervisorEvent {
    SupervisorEvent(
      buildID: buildID ?? self.buildID, kind: kind, attemptID: attemptID,
      sessionID: sessionID, command: command
    )
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
      "runtinue-events-\(UUID().uuidString)", isDirectory: true
    )
  }
}

private actor EventTestSink: SupervisorEventRecording {
  var events: [SupervisorEvent] = []
  private var shouldFail = false
  func failNextWrite() { shouldFail = true }
  func record(_ event: SupervisorEvent) throws {
    if shouldFail {
      shouldFail = false
      throw SupervisorEventStoreError.invalidLog
    }
    events.append(event)
  }
}

private func makeStatus(
  sessionID: UUID, phase: WireTripPhase, verdict: WireProtectionVerdict
) -> SupervisorStatusWire {
  SupervisorStatusWire(
    phase: phase, mode: .trip, sessionID: sessionID, verdict: verdict,
    remainingSeconds: nil, batteryPercent: nil, thermalLevel: nil, lidState: nil,
    detail: "private-detail", updatedAt: Date()
  )
}
