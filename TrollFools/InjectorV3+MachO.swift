//
//  InjectorV3+MachO.swift
//  TrollFools
//
//  Created by 82Flex on 2025/1/10.
//

import Foundation
import CryptoKit
import MachOKit
import OrderedCollections

extension InjectorV3 {
    struct MachOSliceMetadata: Codable, Equatable {
        let magic: String
        let cpuType: Int32
        let cpuSubtype: Int32
        let architecture: String
        let fileType: UInt32
        let numberOfLoadCommands: UInt32
        let sizeOfLoadCommands: UInt32
        let headerPadding: UInt64
        let headerPaddingIsZeroFilled: Bool
        let uuid: String?
        let installName: String?
        let dependencies: [String]
        let runtimePaths: [String]
        let minimumOS: String?
        let platform: String?
        let codeSignatureOffset: UInt64?
        let codeSignatureSize: UInt64?
        let codeDirectoryVersion: String?
        let cdHash: String?
        let hasXMLAuthEntitlements: Bool
        let hasDEREntitlements: Bool
        let hasCMSSignature: Bool
        let codeSlotsValid: Bool?
        let hasChainedFixups: Bool
        let hasExportsTrie: Bool
        let hasDataInCode: Bool
        let hasFunctionStarts: Bool
        let linkeditOffset: UInt64?
        let linkeditSize: UInt64?
        let hasObjectiveCMetadata: Bool
        let hasSwiftMetadata: Bool
    }

    struct MachOMetadata: Codable, Equatable {
        let path: String
        let fileSize: UInt64
        let isFat: Bool
        let slices: [MachOSliceMetadata]

        var architectures: [String] {
            slices.map(\.architecture)
        }

        var isStructurallyValid: Bool {
            !slices.isEmpty && slices.allSatisfy { $0.numberOfLoadCommands > 0 }
        }

        var codeSignaturesValid: Bool {
            slices.allSatisfy { $0.codeSignatureOffset != nil && $0.codeSlotsValid == true }
        }
    }

    struct InjectionReport: Codable {
        enum Status: String, Codable {
            case safeToInject = "SAFE TO INJECT"
            case notSafeToInject = "NOT SAFE TO INJECT"
            case injectionSuccessful = "INJECTION SUCCESSFUL"
            case injectionFailed = "INJECTION FAILED"
            case rolledBack = "ROLLED BACK"
        }

        var generatedAt = Date()
        var status: Status
        var targetApp: String
        var bundleIdentifier: String
        var bundlePath: String
        var executablePath: String
        var systemVersion: String
        var signingBackend: String
        var mainExecutable: MachOMetadata?
        var targetMachO: MachOMetadata?
        var injectedAssets: [MachOMetadata]
        var requestedLoadCommands: [String]
        var originalTargetMachO: MachOMetadata?
        var finalTargetMachO: MachOMetadata?
        var originalEntitlementsPresent: Bool
        var finalEntitlementsMatch: Bool?
        var backupPath: String?
        var reportPath: String?
        var warnings: [String]
        var errors: [String]

        var isSafe: Bool { errors.isEmpty }

