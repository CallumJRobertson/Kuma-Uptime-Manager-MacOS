import Combine
import Foundation
import Network
import os
import Security
import ServiceManagement
import SwiftUI
import UserNotifications

@MainActor
final class UptimeKumaStatusStore: ObservableObject {
    @Published var connectionMode: UptimeKumaConnectionMode
    @Published var privateAuthMethod: UptimeKumaPrivateAuthMethod
    @Published var dashboardStyle: UptimeKumaDashboardStyle
    @Published var menuIconStyle: UptimeKumaMenuIconStyle
    @Published var displayName: String
    @Published var baseURLString: String
    @Published var statusPageSlug: String
    @Published var authEnabled: Bool
    @Published var twoFactorEnabled: Bool
    @Published var connectOverWiFiOnly: Bool
    @Published var launchAtLogin: Bool
    @Published var pollingIntervalSeconds: Int
    @Published var authUsername = ""
    @Published var authPassword = ""
    @Published var metricsAPIKey = ""
    @Published var managementUsername = ""
    @Published var managementPassword = ""
    @Published var isShowingWebLogin = false
    @Published private(set) var webLoginURL: URL?
    @Published private(set) var monitors: [MonitorStatus] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var debugLogLines: [String] = []
    @Published private(set) var downCountHistory: [Int] = []
    @Published private(set) var pingHistoryByMonitorID: [Int: [Double]] = [:]

    private enum Keys {
        static let connectionMode = "uptimekuma.connectionMode"
        static let privateAuthMethod = "uptimekuma.privateAuthMethod"
        static let dashboardStyle = "uptimekuma.dashboardStyle"
        static let menuIconStyle = "uptimekuma.menuIconStyle"
        static let displayName = "uptimekuma.displayName"
        static let baseURL = "uptimekuma.baseURL"
        static let statusPageSlug = "uptimekuma.statusPageSlug"
        static let authEnabled = "uptimekuma.authEnabled"
        static let twoFactorEnabled = "uptimekuma.twoFactorEnabled"
        static let connectOverWiFiOnly = "uptimekuma.connectOverWiFiOnly"
        static let launchAtLogin = "uptimekuma.launchAtLogin"
        static let pollingIntervalSeconds = "uptimekuma.pollingIntervalSeconds"
    }

    private static let minPollingIntervalSeconds = 5
    private static let maxPollingIntervalSeconds = 300

