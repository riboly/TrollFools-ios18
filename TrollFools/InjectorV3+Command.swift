//
//  InjectorV3+Command.swift
//  TrollFools
//
//  Created by 82Flex on 2025/1/9.
//

import CocoaLumberjackSwift
import Foundation
import MachOKit

extension InjectorV3 {
    // MARK: - chown

    fileprivate static let chownBinaryURL = findExecutable("chown")

    func cmdChangeOwner(_ target: URL, owner: uid_t, groupOwner: uid_t? = nil, recursively: Bool = false) throws {
        if isPrivileged {
            try rootChangeOwner(target, owner: owner, groupOwner: groupOwner, recursively: recursively)
            return
        }
        var args = [String]()
        if recursively {
            args.append("-R")
        }
        if let groupOwner {
            args.append(String(format: "%d:%d", owner, groupOwner))
        } else {
            args.append(String(format: "%d", owner))
        }
        args.append(target.path)
        let retCode = try Execute.rootSpawn(binary: Self.chownBinaryURL.path, arguments: args, ddlog: logger)
        guard case let .exit(code) = retCode, code == EXIT_SUCCESS else {
            try throwCommandFailure("chown", reason: retCode)
        }
    }

    func cmdChangeOwnerToInstalld(_ target: URL, recursively: Bool = false) throws {
        try cmdChangeOwner(target, owner: 33, groupOwner: 33, recursively: recursively)
    }

