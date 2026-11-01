// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DeedarbCapacitorTcpSocket",
    platforms: [.iOS(.v15)],
    products: [
        .library(
            name: "DeedarbCapacitorTcpSocket",
            targets: ["TcpSocketPlugin"])
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", from: "8.0.0"),
        .package(url: "https://github.com/Kitura/BlueSocket.git", from: "2.0.4")
    ],
    targets: [
        .target(
            name: "TcpSocketPlugin",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm"),
                .product(name: "Socket", package: "BlueSocket")
            ],
            path: "ios/Plugin",
            exclude: ["Info.plist", "TcpSocketPlugin.h"])
    ]
)