    private let defaults: UserDefaults
    private let keychain = CredentialsKeychainStore()
    private var pollingTask: Task<Void, Never>?
    private var activeConfiguration: ResolvedConfiguration?
    private var currentCredentials: BasicAuthCredentials?
    private var currentManagementCredentials: BasicAuthCredentials?
    private var activeRefreshCount = 0
    private var configurationVersion = 0
    private var lastKnownMonitorStateByID: [Int: MonitorState] = [:]
    private var hasLoadedInitialSnapshot = false
    private var hasRequestedNotificationAuthorization = false
    private var latestNetworkSatisfied = true
    private var latestOnWiFi = true
    private var hasReceivedNetworkPath = false
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "uptimekuma.path-monitor")
    private let logger = Logger(subsystem: "uptime.UptimeKuma-Mac", category: "store")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedConnectionMode = UptimeKumaConnectionMode(rawValue: defaults.string(forKey: Keys.connectionMode) ?? "") ?? .privateServer
        let savedAuthMethod = UptimeKumaPrivateAuthMethod(rawValue: defaults.string(forKey: Keys.privateAuthMethod) ?? "") ?? .apiKey
        privateAuthMethod = savedAuthMethod == .webSession ? .apiKey : savedAuthMethod
        dashboardStyle = UptimeKumaDashboardStyle(rawValue: defaults.string(forKey: Keys.dashboardStyle) ?? "") ?? .compactList
        menuIconStyle = UptimeKumaMenuIconStyle(rawValue: defaults.string(forKey: Keys.menuIconStyle) ?? "") ?? .rack
        connectionMode = savedConnectionMode
        displayName = defaults.string(forKey: Keys.displayName) ?? "Uptime Kuma Server"

        let savedBaseURL = defaults.string(forKey: Keys.baseURL) ?? ""
        let savedStatusPageSlug = defaults.string(forKey: Keys.statusPageSlug) ?? ""
        authEnabled = savedConnectionMode == .privateServer || defaults.bool(forKey: Keys.authEnabled)
        twoFactorEnabled = defaults.bool(forKey: Keys.twoFactorEnabled)
        connectOverWiFiOnly = defaults.bool(forKey: Keys.connectOverWiFiOnly)
        launchAtLogin = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false
        pollingIntervalSeconds = Self.clampPollingInterval(defaults.object(forKey: Keys.pollingIntervalSeconds) as? Int ?? 30)
        baseURLString = savedBaseURL
        statusPageSlug = savedStatusPageSlug

        if let configuration = Self.resolveConfiguration(
            baseURLString: savedBaseURL,
            statusPageSlugOverride: savedStatusPageSlug,
            connectionMode: savedConnectionMode
        ) {
            activeConfiguration = configuration
            if configuration.connectionMode == .privateServer {
                currentCredentials = try? keychain.load(for: configuration.credentialsKey)
                if privateAuthMethod == .apiKey {
                    metricsAPIKey = currentCredentials?.password ?? ""
                    authUsername = ""
                    authPassword = ""
                } else {
                    metricsAPIKey = ""
                    authUsername = ""
                    authPassword = ""
                }
                currentManagementCredentials = try? keychain.load(for: Self.managementCredentialsKey(for: configuration.credentialsKey))
                managementUsername = currentManagementCredentials?.username ?? ""
                managementPassword = currentManagementCredentials?.password ?? ""
            }
        }

        requestNotificationAuthorizationIfNeeded()
        startPathMonitor()
        if defaults.object(forKey: Keys.launchAtLogin) != nil {
            applyLaunchAtLoginSetting(launchAtLogin)
        } else {
            appendLog("Launch at login defaults to disabled until enabled in Settings")
        }
        if savedAuthMethod == .webSession {
            defaults.set(UptimeKumaPrivateAuthMethod.apiKey.rawValue, forKey: Keys.privateAuthMethod)
            appendLog("Migrated auth mode from Web Session to API Key for stability")
        }
        startPolling()
    }

    deinit {
        pathMonitor.cancel()
    }

    var menuLabel: String {
        guard hasConfiguration else { return "Kuma" }
        guard !monitors.isEmpty else { return "..." }

        let downCount = monitors.filter { $0.state == .down }.count
        return downCount == 0 ? "\(monitors.count)" : "\(downCount)"
    }

    var menuSymbolName: String {
        menuIconStyle.symbolName
    }

    var menuShowsDownDot: Bool {
        monitors.contains(where: { $0.state == .down })
    }

    var emptyStateMessage: String {
        if !hasConfiguration {
            return "Open Settings and enter your Uptime Kuma Host URL."
        }
        if isLoading {
            return "Loading monitor statuses..."
        }
        return "No monitors returned from /metrics."
    }

    var hasConfiguration: Bool {
        activeConfiguration != nil
    }

    var dashboardURL: URL? {
        guard connectionMode == .privateServer else { return nil }
        return makeWebAppURL(fragment: "/dashboard")
    }

    var addMonitorURL: URL? {
        guard connectionMode == .privateServer else { return nil }
        return makeWebAppURL(fragment: "/add")
    }

    var apiKeysURL: URL? {
        guard connectionMode == .privateServer else { return nil }
        guard let baseURL = currentBaseURLForLinks else { return nil }
        return baseURL
            .appendingPathComponent("settings")
            .appendingPathComponent("api-keys")
    }

    func addHTTPMonitor(name: String, targetURL: String, intervalSeconds: Int) async throws -> Int {
        guard connectionMode == .privateServer else {
            throw UptimeKumaError.addMonitorUnavailable("Add monitor is available only in Private mode.")
        }
        guard let configuration = activeConfiguration else {
            throw UptimeKumaError.addMonitorUnavailable("Save a valid host before adding monitors.")
        }
        guard let managementCredentials = currentManagementCredentials else {
            throw UptimeKumaError.addMonitorUnavailable("Set monitor-management username/password in Settings first.")
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTarget = targetURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw UptimeKumaError.addMonitorUnavailable("Monitor name is required.")
        }
        guard URL(string: trimmedTarget) != nil else {
            throw UptimeKumaError.addMonitorUnavailable("Enter a valid target URL.")
        }

        appendLog("Add monitor start. name=\(trimmedName) target=\(trimmedTarget)")
        let monitorID = try await UptimeKumaSocketAPI.addHTTPMonitor(
            baseURL: configuration.baseURL,
            username: managementCredentials.username,
            password: managementCredentials.password,
            name: trimmedName,
            targetURL: trimmedTarget,
            intervalSeconds: max(20, intervalSeconds)
        )
        appendLog("Add monitor success. id=\(monitorID) name=\(trimmedName)")
        refreshNow()
        return monitorID
    }

    func saveSettings() {
        appendLog("Save tapped. mode=\(connectionMode.rawValue) host=\(baseURLString)")
        guard let configuration = Self.resolveConfiguration(
            baseURLString: baseURLString,
            statusPageSlugOverride: statusPageSlug,
            connectionMode: connectionMode
        ) else {
            errorMessage = "Enter a valid Host URL. HTTP is allowed only for local hosts/IPs; use HTTPS for remote servers."
            appendLog("Save failed: invalid host URL")
            return
        }
        appendLog("Resolved host=\(configuration.savedBaseURL) mode=\(configuration.connectionMode.rawValue) slug=\(configuration.preferredStatusPageSlug ?? "n/a")")

        let normalizedDisplayName: String = {
            let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Uptime Kuma Server" : trimmed
        }()

        let apiKey = metricsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

        var nextCredentials: BasicAuthCredentials?
        var warningMessage: String?

        if configuration.connectionMode == .privateServer {
            if privateAuthMethod != .apiKey {
                privateAuthMethod = .apiKey
                appendLog("Auth method forced to API Key in current build")
            }
            let resolvedAPIKey: String
            if apiKey.isEmpty {
                if
                    let existing = try? keychain.load(for: configuration.credentialsKey),
                    !existing.password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    resolvedAPIKey = existing.password
                    appendLog("API key field empty; reusing saved keychain key for \(configuration.savedBaseURL)")
                } else {
                    errorMessage = "Private mode API key is required."
                    appendLog("Save failed: private mode API key missing")
                    return
                }
            } else {
                resolvedAPIKey = apiKey
            }

            let credentials = BasicAuthCredentials(username: "", password: resolvedAPIKey)
            nextCredentials = credentials
            authUsername = ""
            authPassword = ""
            metricsAPIKey = resolvedAPIKey

            let managementUser = managementUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            let managementPass = managementPassword.trimmingCharacters(in: .whitespacesAndNewlines)
            let managementKey = Self.managementCredentialsKey(for: configuration.credentialsKey)
            if managementUser.isEmpty && managementPass.isEmpty {
                if
                    let existing = try? keychain.load(for: managementKey),
                    !existing.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    !existing.password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    currentManagementCredentials = existing
                    managementUsername = existing.username
                    managementPassword = existing.password
                    appendLog("Mgmt fields empty; reusing saved management credentials")
                } else {
                    currentManagementCredentials = nil
                    try? keychain.delete(for: managementKey)
                }
            } else if !managementUser.isEmpty && !managementPass.isEmpty {
                let managementCredentials = BasicAuthCredentials(username: managementUser, password: managementPass)
                currentManagementCredentials = managementCredentials
                managementUsername = managementUser
                managementPassword = managementPass
                do {
                    try keychain.save(managementCredentials, for: managementKey)
                    appendLog("Management credentials saved for \(configuration.savedBaseURL)")
                } catch {
                    warningMessage = "Could not securely store monitor-management credentials."
                    appendLog("Management credential keychain save failed: \(error.localizedDescription)")
                }
            } else {
                warningMessage = "Monitor-management credentials require both username and password."
                currentManagementCredentials = nil
            }

            if let nextCredentials {
                do {
                    try keychain.save(nextCredentials, for: configuration.credentialsKey)
                    appendLog("Credentials saved to keychain for \(configuration.savedBaseURL)")
                } catch {
                    warningMessage = "Saved for this session only. Could not store credentials in Keychain."
                    appendLog("Keychain save failed: \(error.localizedDescription)")
                }
            }
            authEnabled = true
        } else {
            authEnabled = false
            nextCredentials = nil
        }

        displayName = normalizedDisplayName
        baseURLString = configuration.savedBaseURL
        statusPageSlug = configuration.savedStatusPageSlug
        pollingIntervalSeconds = Self.clampPollingInterval(pollingIntervalSeconds)
        connectionMode = configuration.connectionMode
        defaults.set(connectionMode.rawValue, forKey: Keys.connectionMode)
        defaults.set(privateAuthMethod.rawValue, forKey: Keys.privateAuthMethod)
        defaults.set(dashboardStyle.rawValue, forKey: Keys.dashboardStyle)
        defaults.set(menuIconStyle.rawValue, forKey: Keys.menuIconStyle)
        defaults.set(displayName, forKey: Keys.displayName)
        defaults.set(baseURLString, forKey: Keys.baseURL)
        defaults.set(statusPageSlug, forKey: Keys.statusPageSlug)
        defaults.set(authEnabled, forKey: Keys.authEnabled)
        defaults.set(twoFactorEnabled, forKey: Keys.twoFactorEnabled)
        defaults.set(connectOverWiFiOnly, forKey: Keys.connectOverWiFiOnly)
        defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
        defaults.set(pollingIntervalSeconds, forKey: Keys.pollingIntervalSeconds)
        applyLaunchAtLoginSetting(launchAtLogin)

        activeConfiguration = configuration
        currentCredentials = nextCredentials
        if let nextCredentials {
            authUsername = nextCredentials.username
            authPassword = nextCredentials.password
        }

        errorMessage = warningMessage
        appendLog("Save complete. Starting polling.")
        startPolling()
    }

    func useDemoServerForReview() {
        appendLog("Applying demo server configuration")
        connectionMode = .privateServer
        privateAuthMethod = .apiKey
        displayName = "Demo Server"
        baseURLString = "https://status.callumrobertson.tech"
        statusPageSlug = ""
        metricsAPIKey = "uk4_i9JzdcCkLzbCabTv4Y_iJ6q_HVirh4fE0PTJhUOn"
        managementUsername = "test123"
        managementPassword = "test123"
        authUsername = ""
        authPassword = ""
        saveSettings()
        refreshNow()
    }

    private func applyLaunchAtLoginSetting(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else {
            appendLog("Launch at login not supported on this macOS version")
            return
        }

        do {
            if enabled {
                try SMAppService.mainApp.register()
                appendLog("Launch at login enabled")
            } else {
                try SMAppService.mainApp.unregister()
                appendLog("Launch at login disabled")
            }
        } catch {
            errorMessage = "Could not update Launch at Login. Check Login Items permissions."
            appendLog("Launch at login update failed: \(error.localizedDescription)")
        }
    }

    func clearSavedCredentials() {
        guard
            let configuration = activeConfiguration
                ?? Self.resolveConfiguration(
                    baseURLString: baseURLString,
                    statusPageSlugOverride: statusPageSlug,
                    connectionMode: connectionMode
                )
        else {
            return
        }

        do {
            try keychain.delete(for: configuration.credentialsKey)
            appendLog("Credentials deleted for \(configuration.savedBaseURL)")
            try? keychain.delete(for: Self.managementCredentialsKey(for: configuration.credentialsKey))
        } catch {
            errorMessage = "Could not clear saved credentials."
            appendLog("Credential delete failed: \(error.localizedDescription)")
            return
        }

        if activeConfiguration?.credentialsKey == configuration.credentialsKey {
            currentCredentials = nil
        }
        authUsername = ""
        authPassword = ""
        managementUsername = ""
        managementPassword = ""
        currentManagementCredentials = nil
        errorMessage = "Saved credentials were removed."
    }

    func startWebLogin() {
        errorMessage = "Web Session login is unavailable in this build. Use Private mode with an API Key."
        appendLog("Web login blocked: unsupported in current sandbox/runtime")
    }

    func cancelWebLogin() {
        isShowingWebLogin = false
    }

    func completeWebLogin(cookies: [HTTPCookie]) {
        guard !cookies.isEmpty else {
            errorMessage = "No session cookies were captured. Please complete login in the web view and try again."
            appendLog("Web login completed with zero cookies; keeping login flow active")
            return
        }

        let storage = HTTPCookieStorage.shared
        for cookie in cookies {
            storage.setCookie(cookie)
        }
        appendLog("Captured \(cookies.count) session cookies from web login")
        errorMessage = nil
        isShowingWebLogin = false
        startPolling()
        refreshNow()
    }

    private func clearSessionCookies(for url: URL) {
        guard let host = url.host?.lowercased() else { return }

        let allCookies = HTTPCookieStorage.shared.cookies ?? []
        var removed = 0
        for cookie in allCookies {
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            if host == domain || host.hasSuffix(".\(domain)") || domain.hasSuffix(".\(host)") {
                HTTPCookieStorage.shared.deleteCookie(cookie)
                removed += 1
            }
        }
        appendLog("Cleared \(removed) existing session cookies for \(host) before web login")
    }

    func refreshNow() {
        let version = configurationVersion
        Task {
            await refresh(expectedConfigurationVersion: version)
        }
    }

    private func startPolling() {
        pollingTask?.cancel()

        guard activeConfiguration != nil else {
            monitors = []
            errorMessage = nil
            isLoading = false
            lastUpdated = nil
            downCountHistory = []
            pingHistoryByMonitorID = [:]
            activeRefreshCount = 0
            lastKnownMonitorStateByID = [:]
            hasLoadedInitialSnapshot = false
            return
        }

        configurationVersion += 1
        let version = configurationVersion

        pollingTask = Task {
            await refresh(expectedConfigurationVersion: version)
            guard !Task.isCancelled, version == configurationVersion, errorMessage == nil else {
                return
            }

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.clampPollingInterval(pollingIntervalSeconds)))
                await refresh(expectedConfigurationVersion: version)
                guard errorMessage == nil else {
                    appendLog("Polling paused due to error: \(errorMessage ?? "unknown")")
                    return
                }
            }
        }
    }

    private static func resolveConfiguration(
        baseURLString: String,
        statusPageSlugOverride: String,
        connectionMode: UptimeKumaConnectionMode
    ) -> ResolvedConfiguration? {
        var input = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        if !input.contains("://") {
            input = "http://\(input)"
        }

        guard var components = URLComponents(string: input) else {
            return nil
        }

        guard
            let scheme = components.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            let host = components.host?.lowercased()
        else {
            return nil
        }
        if scheme == "http", !isAllowedLocalHTTPHost(host) {
            return nil
        }

        components.scheme = scheme
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil

        let inputPathComponents = components.path
            .split(separator: "/")
            .map(String.init)
        var normalizedPathComponents = inputPathComponents
        var resolvedStatusPageSlug: String?
        let overrideSlug = statusPageSlugOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if connectionMode == .publicStatusPage, !overrideSlug.isEmpty {
            resolvedStatusPageSlug = overrideSlug
        }
        if let statusMarkerIndex = inputPathComponents.firstIndex(where: { component in
            let lowered = component.lowercased()
            return lowered == "status" || lowered == "status-page"
        }) {
            if connectionMode == .publicStatusPage, resolvedStatusPageSlug == nil, statusMarkerIndex + 1 < inputPathComponents.count {
                resolvedStatusPageSlug = inputPathComponents[statusMarkerIndex + 1]
            }
            normalizedPathComponents = Array(inputPathComponents.prefix(statusMarkerIndex))
        }

        if normalizedPathComponents.isEmpty {
            components.percentEncodedPath = ""
        } else {
            let encodedPath = normalizedPathComponents
                .map { $0.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlPathAllowed) ?? $0 }
                .joined(separator: "/")
            components.percentEncodedPath = "/\(encodedPath)"
        }

        guard let normalizedBaseURL = components.url else {
            return nil
        }

        let savedBaseURL = normalizedBaseURL.absoluteString
        return ResolvedConfiguration(
            baseURL: normalizedBaseURL,
            credentialsKey: savedBaseURL.lowercased(),
            savedBaseURL: savedBaseURL,
            connectionMode: connectionMode,
            preferredStatusPageSlug: resolvedStatusPageSlug,
            savedStatusPageSlug: connectionMode == .publicStatusPage ? overrideSlug : ""
        )
    }

    private static func isAllowedLocalHTTPHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }

        if normalized == "localhost" || normalized == "::1" || normalized == "0.0.0.0" {
            return true
        }
        if normalized.hasSuffix(".local") {
            return true
        }
        if normalized.contains(":"),
           (normalized.hasPrefix("fe80:") || normalized.hasPrefix("fc") || normalized.hasPrefix("fd"))
        {
            return true
        }
        return isLocalIPv4Address(normalized)
    }

    private static func isLocalIPv4Address(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0 ... 255).contains($0) }) else {
            return false
        }

        let first = octets[0]
        let second = octets[1]

        if first == 10 { return true }
        if first == 127 { return true }
        if first == 192, second == 168 { return true }
        if first == 172, (16 ... 31).contains(second) { return true }
        if first == 169, second == 254 { return true }
        return false
    }

    private func handleUnauthorized() {
        if connectionMode == .publicStatusPage {
            errorMessage = "This endpoint requires authentication. Switch to Private mode."
        } else {
            errorMessage = "Metrics endpoint unauthorized. In Private mode, use a valid API Key."
        }
        authEnabled = connectionMode == .privateServer
        defaults.set(authEnabled, forKey: Keys.authEnabled)
        appendLog("Unauthorized response from server")
    }

    private func refresh(expectedConfigurationVersion: Int) async {
        guard let configuration = activeConfiguration else {
            monitors = []
            return
        }

        if connectOverWiFiOnly, hasReceivedNetworkPath, (!latestNetworkSatisfied || !latestOnWiFi) {
            errorMessage = "Wi-Fi only mode is enabled. Connect to Wi-Fi to refresh."
            appendLog("Refresh blocked: Wi-Fi only mode active and current path is not Wi-Fi")
            return
        }

        activeRefreshCount += 1
        isLoading = true
        if expectedConfigurationVersion == configurationVersion {
            errorMessage = nil
        }

        defer {
            activeRefreshCount = max(0, activeRefreshCount - 1)
            isLoading = activeRefreshCount > 0
        }

        do {
            appendLog("Refresh start. mode=\(configuration.connectionMode.rawValue) host=\(configuration.savedBaseURL) slug=\(configuration.preferredStatusPageSlug ?? "n/a")")
            let fetched = try await UptimeKumaClient.fetchMonitors(
                baseURL: configuration.baseURL,
                connectionMode: configuration.connectionMode,
                preferredStatusPageSlug: configuration.preferredStatusPageSlug,
                credentials: currentCredentials
            )
            guard expectedConfigurationVersion == configurationVersion else { return }
            notifyForStatusTransitions(in: fetched)

            monitors = fetched
            lastUpdated = Date()
            errorMessage = nil
            updateHistory(with: fetched)
            updateLastKnownMonitorStates(from: fetched)
            appendLog("Refresh success. monitors=\(fetched.count)")
        } catch UptimeKumaError.unauthorized {
            guard expectedConfigurationVersion == configurationVersion else { return }
            monitors = []
            appendLog("Refresh unauthorized. authEnabled=\(authEnabled) hasCredentials=\(currentCredentials != nil)")
            handleUnauthorized()
        } catch UptimeKumaError.timedOut {
            guard expectedConfigurationVersion == configurationVersion else { return }
            errorMessage = "Connection timed out. Check host and network settings."
            appendLog("Refresh failed: timeout")
        } catch UptimeKumaError.networkUnavailable {
            guard expectedConfigurationVersion == configurationVersion else { return }
            errorMessage = "Network unavailable. Check your connection."
            appendLog("Refresh failed: network unavailable")
        } catch UptimeKumaError.tlsValidationFailed {
            guard expectedConfigurationVersion == configurationVersion else { return }
            errorMessage = "TLS certificate validation failed. Use a valid HTTPS certificate or try an HTTP URL."
            appendLog("Refresh failed: TLS validation")
        } catch UptimeKumaError.metricsUnavailable {
            guard expectedConfigurationVersion == configurationVersion else { return }
            errorMessage = "Could not read monitors from /metrics or status-page API."
            appendLog("Refresh failed: no metrics/status data")
        } catch UptimeKumaError.httpStatus(let statusCode) where statusCode == 404 {
            guard expectedConfigurationVersion == configurationVersion else { return }
            errorMessage = "Host responded with 404. If your slug is not `default`, set Host to the full status-page URL (for example: https://host/status/your-slug)."
            appendLog("Refresh failed: HTTP 404")
        } catch is CancellationError {
            return
        } catch {
            guard expectedConfigurationVersion == configurationVersion else { return }
            errorMessage = error.localizedDescription
            appendLog("Refresh failed: \(error.localizedDescription)")
        }
    }

    private func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let line = "\(formatter.string(from: Date())) \(message)"
        debugLogLines.append(line)
        if debugLogLines.count > 120 {
            debugLogLines.removeFirst(debugLogLines.count - 120)
        }
        logger.log("\(line, privacy: .public)")
        print("[Kuma] \(line)")
    }

    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let isSatisfied = path.status == .satisfied
            let isWiFi = path.usesInterfaceType(.wifi)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.latestNetworkSatisfied = isSatisfied
                self.latestOnWiFi = isWiFi
                self.hasReceivedNetworkPath = true
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    private func updateHistory(with monitors: [MonitorStatus]) {
        let downCount = monitors.filter { $0.state == .down }.count
        downCountHistory.append(downCount)
        if downCountHistory.count > 60 {
            downCountHistory.removeFirst(downCountHistory.count - 60)
        }

        var nextPingHistory = pingHistoryByMonitorID
        for monitor in monitors {
            guard let ping = monitor.ping else { continue }
            var series = nextPingHistory[monitor.id] ?? []
            series.append(ping)
            if series.count > 40 {
                series.removeFirst(series.count - 40)
            }
            nextPingHistory[monitor.id] = series
        }
        pingHistoryByMonitorID = nextPingHistory
    }

    private func updateLastKnownMonitorStates(from monitors: [MonitorStatus]) {
        var next: [Int: MonitorState] = [:]
        for monitor in monitors {
            next[monitor.id] = monitor.state
        }
        lastKnownMonitorStateByID = next
        hasLoadedInitialSnapshot = true
    }

    private func notifyForStatusTransitions(in monitors: [MonitorStatus]) {
        guard hasLoadedInitialSnapshot else { return }

        var wentDown: [MonitorStatus] = []
        var recovered: [MonitorStatus] = []

        for monitor in monitors {
            let previous = lastKnownMonitorStateByID[monitor.id]
            if monitor.state == .down && previous != .down {
                wentDown.append(monitor)
            } else if previous == .down && monitor.state != .down {
                recovered.append(monitor)
            }
        }

        guard !wentDown.isEmpty || !recovered.isEmpty else { return }
        sendStatusChangeNotification(wentDown: wentDown, recovered: recovered)
    }

    private func requestNotificationAuthorizationIfNeeded() {
        guard !hasRequestedNotificationAuthorization else { return }
        hasRequestedNotificationAuthorization = true

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.appendLog("Notification auth request failed: \(error.localizedDescription)")
                    return
                }
                self.appendLog(granted ? "Notification permission granted" : "Notification permission not granted")
            }
        }
    }

    private func sendStatusChangeNotification(wentDown: [MonitorStatus], recovered: [MonitorStatus]) {
        let content = UNMutableNotificationContent()

        if !wentDown.isEmpty, !recovered.isEmpty {
            content.title = "\(wentDown.count) down, \(recovered.count) recovered"
        } else if !wentDown.isEmpty {
            content.title = "\(wentDown.count) monitor\(wentDown.count == 1 ? "" : "s") down"
        } else {
            content.title = "\(recovered.count) monitor\(recovered.count == 1 ? "" : "s") recovered"
        }

        let downNames = wentDown.prefix(3).map(\.name).joined(separator: ", ")
        let upNames = recovered.prefix(3).map(\.name).joined(separator: ", ")
        let downSuffix = wentDown.count > 3 ? " +\(wentDown.count - 3) more" : ""
        let upSuffix = recovered.count > 3 ? " +\(recovered.count - 3) more" : ""
        var bodyParts: [String] = []
        if !wentDown.isEmpty {
            bodyParts.append("Down: \(downNames)\(downSuffix)")
        }
        if !recovered.isEmpty {
            bodyParts.append("Recovered: \(upNames)\(upSuffix)")
        }
        content.body = bodyParts.joined(separator: "  ")
        content.sound = .default

        let id = "monitor-status-changes"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if let error {
                Task { @MainActor [weak self] in
                    self?.appendLog("Failed to send status-change notification: \(error.localizedDescription)")
                }
            }
        }
    }

    private static func clampPollingInterval(_ seconds: Int) -> Int {
        min(max(seconds, minPollingIntervalSeconds), maxPollingIntervalSeconds)
    }

    private static func managementCredentialsKey(for credentialsKey: String) -> String {
        "\(credentialsKey)#management"
    }

    private var currentBaseURLForLinks: URL? {
        if let activeConfiguration {
            return activeConfiguration.baseURL
        }
        return Self.resolveConfiguration(
            baseURLString: baseURLString,
            statusPageSlugOverride: statusPageSlug,
            connectionMode: connectionMode
        )?.baseURL
    }

    private func makeWebAppURL(fragment: String) -> URL? {
        guard var components = currentBaseURLForLinks.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else {
            return nil
        }
        components.fragment = fragment
        return components.url
    }
}

