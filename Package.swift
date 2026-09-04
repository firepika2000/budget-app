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
        .library(name: "BudgetAPI", targets: ["BudgetAPI"])
    ],
    targets: [
        .target(name: "BudgetCore"),
        .target(name: "BudgetAPI"),
        .testTarget(name: "BudgetCoreTests", dependencies: ["BudgetCore"]),
        .testTarget(name: "BudgetAPITests", dependencies: ["BudgetAPI"])
    ]
)
