//
//  InjectorV3+Inject.swift
//  TrollFools
//
//  Created by 82Flex on 2025/1/10.
//

import CocoaLumberjackSwift
import Foundation

extension InjectorV3 {
    enum Strategy: String, CaseIterable {
        case lexicographic
        case fast
        case preorder
        case postorder

        var localizedDescription: String {
            switch self {
            case .lexicographic: NSLocalizedString("Lexicographic", comment: "")
            case .fast: NSLocalizedString("Fast", comment: "")
            case .preorder: NSLocalizedString("Pre-order", comment: "")
            case .postorder: NSLocalizedString("Post-order", comment: "")
            }
        }
    }

    // MARK: - Instance Methods

    func inject(_ assetURLs: [URL], shouldPersist: Bool) throws {
        didUseMachOEnumerationFallback = false
        let preparedAssetURLs = try preprocessAssets(assetURLs)
        precondition(!preparedAssetURLs.isEmpty, "No asset to inject.")

        var report = try preflight(preparedAssetURLs)
        guard report.isSafe else {
            report.status = .notSafeToInject
            try writeInjectionReport(&report)
            throw Error.generic(report.errors.joined(separator: "\n"))
        }

        let dylibsAndFrameworks = preparedAssetURLs.filter {
            $0.pathExtension.lowercased() == "dylib" || $0.pathExtension.lowercased() == "framework"
        }
        let bundles = preparedAssetURLs.filter { $0.pathExtension.lowercased() == "bundle" }
        let targetMachO = report.targetMachO.map { URL(fileURLWithPath: $0.path) }
        var destinationURLs = bundles.map { bundleURL.appendingPathComponent($0.lastPathComponent) }
        destinationURLs += dylibsAndFrameworks.map { frameworksDirectoryURL.appendingPathComponent($0.lastPathComponent) }
        if !dylibsAndFrameworks.isEmpty {
            destinationURLs.append(frameworksDirectoryURL.appendingPathComponent(Self.substrateFwkName))
        }
        if let targetMachO {
            destinationURLs.append(Self.alternateURL(for: targetMachO))
        }

        let transaction = try beginInjectionTransaction(
            targetMachO: targetMachO,
            destinationURLs: destinationURLs,
            metadata: report.targetMachO
        )
        report.backupPath = transaction.rootURL.path
        terminateApp()

        do {
            try injectBundles(bundles)
            if !dylibsAndFrameworks.isEmpty {
                guard let targetMachO else { throw Error.generic("Preflight did not select a target Mach-O.") }
                try injectDylibsAndFrameworks(dylibsAndFrameworks, targetMachO: targetMachO)
            }
            if shouldPersist {
                try persist(preparedAssetURLs)
            }
            try validateInjection(report: &report, transaction: transaction)
            report.status = .injectionSuccessful
            try writeInjectionReport(&report, backupURL: transaction.rootURL)
        } catch {
            report.errors.append(error.localizedDescription)
            do {
                try rollbackInjectionTransaction(transaction)
                report.status = .rolledBack
            } catch {
                report.status = .injectionFailed
                report.errors.append("Rollback failed: \(error.localizedDescription)")
            }
            try? writeInjectionReport(&report, backupURL: transaction.rootURL)
            throw Error.generic(report.errors.joined(separator: "\n"))
        }
    }

    func dryRun(_ assetURLs: [URL]) throws -> InjectionReport {
        didUseMachOEnumerationFallback = false
        let preparedAssetURLs = try preprocessAssets(assetURLs)
        var report = try preflight(preparedAssetURLs)
        report.status = report.isSafe ? .safeToInject : .notSafeToInject
        try writeInjectionReport(&report)
        return report
    }

    // MARK: - Private Methods

    fileprivate func injectBundles(_ assetURLs: [URL]) throws {
        guard !assetURLs.isEmpty else {
            return
        }

        for assetURL in assetURLs {
            let targetURL = bundleURL.appendingPathComponent(assetURL.lastPathComponent)

            try cmdCopy(from: assetURL, to: targetURL, clone: true, overwrite: true)
            try cmdChangeOwnerToInstalld(targetURL, recursively: true)
        }
    }

