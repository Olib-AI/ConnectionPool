# Configuration

[Back to README](../README.md)

Every injection point is a static property on `ConnectionPoolConfiguration`. Set them at app startup, before any other ConnectionPool API is used.

## Contents

- [Injecting a Custom Logger](#injecting-a-custom-logger)
- [Injecting Encrypted Block List Storage](#injecting-encrypted-block-list-storage)
- [Injecting Encrypted Remote Pool State Storage](#injecting-encrypted-remote-pool-state-storage)

## Injecting a Custom Logger

```swift
struct MyLogger: ConnectionPoolLogger {
    func log(
        _ message: String,
        level: PoolLogLevel,
        category: PoolLogCategory,
        file: String,
        function: String,
        line: Int
    ) {
        print("[\(level.rawValue)] [\(category.rawValue)] \(message)")
    }
}

// Set before using any ConnectionPool APIs
ConnectionPoolConfiguration.logger = MyLogger()
```

## Injecting Encrypted Block List Storage

```swift
struct SecureStorage: BlockListStorageProvider {
    func save(_ data: Data, forKey key: String) throws {
        // Write to Keychain or encrypted file
    }
    func load(forKey key: String) throws -> Data? {
        // Read from Keychain or encrypted file
    }
}

// Set at app startup
ConnectionPoolConfiguration.blockListStorageProvider = SecureStorage()
```

## Injecting Encrypted Remote Pool State Storage

```swift
// Same protocol as block list storage, so reuse your SecureStorage implementation
ConnectionPoolConfiguration.remotePoolStateStorageProvider = SecureStorage()
```

When set, `RemotePoolState` persists through this provider instead of plain `UserDefaults`, preventing connection history (server URL, pool ID, host status) from being stored unencrypted.
