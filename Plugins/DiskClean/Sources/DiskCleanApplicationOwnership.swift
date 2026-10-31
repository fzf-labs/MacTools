import AppKit
import Darwin
import Foundation
import MacToolsPluginKit
import Security

enum DiskCleanApplicationFileCategory: String, CaseIterable, Sendable, Identifiable {
    case application, support, caches, preferences, sandbox, services
    var id: String { rawValue }
    var title: String {
        switch self {
        case .application: "程序文件"
        case .support: "支持文件"
        case .caches: "缓存文件"
        case .preferences: "设置文件"
        case .sandbox: "沙盒文件"
        case .services: "后台组件"
        }
    }
    var symbol: String {
        switch self {
        case .application: "macwindow"
        case .support: "folder"
        case .caches: "internaldrive"
        case .preferences: "slider.horizontal.3"
        case .sandbox: "shippingbox"
        case .services: "gearshape.2"
        }
    }
    func title(_ localization: PluginLocalization) -> String {
        localization.string("uninstall.category." + rawValue, defaultValue: title)
    }
}

enum DiskCleanApplicationCoverage: Int, Sendable {
    case checked, incomplete, permissionRequired
}

enum DiskCleanApplicationOwnershipCheck: Sendable {
    case confirmed, sharedRuntime, conflictingOwner, incomplete

    var rejection: String? {
        switch self {
        case .confirmed: nil
        case .sharedRuntime: "共享运行组件仅供查看"
        case .conflictingOwner: "另一个应用使用相同组件"
        case .incomplete: "文件归属检查未完成"
        }
    }
}

struct DiskCleanApplicationProof: Equatable, Sendable {
    let path: String
    var containerOwner: String? = nil
    var ownerID: String? = nil
    var product: DiskCleanApplicationProductProof? = nil
    var mainBundleID: String? = nil
    var privateComponentID: String? = nil
    var crashRecord: DiskCleanApplicationCrashRecord? = nil
    var allowsPersonalSessionRemoval = false
    var logicalPaths: [String] = []
    var nameCandidate: DiskCleanApplicationNameCandidate? = nil
    var service: DiskCleanApplicationServiceProof? = nil

    func requiresCompleteClaims(for bundleID: String) -> Bool {
        guard mainBundleID == bundleID, let ownerID else { return true }
        return ownerID != bundleID && !(privateComponentID == ownerID && ownerID.lowercased().hasPrefix(bundleID.lowercased() + "."))
    }

    func ownershipCheck(for bundleID: String, otherOwners: Set<String>, claimsComplete: Bool) -> DiskCleanApplicationOwnershipCheck {
        guard let ownerID else { return .incomplete }
        if DiskCleanApplicationIdentity.isSharedRuntime(ownerID) { return .sharedRuntime }
        if let label = service?.label {
            if DiskCleanApplicationIdentity.isSharedRuntime(label) { return .sharedRuntime }
            if DiskCleanApplicationIdentity.hasPotentialOwner(label, in: otherOwners) { return .conflictingOwner }
        }
        if DiskCleanApplicationIdentity.hasPotentialOwner(ownerID, in: otherOwners) { return .conflictingOwner }
        if !claimsComplete && requiresCompleteClaims(for: bundleID) { return .incomplete }
        return .confirmed
    }

    func rejection(at currentPath: String) -> String? {
        guard DiskCleanPhysicalPath.resolve(currentPath) == DiskCleanPhysicalPath.resolve(path) else { return "文件归属已变化" }
        if let nameCandidate, !nameCandidate.permits(currentPath) { return "关联文件位置已变化" }
        if let crashRecord, !crashRecord.permits(currentPath) { return "退出记录已变化或无法确认" }
        if let product, !product.permits(currentPath) { return "应用目录规则已变化或需要手动核对" }
        if let ownerID, DiskCleanApplicationIdentity.isSharedRuntime(ownerID) { return "共享运行组件仅供查看" }
        if let containerOwner, DiskCleanApplicationOwnership.containerOwner(at: currentPath) != containerOwner {
            return "沙盒容器归属已变化"
        }
        if let service, let reason = service.rejection() { return reason }
        return nil
    }
}

