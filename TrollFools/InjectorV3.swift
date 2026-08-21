//
//  InjectorV3.swift
//  TrollFools
//
//  Created by 82Flex on 2025/1/9.
//

import CocoaLumberjackSwift
import Darwin
import Foundation

final class InjectorV3 {
    enum LoggerType {
        case os
        case file
    }

    enum SigningBackend: String, Codable {
        case coreTrustBypass = "CoreTrust/ChOma"
        case rootlessAdHoc = "Rootless ad-hoc"
        case rootHideFastPath = "RootHide fast-path"
        case rootHideCustomTrust = "RootHide custom-trust"
    }

    static let rootlessLdidBinaryURL = URL(fileURLWithPath: "/var/jb/usr/bin/ldid")
    static let rootHideCustomTrustEntitlementKey = "jb.pmap_cs.custom_trust"
    static let rootHideCustomTrustEntitlementValue = "PMAP_CS_APP_STORE"

    static func rootHideMappedURL(forPath path: String) -> URL? {
        typealias JBRootFunction = @convention(c) (UnsafePointer<CChar>) -> UnsafePointer<CChar>?

        guard path.hasPrefix("/"),
              let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "jbroot")
        else {
            return nil
        }

        var symbolInfo = Dl_info()
        guard dladdr(symbol, &symbolInfo) != 0,
              let imageName = symbolInfo.dli_fname,
              String(cString: imageName).hasSuffix("/usr/lib/libroothide.dylib")
        else {
            return nil
        }

        let jbroot = unsafeBitCast(symbol, to: JBRootFunction.self)
        guard let mappedPath = path.withCString({ pathPointer -> String? in
            guard let mappedPath = jbroot(pathPointer) else { return nil }
            return String(cString: mappedPath)
        }), mappedPath.hasPrefix("/"), mappedPath != path, mappedPath.hasSuffix(path)
        else {
            return nil
        }

