// BonjourBrowser.swift
// ConnectionPool / CrossPlatform / Discovery
//
// `_chessup-pvp._tcp` mDNS browser using `NWBrowser`. Emits a stream of
// `DiscoveredService` values; the consumer parses the TXT record per
// spec §2.2 and decides whether to surface the peer in the lobby UI.
//
// Receiver-side TXT cap enforcement is best-effort (ADR-0006 §5) — the
// platform mDNS stack truncates per RFC 6763 §6.1, so we trust what
// `NWBrowser` hands us and drop entries the v1 schema can't make sense of
// rather than throwing.

import Foundation
import Network

public final class BonjourBrowser: @unchecked Sendable {

    public struct DiscoveredService: Sendable, Equatable {
        public let name: String
        public let endpoint: NWEndpoint
        public let txt: [String: String]

        /// `cap=chess.1` per spec §2.2. The browser surfaces every service
        /// regardless; the consumer filters on this so a future `chess.2`
        /// receiver still discovers v1 hosts but doesn't claim them.
        public var hasChessV1Capability: Bool {
            (txt["cap"] ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .contains(CrossPlatformHandshake.capChess1)
        }
    }

    private let queue: DispatchQueue
    private var browser: NWBrowser?

    public init(queue: DispatchQueue = DispatchQueue(label: "ConnectionPool.BonjourBrowser")) {
        self.queue = queue
    }

    /// Begin browsing `_chessup-pvp._tcp` services in the local domain.
    /// `onChange` is invoked with the full current snapshot of discovered
    /// services every time a TXT/endpoint update arrives.
    public func start(onChange: @escaping @Sendable ([DiscoveredService]) -> Void) {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        // `NWBrowser.Descriptor.bonjour(type:domain:)` discovers
        // services BUT omits their TXT records — `result.metadata`
        // arrives as `.none` and the consumer sees an empty txt dict.
        // Our v1 capability filter (`cap=chess.1`) and platform tag
        // (`plat=ios|and`) both live in the TXT, so the non-TXT
        // descriptor effectively drops every cross-platform host. Use
        // `.bonjourWithTXTRecord(...)` so TXT travels with each result.
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: BonjourAdvertiser.serviceType,
            domain: BonjourAdvertiser.domain
        )
        let browser = NWBrowser(for: descriptor, using: parameters)
        browser.browseResultsChangedHandler = { results, _ in
            let services: [DiscoveredService] = results.compactMap { result in
                let name: String
                switch result.endpoint {
                case .service(let n, _, _, _): name = n
                case .hostPort(let host, _):   name = "\(host)"
                default:                       name = "\(result.endpoint)"
                }
                var txt: [String: String] = [:]
                switch result.metadata {
                case .bonjour(let record):
                    for entry in record.dictionary {
                        txt[entry.key] = entry.value
                    }
                default:
                    break
                }
                return DiscoveredService(name: name, endpoint: result.endpoint, txt: txt)
            }
            onChange(services)
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }
}
