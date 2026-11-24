// swift-tools-version: 6.0

import Foundation
import PackageDescription

func resolveBrewPrefix(envKey: String, formula: String) -> String {
    let env = ProcessInfo.processInfo.environment
    if let explicit = env[envKey], !explicit.isEmpty {
        return explicit
    }
    var candidates: [String] = []
    if let brewPrefix = env["HOMEBREW_PREFIX"], !brewPrefix.isEmpty {
        candidates.append("\(brewPrefix)/opt/\(formula)")
    }
    candidates.append("/opt/homebrew/opt/\(formula)")
    candidates.append("/usr/local/opt/\(formula)")
    for path in candidates where FileManager.default.fileExists(atPath: path) {
        return path
    }
    return "/opt/homebrew/opt/\(formula)"
}

let opensslPrefix = resolveBrewPrefix(envKey: "NODEDECK_OPENSSL_PREFIX", formula: "openssl@3")
let opusPrefix = resolveBrewPrefix(envKey: "NODEDECK_OPUS_PREFIX", formula: "opus")

let package = Package(
    name: "NodeDeck",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "NodeDeck", targets: ["NodeDeck"])
    ],
    targets: [
        .target(
            name: "CMoonlightCommon",
            path: "Sources/CMoonlightCommon",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("src"),
                .headerSearchPath("enet/include"),
                .headerSearchPath("nanors"),
                .headerSearchPath("nanors/deps"),
                .headerSearchPath("nanors/deps/obl"),
                .unsafeFlags([
                    "-I\(opensslPrefix)/include",
                    "-I\(opusPrefix)/include",
                    "-DHAS_FCNTL=1",
                    "-DHAS_IOCTL=1",
                    "-DHAS_POLL=1",
                    "-DHAS_GETNAMEINFO=1",
                    "-DHAS_GETADDRINFO=1",
                    "-DHAS_INET_PTON=1",
                    "-DHAS_INET_NTOP=1",
                    "-DHAS_MSGHDR_FLAGS=1",
                    "-DHAS_SOCKLEN_T=1",
                    "-D__APPLE_USE_RFC_3542=1",
                    "-DNDEBUG=1",
                    "-Wno-deprecated-declarations",
                    "-Wno-unused-parameter",
                    "-Wno-shorten-64-to-32"
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "\(opensslPrefix)/lib/libcrypto.a",
                    "\(opusPrefix)/lib/libopus.a"
                ])
            ]
        ),
        .target(
            name: "NodeDeckCore",
            dependencies: ["CMoonlightCommon"],
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "NodeDeck",
            dependencies: ["NodeDeckCore", "CMoonlightCommon"],
            linkerSettings: [
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("QuartzCore")
            ]
        ),
        .testTarget(
            name: "NodeDeckCoreTests",
            dependencies: ["NodeDeckCore"]
        )
    ],
    swiftLanguageModes: [.v5]
)