struct DiskCleanApplicationAssociation: Sendable {
    let path: String
    let bundleID: String
    let isPersonal: Bool
    let evidence: String
    var manualReason: String? = nil
    var category: DiskCleanApplicationFileCategory = .support
    var proof: DiskCleanApplicationProof? = nil
    var logicalPaths: [String] = []
}

struct DiskCleanApplicationOwnershipResult: Sendable {
    var associations: [DiskCleanApplicationAssociation] = []
    var coverage: [DiskCleanApplicationFileCategory: DiskCleanApplicationCoverage] = [:]
    var report = DiskCleanApplicationScanReport()
}

struct DiskCleanApplicationIdentity: Sendable {
    var ids: Set<String>
    var groups: Set<String> = []
    var componentPaths: [String] = []
    var names: Set<String> = []
    var isComplete = true
    var mainBundleID: String? = nil
    var verifiedPrivateIDs: Set<String> = []
    var executables: Set<String> = []
    var applications: [DiskCleanInstalledApplication] = []

    static func read(bundleID: String, copies: [DiskCleanInstalledApplication]) -> Self {
        var result = Self(ids: [bundleID])
        result.applications = copies
        if !copies.isEmpty, copies.allSatisfy({ $0.bundleID == bundleID && Bundle(path: $0.path)?.bundleIdentifier == bundleID }) {
            result.mainBundleID = bundleID
        }
        for app in copies {
            result.names.insert(URL(fileURLWithPath: app.path).deletingPathExtension().lastPathComponent)
            let bundle = Bundle(path: app.path)
            for key in ["CFBundleName", "CFBundleExecutable", "CFBundleDisplayName"] {
                if let name = bundle?.object(forInfoDictionaryKey: key) as? String { result.names.insert(name) }
            }
            if bundle?.bundleIdentifier == bundleID,
               let executable = bundle?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String {
                result.executables.insert(executable)
            }
            let main = signingInfo(app.path)
            result.groups.formUnion(main?.groups ?? [])
            var remaining = 2000
            let deadline = Date().addingTimeInterval(5)
            func visit(_ path: String, depth: Int) {
                guard depth < 6, remaining > 0, Date() < deadline, !Task.isCancelled else { result.isComplete = false; return }
                var status = stat()
                guard lstat(path, &status) == 0 else { if errno != ENOENT { result.isComplete = false }; return }
                guard let entries = try? DiskCleanDirectoryListing.read(path) else { result.isComplete = false; return }
                for entry in entries where entry.isDirectory && !["Resources", "Headers", "Modules", "_CodeSignature"].contains(URL(fileURLWithPath: entry.path).lastPathComponent) && !entry.path.hasSuffix(".lproj") {
                    remaining -= 1
                    if ["app", "appex", "xpc"].contains(URL(fileURLWithPath: entry.path).pathExtension.lowercased()) {
                        if let info = signingInfo(entry.path), let team = main?.team, info.team == team,
                           DiskCleanApplicationInventory.validBundleID(info.id) {
                            result.ids.insert(info.id)
                            if info.id.lowercased().hasPrefix(bundleID.lowercased() + ".") {
                                result.verifiedPrivateIDs.insert(info.id)
                            }
                            result.groups.formUnion(info.groups)
                            result.componentPaths.append(entry.path)
                        } else { result.isComplete = false }
                    } else { visit(entry.path, depth: depth + 1) }
                    if remaining <= 0 || Date() >= deadline { result.isComplete = false; break }
                }
            }
            for folder in ["PlugIns", "XPCServices", "Library/LoginItems", "Helpers", "Frameworks"] {
                visit(app.path + "/Contents/" + folder, depth: 0)
            }
        }
        return result
    }

    static func otherClaims(excluding bundleID: String, applications: [DiskCleanInstalledApplication]) -> (ids: Set<String>, complete: Bool) {
        DiskCleanApplicationClaimsSnapshot.read(applications).otherClaims(excluding: bundleID)
    }