private struct ResolvedConfiguration {
    let baseURL: URL
    let credentialsKey: String
    let savedBaseURL: String
    let connectionMode: UptimeKumaConnectionMode
    let preferredStatusPageSlug: String?
    let savedStatusPageSlug: String
}

enum UptimeKumaConnectionMode: String, CaseIterable, Identifiable {
    case publicStatusPage = "public"
    case privateServer = "private"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .publicStatusPage:
            return "Public"
        case .privateServer:
            return "Private"
        }
    }
}

enum UptimeKumaPrivateAuthMethod: String, CaseIterable, Identifiable {
    case apiKey = "apikey"
    case webSession = "websession"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apiKey:
            return "API Key"
        case .webSession:
            return "Web Session"
        }
    }
}

enum UptimeKumaDashboardStyle: String, CaseIterable, Identifiable {
    case compactList = "compact"
    case statusCards = "cards"
    case analytics = "analytics"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compactList:
            return "Compact"
        case .statusCards:
            return "Cards"
        case .analytics:
            return "Analytics"
        }
    }
}

enum UptimeKumaMenuIconStyle: String, CaseIterable, Identifiable {
    case rack = "rack"
    case pulse = "pulse"
    case shield = "shield"
    case cloud = "cloud"
    case gauge = "gauge"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rack:
            return "Rack"
        case .pulse:
            return "Pulse"
        case .shield:
            return "Shield"
        case .cloud:
            return "Cloud"
        case .gauge:
            return "Gauge"
        }
    }

    var symbolName: String {
        switch self {
        case .rack:
            return "server.rack"
        case .pulse:
            return "waveform.path.ecg"
        case .shield:
            return "shield.fill"
        case .cloud:
            return "cloud.fill"
        case .gauge:
            return "gauge.with.dots.needle.67percent"
        }
    }
}

