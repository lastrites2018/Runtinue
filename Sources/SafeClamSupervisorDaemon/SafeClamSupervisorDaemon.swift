import Darwin
import Dispatch
import Foundation
import SafeClamIPC
import SafeClamSupervisorSystem
import SafeClamSystem
import SafeClamUserSupport

@main
struct SafeClamSupervisorDaemon {
  static func main() async {
    guard geteuid() != 0 else {
      FileHandle.standardError.write(
        Data("safeclam-supervisor must run in a user session\n".utf8)
      )
      Foundation.exit(77)
    }

    let ownerUID = getuid()
    let eventRecorder = SupervisorEventRecorder(
      sink: FileSupervisorEventStore(),
      buildID: ExecutableBuildIdentity.current()
    )
    let backend = XPCPrivilegedLeaseBackend(ownerUID: ownerUID, eventRecorder: eventRecorder)
    let runtime = SupervisorRuntime(
      backend: backend,
      sampler: MacEnvironmentSampler(),
      statusCache: FileSupervisorStatusCache(),
      historyRecorder: FileSupervisorHistoryStore(),
      eventRecorder: eventRecorder,
      configurationStore: FileSupervisorConfigurationStore(),
      powerAssertionBackend: IOPMUserPowerAssertionBackend(),
      ownerUID: ownerUID
    )
    _ = await runtime.startup()

    let controlListener = NSXPCListener(
      machServiceName: SafeClamIPCContract.supervisorMachServiceName
    )
    let controlDelegate = SupervisorListenerDelegate(
      role: .control,
      runtime: runtime,
      authenticator: SupervisorCallerAuthenticator(role: .control)
    )
    controlListener.delegate = controlDelegate
    controlListener.resume()

    let activityListener = NSXPCListener(
      machServiceName: SafeClamIPCContract.supervisorActivityMachServiceName
    )
    let activityDelegate = SupervisorListenerDelegate(
      role: .activity,
      runtime: runtime,
      authenticator: SupervisorCallerAuthenticator(role: .activity)
    )
    activityListener.delegate = activityDelegate
    activityListener.resume()

    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    let terminationSource = DispatchSource.makeSignalSource(
      signal: SIGTERM,
      queue: .global(qos: .userInitiated)
    )
    let interruptSource = DispatchSource.makeSignalSource(
      signal: SIGINT,
      queue: .global(qos: .userInitiated)
    )
    let terminationSignals = AsyncStream<Void> { continuation in
      let finish: @Sendable () -> Void = {
        // Keep listener delegates alive until a termination signal arrives.
        _ = controlDelegate
        _ = activityDelegate
        continuation.finish()
      }
      terminationSource.setEventHandler(handler: finish)
      interruptSource.setEventHandler(handler: finish)
      continuation.onTermination = { @Sendable _ in
        terminationSource.cancel()
        interruptSource.cancel()
      }
    }
    terminationSource.resume()
    interruptSource.resume()

    for await _ in terminationSignals {}
    _ = await runtime.shutdown()
  }
}
