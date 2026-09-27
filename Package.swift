// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "BudgetApp",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "BudgetCore", targets: ["BudgetCore"]),
        .library(name: "BudgetAPI", targets: ["BudgetAPI"]),
        .library(name: "BudgetStorage", targets: ["BudgetStorage"])
    ],
    targets: [
        .target(name: "BudgetCore"),
        .target(name: "BudgetAPI"),
        .target(name: "BudgetStorage", linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "BudgetCoreTests", dependencies: ["BudgetCore"]),
        .testTarget(name: "BudgetAPITests", dependencies: ["BudgetAPI"]),
        .testTarget(name: "BudgetStorageTests", dependencies: ["BudgetStorage"])
    ]
)