    static func isSharedRuntime(_ id: String) -> Bool {
        let id = id.lowercased()
        return id == "com.github.electron.helper" || id == "com.google.googleupdater"
            || id.hasPrefix("com.google.googleupdater.") || id.hasPrefix("com.google.keystone.")
            || id.hasPrefix("org.sparkle-project.")
    }

    static func hasPotentialOwner(_ id: String, in claims: Set<String>) -> Bool {
        let candidate = id.lowercased()
        return claims.contains {
            let owner = $0.lowercased()
            return candidate == owner || candidate.hasPrefix(owner + ".")
        }
    }

    static func signingInfo(_ path: String) -> (id: String, team: String?, groups: Set<String>)? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code, SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let information = information as? [String: Any],
              let id = information[kSecCodeInfoIdentifier as String] as? String else { return nil }
        let entitlements = information[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        return (id, information[kSecCodeInfoTeamIdentifier as String] as? String,
            Set(entitlements?["com.apple.security.application-groups"] as? [String] ?? []))
    }
}

/// Candidates and permission coverage are independent; a denied read is never an empty category.
struct DiskCleanApplicationOwnership: Sendable {
    let home: String
    var includeContainers = false
    var userCacheRoot: String? = nil
    static let locations: [(String, Bool)] = [
        ("Library/Caches", false), ("Library/Logs", false),
        ("Library/Preferences", true), ("Library/Application Support", true),
        ("Library/Saved Application State", true), ("Library/HTTPStorages", true),
        ("Library/WebKit", true), ("Library/Application Scripts", true)
    ]

