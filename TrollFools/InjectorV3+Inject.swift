//
//  InjectorV3+Inject.swift
//  TrollFools
//
//  Created by 82Flex on 2025/1/10.
//

import CocoaLumberjackSwift
import Darwin
import Foundation

extension InjectorV3 {
    struct DeferredLoaderManifest: Codable {
        var version = 1
        var plugIns = [String]()

        enum CodingKeys: String, CodingKey {
            case version = "Version"
            case plugIns = "Plugins"
        }
    }

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

        var localizedDetail: String {
            switch self {
            case .lexicographic:
                NSLocalizedString("Sorts candidate Mach-Os by filename for predictable selection. This is the recommended default.", comment: "")
            case .fast:
                NSLocalizedString("Tries smaller Mach-Os first to reduce patching and signing time in apps with many frameworks.", comment: "")
            case .preorder:
                NSLocalizedString("Uses the original framework scan order and tries earlier candidates first.", comment: "")
            case .postorder:
                NSLocalizedString("Reverses the original framework scan order and tries later candidates first.", comment: "")
            }
        }
    }

    // MARK: - Instance Methods

    func inject(_ assetURLs: [URL], shouldPersist: Bool) throws {
        didUseMachOEnumerationFallback = false
        rootHideTrustDiagnostics.removeAll()
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
            destinationURLs.append(deferredLoaderDestinationURL)
            destinationURLs.append(deferredLoaderManifestURL)
        }
        if let targetMachO {
            destinationURLs.append(Self.alternateURL(for: targetMachO))
        }

        let transaction: InjectionTransaction
        do {
            transaction = try beginInjectionTransaction(
                targetMachO: targetMachO,
                destinationURLs: destinationURLs,
                metadata: report.targetMachO
            )
        } catch {
            report.status = .injectionFailed
            report.errors.append("Backup failed before injection: \(error.localizedDescription)")
            try? writeInjectionReport(&report)
            throw Error.generic(report.errors.joined(separator: "\n"))
        }
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
            appendUniqueReportErrors(error.localizedDescription, to: &report.errors)
            do {
                try rollbackInjectionTransaction(transaction)
                report.status = .rolledBack
            } catch {
                report.status = .injectionFailed
                appendUniqueReportErrors("Rollback failed: \(error.localizedDescription)", to: &report.errors)
            }
            try? writeInjectionReport(&report, backupURL: transaction.rootURL)
            throw Error.generic(report.errors.joined(separator: "\n"))
        }
    }

    func dryRun(_ assetURLs: [URL]) throws -> InjectionReport {
        didUseMachOEnumerationFallback = false
        rootHideTrustDiagnostics.removeAll()
        let preparedAssetURLs = try preprocessAssets(assetURLs)
        var report = try preflight(preparedAssetURLs)
        if report.isSafe {
            do {
                try validateDryRunSigning(preparedAssetURLs, report: &report)
            } catch {
                report.errors.append("Signing simulation failed: \(error.localizedDescription)")
            }
        }
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
            try ensureSystemDylibRuntimePath($0)
            try standardizeLoadCommandDylibToSubstrate($0)
            try applyCompatibleSignature($0)
        }

        let substrateFwkURL = try prepareSubstrate()
        let deferredSupportURLs = deferPlugInLoading
            ? try prepareDeferredLoaderSupport(for: assetURLs)
            : []
        let targetMachO = selectedTargetMachO
        if targetMachO.path.isEmpty {
            DDLogError("All Mach-Os are protected", ddlog: logger)

            throw Error.generic(NSLocalizedString("No eligible framework found.\n\nIt is usually not a bug with TrollFools itself, but rather with the target app. You may re-install that from App Store. You can’t use TrollFools with apps installed via “Asspp” or tweaks like “NoAppThinning”.", comment: ""))
        }

        DDLogInfo("Best matched Mach-O is \(targetMachO.path)", ddlog: logger)

        let resourceURLs: [URL] = [substrateFwkURL] + assetURLs + deferredSupportURLs
        try makeAlternate(targetMachO)
        do {
            try copyfiles(resourceURLs)
            if deferPlugInLoading {
                guard let loaderURL = deferredSupportURLs.first(where: { $0.lastPathComponent == Self.deferredLoaderFileName }) else {
                    throw Error.generic("Deferred loader staging did not produce \(Self.deferredLoaderFileName).")
                }
                for assetURL in assetURLs {
                    try removeLoadCommandIfPresent(for: assetURL, from: targetMachO)
                }
                try insertLoadCommandOfAsset(loaderURL, to: targetMachO)
            } else {
                try transitionAssetsToDirectLoading(assetURLs, targetMachO: targetMachO)
                for assetURL in assetURLs {
                    try insertLoadCommandOfAsset(assetURL, to: targetMachO)
                }
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

    var deferredLoaderDestinationURL: URL {
        frameworksDirectoryURL.appendingPathComponent(Self.deferredLoaderFileName)
    }

    var deferredLoaderManifestURL: URL {
        frameworksDirectoryURL.appendingPathComponent(Self.deferredLoaderManifestName)
    }

    func deferredLoadPath(of assetURL: URL) throws -> String {
        if checkIsBundle(assetURL) {
            let executable = try locateExecutableInBundle(assetURL)
            return "\(assetURL.lastPathComponent)/\(executable.lastPathComponent)"
        }
        let parentURL = assetURL.deletingLastPathComponent()
        if parentURL.pathExtension.lowercased() == "framework" {
            return "\(parentURL.lastPathComponent)/\(assetURL.lastPathComponent)"
        }
        return assetURL.lastPathComponent
    }

    func readDeferredLoaderManifest() throws -> DeferredLoaderManifest {
        guard FileManager.default.fileExists(atPath: deferredLoaderManifestURL.path) else {
            return DeferredLoaderManifest()
        }
        let data = try Data(contentsOf: deferredLoaderManifestURL)
        return try PropertyListDecoder().decode(DeferredLoaderManifest.self, from: data)
    }

    func installDeferredLoaderManifest(_ manifest: DeferredLoaderManifest) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let stagingURL = temporaryDirectoryURL
            .appendingPathComponent("\(UUID().uuidString)-\(Self.deferredLoaderManifestName)")
        try encoder.encode(manifest).write(to: stagingURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: stagingURL) }
        try cmdCopy(from: stagingURL, to: deferredLoaderManifestURL, clone: true, overwrite: true)
        try cmdChangeOwnerToInstalld(deferredLoaderManifestURL)
    }

    fileprivate func prepareDeferredLoaderSupport(for assetURLs: [URL]) throws -> [URL] {
        let sourceURL = try deferredLoaderResourceURL()
        let loaderURL = temporaryDirectoryURL.appendingPathComponent(Self.deferredLoaderFileName)
        if FileManager.default.fileExists(atPath: loaderURL.path) {
            try FileManager.default.removeItem(at: loaderURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: loaderURL)
        try applyCompatibleSignature(loaderURL)

        var manifest = try readDeferredLoaderManifest()
        manifest.version = 1
        let newPaths = try assetURLs.map { try deferredLoadPath(of: $0) }
        for path in newPaths where !manifest.plugIns.contains(path) {
            manifest.plugIns.append(path)
        }
        manifest.plugIns.sort { $0.localizedStandardCompare($1) == .orderedAscending }

        let manifestURL = temporaryDirectoryURL.appendingPathComponent(Self.deferredLoaderManifestName)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        return [loaderURL, manifestURL]
    }

    fileprivate func deferredLoaderResourceURL() throws -> URL {
        guard let url = Self.findResourceIfAvailable(Self.deferredLoaderName, fileExtension: "dylib") else {
            throw Error.generic("Missing bundled resource: \(Self.deferredLoaderFileName)")
        }
        return url
    }

    fileprivate func transitionAssetsToDirectLoading(_ assetURLs: [URL], targetMachO: URL) throws {
        var manifest = try readDeferredLoaderManifest()
        let paths = Set(try assetURLs.map { try deferredLoadPath(of: $0) })
        let originalCount = manifest.plugIns.count
        manifest.plugIns.removeAll(where: paths.contains)
        guard manifest.plugIns.count != originalCount else { return }

        if manifest.plugIns.isEmpty {
            try removeLoadCommandIfPresent(for: deferredLoaderDestinationURL, from: targetMachO)
            try? cmdRemove(deferredLoaderDestinationURL)
            try? cmdRemove(deferredLoaderManifestURL)
        } else {
            try installDeferredLoaderManifest(manifest)
        }
    }

    fileprivate func removeLoadCommandIfPresent(for assetURL: URL, from targetMachO: URL) throws {
        let name = try loadCommandNameOfAsset(assetURL)
        if try loadedDylibsOfMachO(targetMachO).contains(name) {
            try cmdRemoveLoadCommandDylib(targetMachO, name: name)
        }
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
        var deferredLoaderMetadata: MachOMetadata?
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
                validateSystemDylibRuntimePathInsertion(metadata, errors: &errors)
                validateMinimumOS(metadata, errors: &errors)
            } catch {
                errors.append("Cannot inspect \(assetURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if deferPlugInLoading, !injectableAssets.isEmpty {
            do {
                let loaderURL = try deferredLoaderResourceURL()
                let metadata = try inspectMachO(loaderURL)
                deferredLoaderMetadata = metadata
                requestedLoadCommands = [try loadCommandNameOfAsset(loaderURL)]
                validateAssetDependencies(metadata, availableAssets: assetURLs, warnings: &warnings, errors: &errors)
                validateSystemDylibRuntimePathInsertion(metadata, errors: &errors)
                validateMinimumOS(metadata, errors: &errors)
                let paths = try injectableAssets.map { try deferredLoadPath(of: $0) }
                warnings.append("Pre-main compatibility loading enabled for: \(paths.joined(separator: ", ")).")
            } catch {
                errors.append("Cannot prepare deferred loader: \(error.localizedDescription)")
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
            let compatibilityAssets = inspectedAssets + [deferredLoaderMetadata].compactMap { $0 }
            for asset in compatibilityAssets where !architecturesAreCompatible(targetMetadata, asset) {
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
            loadingMode: deferPlugInLoading ? "Pre-main deferred" : "Direct",
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
            report.warnings.append("TrollStore Lite rootless capability detected; ad-hoc signing candidates: \(ldidBinaryURLs.map(\.path).joined(separator: ", ")).")
        } else if signingBackend == .rootHideFastPath {
            let fastPathSign = Self.rootHideFastPathSignBinaryURL?.path ?? "unavailable"
            report.warnings.append("TrollStore Lite RootHide capability detected through libroothide; ldid candidates: \(ldidBinaryURLs.map(\.path).joined(separator: ", ")); fastPathSign: \(fastPathSign).")
        } else if signingBackend == .rootHideTrustCache {
            report.warnings.append("RootHide recursive trust capability detected; real injection will preserve entitlements, ad-hoc sign each modified Mach-O, trust removable-App files through the validated hidden staging root, copy the randomized signature back, and verify the final CDHash in the jailbreak trust cache. Dry Run does not upload temporary CDHashes.")
        } else {
            report.warnings.append(contentsOf: Self.signingCapabilityDiagnostics.map { "Signing capability: \($0)." })
        }
        return report
    }

    fileprivate func validateDryRunSigning(_ assetURLs: [URL], report: inout InjectionReport) throws {
        if signingBackend == .rootHideTrustCache {
            report.warnings.append("Dry Run validated the RootHide recursive trust API but intentionally skipped trust-cache mutation for temporary files.")
        }
        let simulationURL = temporaryDirectoryURL
            .appendingPathComponent("DryRunSigning-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: simulationURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: simulationURL) }

        let injectableAssets = assetURLs.filter {
            $0.pathExtension.lowercased() == "dylib" || $0.pathExtension.lowercased() == "framework"
        }
        for assetURL in injectableAssets {
            let copyURL = simulationURL.appendingPathComponent(assetURL.lastPathComponent)
            try FileManager.default.copyItem(at: assetURL, to: copyURL)
            try ensureSystemDylibRuntimePath(copyURL)
            try standardizeLoadCommandDylibToSubstrate(copyURL)
            let executable = checkIsBundle(copyURL) ? try locateExecutableInBundle(copyURL) : copyURL
            try applyDryRunSignature(executable)
            let metadata = try inspectMachO(executable)
            guard metadata.codeSignaturesValid else {
                throw Error.generic("Dry Run produced an invalid CodeDirectory for \(assetURL.lastPathComponent).")
            }
            try validateNormalizedSystemDylibRuntimePaths(metadata)
            report.warnings.append("Signing simulation passed for \(assetURL.lastPathComponent).")
        }

        var loadCommandAssets = injectableAssets
        if deferPlugInLoading, !injectableAssets.isEmpty {
            let sourceURL = try deferredLoaderResourceURL()
            let loaderCopyURL = simulationURL.appendingPathComponent(Self.deferredLoaderFileName)
            try FileManager.default.copyItem(at: sourceURL, to: loaderCopyURL)
            try applyDryRunSignature(loaderCopyURL)
            let loaderMetadata = try inspectMachO(loaderCopyURL)
            guard loaderMetadata.codeSignaturesValid else {
                throw Error.generic("Dry Run produced an invalid CodeDirectory for \(Self.deferredLoaderFileName).")
            }
            loadCommandAssets = [loaderCopyURL]
            report.warnings.append("Signing simulation passed for \(Self.deferredLoaderFileName).")
        }

        guard let targetMetadata = report.targetMachO else { return }
        let sourceTargetURL = URL(fileURLWithPath: targetMetadata.path)
        let targetCopyURL = simulationURL.appendingPathComponent("Target-\(sourceTargetURL.lastPathComponent)")
        try FileManager.default.copyItem(at: sourceTargetURL, to: targetCopyURL)
        if deferPlugInLoading {
            for assetURL in injectableAssets {
                try removeLoadCommandIfPresent(for: assetURL, from: targetCopyURL)
            }
        } else {
            var manifest = try readDeferredLoaderManifest()
            let directPaths = Set(try injectableAssets.map { try deferredLoadPath(of: $0) })
            let hadDeferredAsset = manifest.plugIns.contains(where: directPaths.contains)
            manifest.plugIns.removeAll(where: directPaths.contains)
            if hadDeferredAsset, manifest.plugIns.isEmpty {
                try removeLoadCommandIfPresent(for: deferredLoaderDestinationURL, from: targetCopyURL)
            }
        }
        for assetURL in loadCommandAssets {
            try insertLoadCommandOfAsset(assetURL, to: targetCopyURL)
        }
        try applyDryRunSignature(targetCopyURL)

        let finalTarget = try inspectMachO(targetCopyURL)
        guard finalTarget.isStructurallyValid, finalTarget.codeSignaturesValid else {
            throw Error.generic("Dry Run produced an invalid target Mach-O or CodeDirectory.")
        }
        let requiredRPath = "@executable_path/Frameworks"
        guard finalTarget.slices.allSatisfy({ $0.runtimePaths.contains(requiredRPath) }) else {
            throw Error.generic("Dry Run target is missing \(requiredRPath) in one or more slices.")
        }
        for command in report.requestedLoadCommands where !finalTarget.slices.allSatisfy({ $0.dependencies.contains(command) }) {
            throw Error.generic("Dry Run target is missing \(command).")
        }
        report.warnings.append("Target Mach-O load-command and signing simulation passed.")
    }

    fileprivate func applyDryRunSignature(_ target: URL) throws {
        if signingBackend == .rootHideFastPath {
            try cmdCompatibleSign(target, teamID: teamID)
        } else if signingBackend == .rootHideTrustCache {
            try cmdRootHideTrustCacheSign(target, uploadTrust: false)
        } else {
            try cmdPseudoSign(target, force: true)
        }
    }

    fileprivate func validateInjection(report: inout InjectionReport, transaction: InjectionTransaction) throws {
        guard let original = report.originalTargetMachO else {
            report.finalEntitlementsMatch = entitlementsEqual(
                transaction.originalEntitlements,
                try? cmdExtractEntitlements(executableURL)
            )
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
        let requiredRPath = "@executable_path/Frameworks"
        if !final.slices.allSatisfy({ $0.runtimePaths.contains(requiredRPath) }) {
            report.errors.append("Missing \(requiredRPath) in one or more final Mach-O slices.")
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
            if finalSlice.fileType != originalSlice.fileType {
                report.errors.append("Mach-O file type changed for \(originalSlice.architecture).")
            }
            if let originalUUID = originalSlice.uuid, finalSlice.uuid != originalUUID {
                report.errors.append("Mach-O UUID changed for \(originalSlice.architecture): expected \(originalUUID), got \(finalSlice.uuid ?? "none").")
            }
            let missingOriginalRPaths = originalSlice.runtimePaths.filter { !finalSlice.runtimePaths.contains($0) }
            if !missingOriginalRPaths.isEmpty {
                report.errors.append("Original runtime paths were removed for \(originalSlice.architecture): \(missingOriginalRPaths.joined(separator: ", ")).")
            }
            if originalSlice.hasChainedFixups != finalSlice.hasChainedFixups {
                report.errors.append("LC_DYLD_CHAINED_FIXUPS changed for \(originalSlice.architecture).")
            }
            if originalSlice.hasExportsTrie != finalSlice.hasExportsTrie {
                report.errors.append("LC_DYLD_EXPORTS_TRIE changed for \(originalSlice.architecture).")
            }
            let rpath = "@executable_path/Frameworks"
            let needsRPathInsertion = !originalSlice.runtimePaths.contains(rpath)
            let needsDylibCommandChange = report.requestedLoadCommands.contains { command in
                if !originalSlice.dependencies.contains(command) {
                    return true
                }
                let itemName = String(command.dropFirst("@rpath/".count))
                return originalSlice.dependencies.contains {
                    $0 != command && $0.hasSuffix("/" + itemName)
                }
            }
            if needsRPathInsertion || needsDylibCommandChange {
                guard let originalCDHash = originalSlice.cdHash, let finalCDHash = finalSlice.cdHash else {
                    report.errors.append("Unable to verify the regenerated CDHash for \(originalSlice.architecture).")
                    continue
                }
                if originalCDHash == finalCDHash {
                    report.errors.append("CDHash was not regenerated for \(originalSlice.architecture).")
                }
            } else {
                let warning = "Requested load commands were already present for \(originalSlice.architecture); idempotent re-signing was accepted."
                if !report.warnings.contains(warning) {
                    report.warnings.append(warning)
                }
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
            do {
                try validateNormalizedSystemDylibRuntimePaths(finalAsset)
            } catch {
                report.errors.append(error.localizedDescription)
            }
        }

        if deferPlugInLoading {
            let finalLoader = try inspectMachO(deferredLoaderDestinationURL)
            if !architecturesAreCompatible(final, finalLoader) {
                report.errors.append("Final deferred loader architecture is incompatible with the target Mach-O.")
            }
            if !finalLoader.codeSignaturesValid {
                report.errors.append("Final deferred loader signature is invalid.")
            }
            let manifest = try readDeferredLoaderManifest()
            for asset in report.injectedAssets {
                let path = try deferredLoadPath(of: URL(fileURLWithPath: asset.path))
                if !manifest.plugIns.contains(path) {
                    report.errors.append("Deferred loader manifest is missing \(path).")
                }
                let directCommand = "@rpath/\(path)"
                if final.slices.contains(where: { $0.dependencies.contains(directCommand) }) {
                    report.errors.append("Deferred asset still has an early load command: \(directCommand).")
                }
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
        let rpath = "@executable_path/Frameworks"
        for slice in target.slices {
            let dylibBytes = loadCommands
                .filter { !slice.dependencies.contains($0) }
                .reduce(0) { $0 + alignedLoadCommandSize(base: 24, string: $1) }
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
                if let systemPath = systemDylibPath(for: dependency) {
                    let warning = "System dyld-cache dependency will resolve through /usr/lib: \(dependency) -> \(systemPath)"
                    if !warnings.contains(warning) {
                        warnings.append(warning)
                    }
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

    fileprivate func validateSystemDylibRuntimePathInsertion(_ metadata: MachOMetadata, errors: inout [String]) {
        let containsSystemAliases = metadata.slices.contains { slice in
            slice.dependencies.contains(where: { systemDylibPath(for: $0) != nil })
        }
        guard containsSystemAliases else { return }

        let slicesWithRuntimePath = metadata.slices.filter {
            $0.runtimePaths.contains(Self.systemDylibRuntimePath)
        }
        if !slicesWithRuntimePath.isEmpty, slicesWithRuntimePath.count != metadata.slices.count {
            errors.append("System dylib runtime path is inconsistent across plug-in architectures: \(URL(fileURLWithPath: metadata.path).lastPathComponent).")
            return
        }
        guard slicesWithRuntimePath.isEmpty else { return }

        let required = UInt64(alignedLoadCommandSize(base: 12, string: Self.systemDylibRuntimePath))
        for slice in metadata.slices {
            if slice.headerPadding < required {
                errors.append("Insufficient plug-in load-command padding for \(slice.architecture): need \(required) to resolve system dylibs, have \(slice.headerPadding).")
            } else if !slice.headerPaddingIsZeroFilled {
                errors.append("Plug-in load-command padding contains mapped data for \(slice.architecture); cannot add the system dylib runtime path safely.")
            }
        }
    }

    fileprivate static let systemDylibRuntimePath = "/usr/lib"

    fileprivate func systemDylibPath(for dependency: String) -> String? {
        let prefix = "@rpath/"
        guard dependency.hasPrefix(prefix) else { return nil }

        let relativePath = String(dependency.dropFirst(prefix.count))
        guard !relativePath.isEmpty,
              !relativePath.contains("/"),
              relativePath.hasSuffix(".dylib")
        else { return nil }

        let candidate = "\(Self.systemDylibRuntimePath)/\(relativePath)"
        return candidate.withCString { dlopen_preflight($0) } ? candidate : nil
    }

    fileprivate func ensureSystemDylibRuntimePath(_ assetURL: URL) throws {
        let executable = checkIsBundle(assetURL) ? try locateExecutableInBundle(assetURL) : assetURL
        let metadata = try inspectMachO(executable)
        let slicesNeedingRuntimePath = metadata.slices.filter { slice in
            slice.dependencies.contains(where: { systemDylibPath(for: $0) != nil }) &&
                !slice.runtimePaths.contains(Self.systemDylibRuntimePath)
        }
        guard !slicesNeedingRuntimePath.isEmpty else { return }

        let slicesAlreadyContainingRuntimePath = metadata.slices.filter {
            $0.runtimePaths.contains(Self.systemDylibRuntimePath)
        }
        guard slicesAlreadyContainingRuntimePath.isEmpty else {
            throw Error.generic("System dylib runtime path is inconsistent across plug-in architectures: \(executable.lastPathComponent).")
        }

        try cmdInsertLoadCommandRuntimePath(executable, name: Self.systemDylibRuntimePath)
        try validateNormalizedSystemDylibRuntimePaths(try inspectMachO(executable))
        DDLogInfo("Added /usr/lib runtime path for system dyld-cache dependencies in \(executable.path)", ddlog: logger)
    }

    fileprivate func validateNormalizedSystemDylibRuntimePaths(_ metadata: MachOMetadata) throws {
        for slice in metadata.slices {
            let aliases = slice.dependencies.filter { systemDylibPath(for: $0) != nil }
            if !aliases.isEmpty, !slice.runtimePaths.contains(Self.systemDylibRuntimePath) {
                throw Error.generic("Missing /usr/lib runtime path for system dependencies in \(slice.architecture): \(aliases.joined(separator: ", ")).")
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

    fileprivate func appendUniqueReportErrors(_ description: String, to errors: inout [String]) {
        for component in description.components(separatedBy: .newlines) {
            let message = component.trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isEmpty, !errors.contains(message) {
                errors.append(message)
            }
        }
    }

    fileprivate func writeInjectionReport(_ report: inout InjectionReport, backupURL: URL? = nil) throws {
        for diagnostic in rootHideTrustDiagnostics where !report.warnings.contains(diagnostic) {
            report.warnings.append(diagnostic)
        }
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
            try writeBackupData(Data(report.text.utf8), name: "injection-report.txt", rootURL: backupURL)
            try writeBackupData(json, name: "injection-report.json", rootURL: backupURL)
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

    static func findResourceIfAvailable(_ name: String, fileExtension: String) -> URL? {
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
        return nil
    }

    fileprivate static func findResource(_ name: String, fileExtension: String) -> URL {
        guard let url = findResourceIfAvailable(name, fileExtension: fileExtension) else {
            fatalError("Unable to locate resource \(name)")
        }
        return url
    }
}
