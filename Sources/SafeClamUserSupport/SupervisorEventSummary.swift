import Foundation

public struct SupervisorEventSummary: Equatable, Sendable {
  public let requestedTrips: Int
  public let rejectedTrips: Int
  public let unresolvedTripRequests: Int
  public let acceptedTrips: Int
  public let protectedTrips: Int
  public let endedTrips: Int
  public let requestedReleases: Int
  public let restoredReleases: Int
  public let pendingReleases: Int
  public let recoveredSessions: Int
  public let authorizationRejections: Int
  public let prefixWasTrimmed: Bool
  public let containsUnknownBuild: Bool
  public let incompleteAttempts: Int

  public init(events: [SupervisorEvent], buildID: String? = nil) {
    var seen = Set<UUID>()
    let unique = events.filter { seen.insert($0.id).inserted }
    let selectedBuild = ExecutableBuildIdentity.validated(buildID)
    let selected = unique.filter { selectedBuild != nil && $0.buildID == selectedBuild }
    func attempts(_ kind: SupervisorEventKind, command: SupervisorCommandKind? = nil) -> Set<UUID> {
      Set(
        selected.filter { $0.kind == kind && (command == nil || $0.command == command) }
          .compactMap(\.attemptID))
    }
    let requested = attempts(.commandRequested, command: .startTrip)
    let accepted = attempts(.commandAccepted, command: .startTrip)
    let rejected = attempts(.commandRejected, command: .startTrip)
    let tripSessions = Set(
      selected.filter {
        $0.kind == .commandAccepted && $0.command == .startTrip
          && $0.attemptID.map(requested.contains) == true
      }.compactMap(\.sessionID))
    let protected = Set(selected.filter { $0.kind == .protectionConfirmed }.compactMap(\.sessionID))
    let ended = Set(selected.filter { $0.kind == .sessionEnded }.compactMap(\.sessionID))
    let releases = attempts(.releaseRequested)
    let restored = attempts(.sleepRestored)
    let recoveries = Set(selected.filter { $0.kind == .recoveryCompleted }.compactMap(\.sessionID))
    let recoveryOrigins = Set(
      selected.filter {
        $0.kind == .recoveryPending || $0.kind == .releaseRequested
      }.compactMap(\.sessionID))
    requestedTrips = requested.count
    rejectedTrips = rejected.intersection(requested).count
    unresolvedTripRequests = requested.subtracting(accepted.union(rejected)).count
    acceptedTrips = accepted.intersection(requested).count
    protectedTrips = protected.intersection(tripSessions).count
    endedTrips = ended.intersection(tripSessions).count
    requestedReleases = releases.count
    restoredReleases = restored.intersection(releases).count
    pendingReleases = releases.subtracting(restored).count
    recoveredSessions = recoveries.intersection(recoveryOrigins).count
    authorizationRejections = selected.filter { $0.kind == .authorizationRejected }.count
    prefixWasTrimmed = (unique.first?.sequence ?? 1) > 1
    containsUnknownBuild = selectedBuild == nil || unique.contains { $0.buildID == nil }
    incompleteAttempts =
      accepted.union(rejected).subtracting(requested).count
      + restored.subtracting(releases).count
      + recoveries.subtracting(recoveryOrigins).count
  }

  public var tripRejectionRate: Double? {
    requestedTrips > 0 ? Double(rejectedTrips) / Double(requestedTrips) : nil
  }

  public var unconfirmedReleaseRate: Double? {
    requestedReleases > 0 ? Double(pendingReleases) / Double(requestedReleases) : nil
  }

  public var text: String {
    [
      "관찰 범위: 현재 파일에 남아 있는 이벤트, 실제 원격 작업 유지 여부는 별도 확인",
      "통근 시작 요청: \(requestedTrips), 수락: \(acceptedTrips), 거부: \(rejectedTrips), 응답 미확인: \(unresolvedTripRequests)",
      "시작 거부율: \(rate(tripRejectionRate))",
      "연결된 통근 세션: 보호 확인 \(protectedTrips), 종료 확인 \(endedTrips)",
      "수면 억제 해제 요청: \(requestedReleases), 정상 수면 확인: \(restoredReleases), 미확인: \(pendingReleases)",
      "해제 미확인율: \(rate(unconfirmedReleaseRate))",
      "후속 복구 확인 세션: \(recoveredSessions), 호출자 인증 거부: \(authorizationRejections)",
      "앞부분 보존 한도 초과: \(prefixWasTrimmed ? "예" : "아니요"), 연결되지 않은 결과: \(incompleteAttempts)",
      "빌드 식별 누락: \(containsUnknownBuild ? "있음" : "없음")",
      "조회 시 Supervisor의 관찰 경고도 함께 확인하세요. 누락된 이벤트를 성공으로 계산하지 않습니다.",
    ].joined(separator: "\n")
  }

  private func rate(_ value: Double?) -> String {
    value.map { String(format: "%.1f%%", $0 * 100) } ?? "표본 없음"
  }
}
