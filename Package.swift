// swift-tools-version: 5.9
//
// wangqi added 2026-07-07 — makes the Carthage-era SwiftGit2 fork importable as a local
// Swift Package (the app cannot consume the bare .xcodeproj). Mirrors the sherpa-onnx_swift
// pattern: a prebuilt C dependency (libgit2) wrapped as a binaryTarget, plus the Swift
// bindings compiled from source.
//
// PREREQUISITE: run ./build-xcframework.sh once to produce build/libgit2.xcframework before
// building the app (the binaryTarget path below must exist). See helper/docs/git.md.

import PackageDescription

let package = Package(
    name: "SwiftGit2",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "SwiftGit2", targets: ["SwiftGit2"]),
    ],
    targets: [
        // libgit2 built by build-xcframework.sh (SecureTransport + CommonCrypto, SSH off).
        // The xcframework bundles the module map naming this module `Clibgit2`, which the
        // Swift sources `import Clibgit2`.
        .binaryTarget(
            name: "Clibgit2",
            path: "build/libgit2.xcframework"
        ),
        .target(
            name: "SwiftGit2",
            dependencies: ["Clibgit2"],
            path: "SwiftGit2",
            // Compile only the Swift bindings. SwiftGit2.m/.h (an ObjC constructor calling
            // git_libgit2_init) are dropped for SPM's single-language-per-target rule — the
            // consumer (GitRepoClient) calls git_libgit2_init() once instead.
            exclude: [
                "Info.plist",
                "SwiftGit2.h",
                "SwiftGit2.m",
            ],
            sources: [
                "CheckoutStrategy.swift",
                "CommitIterator.swift",
                "Credentials.swift",
                "Diffs.swift",
                "Errors.swift",
                "Libgit2.swift",
                "Objects.swift",
                "OID.swift",
                "Pointers.swift",
                "References.swift",
                "Remotes.swift",
                "Repository.swift",
                "StatusOptions.swift",
            ],
            linkerSettings: [
                // libgit2's static deps: zlib + iconv, Secure Transport (Security),
                // and CoreFoundation. No OpenSSL / libssh2 in this configuration.
                .linkedLibrary("z"),
                .linkedLibrary("iconv"),
                .linkedFramework("Security"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
    ]
)