        return URL(fileURLWithPath: mappedPath).standardizedFileURL
    }

    static let rootHideLdidBinaryURL: URL? = {
        guard let candidate = rootHideMappedURL(forPath: "/usr/bin/ldid") else {
            return nil
        }
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            return nil
        }
        return candidate
    }()

    static let rootHideFastPathSignBinaryURL: URL? = {
        for path in ["/basebin/fastPathSign", "/usr/bin/fastPathSign"] {
            guard let candidate = rootHideMappedURL(forPath: path) else { continue }
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }()

    static let rootHideCustomTrustHelperURL: URL? = {
        guard let proxy = LSApplicationProxy(forIdentifier: "com.opa334.TrollStoreLite"),
              let bundleURL = proxy.bundleURL()
        else {
            return nil
        }

        let helperURL = bundleURL.appendingPathComponent("trollstorehelper")
        guard FileManager.default.isExecutableFile(atPath: helperURL.path),
              let helperData = try? Data(contentsOf: helperURL),
              helperData.range(of: Data(rootHideCustomTrustEntitlementKey.utf8)) != nil,
              helperData.range(of: Data(rootHideCustomTrustEntitlementValue.utf8)) != nil
        else {
            return nil
        }
        return helperURL
    }()

    static var signingCapabilityDiagnostics: [String] {
        let hasTrollStoreLite = LSApplicationProxy(forIdentifier: "com.opa334.TrollStoreLite") != nil
        return [
            "TrollStore Lite registration: \(hasTrollStoreLite ? "available" : "missing")",
            "rootless ldid: \(FileManager.default.isExecutableFile(atPath: rootlessLdidBinaryURL.path) ? "available" : "missing")",
            "validated RootHide ldid mapping: \(rootHideLdidBinaryURL == nil ? "missing" : "available")",
            "RootHide fastPathSign mapping: \(rootHideFastPathSignBinaryURL == nil ? "missing" : "available")",
            "TrollStore Lite custom-trust markers: \(rootHideCustomTrustHelperURL == nil ? "missing" : "available")",
        ]
    }

    static let temporaryRoot: URL = {
        let standardURL = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask).first!
        .appendingPathComponent(Constants.gAppIdentifier, isDirectory: true)
        .appendingPathComponent("InjectorV3", isDirectory: true)
        return rootHideMappedURL(forPath: standardURL.path) ?? standardURL
    }()

    static let main = try! InjectorV3(Bundle.main.bundleURL)

    let bundleURL: URL
    let temporaryDirectoryURL: URL
    let isPrivileged: Bool = geteuid() == 0

    var appID: String!
    var teamID: String!

    private(set) var executableURL: URL!
    private(set) var frameworksDirectoryURL: URL!
    private(set) var logsDirectoryURL: URL!

    var useWeakReference: Bool = false
    var preferMainExecutable: Bool = false
    var useFrameworkEnumerationFallback: Bool = true
    var deferPlugInLoading: Bool = false
    var injectStrategy: Strategy = .lexicographic
    var didUseMachOEnumerationFallback: Bool = false
    var lastReport: InjectionReport?
    var latestReportURL: URL?

    var signingBackend: SigningBackend {
        let hasTrollStoreLite = LSApplicationProxy(forIdentifier: "com.opa334.TrollStoreLite") != nil
        if hasTrollStoreLite,
           Self.rootHideLdidBinaryURL != nil,
           Self.rootHideFastPathSignBinaryURL != nil
        {
            return .rootHideFastPath
        }
        if hasTrollStoreLite,
           Self.rootHideLdidBinaryURL != nil,
           Self.rootHideCustomTrustHelperURL != nil
        {
            return .rootHideCustomTrust
        }
        if hasTrollStoreLite && FileManager.default.isExecutableFile(atPath: Self.rootlessLdidBinaryURL.path) {
            return .rootlessAdHoc
        }
        return .coreTrustBypass
    }

    let logger: DDLog
    let loggerType: LoggerType

    private init() { fatalError("Not implemented") }

    init(_ bundleURL: URL, loggerType: LoggerType = .file) throws {
        self.bundleURL = bundleURL
        temporaryDirectoryURL = Self.temporaryRoot
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: true)

        logger = DDLog()
        self.loggerType = loggerType

        let executableURL = try locateExecutableInBundle(bundleURL)
        let frameworksDirectoryURL = try locateFrameworksDirectoryInBundle(bundleURL)
        let appID = try identifierOfBundle(bundleURL)
        let teamID = try teamIdentifierOfMachO(executableURL) ?? ""

        self.appID = appID
        self.teamID = teamID
        self.executableURL = executableURL
        self.frameworksDirectoryURL = frameworksDirectoryURL
        logsDirectoryURL = temporaryDirectoryURL.appendingPathComponent("Logs/\(appID)")

        setupLoggers()
    }

    // MARK: - Instance Methods

    func terminateApp() {
        TFUtilKillAll(executableURL.lastPathComponent, true)
    }

    // MARK: - Logger

    private func setupLoggers() {
        if loggerType == .file {
            try? FileManager.default.createDirectory(at: logsDirectoryURL, withIntermediateDirectories: true)

            let fileLogger = DDFileLogger(logFileManager: DDLogFileManagerDefault(logsDirectory: logsDirectoryURL.path))

            fileLogger.rollingFrequency = 60 * 60 * 24
            fileLogger.logFileManager.maximumNumberOfLogFiles = 7
            fileLogger.doNotReuseLogFiles = true

            logger.add(fileLogger)
        }

        logger.add(DDOSLogger.sharedInstance)

        DDLogWarn("Logger setup \(appID!)", asynchronous: false, ddlog: logger)
    }

    var latestLogFileURL: URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: logsDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey]
        ) else {
            return nil
        }

        var latestLogFileURL: URL?
        var latestCreationDate: Date?
        while let fileURL = enumerator.nextObject() as? URL {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .creationDateKey]),
                  let isRegularFile = resourceValues.isRegularFile, isRegularFile,
                  let creationDate = resourceValues.creationDate
            else {
                continue
            }

            if latestCreationDate == nil || creationDate > latestCreationDate! {
                latestLogFileURL = fileURL
                latestCreationDate = creationDate
            }
        }

        return latestLogFileURL
    }

    // MARK: - Persistent

    static let persistentPlugInsRootURL: URL = {
        let standardURL = URL(fileURLWithPath: "/var/mobile/Library/TrollFools/PersistentPlugins")
        let url = rootHideMappedURL(forPath: standardURL.path) ?? standardURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    lazy var persistentPlugInsDirectoryURL: URL = {
        let url = Self.persistentPlugInsRootURL.appendingPathComponent(appID, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}