private struct BasicAuthCredentials: Codable {
    let username: String
    let password: String

    var authorizationHeaderValue: String {
        let joined = "\(username):\(password)"
        let data = Data(joined.utf8)
        return "Basic \(data.base64EncodedString())"
    }
}

struct MonitorStatus: Identifiable {
    let id: Int
    let name: String
    let state: MonitorState
    let ping: Double?
    let target: String?

    var pingText: String? {
        guard let ping else { return nil }
        return "\(Int(ping.rounded())) ms"
    }
}

enum MonitorState: Equatable {
    case up
    case down
    case pending
    case maintenance
    case unknown

    init(code: Int?) {
        switch code {
        case 0:
            self = .down
        case 1:
            self = .up
        case 2:
            self = .pending
        case 3:
            self = .maintenance
        default:
            self = .unknown
        }
    }

    var title: String {
        switch self {
        case .up:
            return "Up"
        case .down:
            return "Down"
        case .pending:
            return "Pending"
        case .maintenance:
            return "Maint."
        case .unknown:
            return "Unknown"
        }
    }

    var symbolName: String {
        switch self {
        case .up:
            return "checkmark.circle.fill"
        case .down:
            return "xmark.circle.fill"
        case .pending:
            return "clock.fill"
        case .maintenance:
            return "wrench.and.screwdriver.fill"
        case .unknown:
            return "questionmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .up:
            return .green
        case .down:
            return .red
        case .pending:
            return .orange
        case .maintenance:
            return .yellow
        case .unknown:
            return .gray
        }
    }