        var text: String {
            var lines = [
                status.rawValue,
                "TARGET APP: \(targetApp)",
                "Bundle ID: \(bundleIdentifier)",
                "Bundle Path: \(bundlePath)",
                "Executable Path: \(executablePath)",
                "iOS: \(systemVersion)",
                "Signing Backend: \(signingBackend)",
            ]
            if let targetMachO {
                lines.append("Target Mach-O: \(targetMachO.path)")
                lines.append("Target Architectures: \(targetMachO.architectures.joined(separator: ", "))")
                for slice in targetMachO.slices {
                    lines.append("  \(slice.architecture): magic=\(slice.magic) cpu=\(slice.cpuType)/\(slice.cpuSubtype) ncmds=\(slice.numberOfLoadCommands) sizeofcmds=\(slice.sizeOfLoadCommands) padding=\(slice.headerPadding)")
                lines.append("  signature=\(slice.codeSignatureOffset.map { String($0) } ?? "none")/\(slice.codeSignatureSize.map { String($0) } ?? "none") cdVersion=\(slice.codeDirectoryVersion ?? "none") cdHash=\(slice.cdHash ?? "none") slotsValid=\(slice.codeSlotsValid.map { String($0) } ?? "unknown")")
                lines.append("  chainedFixups=\(slice.hasChainedFixups) exportsTrie=\(slice.hasExportsTrie) __LINKEDIT=\(slice.linkeditOffset.map { String($0) } ?? "none")/\(slice.linkeditSize.map { String($0) } ?? "none")")
                }
            }
            for asset in injectedAssets {
                lines.append("Asset: \(asset.path) [\(asset.architectures.joined(separator: ", "))]")
                for slice in asset.slices {
                    lines.append("  installName=\(slice.installName ?? "none") minOS=\(slice.minimumOS ?? "unknown") platform=\(slice.platform ?? "unknown")")
                    if !slice.dependencies.isEmpty {
                        lines.append("  dependencies=\(slice.dependencies.joined(separator: ", "))")
                    }
                }
            }
            lines.append(contentsOf: requestedLoadCommands.map { "LC_LOAD_DYLIB added: \($0)" })
            lines.append(contentsOf: warnings.map { "WARNING: \($0)" })
            lines.append(contentsOf: errors.map { "ERROR: \($0)" })
            if let backupPath { lines.append("Backup: \(backupPath)") }
            if let reportPath { lines.append("Report: \(reportPath)") }
            return lines.joined(separator: "\n")
        }
    }
}

extension InjectorV3 {
    func inspectMachO(_ target: URL) throws -> MachOMetadata {
        try MachOInspector.inspect(target)
    }

    func architecturesAreCompatible(_ target: MachOMetadata, _ asset: MachOMetadata) -> Bool {
        target.slices.contains { targetSlice in
            asset.slices.contains { assetSlice in
                guard targetSlice.cpuType == assetSlice.cpuType else { return false }
                let targetSubtype = targetSlice.cpuSubtype & 0x00FF_FFFF
                let assetSubtype = assetSlice.cpuSubtype & 0x00FF_FFFF
                return targetSubtype == assetSubtype || targetSubtype == 0 || assetSubtype == 0
            }
        }
    }

    func isMachO(_ target: URL) -> Bool {
        if (try? MachOKit.loadFromFile(url: target)) != nil {
            true
        } else {
            false
        }
    }

    func isProtectedMachO(_ target: URL) throws -> Bool {
        let machOFile = try MachOKit.loadFromFile(url: target)
        switch machOFile {
        case let .machO(machOFile):
            for command in machOFile.loadCommands {
                switch command {
                case let .encryptionInfo(encryptionInfoCommand):
                    if encryptionInfoCommand.cryptid != 0 {
                        return true
                    }
                case let .encryptionInfo64(encryptionInfoCommand):
                    if encryptionInfoCommand.cryptid != 0 {
                        return true
                    }
                default:
                    continue
                }
            }
        case let .fat(fatFile):
            let machOFiles = try fatFile.machOFiles()
            for machOFile in machOFiles {
                for command in machOFile.loadCommands {
                    switch command {
                    case let .encryptionInfo(encryptionInfoCommand):
                        if encryptionInfoCommand.cryptid != 0 {
                            return true
                        }
                    case let .encryptionInfo64(encryptionInfoCommand):
                        if encryptionInfoCommand.cryptid != 0 {
                            return true
                        }
                    default:
                        continue
                    }
                }
            }
        }
        return false
    }

    func linkedDylibsRecursivelyOfMachO(_ target: URL, collected: OrderedSet<URL> = []) throws -> OrderedSet<URL> {
        if collected.contains(target) {
            return collected
        }

        var newCollected = collected
        newCollected.append(target)

        // If the Mach-O has a backup (made before injection), read load commands
        // from the original to avoid picking up previously-injected dylibs.
        let readTarget = hasAlternate(target) ? Self.alternateURL(for: target) : target
        let loadedDylibs = try loadedDylibsOfMachO(readTarget).compactMap({ resolveLoadCommand($0) })
        for dylib in loadedDylibs {
            newCollected = try linkedDylibsRecursivelyOfMachO(dylib, collected: newCollected)
        }

        return newCollected
    }