    private func rootChangeOwner(_ target: URL, owner: uid_t, groupOwner: uid_t? = nil, recursively: Bool = false) throws {
        let attrs: [FileAttributeKey: Any] = [
            .ownerAccountID: NSNumber(value: owner),
            .groupOwnerAccountID: NSNumber(value: groupOwner ?? owner),
        ]
        if !recursively {
            try FileManager.default.setAttributes(attrs, ofItemAtPath: target.path)
            return
        }
        if let enumerator = FileManager.default.enumerator(at: target, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                try FileManager.default.setAttributes(attrs, ofItemAtPath: fileURL.path)
            }
        }
    }

    // MARK: - cp

    fileprivate static let cpBinaryURL: URL = {
        if #available(iOS 16, *) {
            findExecutable("cp")
        } else {
            findExecutable("cp-15")
        }
    }()

    func cmdCopy(from srcURL: URL, to destURL: URL, clone: Bool = false, overwrite: Bool = false) throws {
        if isPrivileged {
            try rootCopy(from: srcURL, to: destURL, overwrite: overwrite)
            return
        }
        if overwrite {
            try? cmdRemove(destURL, recursively: true)
        }
        var args = [String]()
        if clone {
            args.append("--reflink=auto")
        }
        args += ["-rfp", srcURL.path, destURL.path]
        let retCode = try Execute.rootSpawn(binary: Self.cpBinaryURL.path, arguments: args, ddlog: logger)
        guard case let .exit(code) = retCode, code == EXIT_SUCCESS else {
            try throwCommandFailure("cp", reason: retCode)
        }
    }

    private func rootCopy(from srcURL: URL, to destURL: URL, overwrite: Bool = false) throws {
        if overwrite {
            try? rootRemove(destURL, recursively: true)
        }
        try FileManager.default.copyItem(at: srcURL, to: destURL)
    }

    // MARK: - ldid

    fileprivate static let bundledLdidBinaryURL: URL = findExecutable("ldid")

    var ldidBinaryURLs: [URL] {
        var candidates = [Self.bundledLdidBinaryURL]
        let environmentLdid: URL? = switch signingBackend {
        case .rootlessAdHoc:
            Self.rootlessLdidBinaryURL
        case .rootHideFastPath:
            Self.rootHideLdidBinaryURL
        case .rootHideTrustCache:
            Self.rootHideLdidBinaryURL
        case .coreTrustBypass:
            nil
        }
        if let environmentLdid,
           FileManager.default.isExecutableFile(atPath: environmentLdid.path),
           environmentLdid.standardizedFileURL.path != Self.bundledLdidBinaryURL.standardizedFileURL.path
        {
            candidates.append(environmentLdid)
        }
        return candidates
    }

    func cmdExtractEntitlements(_ target: URL) throws -> String? {
        let receipt = try runLdid(arguments: ["-e", target.path], operation: "extract entitlements", target: target)
        return receipt.stdout.isEmpty ? nil : receipt.stdout
    }

    func cmdPseudoSign(_ target: URL, force: Bool = false) throws {
        var hasCodeSign = false
        var preservesEntitlements = false

        let targetFile = try MachOKit.loadFromFile(url: target)
        switch targetFile {
        case let .machO(machOFile):
            preservesEntitlements = machOFile.header.fileType == .execute
            for command in machOFile.loadCommands {
                switch command {
                case .codeSignature:
                    hasCodeSign = true
                    break
                default:
                    continue
                }
            }
        case let .fat(fatFile):
            let machOFiles = try fatFile.machOFiles()
            for machOFile in machOFiles {
                preservesEntitlements = machOFile.header.fileType == .execute
                for command in machOFile.loadCommands {
                    switch command {
                    case .codeSignature:
                        hasCodeSign = true
                        break
                    default:
                        continue
                    }
                }
            }
        }

        guard force || !hasCodeSign else {
            return
        }

        if preservesEntitlements {
            let receipt = try runLdid(arguments: ["-e", target.path], operation: "extract entitlements", target: target)
            let xmlContent = receipt.stdout
            let xmlURL = temporaryDirectoryURL
                .appendingPathComponent("\(UUID().uuidString)_\(target.lastPathComponent)")
                .appendingPathExtension("xml")

            try xmlContent.write(to: xmlURL, atomically: true, encoding: .utf8)
            try runLdid(
                arguments: ["-S\(xmlURL.path)", target.path],
                operation: "sign with preserved entitlements",
                target: target
            )
        } else {
            try runLdid(arguments: ["-S", target.path], operation: "ad-hoc sign", target: target)
        }
    }

    @discardableResult
    private func runLdid(arguments: [String], operation: String, target: URL) throws -> AuxiliaryExecute.ExecuteReceipt {
        var failures = [String]()
        for binaryURL in ldidBinaryURLs {
            do {
                let receipt = try Execute.rootSpawnWithOutputs(
                    binary: binaryURL.path,
                    arguments: arguments,
                    ddlog: logger
                )
                if case let .exit(code) = receipt.terminationReason, code == EXIT_SUCCESS {
                    DDLogInfo("ldid \(operation) succeeded with \(binaryURL.path): \(target.path)", ddlog: logger)
                    return receipt
                }

                let detail = ldidFailureDetail(binaryURL: binaryURL, receipt: receipt)
                failures.append(detail)
                DDLogError("ldid \(operation) failed for \(target.path): \(detail)", ddlog: logger)
            } catch {
                let detail = "\(binaryURL.path): \(error.localizedDescription)"
                failures.append(detail)
                DDLogError("ldid \(operation) failed for \(target.path): \(detail)", ddlog: logger)
            }
        }
        throw Error.generic("ldid \(operation) failed for \(target.path)\n\(failures.joined(separator: "\n"))")
    }

    private func ldidFailureDetail(binaryURL: URL, receipt: AuxiliaryExecute.ExecuteReceipt) -> String {
        let reason: String
        switch receipt.terminationReason {
        case let .exit(code):
            reason = "exit \(code)"
        case let .uncaughtSignal(signal):
            reason = "signal \(signal)"
        }
        let stderr = receipt.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = receipt.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        var components = ["\(binaryURL.path): \(reason)"]
        if !stderr.isEmpty { components.append("stderr: \(stderr)") }
        if !stdout.isEmpty { components.append("stdout: \(stdout)") }
        return components.joined(separator: "; ")
    }

    func cmdRootHideFastPathSign(_ target: URL) throws {
        guard let binaryURL = Self.rootHideFastPathSignBinaryURL else {
            throw Error.generic("RootHide fastPathSign is unavailable through the validated jbroot mapping.")
        }

        let receipt = try Execute.rootSpawnWithOutputs(
            binary: binaryURL.path,
            arguments: [target.path],
            ddlog: logger
        )
        guard case let .exit(code) = receipt.terminationReason, code == EXIT_SUCCESS else {
            let detail = ldidFailureDetail(binaryURL: binaryURL, receipt: receipt)
            DDLogError("RootHide fastPathSign failed for \(target.path): \(detail)", ddlog: logger)
            throw Error.generic("RootHide fastPathSign failed for \(target.path): \(detail)")
        }
        DDLogInfo("RootHide fastPathSign succeeded with \(binaryURL.path): \(target.path)", ddlog: logger)
    }

    func cmdRootHideTrustCacheSign(_ target: URL, uploadTrust: Bool = true) throws {
        let existingEntitlements = try cmdExtractEntitlements(target)
        if let existingEntitlements, !existingEntitlements.isEmpty {
            guard let data = existingEntitlements.data(using: .utf8),
                  let dictionary = try PropertyListSerialization.propertyList(
                      from: data,
                      options: [],
                      format: nil
                  ) as? [String: Any]
            else {
                throw Error.generic("Cannot parse existing entitlements for RootHide trust-cache signing: \(target.path)")
            }

            let entitlementsData = try PropertyListSerialization.data(
                fromPropertyList: dictionary,
                format: .xml,
                options: 0
            )
            let entitlementsURL = temporaryDirectoryURL
                .appendingPathComponent("\(UUID().uuidString)_\(target.lastPathComponent)")
                .appendingPathExtension("xml")
            try entitlementsData.write(to: entitlementsURL, options: .atomic)
            defer { try? FileManager.default.removeItem(at: entitlementsURL) }

            try runLdid(
                arguments: ["-S\(entitlementsURL.path)", target.path],
                operation: "RootHide trust-cache sign with preserved entitlements",
                target: target
            )
        } else {
            try runLdid(
                arguments: ["-S", target.path],
                operation: "RootHide trust-cache ad-hoc sign",
                target: target
            )
        }

        if uploadTrust {
            try cmdRootHideTrustExecutableRecurse(target)
        }
    }

    func cmdRootHideTrustExecutableRecurse(_ target: URL) throws {
        guard let trustExecutableRecurse = Self.rootHideTrustExecutableRecurse else {
            throw Error.generic("RootHide recursive trust API is unavailable through the validated jbroot mapping.")
        }

        let originalCDHashes = try inspectMachO(target).slices.compactMap(\.cdHash)
        let usesHiddenStaging = removableAppContainerURL(containing: target) != nil
        let trustTarget: URL
        if usesHiddenStaging {
            trustTarget = temporaryDirectoryURL
                .appendingPathComponent("RootHideTrust-\(UUID().uuidString)-\(target.lastPathComponent)")
            try cmdCopy(from: target, to: trustTarget, clone: true, overwrite: true)
        } else {
            trustTarget = target
        }
        defer {
            if usesHiddenStaging, FileManager.default.fileExists(atPath: trustTarget.path) {
                try? cmdRemove(trustTarget)
            }
        }

        let result = trustTarget.path.withCString { trustExecutableRecurse($0, nil) }
        guard result == 0 else {
            throw Error.generic("RootHide recursive trust failed for \(trustTarget.path): result \(result)")
        }

        let finalCDHashes = try inspectMachO(trustTarget).slices.compactMap(\.cdHash)
        guard !finalCDHashes.isEmpty else {
            throw Error.generic("RootHide recursive trust produced no verifiable CDHash for \(trustTarget.path).")
        }
        let trustedCDHashes = try verifiedRootHideTrustCacheCDHashes(finalCDHashes)
        guard !trustedCDHashes.isEmpty else {
            throw Error.generic(
                "RootHide recursive trust returned success but the final CDHash is absent from the trust cache: \(target.path) [\(finalCDHashes.joined(separator: ", "))]"
            )
        }

        if usesHiddenStaging {
            try cmdCopy(from: trustTarget, to: target, clone: true, overwrite: true)
            let copiedCDHashes = try inspectMachO(target).slices.compactMap(\.cdHash)
            guard copiedCDHashes == finalCDHashes else {
                throw Error.generic(
                    "RootHide hidden staging copy-back changed the trusted CDHash: \(target.path) [expected \(finalCDHashes.joined(separator: ", ")), got \(copiedCDHashes.joined(separator: ", "))]"
                )
            }
        }

        let transition = originalCDHashes == finalCDHashes
            ? "unchanged (already trusted or idempotent)"
            : "\(originalCDHashes.joined(separator: ", ")) -> \(finalCDHashes.joined(separator: ", "))"
        let route = usesHiddenStaging ? " via hidden staging" : ""
        let diagnostic = "RootHide trust-cache verified\(route) for \(target.lastPathComponent): \(trustedCDHashes.joined(separator: ", ")); CDHash \(transition)."
        rootHideTrustDiagnostics.append(diagnostic)
        DDLogInfo(diagnostic, ddlog: logger)
    }

    private func verifiedRootHideTrustCacheCDHashes(_ cdHashes: [String]) throws -> [String] {
        guard let jbctlURL = Self.rootHideJBCTLBinaryURL else {
            throw Error.generic("RootHide trust-cache verification is unavailable through the validated jbroot mapping.")
        }
        let receipt = try Execute.rootSpawnWithOutputs(
            binary: jbctlURL.path,
            arguments: ["trustcache", "info"],
            ddlog: logger
        )
        guard case let .exit(code) = receipt.terminationReason, code == EXIT_SUCCESS else {
            let detail = ldidFailureDetail(binaryURL: jbctlURL, receipt: receipt)
            throw Error.generic("RootHide trust-cache verification failed: \(detail)")
        }
        return cdHashes.filter { receipt.stdout.range(of: $0, options: .caseInsensitive) != nil }
    }

    private func removableAppContainerURL(containing target: URL) -> URL? {
        var path = target.standardizedFileURL.path
        if path == "/rootfs" || path.hasPrefix("/rootfs/") {
            path.removeFirst("/rootfs".count)
        }
        if path == "/var" || path.hasPrefix("/var/") {
            path = "/private" + path
        }

        let prefix = "/private/var/containers/Bundle/Application/"
        guard path.hasPrefix(prefix) else { return nil }
        let remainder = path.dropFirst(prefix.count)
        guard let uuid = remainder.split(separator: "/", maxSplits: 1).first.map(String.init),
              uuid.count == 36,
              UUID(uuidString: uuid) != nil
        else {
            return nil
        }
        return URL(fileURLWithPath: prefix, isDirectory: true).appendingPathComponent(uuid, isDirectory: true)
    }

    // MARK: - mkdir

    fileprivate static let mkdirBinaryURL = findExecutable("mkdir")

    func cmdMakeDirectory(at target: URL, withIntermediateDirectories: Bool = false) throws {
        if isPrivileged {
            try rootMakeDirectory(at: target, withIntermediateDirectories: withIntermediateDirectories)
            return
        }
        var args = [String]()
        if withIntermediateDirectories {
            args.append("-p")
        }
        args.append(target.path)
        let retCode = try Execute.rootSpawn(binary: Self.mkdirBinaryURL.path, arguments: args, ddlog: logger)
        guard case let .exit(code) = retCode, code == EXIT_SUCCESS else {
            try throwCommandFailure("mkdir", reason: retCode)
        }
    }

    private func rootMakeDirectory(at target: URL, withIntermediateDirectories: Bool = false) throws {
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: withIntermediateDirectories)
    }

    // MARK: - mv

    fileprivate static let mvBinaryURL: URL = {
        if #available(iOS 16, *) {
            findExecutable("mv")
        } else {
            findExecutable("mv-15")
        }
    }()

    func cmdMove(from srcURL: URL, to destURL: URL, overwrite: Bool = false) throws {
        if isPrivileged {
            try rootMove(from: srcURL, to: destURL, overwrite: overwrite)
            return
        }
        if overwrite {
            try? cmdRemove(destURL, recursively: true)
        }
        var args = [String]()
        if overwrite {
            args.append("-f")
        }
        args += [srcURL.path, destURL.path]
        let retCode = try Execute.rootSpawn(binary: Self.mvBinaryURL.path, arguments: args, ddlog: logger)
        guard case let .exit(code) = retCode, code == EXIT_SUCCESS else {
            try throwCommandFailure("mv", reason: retCode)
        }
    }

    private func rootMove(from srcURL: URL, to destURL: URL, overwrite: Bool = false) throws {
        if overwrite {
            try? rootRemove(destURL, recursively: true)
        }
        try FileManager.default.moveItem(at: srcURL, to: destURL)
    }

    // MARK: - rm

    fileprivate static let rmBinaryURL = findExecutable("rm")

    func cmdRemove(_ target: URL, recursively: Bool = false) throws {
        if isPrivileged {
            try rootRemove(target, recursively: recursively)
            return
        }
        let retCode = try Execute.rootSpawn(binary: Self.rmBinaryURL.path, arguments: [
            recursively ? "-rf" : "-f", target.path,
        ], ddlog: logger)
        guard case let .exit(code) = retCode, code == EXIT_SUCCESS else {
            try throwCommandFailure("rm", reason: retCode)
        }
    }

    private func rootRemove(_ target: URL, recursively: Bool = false) throws {
        if !recursively {
            let retCode = target.withUnsafeFileSystemRepresentation { unlink($0) }
            guard retCode == 0 else {
                throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EPERM)
            }
            return
        }
        try FileManager.default.removeItem(at: target)
    }

    // MARK: - ct_bypass

    fileprivate static let ctBypassBinaryURL = findExecutable("ct_bypass")

    func cmdCoreTrustBypass(_ target: URL, teamID: String) throws {
        try cmdPseudoSign(target)
        let retCode = try Execute.rootSpawn(binary: Self.ctBypassBinaryURL.path, arguments: [
            "-r", "-i", target.path, "-t", teamID,
        ], ddlog: logger)
        guard case let .exit(code) = retCode, code == EXIT_SUCCESS else {
            try throwCommandFailure("ct_bypass", reason: retCode)
        }
    }

    func cmdCompatibleSign(_ target: URL, teamID: String) throws {
        switch signingBackend {
        case .rootlessAdHoc:
            try cmdPseudoSign(target, force: true)
        case .rootHideFastPath:
            try cmdPseudoSign(target, force: true)
            try cmdRootHideFastPathSign(target)
        case .rootHideTrustCache:
            try cmdRootHideTrustCacheSign(target)
        case .coreTrustBypass:
            try cmdCoreTrustBypass(target, teamID: teamID)
        }
    }

    // MARK: - insert_dylib

    fileprivate static let insertDylibBinaryURL = findExecutable("insert_dylib")

    func cmdInsertLoadCommandDylib(_ target: URL, name: String, weak: Bool = false) throws {
        let dylibs = try loadedDylibsOfMachO(target)
        if dylibs.contains(name) {
            return
        }
        var args = [
            name, target.path,
            "--inplace", "--overwrite", "--no-strip-codesig", "--all-yes",
        ]
        if weak {
            args.append("--weak")
        }
        let retCode = try Execute.rootSpawn(binary: Self.insertDylibBinaryURL.path, arguments: args, ddlog: logger)
        guard case let .exit(code) = retCode, code == EXIT_SUCCESS else {
            try throwCommandFailure("insert_dylib", reason: retCode)
        }
    }

    // MARK: - install_name_tool

    fileprivate static let installNameToolBinaryURL = findExecutable("install_name_tool")

    func cmdInsertLoadCommandRuntimePath(_ target: URL, name: String) throws {
        let rpaths = try runtimePathsOfMachO(target)
        if rpaths.contains(name) {
            return
        }
        try cmdPseudoSign(target, force: true)
        let retCode = try Execute.rootSpawn(binary: Self.installNameToolBinaryURL.path, arguments: [
            "-add_rpath", name, target.path,
        ], ddlog: logger)
        guard case let .exit(code) = retCode, code == EXIT_SUCCESS else {
            try throwCommandFailure("install_name_tool", reason: retCode)
        }
    }

    func cmdChangeLoadCommandDylib(_ target: URL, from srcName: String, to destName: String) throws {
        try cmdPseudoSign(target, force: true)
        let retCode = try Execute.rootSpawn(binary: Self.installNameToolBinaryURL.path, arguments: [
            "-change", srcName, destName, target.path,
        ], ddlog: logger)
        guard case let .exit(code) = retCode, code == EXIT_SUCCESS else {
            try throwCommandFailure("install-name-tool", reason: retCode)
        }
    }

    // MARK: - optool

    fileprivate static let optoolBinaryURL = findExecutable("optool")

    func cmdRemoveLoadCommandDylib(_ target: URL, name: String) throws {
        let dylibs = try loadedDylibsOfMachO(target)
        guard dylibs.contains(name) else {
            return
        }
        let retCode = try Execute.rootSpawn(binary: Self.optoolBinaryURL.path, arguments: [
            "uninstall", "-p", name, "-t", target.path,
        ], ddlog: logger)
        guard case let .exit(code) = retCode, code == EXIT_SUCCESS else {
            try throwCommandFailure("optool", reason: retCode)
        }
    }

    // MARK: - Error Handling

    fileprivate func throwCommandFailure(_ command: String, reason: AuxiliaryExecute.TerminationReason) throws -> Never {
        switch reason {
        case let .exit(code):
            throw Error.generic(String(format: NSLocalizedString("%@ exited with code %d", comment: ""), command, code))
        case let .uncaughtSignal(signal):
            throw Error.generic(String(format: NSLocalizedString("%@ terminated with signal %d", comment: ""), command, signal))
        }
    }

    // MARK: - Path Finder

    fileprivate static func findExecutable(_ name: String) -> URL {
        if let url = Bundle.main.url(forResource: name, withExtension: nil) {
            return url
        }
        if let firstArg = ProcessInfo.processInfo.arguments.first {
            let execURL = URL(fileURLWithPath: firstArg)
                .deletingLastPathComponent().appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: execURL.path) {
                return execURL
            }
        }
        if let tfProxy = LSApplicationProxy(forIdentifier: Constants.gAppIdentifier),
           let tfBundleURL = tfProxy.bundleURL()
        {
            let execURL = tfBundleURL.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: execURL.path) {
                return execURL
            }
        }
        fatalError("Unable to locate executable \(name)")
    }
}