    fileprivate var rawValueForSnapshot: String {
        switch self {
        case .up:
            return "up"
        case .down:
            return "down"
        case .pending:
            return "pending"
        case .maintenance:
            return "maintenance"
        case .unknown:
            return "unknown"
        }
    }
}

private enum UptimeKumaClient {
    private static let requestTimeout: TimeInterval = 12
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        configuration.httpShouldSetCookies = true
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        return URLSession(configuration: configuration)
    }()
    private static let logger = Logger(subsystem: "uptime.UptimeKuma-Mac", category: "network")

    static func fetchMonitors(
        baseURL: URL,
        connectionMode: UptimeKumaConnectionMode,
        preferredStatusPageSlug: String?,
        credentials: BasicAuthCredentials?
    ) async throws -> [MonitorStatus] {
        if connectionMode == .publicStatusPage {
            debug("Connection mode public: skipping /metrics and using status-page APIs")
            return try await fetchMonitorsFromStatusPageAPIFallback(
                baseURL: baseURL,
                preferredStatusPageSlug: preferredStatusPageSlug,
                credentials: nil
            )
        }

        let metricsURL = baseURL.appendingPathComponent("metrics")
        debug("Trying metrics endpoint: \(metricsURL.absoluteString)")
        let metricsData = try await data(for: metricsURL, credentials: credentials)
        return try MetricsParser.parseMonitors(from: metricsData)
    }

    private static func fetchMonitorsFromStatusPageAPIFallback(
        baseURL: URL,
        preferredStatusPageSlug: String?,
        credentials: BasicAuthCredentials?
    ) async throws -> [MonitorStatus] {
        let candidateSlugs = statusPageSlugCandidates(preferredStatusPageSlug, baseURL: baseURL)
        var lastError: Error?

        // Some Uptime Kuma setups expose default status page on no-slug endpoints.
        do {
            debug("Trying status-page API with no slug")
            return try await fetchMonitorsFromStatusPageAPIWithoutSlug(
                baseURL: baseURL,
                credentials: credentials
            )
        } catch {
            debug("No-slug status-page API failed: \(error.localizedDescription)")
            lastError = error
        }

        for candidate in candidateSlugs {
            do {
                debug("Trying status-page API with slug: \(candidate)")
                return try await fetchMonitorsFromStatusPageAPI(
                    baseURL: baseURL,
                    statusPageSlug: candidate,
                    credentials: credentials
                )
            } catch {
                debug("Status-page API failed for slug \(candidate): \(error.localizedDescription)")
                lastError = error
            }
        }

        throw lastError ?? UptimeKumaError.metricsUnavailable
    }

    private static func statusPageSlugCandidates(_ preferred: String?, baseURL: URL) -> [String] {
        var candidates: [String] = []

        if let preferred = preferred?.trimmingCharacters(in: .whitespacesAndNewlines), !preferred.isEmpty {
            candidates.append(preferred)
        }

        // Heuristic fallback slugs derived from host names (e.g. status.callumstorrents.dev -> callumstorrents).
        let hostParts = (baseURL.host ?? "")
            .split(separator: ".")
            .map(String.init)
            .filter { !$0.isEmpty }
        for part in hostParts where part.lowercased() != "status" && part.lowercased() != "www" {
            if !candidates.contains(part) {
                candidates.append(part)
            }
        }

        if !candidates.contains("default") {
            candidates.append("default")
        }
        if !candidates.contains("status") {
            candidates.append("status")
        }
        return candidates
    }

    private static func fetchMonitorsFromStatusPageAPIWithoutSlug(
        baseURL: URL,
        credentials: BasicAuthCredentials?
    ) async throws -> [MonitorStatus] {
        let statusPageURL = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("status-page")

        let heartbeatURL = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("status-page")
            .appendingPathComponent("heartbeat")

        return try await fetchMonitorsFromStatusPageEndpoints(
            statusPageURL: statusPageURL,
            heartbeatURL: heartbeatURL,
            slugLabel: "<none>",
            credentials: credentials
        )
    }

    private static func fetchMonitorsFromStatusPageAPI(
        baseURL: URL,
        statusPageSlug: String,
        credentials: BasicAuthCredentials?
    ) async throws -> [MonitorStatus] {
        let statusPageURL = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("status-page")
            .appendingPathComponent(statusPageSlug)

        let heartbeatURL = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("status-page")
            .appendingPathComponent("heartbeat")
            .appendingPathComponent(statusPageSlug)

        return try await fetchMonitorsFromStatusPageEndpoints(
            statusPageURL: statusPageURL,
            heartbeatURL: heartbeatURL,
            slugLabel: statusPageSlug,
            credentials: credentials
        )
    }

    private static func fetchMonitorsFromStatusPageEndpoints(
        statusPageURL: URL,
        heartbeatURL: URL,
        slugLabel: String,
        credentials: BasicAuthCredentials?
    ) async throws -> [MonitorStatus] {
        debug("Status-page endpoints: meta=\(statusPageURL.absoluteString) heartbeat=\(heartbeatURL.absoluteString)")

        let heartbeatData = try await data(for: heartbeatURL, credentials: credentials)
        let heartbeatRowsByMonitor = HeartbeatParser.parseRowsByMonitor(from: heartbeatData)
        if heartbeatRowsByMonitor.isEmpty {
            debug("Heartbeat parse returned zero monitor rows for slug \(slugLabel). Body snippet: \(bodySnippet(from: heartbeatData))")
            throw UptimeKumaError.metricsUnavailable
        }

        var monitorMetadataByID: [Int: (name: String, target: String?)] = [:]
        do {
            let decoder = JSONDecoder()
            let statusPageData = try await data(for: statusPageURL, credentials: credentials)
            let statusPage = try decoder.decode(StatusPageResponse.self, from: statusPageData)
            for group in statusPage.publicGroupList {
                for monitor in group.monitorList {
                    monitorMetadataByID[monitor.id] = (name: monitor.name, target: monitor.resolvedTarget)
                }
            }
        } catch {
            debug("Status-page metadata timed out/failed; using heartbeat-only fallback for slug \(slugLabel)")
        }

        var collected: [MonitorStatus] = []
        for (monitorID, points) in heartbeatRowsByMonitor {
            let latestPoint = points.max(by: { lhs, rhs in
                let lhsTimestamp = lhs[safe: 0].flatMap { $0 } ?? .zero
                let rhsTimestamp = rhs[safe: 0].flatMap { $0 } ?? .zero
                return lhsTimestamp < rhsTimestamp
            })

            let stateCode = latestPoint?[safe: 1].flatMap { $0 }.map { Int($0.rounded()) }
            let ping = latestPoint?[safe: 2].flatMap { $0 }
            let metadata = monitorMetadataByID[monitorID]
            let name = metadata?.name ?? "Monitor \(monitorID)"
            let target = metadata?.target

            let item = MonitorStatus(
                id: monitorID,
                name: name,
                state: MonitorState(code: stateCode),
                ping: ping,
                target: target
            )
            collected.append(item)
        }

        guard !collected.isEmpty else {
            throw UptimeKumaError.metricsUnavailable
        }

        return collected.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func data(for url: URL, credentials: BasicAuthCredentials?) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        var hasAuthHeader = false
        if let credentials {
            request.setValue(credentials.authorizationHeaderValue, forHTTPHeaderField: "Authorization")
            hasAuthHeader = true
        }

        let data: Data
        let response: URLResponse
        do {
            let cookieCount = HTTPCookieStorage.shared.cookies(for: url)?.count ?? 0
            debug("HTTP GET \(url.absoluteString) authHeader=\(hasAuthHeader) cookies=\(cookieCount)")
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            debug("Request timed out: \(url.absoluteString)")
            throw UptimeKumaError.timedOut
        } catch let error as URLError where
            error.code == .notConnectedToInternet ||
            error.code == .networkConnectionLost ||
            error.code == .cannotFindHost ||
            error.code == .cannotConnectToHost ||
            error.code == .dnsLookupFailed
        {
            debug("Network unavailable for \(url.absoluteString): \(error.localizedDescription)")
            throw UptimeKumaError.networkUnavailable
        } catch let error as URLError where
            error.code == .serverCertificateUntrusted ||
            error.code == .serverCertificateHasBadDate ||
            error.code == .serverCertificateNotYetValid ||
            error.code == .secureConnectionFailed
        {
            debug("TLS validation failed for \(url.absoluteString): \(error.localizedDescription)")
            throw UptimeKumaError.tlsValidationFailed
        }

        guard let httpResponse = response as? HTTPURLResponse else { return data }
        debug("HTTP \(httpResponse.statusCode) \(url.absoluteString)")
        guard httpResponse.statusCode != 401, httpResponse.statusCode != 403 else {
            throw UptimeKumaError.unauthorized
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw UptimeKumaError.httpStatus(httpResponse.statusCode)
        }
        return data
    }

    private static func debug(_ message: String) {
        logger.log("\(message, privacy: .public)")
        print("[Kuma/Network] \(message)")
    }

    private static func bodySnippet(from data: Data) -> String {
        guard var text = String(data: data, encoding: .utf8) else {
            return "<non-utf8 \(data.count) bytes>"
        }
        text = text.replacingOccurrences(of: "\n", with: " ")
        if text.count > 280 {
            return String(text.prefix(280)) + "..."
        }
        return text
    }
}

