// DeviceBlockListService.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation

/// Manages a persistent block list of devices.
///
/// When `ConnectionPoolConfiguration.blockListStorageProvider` is set, the block list
/// is persisted through the provided secure storage backend. Otherwise, falls back to
/// plain `UserDefaults` for backwards compatibility.
@MainActor
public final class DeviceBlockListService {

    // MARK: - Singleton

    public static let shared = DeviceBlockListService()

    // MARK: - Constants

    private static let storageKey = "connection_pool_blocked_devices"

    // MARK: - State

    public private(set) var blockedDevices: [BlockedDevice] = []

    // MARK: - Initialization

    private init() {
        load()
    }

    // MARK: - Public API

    /// Check if a device is blocked by peer ID
    public func isBlocked(_ peerID: String) -> Bool {
        blockedDevices.contains { $0.id == peerID }
    }

    /// Block a device
    public func blockDevice(_ peerID: String, displayName: String, reason: BlockReason) {
        guard !isBlocked(peerID) else { return }

        let device = BlockedDevice(
            id: peerID,
            peerDisplayName: displayName,
            reason: reason
        )
        blockedDevices.append(device)
        save()
        log("Blocked device: \(displayName) (\(peerID.prefix(8))...), reason: \(reason.rawValue)", category: .network)
    }

    /// Unblock a device
    public func unblockDevice(_ peerID: String) {
        blockedDevices.removeAll { $0.id == peerID }
        save()
        log("Unblocked device: \(peerID.prefix(8))...", category: .network)
    }

    // MARK: - Persistence

    private var secureProvider: BlockListStorageProvider? {
        ConnectionPoolConfiguration.blockListStorageProvider
    }

    private func load() {
        let data: Data?

        if let provider = secureProvider {
            data = try? provider.load(forKey: Self.storageKey)
        } else {
            data = UserDefaults.standard.data(forKey: Self.storageKey)
        }

        guard let data,
              let devices = try? JSONDecoder().decode([BlockedDevice].self, from: data) else {
            return
        }
        blockedDevices = devices

        let storageBackend = secureProvider != nil ? "secure storage" : "UserDefaults"
        log("Loaded \(devices.count) blocked device(s) from \(storageBackend)", category: .network)
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(blockedDevices)

            if let provider = secureProvider {
                try provider.save(data, forKey: Self.storageKey)
            } else {
                UserDefaults.standard.set(data, forKey: Self.storageKey)
            }
        } catch {
            log("Failed to save block list: \(error)", level: .error, category: .network)
        }
    }
}
