// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "BudgetApp",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "BudgetCore", targets: ["BudgetCore"])
    ],
    targets: [
        .target(name: "BudgetCore"),
        .testTarget(name: "BudgetCoreTests", dependencies: ["BudgetCore"])
    ]
)