    func loadedDylibsOfMachO(_ target: URL) throws -> OrderedSet<String> {
        var dylibs = OrderedSet<String>()
        let machOFile = try MachOKit.loadFromFile(url: target)
        switch machOFile {
        case let .machO(machOFile):
            for command in machOFile.loadCommands {
                switch command {
                case let .loadDylib(loadDylibCommand):
                    dylibs.append(loadDylibCommand.dylib(in: machOFile).name)
                case let .loadWeakDylib(loadWeakDylibCommand):
                    dylibs.append(loadWeakDylibCommand.dylib(in: machOFile).name)
                default:
                    continue
                }
            }
        case let .fat(fatFile):
            let machOFiles = try fatFile.machOFiles()
            for machOFile in machOFiles {
                for command in machOFile.loadCommands {
                    switch command {
                    case let .loadDylib(loadDylibCommand):
                        dylibs.append(loadDylibCommand.dylib(in: machOFile).name)
                    case let .loadWeakDylib(loadWeakDylibCommand):
                        dylibs.append(loadWeakDylibCommand.dylib(in: machOFile).name)
                    default:
                        continue
                    }
                }
            }
        }
        return dylibs
    }

    func runtimePathsOfMachO(_ target: URL) throws -> OrderedSet<String> {
        var paths = OrderedSet<String>()
        let machOFile = try MachOKit.loadFromFile(url: target)
        switch machOFile {
        case let .machO(machOFile):
            for command in machOFile.loadCommands {
                switch command {
                case let .rpath(rpathCommand):
                    paths.append(rpathCommand.path(in: machOFile))
                default:
                    continue
                }
            }
        case let .fat(fatFile):
            let machOFiles = try fatFile.machOFiles()
            for machOFile in machOFiles {
                for command in machOFile.loadCommands {
                    switch command {
                    case let .rpath(rpathCommand):
                        paths.append(rpathCommand.path(in: machOFile))
                    default:
                        continue
                    }
                }
            }
        }
        return paths
    }

    func teamIdentifierOfMachO(_ target: URL) throws -> String? {
        let machOFile = try MachOKit.loadFromFile(url: target)
        switch machOFile {
        case let .machO(machOFile):
            if let codeSign = machOFile.codeSign, let teamID = codeSign.codeDirectory?.teamId(in: codeSign) {
                return teamID
            }
        case let .fat(fatFile):
            let machOFiles = try fatFile.machOFiles()
            for machOFile in machOFiles {
                if let codeSign = machOFile.codeSign, let teamID = codeSign.codeDirectory?.teamId(in: codeSign) {
                    return teamID
                }
            }
        }
        return nil
    }

    fileprivate func resolveLoadCommand(_ name: String) -> URL? {
        guard (name.hasPrefix("@rpath/") && !name.hasPrefix("@rpath/libswift")) || name.hasPrefix("@executable_path/") else {
            return nil
        }

        var resolvedName = name
        resolvedName = resolvedName
            .replacingOccurrences(of: "@executable_path/", with: executableURL.deletingLastPathComponent().path + "/")
        resolvedName = resolvedName
            .replacingOccurrences(of: "@rpath/", with: frameworksDirectoryURL.path + "/")

        let resolvedURL = URL(fileURLWithPath: resolvedName)
        guard FileManager.default.fileExists(atPath: resolvedURL.path) else {
            return nil
        }

        return resolvedURL
    }
}

private enum MachOInspector {
    private static let mhMagic = UInt32(0xFEED_FACE)
    private static let mhMagic64 = UInt32(0xFEED_FACF)
    private static let fatMagic = UInt32(0xCAFE_BABE)
    private static let fatMagic64 = UInt32(0xCAFE_BABF)

    private static let lcSegment = UInt32(0x1)
    private static let lcSegment64 = UInt32(0x19)
    private static let lcLoadDylib = UInt32(0xC)
    private static let lcIDDylib = UInt32(0xD)
    private static let lcLoadWeakDylib = UInt32(0x8000_0018)
    private static let lcUUID = UInt32(0x1B)
    private static let lcRPath = UInt32(0x8000_001C)
    private static let lcCodeSignature = UInt32(0x1D)
    private static let lcVersionMinIPhoneOS = UInt32(0x25)
    private static let lcFunctionStarts = UInt32(0x26)
    private static let lcDataInCode = UInt32(0x29)
    private static let lcBuildVersion = UInt32(0x32)
    private static let lcExportsTrie = UInt32(0x8000_0033)
    private static let lcChainedFixups = UInt32(0x8000_0034)