private enum UptimeKumaSocketAPI {
    private static let logger = Logger(subsystem: "uptime.UptimeKuma-Mac", category: "socket")

    static func addHTTPMonitor(
        baseURL: URL,
        username: String,
        password: String,
        name: String,
        targetURL: String,
        intervalSeconds: Int
    ) async throws -> Int {
        let socketURL = try makeSocketURL(from: baseURL)
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: socketURL)
        task.resume()
        defer {
            task.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }

        _ = try await waitForEngineOpen(task)
        try await sendText("40", on: task)
        _ = try await waitForNamespaceConnect(task)

        try await sendEvent(
            event: "login",
            payload: [
                "username": username,
                "password": password,
                "token": "",
            ],
            ackID: 1,
            on: task
        )
        let loginAck = try await waitForAck(id: 1, on: task)
        guard ackOK(loginAck) else {
            throw UptimeKumaError.addMonitorUnavailable(ackMessage(loginAck) ?? "Login failed for monitor-management API.")
        }

        let payload: [String: Any] = [
            "type": "http",
            "name": name,
            "url": targetURL,
            "method": "GET",
            "timeout": 48,
            "interval": intervalSeconds,
            "retryInterval": 60,
            "resendInterval": 0,
            "maxretries": 0,
            "maxredirects": 10,
            "accepted_statuscodes": ["200-299"],
            "ignoreTls": false,
            "upsideDown": false,
            "notificationIDList": [String: Any](),
            "dns_resolve_type": "A",
            "dns_resolve_server": "1.1.1.1",
            "httpBodyEncoding": "json",
        ]
        try await sendEvent(event: "add", payload: payload, ackID: 2, on: task)
        let addAck = try await waitForAck(id: 2, on: task)
        guard ackOK(addAck) else {
            throw UptimeKumaError.addMonitorUnavailable(ackMessage(addAck) ?? "Failed to add monitor.")
        }