    fileprivate func injectDylibsAndFrameworks(_ assetURLs: [URL], targetMachO selectedTargetMachO: URL) throws {
        guard !assetURLs.isEmpty else {
            return
        }

        try assetURLs.forEach {
            try standardizeLoadCommandDylibToSubstrate($0)
            try applyCompatibleSignature($0)
        }

        let substrateFwkURL = try prepareSubstrate()
        let targetMachO = selectedTargetMachO
        if targetMachO.path.isEmpty {
            DDLogError("All Mach-Os are protected", ddlog: logger)

            throw Error.generic(NSLocalizedString("No eligible framework found.\n\nIt is usually not a bug with TrollFools itself, but rather with the target app. You may re-install that from App Store. You can’t use TrollFools with apps installed via “Asspp” or tweaks like “NoAppThinning”.", comment: ""))
        }

        DDLogInfo("Best matched Mach-O is \(targetMachO.path)", ddlog: logger)

        let resourceURLs: [URL] = [substrateFwkURL] + assetURLs
        try makeAlternate(targetMachO)
        do {
            try copyfiles(resourceURLs)
            for assetURL in assetURLs {
                try insertLoadCommandOfAsset(assetURL, to: targetMachO)
            }
            try applyCompatibleSignature(targetMachO)
        } catch {
            try? restoreAlternate(targetMachO)
            try? batchRemove(resourceURLs)
            throw error
        }
    }

    // MARK: - Core Trust

    func applyCompatibleSignature(_ target: URL) throws {
        let isFramework = checkIsBundle(target)

        let machO: URL
        if isFramework {
            machO = try locateExecutableInBundle(target)
        } else {
            machO = target
        }

        try cmdCompatibleSign(machO, teamID: teamID)
        try cmdChangeOwnerToInstalld(target, recursively: isFramework)
    }

    // MARK: - Cydia Substrate

    fileprivate static let substrateZipURL = findResource(substrateFwkName, fileExtension: "zip")

    fileprivate func prepareSubstrate() throws -> URL {
        try FileManager.default.unzipItem(at: Self.substrateZipURL, to: temporaryDirectoryURL)

        let fwkURL = temporaryDirectoryURL.appendingPathComponent(Self.substrateFwkName)
        try markBundlesAsInjected([fwkURL], privileged: false)

        let machO = fwkURL.appendingPathComponent(Self.substrateName)

        try cmdCompatibleSign(machO, teamID: teamID)
        try cmdChangeOwnerToInstalld(fwkURL, recursively: true)

        return fwkURL
    }

    fileprivate func standardizeLoadCommandDylibToSubstrate(_ assetURL: URL) throws {
        let machO: URL
        if checkIsBundle(assetURL) {
            machO = try locateExecutableInBundle(assetURL)
        } else {
            machO = assetURL
        }

        let dylibs = try loadedDylibsOfMachO(machO)
        for dylib in dylibs {
            if Self.ignoredDylibAndFrameworkNames.firstIndex(where: { dylib.lowercased().hasSuffix("/\($0)") }) != nil {
                try cmdChangeLoadCommandDylib(machO, from: dylib, to: "@executable_path/Frameworks/\(Self.substrateFwkName)/\(Self.substrateName)")
            }
        }
    }

    // MARK: - Load Commands

    func loadCommandNameOfAsset(_ assetURL: URL) throws -> String {
        var name = "@rpath/"

        if checkIsBundle(assetURL) {
            precondition(assetURL.pathExtension == "framework", "Invalid framework: \(assetURL.path)")
            let machO = try locateExecutableInBundle(assetURL)
            name += machO.pathComponents.suffix(2).joined(separator: "/") // @rpath/XXX.framework/XXX
            precondition(name.contains(".framework/"), "Invalid framework name: \(name)")
        } else {
            precondition(assetURL.pathExtension == "dylib", "Invalid dylib: \(assetURL.path)")
            name += assetURL.lastPathComponent
            precondition(name.hasSuffix(".dylib"), "Invalid dylib name: \(name)") // @rpath/XXX.dylib
        }

        return name
    }

    fileprivate func insertLoadCommandOfAsset(_ assetURL: URL, to target: URL) throws {
        let name = try loadCommandNameOfAsset(assetURL)

        try cmdInsertLoadCommandRuntimePath(target, name: "@executable_path/Frameworks")
        try cmdInsertLoadCommandDylib(target, name: name, weak: useWeakReference)
        try standardizeLoadCommandDylib(target, to: name)
    }

