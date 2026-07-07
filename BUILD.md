# Building SwiftGit2 for the Privacy AI app

This fork of [SwiftGit2](https://github.com/SwiftGit2/SwiftGit2) is consumed by the Privacy AI
app as a **local Swift Package**. Upstream SwiftGit2 ships only a Carthage-era Xcode project,
which cannot be imported by SwiftPM, so this fork adds:

- **`Package.swift`** — a Swift Package that builds the Swift bindings and links a prebuilt
  `libgit2` binary target.
- **`build-xcframework.sh`** — builds `libgit2` into `build/libgit2.xcframework`.
- Two extra libgit2 bindings the app needs (`push`, `graphAheadBehind`) and an SSH guard.

> The companion app-side design doc is `helper/docs/git.md` in the main repository.

---

## Prerequisites

- macOS with **Xcode** (command-line tools) — provides the iOS/macOS SDKs and `xcodebuild`.
- **CMake** (`brew install cmake`).
- The `libgit2` git submodule (checked out automatically by the build script if missing).

No OpenSSL, libssh2, autoconf, automake, libtool, or Homebrew-provided crypto are required —
see the build configuration below.

---

## One-command build

```bash
cd thirdparty/SwiftGit2
./build-xcframework.sh            # full build
./build-xcframework.sh --clean    # wipe build/ and rebuild
```

Output: `build/libgit2.xcframework` (a gitignored build artifact). **Run this once before
building the app** — `Package.swift`'s `Clibgit2` binary target points at it.

---

## What the build produces

`build-xcframework.sh` builds the vendored **libgit2 1.1.0** submodule as a static library for
three Apple platform slices and packages them into one xcframework:

| Slice | Architectures |
|---|---|
| `ios-arm64` | iOS device (arm64) |
| `ios-arm64_x86_64-simulator` | iOS Simulator (arm64 + x86_64) |
| `macos-arm64_x86_64` | macOS (arm64 + x86_64) |

Supports **both iOS and macOS**. Each slice is ~5–10 MB (~28 MB total).

### libgit2 configuration — no third-party crypto

The app's Git integration is **HTTPS + Personal Access Token only** (SSH is deferred). That
lets libgit2 use Apple-native crypto/TLS and drop OpenSSL and libssh2 entirely:

| CMake flag | Value | Effect |
|---|---|---|
| `USE_HTTPS` | `SecureTransport` | Apple system TLS — no OpenSSL |
| `USE_SHA1` | `CollisionDetection` | libgit2 builtin sha1dc — no OpenSSL |
| `USE_SSH` | `OFF` | no libssh2 |
| `REGEX_BACKEND` | `regcomp` | system regex — no PCRE |
| `BUILD_SHARED_LIBS` / `BUILD_CLAR` / `BUILD_EXAMPLES` / `BUILD_FUZZERS` | `OFF` | static lib only |

The resulting `libgit2.a` links only the system `Security` + `CoreFoundation` frameworks and
`z` / `iconv` (declared in `Package.swift`).

### Build gotchas the script already handles

These matter if you upgrade the toolchain or libgit2:

1. **iOS framework detection.** Under the iOS sysroot, libgit2's `FIND_PATH`/`FIND_LIBRARY`
   cannot locate `CoreFoundation`/`Security`, so the SecureTransport gate `FATAL_ERROR`s —
   even though the compiler resolves the framework headers via `-isysroot`. The script
   pre-seeds `COREFOUNDATION_FOUND`, `SECURITY_FOUND`, `SECURITY_HAS_SSLCREATECONTEXT`.
2. **Generated header.** libgit2 generates `git2/sys/features.h` into the build tree (not
   `include/`); the script merges it into the xcframework headers so the `Clibgit2` module
   map's `sys` umbrella resolves.
3. **CMake 4.x.** libgit2 1.1.0 declares `cmake_minimum_required(3.5.1)`; the script passes
   `CMAKE_POLICY_VERSION_MINIMUM=3.5`. iOS cross-compiles also need
   `CMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY`.
4. **libgit2 1.1.0 flag names.** Tests flag is `BUILD_CLAR` (not `BUILD_TESTS`); there is no
   `BUILD_CLI` and no `USE_SHA256`.

---

## How the app consumes it

`Package.swift` defines:

- `Clibgit2` — a `.binaryTarget` at `build/libgit2.xcframework`. Its bundled module map names
  the module `Clibgit2`, which the Swift sources `import`.
- `SwiftGit2` — the Swift bindings (the `.swift` files in `SwiftGit2/`). The ObjC
  `SwiftGit2.m`/`.h` (an `__attribute__((constructor))` that calls `git_libgit2_init`) are
  **excluded** for SPM's single-language-per-target rule; the consuming code must call
  `git_libgit2_init()` itself once.

In Xcode, the main app adds this directory as a **local package** (File ▸ Add Package
Dependencies ▸ Add Local) and links the `SwiftGit2` product to the iOS and macOS app targets.

---

## Fork modifications

All local changes are marked `// wangqi <added|modified> YYYY-MM-DD` for upstream-merge
tracking:

- **`SwiftGit2/Repository.swift`** — added `push(remoteName:refspecs:credentials:)`
  (`git_remote_push`, supports force-push) and `graphAheadBehind(local:upstream:)`
  (`git_graph_ahead_behind`) for the app's Git sync (push + divergence detection). Upstream
  SwiftGit2 wraps neither.
- **`SwiftGit2/Credentials.swift`** — the `sshAgent`/`sshMemory` credential cases are guarded
  to `GIT_PASSTHROUGH` because libgit2 is built with `USE_SSH=OFF`; this keeps the bindings
  linking without libssh2 while SSH support is deferred.
- **`Package.swift`, `build-xcframework.sh`, `BUILD.md`** — new build/packaging files.