    static func inspect(_ url: URL) throws -> InjectorV3.MachOMetadata {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count >= 4 else { throw InspectorError.invalid("file is too small") }

        let bigMagic = try data.u32be(0)
        var slices = [InjectorV3.MachOSliceMetadata]()
        var isFat = false
        if bigMagic == fatMagic || bigMagic == fatMagic64 {
            isFat = true
            let count = Int(try data.u32be(4))
            let archSize = bigMagic == fatMagic64 ? 32 : 20
            guard count > 0, count <= 64, 8 + count * archSize <= data.count else {
                throw InspectorError.invalid("invalid fat header")
            }
            for index in 0 ..< count {
                let archOffset = 8 + index * archSize
                let sliceOffset: UInt64
                let sliceSize: UInt64
                if bigMagic == fatMagic64 {
                    sliceOffset = try data.u64be(archOffset + 8)
                    sliceSize = try data.u64be(archOffset + 16)
                } else {
                    sliceOffset = UInt64(try data.u32be(archOffset + 8))
                    sliceSize = UInt64(try data.u32be(archOffset + 12))
                }
                slices.append(try parseSlice(data, base: sliceOffset, size: sliceSize))
            }
        } else {
            slices.append(try parseSlice(data, base: 0, size: UInt64(data.count)))
        }

        return InjectorV3.MachOMetadata(
            path: url.path,
            fileSize: UInt64(data.count),
            isFat: isFat,
            slices: slices
        )
    }

