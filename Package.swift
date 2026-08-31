// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "Runtinue",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .library(name: "RuntinueCore", targets: ["RuntinueCore"]),
    .library(name: "RuntinueIPC", targets: ["RuntinueIPC"]),
    .library(name: "RuntinueHelperCore", targets: ["RuntinueHelperCore"]),
    .library(name: "RuntinueHelperSystem", targets: ["RuntinueHelperSystem"]),
    .library(name: "RuntinueSupervisorCore", targets: ["RuntinueSupervisorCore"]),
    .library(name: "RuntinueSupervisorSystem", targets: ["RuntinueSupervisorSystem"]),
    .library(name: "RuntinueSystem", targets: ["RuntinueSystem"]),
    .library(name: "RuntinueKit", targets: ["RuntinueKit"]),
    .library(name: "RuntinueUserSupport", targets: ["RuntinueUserSupport"]),
    .library(name: "RuntinueActivity", targets: ["RuntinueActivity"]),
    .executable(name: "runtinue", targets: ["RuntinueCLI"]),
    .executable(name: "runtinue-helper", targets: ["RuntinueHelperDaemon"]),
    .executable(name: "runtinue-supervisor", targets: ["RuntinueSupervisorDaemon"]),
    .executable(name: "runtinue-hook", targets: ["RuntinueActivityHook"]),
    .executable(name: "runtinue-activity", targets: ["RuntinueActivityAdapter"]),
    .executable(name: "runtinue-menubar", targets: ["RuntinueMenuBar"]),
  ],
  targets: [
    .target(name: "RuntinueCore"),
    .target(name: "RuntinueIPC"),
    .target(
      name: "RuntinueHelperCore",
      dependencies: ["RuntinueCore"]
    ),
    .target(
      name: "RuntinueHelperSystem",
      dependencies: ["RuntinueCore", "RuntinueHelperCore"],
      linkerSettings: [
        .linkedFramework("IOKit")
      ]
    ),
    .target(
      name: "RuntinueSupervisorCore",
      dependencies: ["RuntinueCore"]
    ),
    .target(
      name: "RuntinueSupervisorSystem",
      dependencies: [
        "RuntinueCore", "RuntinueIPC", "RuntinueSupervisorCore", "RuntinueSystem",
        "RuntinueUserSupport",
      ]
    ),
    .target(
      name: "RuntinueSystem",
      dependencies: ["RuntinueCore"],
      linkerSettings: [
        .linkedFramework("CoreGraphics"),
        .linkedFramework("CoreWLAN"),
        .linkedFramework("IOKit"),
        .linkedFramework("SystemConfiguration"),
      ]
    ),
    .target(
      name: "RuntinueKit",
      dependencies: ["RuntinueCore", "RuntinueIPC"]
    ),
    .target(
      name: "RuntinueUserSupport",
      dependencies: ["RuntinueIPC"]
    ),
    .target(name: "RuntinueActivity"),
    .executableTarget(
      name: "RuntinueCLI",
      dependencies: [
        "RuntinueCore", "RuntinueIPC", "RuntinueSystem", "RuntinueUserSupport",
      ]
    ),
    .executableTarget(
      name: "RuntinueHelperDaemon",
      dependencies: ["RuntinueCore", "RuntinueHelperCore", "RuntinueHelperSystem", "RuntinueIPC"],
      linkerSettings: [
        .linkedFramework("Security")
      ]
    ),
    .executableTarget(
      name: "RuntinueSupervisorDaemon",
      dependencies: [
        "RuntinueCore", "RuntinueIPC", "RuntinueSupervisorCore", "RuntinueSupervisorSystem",
        "RuntinueSystem", "RuntinueUserSupport",
      ],
      linkerSettings: [
        .linkedFramework("Security")
      ]
    ),
    .executableTarget(
      name: "RuntinueActivityHook",
      dependencies: ["RuntinueIPC"]
    ),
    .executableTarget(
      name: "RuntinueActivityAdapter",
      dependencies: ["RuntinueActivity", "RuntinueIPC"]
    ),
    .executableTarget(
      name: "RuntinueMenuBar",
      dependencies: ["RuntinueIPC", "RuntinueSystem", "RuntinueUserSupport"],
      resources: [.copy("Resources/RuntinueTemplate.png")],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("CoreLocation"),
      ]
    ),
    .testTarget(
      name: "RuntinueCoreTests",
      dependencies: ["RuntinueCore"]
    ),
    .testTarget(
      name: "RuntinueHelperCoreTests",
      dependencies: ["RuntinueCore", "RuntinueHelperCore", "RuntinueHelperSystem"]
    ),
    .testTarget(
      name: "RuntinueIPCTests",
      dependencies: ["RuntinueIPC"]
    ),
    .testTarget(
      name: "RuntinueSupervisorCoreTests",
      dependencies: ["RuntinueCore", "RuntinueSupervisorCore"]
    ),
    .testTarget(
      name: "RuntinueSupervisorSystemTests",
      dependencies: [
        "RuntinueCore", "RuntinueHelperCore", "RuntinueIPC", "RuntinueSupervisorCore",
        "RuntinueSupervisorSystem", "RuntinueUserSupport",
      ]
    ),
    .testTarget(
      name: "RuntinueKitTests",
      dependencies: ["RuntinueIPC", "RuntinueKit"]
    ),
    .testTarget(
      name: "RuntinueUserSupportTests",
      dependencies: ["RuntinueIPC", "RuntinueUserSupport"]
    ),
    .testTarget(
      name: "RuntinueActivityTests",
      dependencies: ["RuntinueActivity"]
    ),
    .testTarget(
      name: "RuntinueSystemTests",
      dependencies: ["RuntinueSystem"]
    ),
    .testTarget(
      name: "RuntinueMenuBarTests",
      dependencies: ["RuntinueIPC", "RuntinueMenuBar"]
    ),
  ]
)