        return ackMonitorID(addAck) ?? 0
    }

    private static func makeSocketURL(from baseURL: URL) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw UptimeKumaError.addMonitorUnavailable("Invalid host URL.")
        }

        if components.path.isEmpty || components.path == "/" {
            components.path = "/socket.io/"
        } else {
            let trimmedPath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
            components.path = "\(trimmedPath)/socket.io/"
        }
        components.scheme = (components.scheme == "https") ? "wss" : "ws"
        components.queryItems = [
            URLQueryItem(name: "EIO", value: "4"),
            URLQueryItem(name: "transport", value: "websocket"),
        ]

        guard let socketURL = components.url else {
            throw UptimeKumaError.addMonitorUnavailable("Could not construct socket URL.")
        }
        return socketURL
    }

    private static func sendEvent(event: String, payload: [String: Any], ackID: Int, on task: URLSessionWebSocketTask) async throws {
        let eventPayload = [event, payload] as [Any]
        let data = try JSONSerialization.data(withJSONObject: eventPayload)
        guard let json = String(data: data, encoding: .utf8) else {
            throw UptimeKumaError.addMonitorUnavailable("Could not encode API payload.")
        }
        try await sendText("42\(ackID)\(json)", on: task)
    }

    private static func sendText(_ text: String, on task: URLSessionWebSocketTask) async throws {
        try await task.send(.string(text))
        logger.log("Socket send: \(safeSocketFrameSummary(text), privacy: .public)")
    }

    private static func waitForEngineOpen(_ task: URLSessionWebSocketTask) async throws -> String {
        for _ in 0 ..< 20 {
            let text = try await receiveText(on: task, timeoutSeconds: 10)
            if text == "2" {
                try await sendText("3", on: task)
                continue
            }
            if text.hasPrefix("0") {
                return text
            }
        }
        throw UptimeKumaError.timedOut
    }

    private static func waitForNamespaceConnect(_ task: URLSessionWebSocketTask) async throws -> String {
        for _ in 0 ..< 30 {
            let text = try await receiveText(on: task, timeoutSeconds: 10)
            if text == "2" {
                try await sendText("3", on: task)
                continue
            }
            if text.hasPrefix("40") {
                return text
            }
            if text.hasPrefix("44") {
                throw UptimeKumaError.addMonitorUnavailable("Socket namespace rejected by server.")
            }
        }
        throw UptimeKumaError.timedOut
    }

    private static func waitForAck(id: Int, on task: URLSessionWebSocketTask) async throws -> Any? {
        for _ in 0 ..< 80 {
            let text = try await receiveText(on: task, timeoutSeconds: 12)
            if text == "2" {
                try await sendText("3", on: task)
                continue
            }
            if let ack = parseAckPacket(text), ack.id == id {
                return ack.payload
            }
        }
        throw UptimeKumaError.timedOut
    }

    private static func receiveText(on task: URLSessionWebSocketTask, timeoutSeconds: TimeInterval) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                let message = try await task.receive()
                switch message {
                case let .string(text):
                    logger.log("Socket recv: \(safeSocketFrameSummary(text), privacy: .public)")
                    return text
                case let .data(data):
                    let text = String(data: data, encoding: .utf8) ?? ""
                    logger.log("Socket recv: \(safeSocketFrameSummary(text), privacy: .public)")
                    return text
                @unknown default:
                    return ""
                }
            }

            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                throw UptimeKumaError.timedOut
            }

            guard let first = try await group.next() else {
                throw UptimeKumaError.timedOut
            }
            group.cancelAll()
            return first
        }
    }

    private static func parseAckPacket(_ text: String) -> (id: Int, payload: Any?)? {
        guard text.hasPrefix("43") else { return nil }
        let body = String(text.dropFirst(2))
        let digits = body.prefix(while: { $0.isNumber })
        guard let id = Int(digits) else { return nil }
        let jsonStart = body.index(body.startIndex, offsetBy: digits.count)
        let jsonText = String(body[jsonStart...])
        guard !jsonText.isEmpty else { return (id, nil) }
        let payload = try? JSONSerialization.jsonObject(with: Data(jsonText.utf8))
        return (id, payload)
    }

    private static func safeSocketFrameSummary(_ text: String) -> String {
        let size = text.utf8.count
        if text == "2" { return "ping (\(size)b)" }
        if text == "3" { return "pong (\(size)b)" }
        if text.hasPrefix("0") { return "engine-open (\(size)b)" }
        if text.hasPrefix("40") { return "namespace-open (\(size)b)" }
        if text.hasPrefix("43") { return "ack (\(size)b)" }
        if text.hasPrefix("42") {
            if let eventName = socketEventName(fromFrame: text) {
                return "event:\(eventName) (\(size)b)"
            }
            return "event (\(size)b)"
        }
        return "frame (\(size)b)"
    }

    private static func socketEventName(fromFrame text: String) -> String? {
        guard text.hasPrefix("42") else { return nil }
        let body = String(text.dropFirst(2))
        guard let jsonStart = body.firstIndex(of: "[") else { return nil }
        let json = String(body[jsonStart...])
        guard
            let data = json.data(using: .utf8),
            let payload = try? JSONSerialization.jsonObject(with: data) as? [Any],
            let eventName = payload.first as? String
        else {
            return nil
        }
        return eventName
    }

    private static func ackObject(_ ack: Any?) -> [String: Any]? {
        if let object = ack as? [String: Any] {
            return object
        }
        if let list = ack as? [Any], let first = list.first as? [String: Any] {
            return first
        }
        return nil
    }

    private static func ackOK(_ ack: Any?) -> Bool {
        if let ok = ackObject(ack)?["ok"] as? Bool {
            return ok
        }
        return false
    }

    private static func ackMessage(_ ack: Any?) -> String? {
        if let message = ackObject(ack)?["msg"] as? String {
            return message
        }
        if let message = ackObject(ack)?["message"] as? String {
            return message
        }
        return nil
    }

    private static func ackMonitorID(_ ack: Any?) -> Int? {
        if let monitorID = ackObject(ack)?["monitorID"] as? Int {
            return monitorID
        }
        if let monitorID = ackObject(ack)?["monitorId"] as? Int {
            return monitorID
        }
        if let monitorID = ackObject(ack)?["id"] as? Int {
            return monitorID
        }
        return nil
    }
}

private struct StatusPageResponse: Decodable {
    let publicGroupList: [PublicGroup]

    private enum CodingKeys: String, CodingKey {
        case publicGroupList
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        publicGroupList = try container.decodeIfPresent([PublicGroup].self, forKey: .publicGroupList) ?? []
    }
}

private struct PublicGroup: Decodable {
    let monitorList: [Monitor]

    private enum CodingKeys: String, CodingKey {
        case monitorList
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        monitorList = try container.decodeIfPresent([Monitor].self, forKey: .monitorList) ?? []
    }
}

private struct Monitor: Decodable {
    let id: Int
    let name: String
    let url: String?
    let hostname: String?
    let pathName: String?
    let port: Int?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case url
        case hostname
        case pathName
        case path
        case port
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        hostname = try container.decodeIfPresent(String.self, forKey: .hostname)
        pathName = try container.decodeIfPresent(String.self, forKey: .pathName)
            ?? container.decodeIfPresent(String.self, forKey: .path)
        if let portValue = try container.decodeIfPresent(Int.self, forKey: .port) {
            port = portValue
        } else if let portString = try container.decodeIfPresent(String.self, forKey: .port), let parsed = Int(portString) {
            port = parsed
        } else {
            port = nil
        }
    }

    var resolvedTarget: String? {
        if let url = url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty {
            return url
        }
        guard let host = hostname?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else {
            return nil
        }
        let normalizedHost = host.hasPrefix("http://") || host.hasPrefix("https://") ? host : "https://\(host)"
        let withPort = (port != nil) ? "\(normalizedHost):\(port!)" : normalizedHost
        if let pathName = pathName?.trimmingCharacters(in: .whitespacesAndNewlines), !pathName.isEmpty {
            let path = pathName.hasPrefix("/") ? pathName : "/\(pathName)"
            return "\(withPort)\(path)"
        }
        return withPort
    }
}

private struct HeartbeatResponse: Decodable {
    let heartbeatList: [String: [[Double?]]]
}

