import Darwin
import Dispatch
import Foundation
import RuntinueHelperCore
import RuntinueHelperSystem
import RuntinueIPC

@main
struct RuntinueHelperDaemon {
  static func main() async {
    guard geteuid() == 0 else {
      FileHandle.standardError.write(Data("runtinue-helper must run as root\n".utf8))
      Foundation.exit(77)
    }

    let leaseActor = LeaseActor(
      powerBackend: PMSetPowerBackend(),
      store: FileLeaseStateStore()
    )
    _ = await leaseActor.start()

    let delegate = HelperListenerDelegate(
      leaseActor: leaseActor,
      authenticator: CallerAuthenticator()
    )
    let listener = NSXPCListener(
      machServiceName: RuntinueIPCContract.helperMachServiceName
    )
    listener.delegate = delegate
    listener.resume()

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
        // Keep the listener delegate alive until a termination signal arrives.
        _ = delegate
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

    let watchdog = Task.detached {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        _ = await leaseActor.tick()
      }
    }

    for await _ in terminationSignals {}
    watchdog.cancel()
    _ = await leaseActor.shutdown()
  }
}
