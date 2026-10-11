import SwiftUI

/// Add/edit form for a Host. Device-key auth shows the copyable
/// `authorized_keys` line (generated on device, never exported beyond its
/// public half); the password goes straight to the Keychain via `HostStore`.
struct HostFormView: View {
    let store: HostStore
    var editing: Host?
    var onSaved: ((Host) -> Void)?
    /// Starts in User, for a prefill that already says where the Host is.
    var focusesUsername = false

    @State private var draft: HostDraft
    @State private var authorizedKeysLine: String?
    @State private var rsaPublicKeyLine: String?
    @State private var didCopyKeyLine = false
    @State private var saveFailed = false
    @State private var deviceKeyIsCorrupt = false
    @State private var rsaKeyIsCorrupt = false
    @State private var isConfirmingDeviceKeyReplacement = false
    @State private var isConfirmingRSAKeyReplacement = false
    @State private var deviceKeyReplacementError: String?
    @State private var rsaKeyReplacementError: String?
    /// The route page on screen, for a Host with more than one route.
    @State private var routePath: [HostRouteDraft.ID] = []
    @State private var isChoosingOverlayPeer = false
    @FocusState private var isUsernameFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private let credentials = HostCredentialsProvider()

    init(store: HostStore, editing: Host? = nil, onSaved: ((Host) -> Void)? = nil) {
        self.store = store
        self.editing = editing
        self.onSaved = onSaved
        _draft = State(initialValue: editing.map(HostDraft.init) ?? HostDraft())
    }

    /// Adds a new Host starting from `prefill`, as Duplicate does: saving
    /// never touches the Host the draft was copied from.
    init(
        store: HostStore, prefill: HostDraft, focusesUsername: Bool = false,
        onSaved: ((Host) -> Void)? = nil
    ) {
        self.store = store
        self.editing = nil
        self.onSaved = onSaved
        self.focusesUsername = focusesUsername
        _draft = State(initialValue: prefill)
    }