    private static func parseSlice(_ data: Data, base: UInt64, size: UInt64) throws -> InjectorV3.MachOSliceMetadata {
        guard base <= UInt64(data.count), size <= UInt64(data.count) - base else {
            throw InspectorError.invalid("fat slice exceeds file bounds")
        }
        let start = Int(base)
        let magic = try data.u32le(start)
        guard magic == mhMagic || magic == mhMagic64 else {
            throw InspectorError.invalid(String(format: "unsupported Mach-O magic 0x%08X", magic))
        }
        let is64 = magic == mhMagic64
        let headerSize = is64 ? 32 : 28
        let cpuType = Int32(bitPattern: try data.u32le(start + 4))
        let cpuSubtype = Int32(bitPattern: try data.u32le(start + 8))
        let fileType = try data.u32le(start + 12)
        let numberOfCommands = try data.u32le(start + 16)
        let sizeOfCommands = try data.u32le(start + 20)
        let commandsStart = start + headerSize
        let commandsEnd = commandsStart + Int(sizeOfCommands)
        guard numberOfCommands <= 4096, commandsEnd <= start + Int(size) else {
            throw InspectorError.invalid("load commands exceed slice bounds")
        }

        var cursor = commandsStart
        var uuid: String?
        var installName: String?
        var dependencies = [String]()
        var runtimePaths = [String]()
        var minimumOS: String?
        var platform: String?
        var signatureOffset: UInt64?
        var signatureSize: UInt64?
        var hasChainedFixups = false
        var hasExportsTrie = false
        var hasDataInCode = false
        var hasFunctionStarts = false
        var linkeditOffset: UInt64?
        var linkeditSize: UInt64?
        var firstSectionOffset: UInt64?
        var hasObjectiveCMetadata = false
        var hasSwiftMetadata = false

        for _ in 0 ..< Int(numberOfCommands) {
            guard cursor + 8 <= commandsEnd else { throw InspectorError.invalid("truncated load command") }
            let command = try data.u32le(cursor)
            let commandSize = Int(try data.u32le(cursor + 4))
            guard commandSize >= 8, cursor + commandSize <= commandsEnd else {
                throw InspectorError.invalid("invalid load command size")
            }

            switch command {
            case lcLoadDylib, lcLoadWeakDylib, lcIDDylib:
                let stringOffset = Int(try data.u32le(cursor + 8))
                if let value = data.cString(cursor + stringOffset, limit: cursor + commandSize) {
                    if command == lcIDDylib { installName = value } else { dependencies.append(value) }
                }
            case lcRPath:
                let stringOffset = Int(try data.u32le(cursor + 8))
                if let value = data.cString(cursor + stringOffset, limit: cursor + commandSize) {
                    runtimePaths.append(value)
                }
            case lcUUID:
                if cursor + 24 <= commandsEnd {
                    let bytes = [UInt8](data[(cursor + 8) ..< (cursor + 24)])
                    uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString
                }
            case lcBuildVersion:
                platform = platformName(try data.u32le(cursor + 8))
                minimumOS = packedVersion(try data.u32le(cursor + 12))
            case lcVersionMinIPhoneOS:
                platform = "iOS"
                minimumOS = packedVersion(try data.u32le(cursor + 8))
            case lcCodeSignature:
                signatureOffset = UInt64(try data.u32le(cursor + 8))
                signatureSize = UInt64(try data.u32le(cursor + 12))
            case lcChainedFixups:
                hasChainedFixups = true
            case lcExportsTrie:
                hasExportsTrie = true
            case lcDataInCode:
                hasDataInCode = true
            case lcFunctionStarts:
                hasFunctionStarts = true
            case lcSegment64 where is64:
                let segmentName = data.fixedString(cursor + 8, count: 16)
                let fileOffset = try data.u64le(cursor + 40)
                let fileSize = try data.u64le(cursor + 48)
                if segmentName == "__LINKEDIT" {
                    linkeditOffset = fileOffset
                    linkeditSize = fileSize
                }
                let sectionCount = Int(try data.u32le(cursor + 64))
                let sectionStart = cursor + 72
                guard sectionCount <= 4096, sectionStart + sectionCount * 80 <= cursor + commandSize else {
                    throw InspectorError.invalid("invalid section table")
                }
                for sectionIndex in 0 ..< sectionCount {
                    let sectionOffset = sectionStart + sectionIndex * 80
                    let sectionName = data.fixedString(sectionOffset, count: 16)
                    let sectionFileOffset = UInt64(try data.u32le(sectionOffset + 48))
                    if sectionFileOffset > 0 {
                        firstSectionOffset = min(firstSectionOffset ?? sectionFileOffset, sectionFileOffset)
                    }
                    hasObjectiveCMetadata = hasObjectiveCMetadata || sectionName.hasPrefix("__objc_")
                    hasSwiftMetadata = hasSwiftMetadata || sectionName.hasPrefix("__swift5_")
                }
            case lcSegment where !is64:
                let segmentName = data.fixedString(cursor + 8, count: 16)
                let fileOffset = UInt64(try data.u32le(cursor + 32))
                let fileSize = UInt64(try data.u32le(cursor + 36))
                if segmentName == "__LINKEDIT" {
                    linkeditOffset = fileOffset
                    linkeditSize = fileSize
                }
            default:
                break
            }
            cursor += commandSize
        }

        let headerEnd = UInt64(headerSize) + UInt64(sizeOfCommands)
        let padding = firstSectionOffset.map { $0 >= headerEnd ? $0 - headerEnd : 0 } ?? 0
        let paddingStart = start + Int(headerEnd)
        let paddingEnd = paddingStart + Int(padding)
        let paddingIsZeroFilled = paddingEnd <= data.count && data[paddingStart ..< paddingEnd].allSatisfy { $0 == 0 }
        let signature = try signatureDetails(data, sliceBase: base, sliceSize: size, offset: signatureOffset, size: signatureSize)

        return InjectorV3.MachOSliceMetadata(
            magic: String(format: "0x%08X", magic),
            cpuType: cpuType,
            cpuSubtype: cpuSubtype,
            architecture: architectureName(cpuType: cpuType, cpuSubtype: cpuSubtype),
            fileType: fileType,
            numberOfLoadCommands: numberOfCommands,
            sizeOfLoadCommands: sizeOfCommands,
            headerPadding: padding,
            headerPaddingIsZeroFilled: paddingIsZeroFilled,
            uuid: uuid,
            installName: installName,
            dependencies: dependencies,
            runtimePaths: runtimePaths,
            minimumOS: minimumOS,
            platform: platform,
            codeSignatureOffset: signatureOffset,
            codeSignatureSize: signatureSize,
            codeDirectoryVersion: signature.codeDirectoryVersion,
            cdHash: signature.cdHash,
            hasXMLAuthEntitlements: signature.hasXMLAuthEntitlements,
            hasDEREntitlements: signature.hasDEREntitlements,
            hasCMSSignature: signature.hasCMSSignature,
            codeSlotsValid: signature.codeSlotsValid,
            hasChainedFixups: hasChainedFixups,
            hasExportsTrie: hasExportsTrie,
            hasDataInCode: hasDataInCode,
            hasFunctionStarts: hasFunctionStarts,
            linkeditOffset: linkeditOffset,
            linkeditSize: linkeditSize,
            hasObjectiveCMetadata: hasObjectiveCMetadata,
            hasSwiftMetadata: hasSwiftMetadata
        )
    }

