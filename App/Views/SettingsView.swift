import SwiftUI

struct SettingsView: View {
    @ObservedObject var serverController: ServerController
    @State private var selectedSection: SettingsSection? = .general

    enum SettingsSection: String, CaseIterable, Identifiable {
        case general = "General"
        case http = "HTTP MCP"

        var id: String { self.rawValue }

        var icon: String {
            switch self {
            case .general: return "gear"
            case .http: return "network"
            }
        }
    }

    var body: some View {
        NavigationView {
            List(
                selection: .init(
                    get: { selectedSection },
                    set: { section in
                        selectedSection = section
                    }
                )
            ) {
                Section {
                    ForEach(SettingsSection.allCases) { section in
                        Label(section.rawValue, systemImage: section.icon)
                            .tag(section)
                    }
                }
            }

            if let selectedSection {
                switch selectedSection {
                case .general:
                    GeneralSettingsView(serverController: serverController)
                        .navigationTitle("General")
                        .formStyle(.grouped)
                case .http:
                    HTTPSettingsView(serverController: serverController)
                        .navigationTitle("HTTP MCP")
                        .formStyle(.grouped)
                }
            } else {
                Text("Select a category")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            Text("")
        }
        .task {
            let window = NSApplication.shared.keyWindow
            window?.toolbarStyle = .unified
            window?.toolbar?.displayMode = .iconOnly
        }
        .onAppear {
            if selectedSection == nil, let firstSection = SettingsSection.allCases.first {
                selectedSection = firstSection
            }
        }
    }

}

struct GeneralSettingsView: View {
    @ObservedObject var serverController: ServerController
    @State private var showingResetAlert = false
    @State private var selectedClients = Set<String>()

    private var trustedClients: [String] {
        serverController.getTrustedClients()
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Trusted Clients")
                            .font(.headline)
                        Spacer()
                        if !trustedClients.isEmpty {
                            Button("Remove All") {
                                showingResetAlert = true
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                        }
                    }

                    Text("Clients that automatically connect without approval.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 4)

                if trustedClients.isEmpty {
                    HStack {
                        Text("No trusted clients")
                            .foregroundStyle(.secondary)
                            .italic()
                        Spacer()
                    }
                    .padding(.vertical, 8)
                } else {
                    List(trustedClients, id: \.self, selection: $selectedClients) { client in
                        HStack {
                            Text(client)
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                        }
                        .contextMenu {
                            Button("Remove Client", role: .destructive) {
                                serverController.removeTrustedClient(client)
                            }
                        }
                    }
                    .frame(minHeight: 100, maxHeight: 200)
                    .onDeleteCommand {
                        for clientID in selectedClients {
                            serverController.removeTrustedClient(clientID)
                        }
                        selectedClients.removeAll()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .alert("Remove All Trusted Clients", isPresented: $showingResetAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Remove All", role: .destructive) {
                serverController.resetTrustedClients()
                selectedClients.removeAll()
            }
        } message: {
            Text(
                "This will remove all trusted clients. They will need to be approved again when connecting."
            )
        }
    }
}

// MARK: - HTTP MCP Settings

struct HTTPSettingsView: View {
    @ObservedObject var serverController: ServerController
    @State private var portText: String = ""
    @State private var showingRegenerateAlert = false
    @State private var copiedAPIKey = false
    @State private var copiedURL = false

    var body: some View {
        Form {
            // 服务器状态
            Section {
                HStack {
                    Text("Server Status")
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(
                                serverController.httpServerStatus == "Running"
                                    ? Color.green : Color.red
                            )
                            .frame(width: 8, height: 8)
                        Text(serverController.httpServerStatus)
                            .foregroundStyle(.secondary)
                    }
                }

                if let url = serverController.httpConnectionURL {
                    HStack {
                        Text("Connection URL")
                        Spacer()
                        HStack(spacing: 4) {
                            Text(url)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url, forType: .string)
                                copiedURL = true
                                Task {
                                    try? await Task.sleep(for: .seconds(2))
                                    copiedURL = false
                                }
                            } label: {
                                Image(systemName: copiedURL ? "checkmark" : "doc.on.doc")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .help("Copy URL")
                        }
                    }
                }
            } header: {
                Text("Status")

            } footer: {
                Text(
                    "Clients on the local network can connect to this MCP server using the URL above."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            // API Key
            Section {
                HStack {
                    Text("API Key")
                    Spacer()
                    HStack(spacing: 4) {
                        SecureField("API Key", text: .constant(serverController.getAPIKey()))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .disabled(true)

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                serverController.getAPIKey(), forType: .string)
                            copiedAPIKey = true
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                copiedAPIKey = false
                            }
                        } label: {
                            Image(systemName: copiedAPIKey ? "checkmark" : "doc.on.doc")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("Copy API Key")
                    }
                }

                Button("Regenerate API Key") {
                    showingRegenerateAlert = true
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
            } header: {
                Text("Authentication")
            } footer: {
                Text(
                    "Use this API key with 'Authorization: Bearer <key>' or 'x-api-key' header when connecting to the server."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            // 端口配置
            Section {
                HStack {
                    Text("Port")
                    Spacer()
                    TextField("Port", text: $portText)
                        .frame(width: 80)
                        .onAppear {
                            portText = String(serverController.getHTTPPort())
                        }
                }

                Button("Apply") {
                    if let port = Int(portText), port > 0, port <= 65535 {
                        Task {
                            await serverController.setHTTPPort(port)
                        }
                    }
                }
                .disabled(portText == String(serverController.getHTTPPort()))
            } header: {
                Text("Port Configuration")
            } footer: {
                Text("Changing the port will restart the HTTP MCP server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .alert("Regenerate API Key", isPresented: $showingRegenerateAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Regenerate", role: .destructive) {
                Task {
                    await serverController.regenerateAPIKey()
                }
            }
        } message: {
            Text("This will invalidate the current API key. All clients will need the new key to connect.")
        }
    }
}