    var body: some View {
        NavigationStack(path: $routePath) {
            Form {
                formSections
            }
            .overlayPeerPicker(
                isPresented: $isChoosingOverlayPeer, route: draft.primaryRoute,
                otherHosts: otherHosts
            ) { candidate, style in
                draft.applyOverlayPeer(candidate, style: style)
            }
            .navigationDestination(for: HostRouteDraft.ID.self) { routeID in
                HostRouteFormView(draft: $draft, routeID: routeID, otherHosts: otherHosts)
            }
            .navigationTitle(editing == nil ? "Add Host" : "Edit Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!draft.canSave(editing: editing))
                }
            }
            .alert("Could not save the Host", isPresented: $saveFailed) {
                Button("OK", role: .cancel) {}
            }
            .alert(
                "Could not replace the Device Key",
                isPresented: Binding(
                    get: { deviceKeyReplacementError != nil },
                    set: { if !$0 { deviceKeyReplacementError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deviceKeyReplacementError ?? "")
            }
            .alert(
                "Could not replace the RSA Key",
                isPresented: Binding(
                    get: { rsaKeyReplacementError != nil },
                    set: { if !$0 { rsaKeyReplacementError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(rsaKeyReplacementError ?? "")
            }
            .confirmationDialog(
                "Replace the Device Key?",
                isPresented: $isConfirmingDeviceKeyReplacement,
                titleVisibility: .visible
            ) {
                Button("Replace Device Key", role: .destructive) { replaceDeviceKey() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "Every Host using Device Key authentication will reject the replacement "
                        + "until you add its new public key to ~/.ssh/authorized_keys.")
            }
            .confirmationDialog(
                "Replace the RSA Key?",
                isPresented: $isConfirmingRSAKeyReplacement,
                titleVisibility: .visible
            ) {
                Button("Replace RSA Key", role: .destructive) { replaceRSAKey() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "Every Host using RSA Key authentication will reject the replacement "
                        + "until you register its new public key on that Host.")
            }
            .task {
                if focusesUsername { isUsernameFocused = true }
                loadDeviceKey()
                if draft.authMethod == .rsaKey {
                    loadRSAKey()
                }
            }
        }
        .onChange(of: routePath) { previous, current in
            for id in previous where !current.contains(id) {
                draft.discardRouteIfBlank(id: id)
            }
        }
    }

    /// Split out of `body` so the type checker sees two smaller
    /// expressions instead of one very long modifier chain.
    @ViewBuilder
    private var formSections: some View {
        Section("Host") {
            TextField("Name (optional)", text: $draft.name)
            TextField("User", text: $draft.username)
                .textContentType(.username)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($isUsernameFocused)
        }

        if draft.routes.count == 1 {
            HostRouteFields(
                route: $draft.primaryRoute,
                authMethod: draft.authMethod,
                isChoosingOverlayPeer: $isChoosingOverlayPeer)
        } else {
            routesSection
        }

        authenticationSection

        Section {
            TextField("Session name", text: $draft.sessionName)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        } header: {
            Text("herdr Session")
        } footer: {
            Text("Leave blank for the default herdr session.")
        }

        if draft.routes.count == 1 {
            Section {
                addRouteButton
            } footer: {
                Text(
                    "Add another way to reach this Host, such as its LAN address at home and "
                        + "an overlay network or Jump Host elsewhere.")
            }
        }
    }

    /// A Host with more than one route lists them; each opens its own page.
    private var routesSection: some View {
        Section {
            ForEach(Array(draft.routes.enumerated()), id: \.element.id) { index, route in
                NavigationLink(value: route.id) {
                    HostRouteRow(route: route, index: index)
                }
            }
            .onDelete { draft.removeRoutes(atOffsets: $0) }
            .onMove { draft.moveRoutes(fromOffsets: $0, toOffset: $1) }
            addRouteButton
        } header: {
            Text("Routes")
        } footer: {
            Text(
                "Heeler tries every route each time it connects and uses the first that "
                    + "reaches the Host. Routes over this device's own network start first; "
                    + "the rest start a moment later. Swipe to delete; hold and drag to reorder.")
        }
    }

    private var addRouteButton: some View {
        Button {
            routePath.append(draft.addRoute())
        } label: {
            Label("Add Route", systemImage: "plus")
        }
    }

    /// The Host being edited is not another Host for the peer picker to tag.
    private var otherHosts: [Host] {
        store.hosts.filter { $0.id != editing?.id }
    }

    private var authenticationSection: some View {
        Section {
            Picker("Method", selection: $draft.authMethod) {
                Text("Device Key").tag(Host.AuthMethod.deviceKey)
                Text("RSA Key").tag(Host.AuthMethod.rsaKey)
                Text("Password").tag(Host.AuthMethod.password)
            }
            .onChange(of: draft.authMethod) {
                didCopyKeyLine = false
                if draft.authMethod == .rsaKey,
                   rsaPublicKeyLine == nil,
                   !rsaKeyIsCorrupt
                {
                    loadRSAKey()
                }
            }
            switch draft.authMethod {
            case .deviceKey:
                deviceKeySection
            case .rsaKey:
                rsaKeySection
            case .password:
                SecureField(
                    editing == nil ? "Password" : "Password (blank keeps current)",
                    text: $draft.password)
            }
        } header: {
            Text("Authentication")
        } footer: {
            switch draft.authMethod {
            case .deviceKey:
                Text(
                    "Add this line to ~/.ssh/authorized_keys on the Host. "
                        + "The private key never leaves this device.")
            case .rsaKey:
                Text(
                    "Register this public key wherever the Host accepts SSH identities. "
                        + "The private key never leaves this device.")
            case .password:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var deviceKeySection: some View {
        if let authorizedKeysLine {
            Text(authorizedKeysLine)
                .font(.caption.monospaced())
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Button {
                UIPasteboard.general.string = authorizedKeysLine
                didCopyKeyLine = true
            } label: {
                Label(
                    didCopyKeyLine ? "Copied" : "Copy authorized_keys Line",
                    systemImage: didCopyKeyLine ? "checkmark" : "doc.on.doc")
            }
        } else {
            Label(
                deviceKeyIsCorrupt ? "Device key is corrupted" : "Device key unavailable",
                systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
            if deviceKeyIsCorrupt {
                Button("Replace Device Key", role: .destructive) {
                    isConfirmingDeviceKeyReplacement = true
                }
            } else {
                Button("Try Again") { loadDeviceKey() }
            }
        }
    }

    @ViewBuilder
    private var rsaKeySection: some View {
        if let rsaPublicKeyLine {
            Text(rsaPublicKeyLine)
                .font(.caption.monospaced())
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Button {
                UIPasteboard.general.string = rsaPublicKeyLine
                didCopyKeyLine = true
            } label: {
                Label(
                    didCopyKeyLine ? "Copied" : "Copy RSA Public Key",
                    systemImage: didCopyKeyLine ? "checkmark" : "doc.on.doc")
            }
        } else {
            Label(
                rsaKeyIsCorrupt ? "RSA Key is corrupted" : "RSA Key unavailable",
                systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
            if !rsaKeyIsCorrupt {
                Button("Try Again") { loadRSAKey() }
            } else {
                Button("Replace RSA Key", role: .destructive) {
                    isConfirmingRSAKeyReplacement = true
                }
            }
        }
    }

    private func loadDeviceKey() {
        do {
            let key = try credentials.deviceKey()
            authorizedKeysLine = key.authorizedKeysLine(comment: "heeler")
            deviceKeyIsCorrupt = false
        } catch DeviceKeyStoreError.storedKeyCorrupt {
            authorizedKeysLine = nil
            deviceKeyIsCorrupt = true
        } catch {
            authorizedKeysLine = nil
            deviceKeyIsCorrupt = false
        }
    }

    private func loadRSAKey() {
        do {
            let key = try credentials.rsaKey()
            rsaPublicKeyLine = key.authorizedKeysLine(comment: "heeler rsa")
            rsaKeyIsCorrupt = false
        } catch RSAKeyStoreError.storedKeyCorrupt {
            rsaPublicKeyLine = nil
            rsaKeyIsCorrupt = true
        } catch {
            rsaPublicKeyLine = nil
            rsaKeyIsCorrupt = false
        }
    }

    private func replaceDeviceKey() {
        do {
            let key = try credentials.replaceDeviceKey()
            authorizedKeysLine = key.authorizedKeysLine(comment: "heeler")
            deviceKeyIsCorrupt = false
            didCopyKeyLine = false
        } catch {
            deviceKeyReplacementError = "The replacement could not be saved to the Keychain."
        }
    }

    private func replaceRSAKey() {
        do {
            let key = try credentials.replaceRSAKey()
            rsaPublicKeyLine = key.authorizedKeysLine(comment: "heeler rsa")
            rsaKeyIsCorrupt = false
            didCopyKeyLine = false
        } catch {
            rsaKeyReplacementError = "The replacement could not be saved to the Keychain."
        }
    }

    private func save() {
        guard draft.canSave(editing: editing) else { return }
        guard let host = draft.makeHost(id: editing?.id ?? UUID()) else { return }
        do {
            if editing == nil {
                try store.add(host, password: draft.passwordUpdate)
            } else {
                try store.update(host, password: draft.passwordUpdate)
            }
        } catch {
            saveFailed = true
            return
        }
        dismiss()
        onSaved?(host)
    }
}
