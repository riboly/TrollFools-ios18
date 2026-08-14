//
//  InjectorV3+Backup.swift
//  TrollFools
//
//  Created by 82Flex on 2025/1/10.
//

import CocoaLumberjackSwift
import Foundation

extension InjectorV3 {
    // MARK: - Constants

    static let alternateSuffix = "troll-fools.bak"
    static let injectionBackupsRoot = URL(fileURLWithPath: "/var/mobile/Library/TrollFools/InjectionBackups", isDirectory: true)

    struct InjectionBackupEntry: Codable {
        let relativePath: String
        let existed: Bool
        let isDirectory: Bool
    }

    final class InjectionTransaction {
        let identifier: String
        let rootURL: URL
        let entries: [InjectionBackupEntry]
        let originalEntitlements: String?

        init(identifier: String, rootURL: URL, entries: [InjectionBackupEntry], originalEntitlements: String?) {
            self.identifier = identifier
            self.rootURL = rootURL
            self.entries = entries
            self.originalEntitlements = originalEntitlements
        }
    }

    static func alternateURL(for target: URL) -> URL {
        target.appendingPathExtension(Self.alternateSuffix)
    }

    // MARK: - Shared Methods

    func hasAlternate(_ target: URL) -> Bool {
        let alternateURL = Self.alternateURL(for: target)
        return FileManager.default.fileExists(atPath: alternateURL.path)
    }

    func makeAlternate(_ target: URL) throws {
        guard !hasAlternate(target) else {
            return
        }
        let alternateURL = Self.alternateURL(for: target)
        try cmdCopy(from: target, to: alternateURL)
    }

    func removeAlternate(_ target: URL) throws {
        guard hasAlternate(target) else {
            return
        }
        let alternateURL = Self.alternateURL(for: target)
        try cmdRemove(alternateURL)
    }

    func restoreAlternate(_ target: URL) throws {
        guard hasAlternate(target) else {
            return
        }
        let alternateURL = Self.alternateURL(for: target)
        try cmdMove(from: alternateURL, to: target, overwrite: true)
    }

    func beginInjectionTransaction(targetMachO: URL?, destinationURLs: [URL], metadata: MachOMetadata?) throws -> InjectionTransaction {
        let identifier = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)"
        let rootURL = Self.injectionBackupsRoot
            .appendingPathComponent(appID, isDirectory: true)
            .appendingPathComponent(identifier, isDirectory: true)
        DDLogInfo("Creating injection backup at \(rootURL.path)", ddlog: logger)
        try cmdMakeDirectory(at: rootURL, withIntermediateDirectories: true)

        let codeSignatureURL = bundleURL.appendingPathComponent("_CodeSignature", isDirectory: true)
        let provisioningURL = bundleURL.appendingPathComponent("embedded.mobileprovision")
        let infoPlistURL = bundleURL.appendingPathComponent("Info.plist")
        var protectedURLs = [executableURL!, infoPlistURL, codeSignatureURL, provisioningURL]
        if let targetMachO { protectedURLs.append(targetMachO) }
        protectedURLs.append(contentsOf: destinationURLs)

        var seen = Set<String>()
        var entries = [InjectionBackupEntry]()
        for sourceURL in protectedURLs {
            let normalized = sourceURL.standardizedFileURL
            let relativePath = try relativeBundlePath(normalized)
            guard seen.insert(relativePath).inserted else { continue }

            var isDirectory: ObjCBool = false
            let existed = FileManager.default.fileExists(atPath: normalized.path, isDirectory: &isDirectory)
            let entry = InjectionBackupEntry(relativePath: relativePath, existed: existed, isDirectory: isDirectory.boolValue)
            entries.append(entry)
            DDLogInfo("Backup entry \(relativePath), existed: \(existed)", ddlog: logger)
            guard existed else { continue }

            let backupURL = rootURL.appendingPathComponent("Files", isDirectory: true).appendingPathComponent(relativePath)
            try cmdMakeDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try cmdCopy(from: normalized, to: backupURL, clone: true, overwrite: true)
        }

        let originalEntitlements = try? cmdExtractEntitlements(executableURL)
        if let originalEntitlements {
            try writeBackupData(Data(originalEntitlements.utf8), name: "entitlements.xml", rootURL: rootURL)
        }
        if let metadata {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try writeBackupData(try encoder.encode(metadata), name: "original-mach-o.json", rootURL: rootURL)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writeBackupData(try encoder.encode(entries), name: "manifest.json", rootURL: rootURL)
        DDLogInfo("Injection backup completed with \(entries.count) entries", ddlog: logger)
        return InjectionTransaction(
            identifier: identifier,
            rootURL: rootURL,
            entries: entries,
            originalEntitlements: originalEntitlements
        )
    }

    func rollbackInjectionTransaction(_ transaction: InjectionTransaction) throws {
        for entry in transaction.entries.reversed() {
            let targetURL = bundleURL.appendingPathComponent(entry.relativePath)
            if entry.existed {
                let backupURL = transaction.rootURL
                    .appendingPathComponent("Files", isDirectory: true)
                    .appendingPathComponent(entry.relativePath)
                guard FileManager.default.fileExists(atPath: backupURL.path) else {
                    throw Error.generic("Backup is incomplete: \(entry.relativePath)")
                }
                try cmdCopy(from: backupURL, to: targetURL, clone: true, overwrite: true)
            } else if FileManager.default.fileExists(atPath: targetURL.path) {
                try cmdRemove(targetURL, recursively: entry.isDirectory || checkIsDirectory(targetURL))
            }
        }
        try cmdChangeOwnerToInstalld(bundleURL, recursively: true)
    }

    private func relativeBundlePath(_ url: URL) throws -> String {
        let root = canonicalFileSystemPath(bundleURL)
        let path = canonicalFileSystemPath(url)
        guard path == root || path.hasPrefix(root + "/") else {
            throw Error.generic("Backup target is outside the app bundle: \(url.path)")
        }
        return path == root ? "." : String(path.dropFirst(root.count + 1))
    }

    private func canonicalFileSystemPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        if path == "/var" || path.hasPrefix("/var/") {
            path = "/private" + path
        }
        return path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    func writeBackupData(_ data: Data, name: String, rootURL: URL) throws {
        let stagingURL = temporaryDirectoryURL.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try data.write(to: stagingURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: stagingURL) }
        try cmdCopy(
            from: stagingURL,
            to: rootURL.appendingPathComponent(name),
            clone: true,
            overwrite: true
        )
    }
}
