import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: UptimeKumaStatusStore
    @Environment(\.dismiss) private var dismiss
    @State private var revealPassword = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Button("Cancel") {
                        dismiss()
                    }
                    Spacer()
                    Button("Test Connection") {
                        store.refreshNow()
                    }
                    .disabled(!store.hasConfiguration)

                    Button("Use Demo Server") {
                        store.useDemoServerForReview()
                    }

                    Button("Save & Connect") {
                        store.saveSettings()
                        store.refreshNow()
                    }
                    .keyboardShortcut(.defaultAction)
                }

                Text("Uptime Kuma Server")
                    .font(.system(size: 46, weight: .bold, design: .rounded))

                card {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(connectionStatusColor)
                            .frame(width: 8, height: 8)
                        Text(connectionStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                sectionTitle("Server Info")
                card {
                    row("Type") {
                        Picker("Type", selection: $store.connectionMode) {
                            ForEach(UptimeKumaConnectionMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    Divider()
                    row("Display Name") {
                        TextField("name", text: $store.displayName)
                            .multilineTextAlignment(.trailing)
                    }
                    Divider()
                    row("Host") {
                        TextField("http://127.0.0.1:3001", text: $store.baseURLString)
                            .multilineTextAlignment(.trailing)
                    }
                    if store.connectionMode == .publicStatusPage {
                        Divider()
                        row("Status Page Slug") {
                            TextField("optional (default)", text: $store.statusPageSlug)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
                Text(store.connectionMode == .publicStatusPage
                    ? "Public mode uses status-page endpoints. Set slug only if it is not `default`."
                    : "Private mode uses authenticated server endpoints and does not require a status-page slug.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("HTTP is supported for local hosts/IPs only. Use HTTPS for remote servers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if store.connectionMode == .privateServer {
                    sectionTitle("Authentication")
                    card {
                        row("Method") {
                            Text("API Key")
                                .foregroundStyle(.secondary)
                        }
                        Divider()
                        row("Metrics API Key") {
                            Group {
                                if revealPassword {
                                    TextField("api key", text: $store.metricsAPIKey)
                                } else {
                                    SecureField("api key", text: $store.metricsAPIKey)
                                }
                            }
                            .multilineTextAlignment(.trailing)
                        }
                        Divider()
                        row("Get API Key") {
                            if let apiKeysURL = store.apiKeysURL {
                                Link("Open /settings/api-keys", destination: apiKeysURL)
                            } else {
                                Text("Enter valid host first")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                        row("Mgmt User") {
                            TextField("admin username", text: $store.managementUsername)
                                .multilineTextAlignment(.trailing)
                        }
                        Divider()
                        row("Mgmt Password") {
                            Group {
                                if revealPassword {
                                    TextField("admin password", text: $store.managementPassword)
                                } else {
                                    SecureField("admin password", text: $store.managementPassword)
                                }
                            }
                            .multilineTextAlignment(.trailing)
                        }
                    }
                    Text("Management credentials are used only for in-app monitor creation via the internal API.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button {
                            revealPassword.toggle()
                        } label: {
                            Label(revealPassword ? "Hide" : "Reveal", systemImage: revealPassword ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain)
                        .tint(.blue)
                    }
                }

                sectionTitle("Connectivity")
                card {
                    Toggle("Launch at Login", isOn: $store.launchAtLogin)
                    Divider()
                    Toggle("Connect Over WiFi Only", isOn: $store.connectOverWiFiOnly)
                }

                sectionTitle("Power Users")
                card {
                    row("Polling Interval") {
                        Stepper(value: $store.pollingIntervalSeconds, in: 5 ... 300, step: 1) {
                            Text("\(store.pollingIntervalSeconds)s")
                                .monospacedDigit()
                        }
                        .labelsHidden()
                    }
                }
                Text("Minimum is 5 seconds to avoid performance issues.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                sectionTitle("Quick Actions")
                card {
                    if let dashboardURL = store.dashboardURL {
                        Link("Open Dashboard", destination: dashboardURL)
                    } else {
                        Text("Open Dashboard")
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                    if let addMonitorURL = store.addMonitorURL {
                        Link("Add Monitor", destination: addMonitorURL)
                    } else {
                        Text("Add Monitor")
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                    if let apiKeysURL = store.apiKeysURL {
                        Link("API Keys", destination: apiKeysURL)
                    } else {
                        Text("API Keys")
                            .foregroundStyle(.secondary)
                    }
                }

                sectionTitle("Appearance")
                card {
                    row("Menu View") {
                        Picker("Menu View", selection: $store.dashboardStyle) {
                            ForEach(UptimeKumaDashboardStyle.allCases) { style in
                                Text(style.title).tag(style)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    Divider()
                    row("Menu Icon") {
                        Picker("Menu Icon", selection: $store.menuIconStyle) {
                            ForEach(UptimeKumaMenuIconStyle.allCases) { iconStyle in
                                Label(iconStyle.title, systemImage: iconStyle.symbolName)
                                    .tag(iconStyle)
                            }
                        }
                        .labelsHidden()
                    }
                }

                if store.isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Connecting to server...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let errorMessage = store.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if !store.monitors.isEmpty {
                    Text("Connected. Loaded \(store.monitors.count) monitor statuses.")
                        .font(.caption)
                        .foregroundStyle(.green)
                }

                if !store.debugLogLines.isEmpty {
                    sectionTitle("Connection Logs")
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(store.debugLogLines.suffix(30).enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 160)
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                Button("Forget Saved Credentials") {
                    store.clearSavedCredentials()
                }
                .buttonStyle(.plain)
            }
            .padding(20)
        }
        .onSubmit {
            store.saveSettings()
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.title3)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 10, content: content)
            .padding(14)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
            Spacer(minLength: 12)
            content()
                .frame(maxWidth: 260)
        }
    }

    private var connectionStatusText: String {
        if store.isLoading {
            return "Connecting..."
        }
        if let error = store.errorMessage, !error.isEmpty {
            return error
        }
        if !store.monitors.isEmpty {
            return "Connected • \(store.monitors.count) monitors loaded"
        }
        return store.hasConfiguration ? "Ready to connect" : "Add host and API key to connect"
    }

    private var connectionStatusColor: Color {
        if store.isLoading {
            return .orange
        }
        if store.errorMessage != nil {
            return .red
        }
        if !store.monitors.isEmpty {
            return .green
        }
        return .secondary
    }
}
