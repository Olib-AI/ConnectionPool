// RemotePoolService+Card.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation

extension RemotePoolService {

    public enum CardPackagingError: Error, LocalizedError {
        case writeFailed(Error)
        case decodeFailed(Error)
        case malformedInnerURL

        public var errorDescription: String? {
            switch self {
            case .writeFailed(let err):
                return "Couldn't write invite file: \(err.localizedDescription)"
            case .decodeFailed(let err):
                return "Invite card couldn't be opened: \(err.localizedDescription)"
            case .malformedInnerURL:
                return "Invite card contained a malformed invitation URL."
            }
        }
    }

    /// Wrap an existing `RemoteInvitation` URL into a `.stcard` file. Returns
    /// a temp-directory file URL suitable for `ShareLink` /
    /// `UIActivityViewController`.
    public func packageInvitationCard(invitation: RemoteInvitation) throws -> URL {
        let bytes = try SealedInviteCard.encode(url: invitation.url.absoluteString)
        let safeToken = invitation.tokenId
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
            .prefix(12)
        let filename = "stealthos-invite-\(safeToken).\(SealedInviteCard.fileExtension)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try? FileManager.default.removeItem(at: url)
            try bytes.write(to: url, options: [.atomic])
            return url
        } catch {
            throw CardPackagingError.writeFailed(error)
        }
    }

    /// Same bytes as the file, suitable for QR-code byte-mode encoding.
    public func packageInvitationCardBytes(invitation: RemoteInvitation) throws -> Data {
        try SealedInviteCard.encode(url: invitation.url.absoluteString)
    }

    /// Decode `.stcard` bytes and return the parsed invitation, ready to
    /// hand to the existing remote-pool join flow.
    public static func parseInvitationCardBytes(_ data: Data) throws -> ParsedInvitation {
        let urlString: String
        do {
            urlString = try SealedInviteCard.decode(data)
        } catch {
            throw CardPackagingError.decodeFailed(error)
        }
        guard let inner = URL(string: urlString),
              let parsed = parseInvitationURL(inner) else {
            throw CardPackagingError.malformedInnerURL
        }
        return parsed
    }
}