    static func darwinCacheRoot() -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count)
        guard length > 0, length <= buffer.count else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let path = String(decoding: bytes, as: UTF8.self)
        guard let physical = DiskCleanPhysicalPath.realpath(of: path) else { return nil }
        var status = stat()
        guard lstat(physical, &status) == 0, status.st_uid == getuid(), (status.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return physical
    }

    var cacheRoot: String? {
        if let userCacheRoot { return userCacheRoot }
        guard DiskCleanPhysicalPath.realpath(of: home) == DiskCleanPhysicalPath.realpath(of: NSHomeDirectory()) else { return nil }
        return Self.darwinCacheRoot()
    }

    var reservedRoots: [String] { [home + "/Library"] + (cacheRoot.map { [$0] } ?? []) }

    func associations(bundleID: String) -> [DiskCleanApplicationAssociation] {
        resolve(bundleID: bundleID, identity: .init(ids: [bundleID])).associations
    }

    func resolve(bundleID: String, identity: DiskCleanApplicationIdentity,
                 applicationName: String? = nil, otherOwners: Set<String> = [], claimsComplete: Bool = true,
                 otherExecutables: Set<String> = [], otherNames: Set<String> = []) -> DiskCleanApplicationOwnershipResult {
        guard DiskCleanApplicationInventory.validBundleID(bundleID) else { return .init() }
        var result = DiskCleanApplicationOwnershipResult(coverage: Dictionary(uniqueKeysWithValues:
            DiskCleanApplicationFileCategory.allCases.map { ($0, .checked) }))
        func record(_ category: DiskCleanApplicationFileCategory, _ state: DiskCleanApplicationCoverage) {
            if state.rawValue > (result.coverage[category]?.rawValue ?? 0) { result.coverage[category] = state }
        }
        let physicalHome = DiskCleanPhysicalPath.realpath(of: home) ?? home
        let productRule = DiskCleanApplicationProductRules.rule(for: bundleID)
        result.report.hasProductRule = productRule != nil
        result.report.identityComplete = identity.isComplete
        result.report.claimsComplete = claimsComplete
        var source = DiskCleanApplicationScanCheck.Source.bundleID
        func check(_ path: String, _ category: DiskCleanApplicationFileCategory, _ state: DiskCleanApplicationScanCheck.State) {
            result.report.record(path: path, category: category, source: source, state: state)
        }
        func readState(_ error: Error) -> DiskCleanApplicationScanCheck.State {
            guard let error = error as? DiskCleanPOSIXError else { return .incomplete }
            if error.code == EPERM || error.code == EACCES { return .permissionRequired }
            return error.code == ENOTSUP ? .unsupported : .incomplete
        }
        var attributionID = bundleID
        func add(_ relative: String, category: DiskCleanApplicationFileCategory, personal: Bool = true,
                 evidence: String = "Bundle ID 精确匹配", manual: String? = nil, containerOwner: String? = nil,
                 absolute: Bool = false, ownerID: String? = nil, product: DiskCleanApplicationProductProof? = nil,
                 crashRecord: DiskCleanApplicationCrashRecord? = nil, candidateName: String? = nil,
                 service: DiskCleanApplicationServiceProof? = nil) {
            let logicalPath = absolute ? relative : home + "/" + relative
            let path = DiskCleanPhysicalPath.resolve(logicalPath)
            var status = stat()
            guard lstat(path, &status) == 0 else {
                let code = errno
                if code != ENOENT { record(category, code == EPERM || code == EACCES ? .permissionRequired : .incomplete) }
                check(logicalPath, category, code == ENOENT ? .missing : (code == EPERM || code == EACCES ? .permissionRequired : .incomplete))
                return
            }
            check(logicalPath, category, .checked)
            let knownSharedPath = (productRule?.locations ?? []).contains { location in
                guard location.reviewOnly else { return false }
                let shared = DiskCleanPhysicalPath.resolve(home + "/" + location.relativePath).lowercased()
                return path.lowercased() == shared || path.lowercased().hasPrefix(shared + "/")
            }
            var nameCandidate: DiskCleanApplicationNameCandidate?
            if let candidateName, identity.mainBundleID == bundleID, !knownSharedPath {
                let prefix = logicalPath.hasPrefix(home + "/") ? home + "/" : physicalHome + "/"
                if logicalPath.hasPrefix(prefix) {
                    let candidate = DiskCleanApplicationNameCandidate(home: home,
                        relativePath: String(logicalPath.dropFirst(prefix.count)), matchedName: candidateName)
                    if candidate.permits(path), !otherNames.contains(candidateName.lowercased()) { nameCandidate = candidate }
                }
            }
            let nameRestriction: String?
            if candidateName != nil && knownSharedPath { nameRestriction = "共享或历史目录，需手动处理" }
            else if let candidateName, otherNames.contains(candidateName.lowercased()) { nameRestriction = "其他应用使用相同名称" }
            else { nameRestriction = nameCandidate == nil ? manual : nil }
            var aliases = Array(Set([path, logicalPath]))
            if path.hasPrefix(physicalHome + "/") {
                aliases = Array(Set(aliases + [home + String(path.dropFirst(physicalHome.count))]))
            }
            var proof = DiskCleanApplicationProof(path: path, containerOwner: containerOwner, ownerID: ownerID ?? attributionID,
                product: product, mainBundleID: identity.mainBundleID,
                privateComponentID: identity.verifiedPrivateIDs.contains(ownerID ?? attributionID)
                    || (service?.helperTeam != nil && (ownerID ?? attributionID).lowercased().hasPrefix(bundleID.lowercased() + ".")) ? ownerID ?? attributionID : nil,
                crashRecord: crashRecord, logicalPaths: aliases, nameCandidate: nameCandidate, service: service)
            let ownership = proof.ownershipCheck(for: bundleID, otherOwners: otherOwners, claimsComplete: claimsComplete)
            let rejection = nameRestriction ?? ownership.rejection
            if nameRestriction == nil, case .incomplete = ownership {
                record(category, .incomplete)
                result.report.record(path: logicalPath, category: category, source: .identity, state: .incomplete)
            }
            proof.allowsPersonalSessionRemoval = (personal || nameCandidate != nil) && rejection == nil
            result.associations.append(.init(path: path, bundleID: bundleID, isPersonal: personal || nameCandidate != nil,
                evidence: evidence, manualReason: rejection, category: category, proof: proof, logicalPaths: aliases))
        }
        func entries(_ relative: String, category: DiskCleanApplicationFileCategory) -> [DiskCleanListedEntry] {
            let path = home + "/" + relative
            var status = stat()
            guard lstat(path, &status) == 0 else {
                let code = errno
                if code != ENOENT { record(category, code == EPERM || code == EACCES ? .permissionRequired : .incomplete) }
                check(path, category, code == ENOENT ? .missing : (code == EPERM || code == EACCES ? .permissionRequired : .incomplete))
                return []
            }
            do {
                let listed = try DiskCleanDirectoryListing.read(DiskCleanPhysicalPath.resolve(path))
                check(path, category, .checked)
                return listed
            } catch {
                let state = readState(error)
                record(category, state == .permissionRequired ? .permissionRequired : .incomplete)
                check(path, category, state)
                return []
            }
        }
        for id in identity.ids.sorted() {
            guard DiskCleanApplicationInventory.validBundleID(id) else { continue }
            attributionID = id
            let keepsOfflineData = ["com.spotify.client", "com.raycast.macos"].contains(bundleID)
                || ["com.spotify.client", "com.raycast.macos"].contains(id)
            for root in ["Caches", "Logs"] {
                add("Library/" + root + "/" + id, category: .caches, personal: keepsOfflineData)
            }
            if let cacheRoot {
                add(cacheRoot + "/" + id, category: .caches,
                    personal: keepsOfflineData, absolute: true)
            }
            add("Library/Application Support/" + id, category: .support)
            add("Library/Preferences/" + id + ".plist", category: .preferences)
            add("Library/Preferences/" + id, category: .preferences)
            add("Library/Saved Application State/" + id + ".savedState", category: .preferences)
            add("Library/SyncedPreferences/" + id + ".plist", category: .preferences)
            for entry in entries("Library/Preferences/ByHost", category: .preferences) {
                let name = URL(fileURLWithPath: entry.path).lastPathComponent
                if name.hasPrefix(id + "."), name.hasSuffix(".plist") {
                    let host = String(name.dropFirst(id.count + 1).dropLast(6))
                    if UUID(uuidString: host) != nil { add(entry.path, category: .preferences, absolute: true) }
                }
            }
            for suffix in ["WebKit/", "HTTPStorages/", "Application Scripts/", "Cookies/"] {
                add("Library/" + suffix + id, category: .sandbox)
            }
            add("Library/WebKit/com.apple.WebKit.WebContent/" + id, category: .sandbox)
            for folder in ["HTTPStorages", "Cookies"] {
                add("Library/" + folder + "/" + id + ".binarycookies", category: .sandbox, manual: "登录与身份数据受保护")
            }
            for root in ["Library/Caches/com.apple.nsurlsessiond/Downloads/", "Library/Caches/com.crashlytics.data/",
                         "Library/Caches/com.plausiblelabs.crashreporter.data/"] {
                add(root + id, category: .caches, personal: false)
            }
            add("Library/Caches/" + id + ".ShipIt", category: .caches, personal: false)
        }
        attributionID = bundleID
        source = .productRule
        for location in productRule?.locations ?? [] {
            guard DiskCleanApplicationProductRules.isSafeRelativePath(location.relativePath) else { continue }
            add(location.relativePath, category: location.category, personal: location.personal,
                evidence: "应用专用目录规则", manual: !DiskCleanApplicationProductRules.isExclusive(location.relativePath, to: bundleID) ? "共享或历史目录，需要核对文件归属" : nil,
                product: .init(home: home, bundleID: bundleID, relativePath: location.relativePath))
        }
        // Name-only leaves are useful discoveries, but cannot authorize removal.
        source = .name
        var sourceNames = identity.names.union(productRule?.aliases ?? [])
        if let applicationName { sourceNames.insert(applicationName) }
        let names = DiskCleanApplicationNameVariants.make(sourceNames)
        if !names.isEmpty {
            for entry in entries("Library/Application Support/CrashReporter", category: .caches) where !entry.isDirectory {
                let name = URL(fileURLWithPath: entry.path).lastPathComponent
                for appName in names where name.hasPrefix(appName + "_") && name.hasSuffix(".plist") {
                    let suffix = String(name.dropFirst(appName.count + 1).dropLast(6))
                    if UUID(uuidString: suffix) != nil {
                        let record = DiskCleanApplicationCrashRecord(home: home, executable: appName)
                        let verified = identity.mainBundleID == bundleID && identity.executables.contains(appName)
                            && !otherExecutables.contains(where: { $0.caseInsensitiveCompare(appName) == .orderedSame })
                            && record.permits(entry.path)
                        source = verified ? .identity : .name
                        add(entry.path, category: .caches, personal: false,
                            evidence: verified ? "应用进程名称与退出记录格式匹配" : "应用名称匹配的崩溃记录",
                            manual: verified ? nil : "需要核对文件归属", absolute: true, crashRecord: verified ? record : nil,
                            candidateName: verified || otherExecutables.contains(where: { $0.caseInsensitiveCompare(appName) == .orderedSame }) ? nil : appName)
                        source = .name
                    }
                }
            }
            for name in names.sorted() {
                for root in [".config/", ".cache/", ".local/share/"] {
                    add(root + name, category: root == ".cache/" ? .caches : .support,
                        evidence: "隐藏目录下的应用名称匹配", manual: "可能与命令行工具共享，需要核对文件归属", candidateName: name)
                }
                for vendor in ["Tencent", "Microsoft", "Adobe", "Google", "JetBrains", "Mozilla", "Avid"] {
                    add("Library/Application Support/" + vendor + "/" + name, category: .support,
                        evidence: "厂商目录下的应用名称匹配", manual: "需要核对文件归属", candidateName: name)
                }
                for (root, category) in [("Application Support", DiskCleanApplicationFileCategory.support), ("Caches", .caches), ("Logs", .caches)] {
                    add("Library/" + root + "/" + name, category: category,
                        evidence: "应用名称匹配，归属尚未确认", manual: "需要核对文件归属", candidateName: name)
                }
            }
        }
        source = .container
        if includeContainers {
            for entry in entries("Library/Containers", category: .sandbox) where entry.isDirectory {
                let owner = Self.containerOwner(at: entry.path)
                if owner == nil {
                    record(.sandbox, .incomplete)
                    check(entry.path, .sandbox, .incomplete)
                }
                if let owner, identity.ids.contains(owner) {
                    add(entry.path, category: .sandbox, evidence: "容器元数据匹配",
                        containerOwner: owner, absolute: true, ownerID: owner)
                }
            }
            for group in identity.groups where DiskCleanApplicationInventory.validBundleID(group) {
                add("Library/Group Containers/" + group, category: .sandbox, evidence: "应用声明的 App Group",
                    manual: "共享容器仅供查看")
            }
        } else {
            record(.sandbox, .permissionRequired)
            check(home + "/Library/Containers", .sandbox, .permissionRequired)
            check(home + "/Library/Group Containers", .sandbox, .permissionRequired)
        }
        if !identity.isComplete { record(.sandbox, .incomplete) }
        source = .system
        for root in [home + "/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons", "/Library/PrivilegedHelperTools"] {
            let listed: [DiskCleanListedEntry]
            do {
                listed = try DiskCleanDirectoryListing.read(root)
                check(root, .support, .checked)
            } catch {
                var status = stat()
                let missing = lstat(root, &status) != 0 && errno == ENOENT
                let state: DiskCleanApplicationScanCheck.State = missing ? .missing : readState(error)
                check(root, .support, state)
                if !missing { record(.support, state == .permissionRequired ? .permissionRequired : .incomplete) }
                continue
            }
            for entry in listed {
                let name = URL(fileURLWithPath: entry.path).lastPathComponent
                if identity.mainBundleID == bundleID,
                   let service = DiskCleanApplicationServiceProof.read(path: entry.path, home: home,
                       bundleID: bundleID, copies: identity.applications) {
                    add(entry.path, category: .services, evidence: "应用专属后台组件", absolute: true,
                        ownerID: service.ownerID ?? bundleID, service: service)
                } else if identity.ids.contains(where: { name == $0 || name == $0 + ".plist" || name.hasPrefix($0 + ".") }) {
                    add(entry.path, category: .support, evidence: "关联后台组件", manual: "后台组件需要专用卸载方式", absolute: true)
                }
            }
        }
        for root in ["/Library/Application Support/", "/Library/Preferences/", "/Library/Caches/"] {
            add(root + bundleID + (root.contains("Preferences") ? ".plist" : ""), category: .support,
                evidence: "系统级关联文件", absolute: true)
        }
        var merged: [DiskCleanApplicationAssociation] = []
        var paths: [String: Int] = [:]
        var objects: [String: Int] = [:]
        for item in result.associations.sorted(by: {
            if ($0.manualReason == nil) != ($1.manualReason == nil) { return $0.manualReason == nil }
            if ($0.proof?.nameCandidate == nil) != ($1.proof?.nameCandidate == nil) { return $0.proof?.nameCandidate == nil }
            return $0.path.count < $1.path.count
        }) {
            var status = stat()
            let object = lstat(item.path, &status) == 0 ? String(status.st_dev) + ":" + String(status.st_ino) : nil
            if let index = paths[item.path] ?? object.flatMap({ objects[$0] }) {
                let aliases = Array(Set(merged[index].logicalPaths + item.logicalPaths))
                merged[index].logicalPaths = aliases
                merged[index].proof?.logicalPaths = aliases
            } else {
                paths[item.path] = merged.count
                if let object { objects[object] = merged.count }
                merged.append(item)
            }
        }
        result.associations = merged.filter { item in
            !merged.contains { parent in
                parent.path != item.path && item.path.hasPrefix(parent.path + "/") && parent.manualReason == nil
            }
        }
        return result
    }

    static func containerOwner(at path: String) -> String? {
        guard let data = DiskCleanProjectRecognition.readSmallFile(path + "/.com.apple.containermanagerd.metadata.plist"),
              let metadata = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return metadata["MCMMetadataIdentifier"] as? String
    }

    func suspectedBundleIDs() -> Set<String> {
        var result = Set<String>()
        for (location, _) in Self.locations {
            guard let entries = try? DiskCleanDirectoryListing.read(DiskCleanPhysicalPath.resolve(home + "/" + location)) else { continue }
            for entry in entries {
                var id = URL(fileURLWithPath: entry.path).lastPathComponent
                for suffix in [".plist", ".savedState", ".binarycookies"] where id.hasSuffix(suffix) { id = String(id.dropLast(suffix.count)) }
                if id.hasSuffix(".ShipIt") { id = String(id.dropLast(7)) }
                let sharedRuntimeRoots: Set<String> = ["com.crashlytics.data", "com.plausiblelabs.crashreporter.data"]
                if DiskCleanApplicationInventory.validBundleID(id), !id.lowercased().hasPrefix("com.apple."),
                   !sharedRuntimeRoots.contains(id) { result.insert(id) }
            }
        }
        if let cacheRoot, let entries = try? DiskCleanDirectoryListing.read(cacheRoot) {
            for entry in entries {
                let id = URL(fileURLWithPath: entry.path).lastPathComponent
                if DiskCleanApplicationInventory.validBundleID(id), !id.lowercased().hasPrefix("com.apple.") { result.insert(id) }
            }
        }
        for rule in DiskCleanApplicationProductRules.all where rule.locations.contains(where: {
            !$0.reviewOnly && $0.category == .support && DiskCleanApplicationProductRules.isSafeRelativePath($0.relativePath)
                && FileManager.default.fileExists(atPath: home + "/" + $0.relativePath)
        }) { result.insert(rule.bundleID) }
        if includeContainers, let entries = try? DiskCleanDirectoryListing.read(DiskCleanPhysicalPath.resolve(home + "/Library/Containers")) {
            for entry in entries {
                if let id = Self.containerOwner(at: entry.path), DiskCleanApplicationInventory.validBundleID(id), !id.hasPrefix("com.apple.") { result.insert(id) }
            }
        }
        return result
    }
}