    private struct SignatureDetails {
        var codeDirectoryVersion: String?
        var cdHash: String?
        var hasXMLAuthEntitlements = false
        var hasDEREntitlements = false
        var hasCMSSignature = false
        var codeSlotsValid: Bool?
    }

    private static func signatureDetails(_ data: Data, sliceBase: UInt64, sliceSize: UInt64, offset: UInt64?, size: UInt64?) throws -> SignatureDetails {
        guard let offset, let size, size >= 12, offset <= sliceSize, size <= sliceSize - offset else {
            return SignatureDetails()
        }
        let signatureStart = Int(sliceBase + offset)
        let signatureEnd = signatureStart + Int(size)
        guard signatureEnd <= data.count, try data.u32be(signatureStart) == 0xFADE_0CC0 else {
            return SignatureDetails(codeSlotsValid: false)
        }
        let blobLength = Int(try data.u32be(signatureStart + 4))
        let blobCount = Int(try data.u32be(signatureStart + 8))
        guard blobLength >= 12, signatureStart + blobLength <= signatureEnd, blobCount <= 128, 12 + blobCount * 8 <= blobLength else {
            return SignatureDetails(codeSlotsValid: false)
        }

        var details = SignatureDetails()
        var bestCodeDirectory: (start: Int, length: Int)?
        for index in 0 ..< blobCount {
            let entry = signatureStart + 12 + index * 8
            let type = try data.u32be(entry)
            let relativeOffset = Int(try data.u32be(entry + 4))
            let blobStart = signatureStart + relativeOffset
            guard blobStart + 8 <= signatureStart + blobLength else {
                details.codeSlotsValid = false
                continue
            }
            let magic = try data.u32be(blobStart)
            let length = Int(try data.u32be(blobStart + 4))
            guard length >= 8, blobStart + length <= signatureStart + blobLength else {
                details.codeSlotsValid = false
                continue
            }
            if magic == 0xFADE_0C02 {
                bestCodeDirectory = (blobStart, length)
            }
            details.hasXMLAuthEntitlements = details.hasXMLAuthEntitlements || type == 5 || magic == 0xFADE_7171
            details.hasDEREntitlements = details.hasDEREntitlements || type == 7 || magic == 0xFADE_7172
            details.hasCMSSignature = details.hasCMSSignature || type == 0x10000 || magic == 0xFADE_0B01
        }

        guard let codeDirectory = bestCodeDirectory, codeDirectory.length >= 44 else {
            details.codeSlotsValid = false
            return details
        }
        let cdStart = codeDirectory.start
        let cdData = Data(data[cdStart ..< cdStart + codeDirectory.length])
        let version = try data.u32be(cdStart + 8)
        let hashOffset = Int(try data.u32be(cdStart + 16))
        let codeSlotCount = Int(try data.u32be(cdStart + 28))
        let codeLimit = UInt64(try data.u32be(cdStart + 32))
        let hashSize = Int(data[cdStart + 36])
        let hashType = data[cdStart + 37]
        let pageShift = data[cdStart + 39]
        let pageSize = pageShift == 0 ? UInt64(0) : UInt64(1) << UInt64(pageShift)
        details.codeDirectoryVersion = String(format: "0x%X", version)
        details.cdHash = hash(cdData, type: hashType).map {
            $0.prefix(20).map { String(format: "%02x", $0) }.joined()
        }

        guard pageSize > 0, codeLimit <= sliceSize, hashSize > 0,
              hashOffset >= 0, hashOffset + codeSlotCount * hashSize <= codeDirectory.length
        else {
            details.codeSlotsValid = false
            return details
        }
        let expectedSlotCount = Int((codeLimit + pageSize - 1) / pageSize)
        guard expectedSlotCount == codeSlotCount else {
            details.codeSlotsValid = false
            return details
        }

        var slotsValid = true
        for slot in 0 ..< codeSlotCount {
            let relativeStart = UInt64(slot) * pageSize
            let relativeEnd = min(relativeStart + pageSize, codeLimit)
            let absoluteStart = Int(sliceBase + relativeStart)
            let absoluteEnd = Int(sliceBase + relativeEnd)
            guard absoluteStart <= absoluteEnd, absoluteEnd <= data.count,
                  let calculated = hash(Data(data[absoluteStart ..< absoluteEnd]), type: hashType)
            else {
                slotsValid = false
                break
            }
            let storedStart = cdStart + hashOffset + slot * hashSize
            let stored = Data(data[storedStart ..< storedStart + hashSize])
            if Data(calculated.prefix(hashSize)) != stored {
                slotsValid = false
                break
            }
        }
        details.codeSlotsValid = slotsValid
        return details
    }