private enum HeartbeatParser {
    nonisolated static func parseRowsByMonitor(from data: Data) -> [Int: [[Double?]]] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }

        var parsed: [Int: [[Double?]]] = [:]
        if let heartbeatList = object["heartbeatList"] {
            extractMonitorRows(from: heartbeatList, into: &parsed)
        }

        if parsed.isEmpty, let uptimeList = object["uptimeList"] as? [String: Any] {
            for key in uptimeList.keys {
                guard let id = Int(key) else { continue }
                parsed[id] = []
            }
        }

        return parsed
    }

    private nonisolated static func extractMonitorRows(from value: Any, into output: inout [Int: [[Double?]]]) {
        if let dictionary = value as? [String: Any] {
            for (key, nested) in dictionary {
                if let monitorID = Int(key) {
                    let rows = parseRows(from: nested)
                    if output[monitorID] == nil {
                        output[monitorID] = rows
                    } else {
                        output[monitorID]?.append(contentsOf: rows)
                    }
                } else {
                    extractMonitorRows(from: nested, into: &output)
                }
            }
            return
        }

        if let array = value as? [Any] {
            for nested in array {
                extractMonitorRows(from: nested, into: &output)
            }
        }
    }

    private nonisolated static func parseRows(from value: Any) -> [[Double?]] {
        if let rows = value as? [[Any]] {
            return rows.compactMap(parseRow(from:))
        }

        if let rows = value as? [Any] {
            return rows.compactMap { element in
                if let row = element as? [Any] {
                    return parseRow(from: row)
                }
                if let row = element as? [String: Any] {
                    return parseRow(from: row)
                }
                return nil
            }
        }

        if let dictionary = value as? [String: Any] {
            return parseRow(from: dictionary).map { [$0] } ?? []
        }

        return []
    }

    private nonisolated static func parseRow(from value: [Any]) -> [Double?]? {
        let time = value.indices.contains(0) ? toDouble(value[0]) : nil
        let status = value.indices.contains(1) ? toDouble(value[1]) : nil
        let ping = value.indices.contains(2) ? toDouble(value[2]) : nil

        if time == nil, status == nil, ping == nil {
            return nil
        }
        return [time, status, ping]
    }

    private nonisolated static func parseRow(from value: [String: Any]) -> [Double?]? {
        let time = toDouble(value["time"]) ?? toDouble(value["timestamp"]) ?? toDouble(value["date"])
        let status = toDouble(value["status"]) ?? toDouble(value["statusCode"])
        let ping = toDouble(value["ping"]) ?? toDouble(value["ms"]) ?? toDouble(value["responseTime"])

        if time == nil, status == nil, ping == nil {
            return nil
        }
        return [time, status, ping]
    }

    private nonisolated static func toDouble(_ value: Any?) -> Double? {
        guard let value else { return nil }
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}

private enum MetricsParser {
    private static let metricPattern = try! NSRegularExpression(
        pattern: #"^([A-Za-z_:][A-Za-z0-9_:]*)(?:\{([^}]*)\})?\s+([-+]?\d*\.?\d+(?:[eE][-+]?\d+)?)$"#
    )

    static func parseMonitors(from data: Data) throws -> [MonitorStatus] {
        guard let payload = String(data: data, encoding: .utf8) else {
            throw UptimeKumaError.metricsUnavailable
        }

        var statusesByKey: [String: (name: String, monitorID: Int?, stateCode: Int?, target: String?)] = [:]
        var pingByKey: [String: Double] = [:]

        for rawLine in payload.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let metric = parseMetricLine(line) else { continue }

            guard metric.metricName == "monitor_status" || metric.metricName == "monitor_response_time" else {
                continue
            }

            let monitorName = metric.labels["monitor_name"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !monitorName.isEmpty else { continue }

            let monitorID = Int(metric.labels["monitor_id"] ?? "")
            let key = monitorKey(name: monitorName, monitorID: monitorID)
            let target = monitorTarget(from: metric.labels)

            if metric.metricName == "monitor_status" {
                statusesByKey[key] = (
                    name: monitorName,
                    monitorID: monitorID,
                    stateCode: Int(metric.value.rounded()),
                    target: target
                )
            } else {
                pingByKey[key] = metric.value
                if let existing = statusesByKey[key], existing.target == nil, let target {
                    statusesByKey[key] = (
                        name: existing.name,
                        monitorID: existing.monitorID,
                        stateCode: existing.stateCode,
                        target: target
                    )
                }
            }
        }

        guard !statusesByKey.isEmpty else {
            throw UptimeKumaError.metricsUnavailable
        }

        let monitors = statusesByKey.map { key, status in
            MonitorStatus(
                id: status.monitorID ?? stableIdentifier(for: key),
                name: status.name,
                state: MonitorState(code: status.stateCode),
                ping: pingByKey[key],
                target: status.target
            )
        }

        return monitors.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func parseMetricLine(_ line: String) -> ParsedMetric? {
        let searchRange = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = metricPattern.firstMatch(in: line, range: searchRange) else {
            return nil
        }

        guard
            let metricName = capture(match, at: 1, in: line),
            let valueString = capture(match, at: 3, in: line),
            let value = Double(valueString)
        else {
            return nil
        }

        let labels = capture(match, at: 2, in: line).map { parseLabels($0) } ?? [:]
        return ParsedMetric(metricName: metricName, labels: labels, value: value)
    }

    private static func capture(_ match: NSTextCheckingResult, at index: Int, in source: String) -> String? {
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: source) else {
            return nil
        }
        return String(source[swiftRange])
    }

    private static func parseLabels(_ raw: String) -> [String: String] {
        var labels: [String: String] = [:]
        var tokens: [String] = []
        var currentToken = ""
        var inQuotes = false
        var escaped = false

        for character in raw {
            if escaped {
                currentToken.append(character)
                escaped = false
                continue
            }

            if character == "\\" {
                currentToken.append(character)
                escaped = true
                continue
            }

            if character == "\"" {
                inQuotes.toggle()
                currentToken.append(character)
                continue
            }

            if character == "," && !inQuotes {
                tokens.append(currentToken)
                currentToken = ""
                continue
            }

            currentToken.append(character)
        }

        if !currentToken.isEmpty {
            tokens.append(currentToken)
        }

        for token in tokens {
            let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }

            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            }
            value = value
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
                .replacingOccurrences(of: "\\n", with: "\n")

            labels[key] = value
        }

        return labels
    }

    private static func monitorKey(name: String, monitorID: Int?) -> String {
        if let monitorID {
            return "id:\(monitorID)"
        }
        return "name:\(name)"
    }

    private static func monitorTarget(from labels: [String: String]) -> String? {
        for key in ["monitor_url", "url", "monitor_hostname", "hostname", "domain"] {
            if let value = labels[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                if value.hasPrefix("http://") || value.hasPrefix("https://") {
                    return value
                }
                if key.contains("url") {
                    return value
                }
                return "https://\(value)"
            }
        }
        return nil
    }

    private static func stableIdentifier(for key: String) -> Int {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Int(hash & 0x7fff_ffff)
    }

    private struct ParsedMetric {
        let metricName: String
        let labels: [String: String]
        let value: Double
    }
}

private struct CredentialsKeychainStore {
    private let service = "uptimekuma.basic-auth"

    func save(_ credentials: BasicAuthCredentials, for key: String) throws {
        let data = try JSONEncoder().encode(credentials)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        SecItemDelete(query as CFDictionary)

        var newItem = query
        newItem[kSecValueData as String] = data
        let status = SecItemAdd(newItem as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CredentialsKeychainError.unexpectedStatus(status)
        }
    }

    func load(for key: String) throws -> BasicAuthCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var output: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &output)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess else {
            throw CredentialsKeychainError.unexpectedStatus(status)
        }
        guard let data = output as? Data else { return nil }
        return try JSONDecoder().decode(BasicAuthCredentials.self, from: data)
    }

    func delete(for key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialsKeychainError.unexpectedStatus(status)
        }
    }
}

private enum CredentialsKeychainError: Error {
    case unexpectedStatus(OSStatus)
}

private enum UptimeKumaError: LocalizedError {
    case unauthorized
    case timedOut
    case networkUnavailable
    case tlsValidationFailed
    case metricsUnavailable
    case httpStatus(Int)
    case addMonitorUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Authentication required."
        case .timedOut:
            return "Connection timed out."
        case .networkUnavailable:
            return "Network unavailable."
        case .tlsValidationFailed:
            return "TLS certificate validation failed."
        case .metricsUnavailable:
            return "No monitor metrics found in server response."
        case let .httpStatus(statusCode):
            return "Uptime Kuma API returned HTTP \(statusCode)."
        case let .addMonitorUnavailable(message):
            return message
        }
    }
}