    fileprivate func standardizeLoadCommandDylib(_ target: URL, to name: String) throws {
        precondition(name.hasPrefix("@rpath/"), "Invalid dylib name: \(name)")

        let itemName = String(name[name.index(name.startIndex, offsetBy: 7)...])
        let dylibs = try loadedDylibsOfMachO(target)

        for dylib in dylibs {
            if dylib.hasSuffix("/" + itemName) {
                try cmdChangeLoadCommandDylib(target, from: dylib, to: name)
            }
        }
    }

    // MARK: - Path Clone

    fileprivate func copyfiles(_ assetURLs: [URL]) throws {
        let targetURLs = assetURLs.map {
            frameworksDirectoryURL.appendingPathComponent($0.lastPathComponent)
        }

        for (assetURL, targetURL) in zip(assetURLs, targetURLs) {
            try cmdCopy(from: assetURL, to: targetURL, clone: true, overwrite: true)
            try cmdChangeOwnerToInstalld(targetURL, recursively: checkIsDirectory(assetURL))
        }
    }

    fileprivate func batchRemove(_ assetURLs: [URL]) throws {
        try assetURLs.forEach {
            try cmdRemove($0, recursively: checkIsDirectory($0))
        }
    }

    // MARK: - Diagnostics and Validation

    fileprivate func preflight(_ assetURLs: [URL]) throws -> InjectionReport {
        let executableMetadata = try inspectMachO(executableURL)
        let injectableAssets = assetURLs.filter {
            $0.pathExtension.lowercased() == "dylib" || $0.pathExtension.lowercased() == "framework"
        }
        var inspectedAssets = [MachOMetadata]()
        var requestedLoadCommands = [String]()
        var warnings = [String]()
        var errors = [String]()

        for assetURL in injectableAssets {
            let executable = checkIsBundle(assetURL) ? try locateExecutableInBundle(assetURL) : assetURL
            do {
                let metadata = try inspectMachO(executable)
                inspectedAssets.append(metadata)
                requestedLoadCommands.append(try loadCommandNameOfAsset(assetURL))
                validateAssetDependencies(metadata, availableAssets: assetURLs, warnings: &warnings, errors: &errors)
                validateMinimumOS(metadata, errors: &errors)
            } catch {
                errors.append("Cannot inspect \(assetURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        var targetMetadata: MachOMetadata?
        if !injectableAssets.isEmpty {
            if let targetURL = try locateAvailableMachO() {
                do {
                    targetMetadata = try inspectMachO(targetURL)
                } catch {
                    errors.append("Cannot inspect target Mach-O: \(error.localizedDescription)")
                }
            } else {
                errors.append("No unencrypted target Mach-O is available.")
            }
        }

        if let targetMetadata {
            for asset in inspectedAssets where !architecturesAreCompatible(targetMetadata, asset) {
                errors.append("Architecture mismatch: \(URL(fileURLWithPath: asset.path).lastPathComponent) [\(asset.architectures.joined(separator: ", "))] cannot load into [\(targetMetadata.architectures.joined(separator: ", "))].")
            }
            validateHeaderPadding(targetMetadata, loadCommands: requestedLoadCommands, errors: &errors)
            validateLinkedit(targetMetadata, prefix: "Original target", errors: &errors)
            if !targetMetadata.codeSignaturesValid {
                errors.append("Original target CodeDirectory code-slot hashes are invalid or unsupported.")
            }
            if signingBackend == .coreTrustBypass,
               targetMetadata.slices.contains(where: { ($0.codeSignatureOffset ?? 0) % 4096 != 0 })
            {
                errors.append("The bundled CoreTrust helper cannot safely update a non-4K-aligned CodeDirectory. Use the TrollStore Lite rootless ad-hoc backend or rebuild the helper before injection.")
            }
        }

        if executableMetadata.architectures.contains("arm64e") {
            warnings.append("The app contains arm64e. Slice identity will be checked again after signing to detect fat-to-thin conversion.")
        }
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 18 {
            warnings.append("iOS 18 detected; compatibility is determined from Mach-O and signing capabilities, not the OS version alone.")
        }

        let originalEntitlements = try? cmdExtractEntitlements(executableURL)
        var report = InjectionReport(
            status: errors.isEmpty ? .safeToInject : .notSafeToInject,
            targetApp: (Bundle(url: bundleURL)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? bundleURL.deletingPathExtension().lastPathComponent,
            bundleIdentifier: appID,
            bundlePath: bundleURL.path,
            executablePath: executableURL.path,
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            signingBackend: signingBackend.rawValue,
            mainExecutable: executableMetadata,
            targetMachO: targetMetadata,
            injectedAssets: inspectedAssets,
            requestedLoadCommands: requestedLoadCommands,
            originalTargetMachO: targetMetadata,
            finalTargetMachO: nil,
            originalEntitlementsPresent: originalEntitlements != nil,
            finalEntitlementsMatch: nil,
            backupPath: nil,
            reportPath: nil,
            warnings: warnings,
            errors: errors
        )
        if signingBackend == .rootlessAdHoc {
            report.warnings.append("TrollStore Lite rootless capability detected; modified Mach-Os will use /var/jb/usr/bin/ldid.")
        }
        return report
    }

    fileprivate func validateInjection(report: inout InjectionReport, transaction: InjectionTransaction) throws {
        guard let original = report.originalTargetMachO else {
            report.finalEntitlementsMatch = entitlementsEqual(transaction.originalEntitlements, try? cmdExtractEntitlements(executableURL))
            return
        }

        let targetURL = URL(fileURLWithPath: original.path)
        let final = try inspectMachO(targetURL)
        report.finalTargetMachO = final
        report.targetMachO = final

        guard final.isStructurallyValid else {
            report.errors.append("Final Mach-O is structurally invalid.")
            throw Error.generic(report.errors.last!)
        }
        for command in report.requestedLoadCommands {
            if !final.slices.allSatisfy({ $0.dependencies.contains(command) }) {
                report.errors.append("Missing \(command) in one or more final Mach-O slices.")
            }
        }
        if !final.codeSignaturesValid {
            report.errors.append("Final CodeDirectory code-slot validation failed.")
        }
        validateLinkedit(final, prefix: "Final target", errors: &report.errors)

        for originalSlice in original.slices {
            guard let finalSlice = final.slices.first(where: { $0.architecture == originalSlice.architecture }) else {
                report.errors.append("Signing removed the \(originalSlice.architecture) slice from the target Mach-O.")
                continue
            }
            if originalSlice.hasChainedFixups != finalSlice.hasChainedFixups {
                report.errors.append("LC_DYLD_CHAINED_FIXUPS changed for \(originalSlice.architecture).")
            }
            if originalSlice.hasExportsTrie != finalSlice.hasExportsTrie {
                report.errors.append("LC_DYLD_EXPORTS_TRIE changed for \(originalSlice.architecture).")
            }
            if originalSlice.cdHash == finalSlice.cdHash, !report.requestedLoadCommands.isEmpty {
                report.errors.append("CDHash was not regenerated for \(originalSlice.architecture).")
            }
        }

        for asset in report.injectedAssets {
            let sourceName = URL(fileURLWithPath: asset.path).lastPathComponent
            let copiedURL: URL
            if URL(fileURLWithPath: asset.path).pathExtension.lowercased() == "dylib" {
                copiedURL = frameworksDirectoryURL.appendingPathComponent(sourceName)
            } else {
                let frameworkURL = frameworksDirectoryURL.appendingPathComponent(URL(fileURLWithPath: asset.path).deletingLastPathComponent().lastPathComponent)
                copiedURL = try locateExecutableInBundle(frameworkURL)
            }
            let finalAsset = try inspectMachO(copiedURL)
            if !architecturesAreCompatible(final, finalAsset) {
                report.errors.append("Final injected asset architecture is incompatible: \(copiedURL.lastPathComponent).")
            }
            if !finalAsset.codeSignaturesValid {
                report.errors.append("Final injected asset signature is invalid: \(copiedURL.lastPathComponent).")
            }
        }

        let finalEntitlements = try? cmdExtractEntitlements(executableURL)
        report.finalEntitlementsMatch = entitlementsEqual(transaction.originalEntitlements, finalEntitlements)
        if transaction.originalEntitlements != nil, report.finalEntitlementsMatch != true {
            report.errors.append("Main executable entitlements changed during injection.")
        }
        if !report.errors.isEmpty {
            throw Error.generic(report.errors.joined(separator: "\n"))
        }
    }

    fileprivate func validateHeaderPadding(_ target: MachOMetadata, loadCommands: [String], errors: inout [String]) {
        let dylibBytes = loadCommands.reduce(0) { $0 + alignedLoadCommandSize(base: 24, string: $1) }
        let rpath = "@executable_path/Frameworks"
        for slice in target.slices {
            let needsRPath = !slice.runtimePaths.contains(rpath)
            let required = UInt64(dylibBytes + (needsRPath ? alignedLoadCommandSize(base: 12, string: rpath) : 0))
            if slice.headerPadding < required {
                errors.append("Insufficient load-command padding for \(slice.architecture): need \(required), have \(slice.headerPadding).")
            }
            if required > 0, !slice.headerPaddingIsZeroFilled {
                errors.append("Load-command padding contains mapped data for \(slice.architecture); insert_dylib --all-yes would overwrite it.")
            }
        }
    }

    fileprivate func alignedLoadCommandSize(base: Int, string: String) -> Int {
        let raw = base + string.lengthOfBytes(using: .utf8) + 1
        return (raw + 7) & ~7
    }

    fileprivate func validateLinkedit(_ metadata: MachOMetadata, prefix: String, errors: inout [String]) {
        for slice in metadata.slices {
            guard let linkeditOffset = slice.linkeditOffset,
                  let linkeditSize = slice.linkeditSize,
                  let signatureOffset = slice.codeSignatureOffset,
                  let signatureSize = slice.codeSignatureSize,
                  signatureOffset >= linkeditOffset,
                  signatureOffset <= linkeditOffset + linkeditSize,
                  signatureSize <= linkeditOffset + linkeditSize - signatureOffset
            else {
                errors.append("\(prefix) LC_CODE_SIGNATURE is outside __LINKEDIT for \(slice.architecture).")
                continue
            }
        }
    }

    fileprivate func validateMinimumOS(_ metadata: MachOMetadata, errors: inout [String]) {
        let current = ProcessInfo.processInfo.operatingSystemVersion
        for slice in metadata.slices {
            guard let minimumOS = slice.minimumOS else { continue }
            let parts = minimumOS.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 3 else { continue }
            let required = OperatingSystemVersion(majorVersion: parts[0], minorVersion: parts[1], patchVersion: parts[2])
            if !ProcessInfo.processInfo.isOperatingSystemAtLeast(required) {
                errors.append("\(URL(fileURLWithPath: metadata.path).lastPathComponent) requires iOS \(minimumOS), current is \(current.majorVersion).\(current.minorVersion).\(current.patchVersion).")
            }
        }
    }

    fileprivate func validateAssetDependencies(_ metadata: MachOMetadata, availableAssets: [URL], warnings: inout [String], errors: inout [String]) {
        let availableNames = Set(availableAssets.map(\.lastPathComponent))
        for slice in metadata.slices {
            for dependency in slice.dependencies {
                if dependency.hasPrefix("/System/") || dependency.hasPrefix("/usr/lib/") {
                    continue
                }
                if Self.ignoredDylibAndFrameworkNames.contains(where: { dependency.lowercased().hasSuffix("/" + $0) }) {
                    continue
                }
                let dependencyName = URL(fileURLWithPath: dependency).lastPathComponent
                let rpathRelative = dependency.replacingOccurrences(of: "@rpath/", with: "")
                let assetRootName = rpathRelative.split(separator: "/").first.map(String.init)
                let loaderResolved = dependency.replacingOccurrences(
                    of: "@loader_path/",
                    with: URL(fileURLWithPath: metadata.path).deletingLastPathComponent().path + "/"
                )
                if availableNames.contains(dependencyName) ||
                    assetRootName.map(availableNames.contains) == true ||
                    FileManager.default.fileExists(atPath: frameworksDirectoryURL.appendingPathComponent(rpathRelative).path) ||
                    (dependency.hasPrefix("@loader_path/") && FileManager.default.fileExists(atPath: loaderResolved))
                {
                    continue
                }
                if dependency.hasPrefix("@rpath/") || dependency.hasPrefix("@loader_path/") || dependency.hasPrefix("@executable_path/") {
                    errors.append("Unresolved dependency for \(URL(fileURLWithPath: metadata.path).lastPathComponent): \(dependency)")
                } else {
                    warnings.append("Non-system absolute dependency requires device verification: \(dependency)")
                }
            }
        }
    }

    fileprivate func entitlementsEqual(_ lhs: String?, _ rhs: String?) -> Bool {
        guard lhs != nil || rhs != nil else { return true }
        guard let lhs, let rhs,
              let lhsData = lhs.data(using: .utf8), let rhsData = rhs.data(using: .utf8),
              let lhsObject = try? PropertyListSerialization.propertyList(from: lhsData, options: [], format: nil) as? NSDictionary,
              let rhsObject = try? PropertyListSerialization.propertyList(from: rhsData, options: [], format: nil) as? NSDictionary
        else { return false }
        return lhsObject.isEqual(rhsObject)
    }

    fileprivate func writeInjectionReport(_ report: inout InjectionReport, backupURL: URL? = nil) throws {
        try FileManager.default.createDirectory(at: logsDirectoryURL, withIntermediateDirectories: true)
        let baseName = "injection-report-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)"
        let textURL = logsDirectoryURL.appendingPathComponent(baseName).appendingPathExtension("txt")
        let jsonURL = logsDirectoryURL.appendingPathComponent(baseName).appendingPathExtension("json")
        report.reportPath = textURL.path
        try report.text.write(to: textURL, atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(report)
        try json.write(to: jsonURL, options: .atomic)
        if let backupURL {
            try report.text.write(to: backupURL.appendingPathComponent("injection-report.txt"), atomically: true, encoding: .utf8)
            try json.write(to: backupURL.appendingPathComponent("injection-report.json"), options: .atomic)
            try cmdChangeOwnerToInstalld(backupURL, recursively: true)
        }
        lastReport = report
        latestReportURL = textURL
        DDLogInfo("\n\(report.text)", ddlog: logger)
    }

    // MARK: - Path Finder

    fileprivate func locateAvailableMachO() throws -> URL? {
        let allMachOs = try frameworkMachOsInBundle(bundleURL)

        DDLogInfo("Mach-O scan: \(allMachOs.count) candidates in \(bundleURL.lastPathComponent)", ddlog: logger)

        var selectedMachO: URL?
        var encryptedCount = 0
        var unreadableCount = 0
        for (index, machO) in allMachOs.enumerated() {
            let fileSize = (try? machO.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)

            do {
                let isProtected = try isProtectedMachO(machO)
                if isProtected {
                    encryptedCount += 1
                    DDLogInfo("  [\(index + 1)/\(allMachOs.count)] ENCRYPTED \(machO.lastPathComponent) (\(sizeStr))", ddlog: logger)
                } else {
                    DDLogInfo("  [\(index + 1)/\(allMachOs.count)] AVAILABLE \(machO.lastPathComponent) (\(sizeStr))", ddlog: logger)
                    if selectedMachO == nil {
                        selectedMachO = machO
                    }
                }
            } catch {
                unreadableCount += 1
                DDLogError("  [\(index + 1)/\(allMachOs.count)] UNREADABLE \(machO.lastPathComponent) (\(sizeStr)): \(error)", ddlog: logger)
            }
        }

        if let selected = selectedMachO {
            DDLogInfo("Selected Mach-O: \(selected.lastPathComponent)", ddlog: logger)
        } else {
            DDLogError(
                "No available Mach-O found: \(encryptedCount) encrypted, \(unreadableCount) unreadable, \(allMachOs.count - encryptedCount - unreadableCount) unavailable",
                ddlog: logger
            )
        }

        return selectedMachO
    }

    fileprivate static func findResource(_ name: String, fileExtension: String) -> URL {
        if let url = Bundle.main.url(forResource: name, withExtension: fileExtension) {
            return url
        }
        if let firstArg = ProcessInfo.processInfo.arguments.first {
            let execURL = URL(fileURLWithPath: firstArg)
                .deletingLastPathComponent()
                .appendingPathComponent(name)
                .appendingPathExtension(fileExtension)
            if FileManager.default.isReadableFile(atPath: execURL.path) {
                return execURL
            }
        }
        if let tfProxy = LSApplicationProxy(forIdentifier: Constants.gAppIdentifier),
           let tfBundleURL = tfProxy.bundleURL()
        {
            let execURL = tfBundleURL
                .appendingPathComponent(name)
                .appendingPathExtension(fileExtension)
            if FileManager.default.isReadableFile(atPath: execURL.path) {
                return execURL
            }
        }
        fatalError("Unable to locate resource \(name)")
    }
}