    private static func hash(_ data: Data, type: UInt8) -> Data? {
        switch type {
        case 1:
            return Data(Insecure.SHA1.hash(data: data))
        case 2, 3:
            return Data(SHA256.hash(data: data))
        default:
            return nil
        }
    }

    private static func architectureName(cpuType: Int32, cpuSubtype: Int32) -> String {
        let subtype = cpuSubtype & 0x00FF_FFFF
        if UInt32(bitPattern: cpuType) == 0x0100_000C {
            switch subtype {
            case 0: return "arm64"
            case 1: return "arm64v8"
            case 2: return "arm64e"
            default: return "arm64-subtype-\(subtype)"
            }
        }
        return String(format: "cpu-%08X-%08X", UInt32(bitPattern: cpuType), UInt32(bitPattern: cpuSubtype))
    }

    private static func packedVersion(_ value: UInt32) -> String {
        "\((value >> 16) & 0xFFFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
    }

    private static func platformName(_ value: UInt32) -> String {
        switch value {
        case 1: return "macOS"
        case 2: return "iOS"
        case 6: return "iOS Simulator"
        case 7: return "Mac Catalyst"
        default: return "platform-\(value)"
        }
    }

    fileprivate enum InspectorError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case let .invalid(reason): "Invalid Mach-O: \(reason)" }
        }
    }
}

private extension Data {
    func u32le(_ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { throw MachOInspector.InspectorError.invalid("read exceeds bounds") }
        return UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 | UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
    }

    func u32be(_ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { throw MachOInspector.InspectorError.invalid("read exceeds bounds") }
        return UInt32(self[offset]) << 24 | UInt32(self[offset + 1]) << 16 | UInt32(self[offset + 2]) << 8 | UInt32(self[offset + 3])
    }

    func u64le(_ offset: Int) throws -> UInt64 {
        UInt64(try u32le(offset)) | UInt64(try u32le(offset + 4)) << 32
    }

    func u64be(_ offset: Int) throws -> UInt64 {
        UInt64(try u32be(offset)) << 32 | UInt64(try u32be(offset + 4))
    }

    func cString(_ offset: Int, limit: Int) -> String? {
        guard offset >= 0, offset < limit, limit <= count else { return nil }
        var end = offset
        while end < limit, self[end] != 0 { end += 1 }
        guard end < limit else { return nil }
        return String(data: self[offset ..< end], encoding: .utf8)
    }

    func fixedString(_ offset: Int, count: Int) -> String {
        guard offset >= 0, offset + count <= self.count else { return "" }
        let end = (offset ..< offset + count).first(where: { self[$0] == 0 }) ?? offset + count
        return String(data: self[offset ..< end], encoding: .utf8) ?? ""
    }
}
