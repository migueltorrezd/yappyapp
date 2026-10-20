import CryptoKit
import Foundation

enum ModelIntegrity {
    static func verifyDownloadedFile(at url: URL, option: ModelOption) throws {
        guard let expected = option.expectedSHA1?.lowercased() else { return }

        let actual = try sha1Hex(for: url)
        guard actual == expected else {
            throw WhisperError.serverFailed(
                "Checksum mismatch for \(option.filename): expected \(expected), got \(actual). Delete the file and download it again."
            )
        }
    }

    static func sha1Hex(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = Insecure.SHA1()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }

        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func sha256Hex(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }

        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Git's object id hashes `blob <byte-count>\0` before the raw bytes. This
    /// verifies regular (non-LFS) files against the OID returned by the pinned
    /// Hugging Face repository tree.
    static func gitBlobSHA1Hex(for url: URL, size: Int) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(size)\0".utf8))
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }

        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func verifyParakeetFile(at url: URL, metadata: ParakeetRemoteFile) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let actualSize = (attributes[.size] as? NSNumber)?.intValue ?? -1
        guard actualSize == metadata.size else {
            throw WhisperError.serverFailed(
                "Size mismatch for \(metadata.path): expected \(metadata.size), got \(actualSize)."
            )
        }

        let actualDigest: String
        switch metadata.digestAlgorithm {
        case .sha256:
            actualDigest = try sha256Hex(for: url)
        case .gitBlobSHA1:
            actualDigest = try gitBlobSHA1Hex(for: url, size: metadata.size)
        }

        guard actualDigest == metadata.digest.lowercased() else {
            throw WhisperError.serverFailed(
                "Integrity mismatch for \(metadata.path): expected \(metadata.digest), got \(actualDigest)."
            )
        }
    }
}
