# SingleFlight

[![CI](https://github.com/abdullahtariq72/SingleFlight/actions/workflows/ci.yml/badge.svg)](https://github.com/abdullahtariq72/SingleFlight/actions/workflows/ci.yml)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-iOS%20%7C%20macOS%20%7C%20tvOS%20%7C%20watchOS%20%7C%20visionOS%20%7C%20Linux-lightgrey.svg)](Package.swift)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Run async work once, no matter how many callers ask for it at the same time.

When several parts of your app request the same thing concurrently, `SingleFlight`
starts the work for the first caller and lets everyone else wait for that same
result. It's Go's [`singleflight`](https://pkg.go.dev/golang.org/x/sync/singleflight)
for Swift concurrency, in one small actor with no dependencies.

```swift
let refresh = SingleFlight<String, Token>()

// Five requests get a 401 at the same moment.
// The token is refreshed once and all five get the new token.
let token = try await refresh.run("token") {
    try await authAPI.refreshToken()
}
```

## Why

Without it, concurrent callers each start their own copy of the work:

- **Token refresh:** several requests fail with 401 and each one refreshes the
  token, sometimes invalidating each other's tokens.
- **Duplicate loads:** a list shows the same avatar in 20 cells, and each cell
  downloads it.
- **Wasted requests:** a screen and its view model both load the profile when
  the app opens.

`SingleFlight` fixes this without a cache. Once the work finishes, the next
call starts fresh, so you never get stale data you didn't ask for.

## Installation

Add the package in Xcode (**File › Add Package Dependencies…**) using
`https://github.com/abdullahtariq72/SingleFlight`, or in `Package.swift`:

```swift
.package(url: "https://github.com/abdullahtariq72/SingleFlight", from: "0.1.0"),
```

```swift
.target(name: "App", dependencies: ["SingleFlight"]),
```

## Usage

### Deduplicating by key

```swift
final class ImageLoader {
    private let downloads = SingleFlight<URL, Data>()

    func data(for url: URL) async throws -> Data {
        try await downloads.run(url) {
            try await URLSession.shared.data(from: url).0
        }
    }
}
```

Different keys run independently; only calls with the same key are shared.

### Knowing whether a result was shared

```swift
let (user, shared) = try await users.runReportingShared(id) {
    try await api.user(id)
}
logger.debug("Loaded user \(id), shared: \(shared)")
```

### Cancelling and forgetting

```swift
await downloads.cancel(url) // cancels the shared work for every caller
await downloads.forget(url) // the next call starts new work; current callers still get their result
```

## Behavior

| Situation | Result |
|---|---|
| Same key while work is running | Waits for and returns the same value, or throws the same error |
| Same key after work finished | Starts new work (nothing is cached) |
| One caller's task is cancelled | The shared work keeps running for the other callers |
| `cancel(key)` | The shared work is cancelled; callers get its result, usually `CancellationError` |
| `forget(key)` | Current callers get the old result; new callers start new work |

`isRunning(_:)` and `callerCount(for:)` are available for debugging and tests.

## Requirements

- Swift 5.9+
- iOS 13, macOS 10.15, tvOS 13, watchOS 6, visionOS 1, or Linux

## License

MIT
