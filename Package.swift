// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "SafeClamshellKit",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .library(name: "SafeClamCore", targets: ["SafeClamCore"]),
    .library(name: "SafeClamIPC", targets: ["SafeClamIPC"]),
    .library(name: "SafeClamHelperCore", targets: ["SafeClamHelperCore"]),
    .library(name: "SafeClamHelperSystem", targets: ["SafeClamHelperSystem"]),
    .library(name: "SafeClamSupervisorCore", targets: ["SafeClamSupervisorCore"]),
    .library(name: "SafeClamSupervisorSystem", targets: ["SafeClamSupervisorSystem"]),
    .library(name: "SafeClamSystem", targets: ["SafeClamSystem"]),
    .library(name: "SafeClamKit", targets: ["SafeClamKit"]),
    .library(name: "SafeClamUserSupport", targets: ["SafeClamUserSupport"]),
    .library(name: "SafeClamActivity", targets: ["SafeClamActivity"]),
    .executable(name: "safeclam", targets: ["SafeClamCLI"]),
    .executable(name: "safeclam-helper", targets: ["SafeClamHelperDaemon"]),
    .executable(name: "safeclam-supervisor", targets: ["SafeClamSupervisorDaemon"]),
    .executable(name: "safeclam-hook", targets: ["SafeClamActivityHook"]),
    .executable(name: "safeclam-activity", targets: ["SafeClamActivityAdapter"]),
    .executable(name: "safeclam-menubar", targets: ["SafeClamMenuBar"]),
  ],
  targets: [
    .target(name: "SafeClamCore"),
    .target(name: "SafeClamIPC"),
    .target(
      name: "SafeClamHelperCore",
      dependencies: ["SafeClamCore"]
    ),
    .target(
      name: "SafeClamHelperSystem",
      dependencies: ["SafeClamCore", "SafeClamHelperCore"],
      linkerSettings: [
        .linkedFramework("IOKit")
      ]
    ),
    .target(
      name: "SafeClamSupervisorCore",
      dependencies: ["SafeClamCore"]
    ),
    .target(
      name: "SafeClamSupervisorSystem",
      dependencies: [
        "SafeClamCore", "SafeClamIPC", "SafeClamSupervisorCore", "SafeClamSystem",
        "SafeClamUserSupport",
      ]
    ),
    .target(
      name: "SafeClamSystem",
      dependencies: ["SafeClamCore"],
      linkerSettings: [
        .linkedFramework("CoreGraphics"),
        .linkedFramework("CoreWLAN"),
        .linkedFramework("IOKit"),
        .linkedFramework("SystemConfiguration"),
      ]
    ),
    .target(
      name: "SafeClamKit",
      dependencies: ["SafeClamCore", "SafeClamIPC"]
    ),
    .target(
      name: "SafeClamUserSupport",
      dependencies: ["SafeClamIPC"]
    ),
    .target(name: "SafeClamActivity"),
    .executableTarget(
      name: "SafeClamCLI",
      dependencies: [
        "SafeClamCore", "SafeClamIPC", "SafeClamSystem", "SafeClamUserSupport",
      ]
    ),
    .executableTarget(
      name: "SafeClamHelperDaemon",
      dependencies: ["SafeClamCore", "SafeClamHelperCore", "SafeClamHelperSystem", "SafeClamIPC"],
      linkerSettings: [
        .linkedFramework("Security")
      ]
    ),
    .executableTarget(
      name: "SafeClamSupervisorDaemon",
      dependencies: [
        "SafeClamCore", "SafeClamIPC", "SafeClamSupervisorCore", "SafeClamSupervisorSystem",
        "SafeClamSystem", "SafeClamUserSupport",
      ],
      linkerSettings: [
        .linkedFramework("Security")
      ]
    ),
    .executableTarget(
      name: "SafeClamActivityHook",
      dependencies: ["SafeClamIPC"]
    ),
    .executableTarget(
      name: "SafeClamActivityAdapter",
      dependencies: ["SafeClamActivity", "SafeClamIPC"]
    ),
    .executableTarget(
      name: "SafeClamMenuBar",
      dependencies: ["SafeClamIPC", "SafeClamSystem", "SafeClamUserSupport"],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("CoreLocation"),
      ]
    ),
    .testTarget(
      name: "SafeClamCoreTests",
      dependencies: ["SafeClamCore"]
    ),
    .testTarget(
      name: "SafeClamHelperCoreTests",
      dependencies: ["SafeClamCore", "SafeClamHelperCore", "SafeClamHelperSystem"]
    ),
    .testTarget(
      name: "SafeClamIPCTests",
      dependencies: ["SafeClamIPC"]
    ),
    .testTarget(
      name: "SafeClamSupervisorCoreTests",
      dependencies: ["SafeClamCore", "SafeClamSupervisorCore"]
    ),
    .testTarget(
      name: "SafeClamSupervisorSystemTests",
      dependencies: [
        "SafeClamCore", "SafeClamHelperCore", "SafeClamIPC", "SafeClamSupervisorCore",
        "SafeClamSupervisorSystem", "SafeClamUserSupport",
      ]
    ),
    .testTarget(
      name: "SafeClamKitTests",
      dependencies: ["SafeClamIPC", "SafeClamKit"]
    ),
    .testTarget(
      name: "SafeClamUserSupportTests",
      dependencies: ["SafeClamIPC", "SafeClamUserSupport"]
    ),
    .testTarget(
      name: "SafeClamActivityTests",
      dependencies: ["SafeClamActivity"]
    ),
    .testTarget(
      name: "SafeClamSystemTests",
      dependencies: ["SafeClamSystem"]
    ),
    .testTarget(
      name: "SafeClamMenuBarTests",
      dependencies: ["SafeClamIPC", "SafeClamMenuBar"]
    ),
  ]
)
