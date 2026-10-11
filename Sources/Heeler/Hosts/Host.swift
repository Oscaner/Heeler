import Foundation

/// One way to reach a Host (ADR 0022): the address to dial, and optionally a
/// Jump Host in front of it and an Overlay Network carrying the first hop. A
/// Host lists one or more; the Console races them and keeps whichever reaches
/// the Host first, so a Host can be dialled on its LAN address at home and
/// through an Overlay Network or Jump Host elsewhere without any rule saying
/// which applies where.
struct HostRoute: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var address: String
    var port: Int
    /// Optional Jump Host this route goes through. Blank means the device
    /// dials `address`/`port` itself; when set, they are resolved from the
    /// Jump Host and normally point at a loopback port held open by a
    /// reverse tunnel.
    var jumpAddress: String
    var jumpPort: Int
    /// Account on the Jump Host. Blank reuses the Host's `username`, which is
    /// the common case only when both machines share an account name.
    var jumpUsername: String
    /// Optional Overlay Network carrying the first hop — the Host, or the
    /// Jump Host when one is set (ADR 0021). nil dials over the device's own
    /// network. With an overlay, the first hop's address is its overlay IP or
    /// name (MagicDNS, for Tailscale).
    var overlayNetworkID: UUID?

    init(
        id: UUID = UUID(),
        address: String,
        port: Int = 22,
        jumpAddress: String = "",
        jumpPort: Int = 22,
        jumpUsername: String = "",
        overlayNetworkID: UUID? = nil
    ) {
        self.id = id
        self.address = address
        self.port = port
        self.jumpAddress = jumpAddress
        self.jumpPort = jumpPort
        self.jumpUsername = jumpUsername
        self.overlayNetworkID = overlayNetworkID
    }

    /// Whether this route goes through a Jump Host.
    var usesJumpHost: Bool {
        !jumpAddress.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The address the device itself dials: the Jump Host's when there is
    /// one, otherwise the Host's. An Overlay Network carries this hop.
    var firstHopAddress: String {
        usesJumpHost ? jumpAddress : address
    }

    /// `address`, with the port when it is not 22.
    var endpointDescription: String {
        port == 22 ? address : "\(address):\(port)"
    }

    /// One line naming how this route reaches the Host:
    /// `100.64.0.5 · home`, `127.0.0.1:2222 via vps.example`.
    func summary(networkName: (UUID) -> String) -> String {
        var summary = endpointDescription
        if usesJumpHost {
            let jump = jumpAddress.trimmingCharacters(in: .whitespaces)
            summary += " via \(jumpPort == 22 ? jump : "\(jump):\(jumpPort)")"
        }
        if let overlayNetworkID {
            summary += " · \(networkName(overlayNetworkID))"
        }
        return summary
    }
}

/// A user-added Host (CONTEXT.md): who the machine is, how to authenticate,
/// which herdr session to reach, and the Routes it can be reached on. Never
/// carries a secret — the password lives in the Keychain keyed by `id`, and
/// private keys live in `DeviceKeyStore` or `RSAKeyStore`.
struct Host: Identifiable, Codable, Hashable, Sendable {
    /// How the app authenticates against this Host. OpenSSH key import is
    /// deliberately absent (out of scope per spec #20).
    enum AuthMethod: String, Codable, Sendable {
        case deviceKey
        case rsaKey
        case password
    }

    let id: UUID
    /// Optional display label; blank falls back to `user@address`.
    var name: String
    var username: String
    var authMethod: AuthMethod
    /// Persisted session selection; onboarding discovers available sessions,
    /// while this field remains editable for older herdr versions. Blank
    /// means the default herdr session.
    var sessionName: String
    /// The ways to reach this Host, in the user's order: never empty. The
    /// first is the primary route, which names the Host where one address
    /// is shown and is what builds without Routes connect to.
    var routes: [HostRoute]

    /// `socatPath` is deliberately absent: Hosts serialized before ADR 0011
    /// still carry it on disk, and leaving it out of the keys both ignores it
    /// on decode and drops it on the Host's next save.
    private enum CodingKeys: String, CodingKey {
        case id, name, username, authMethod, sessionName
        case routes
        // The primary route, flattened as Hosts were saved before Routes
        // (ADR 0022), so a build without them still decodes and connects it.
        case address, port, jumpAddress, jumpPort, jumpUsername
        case overlayNetworkID
    }

    init(
        id: UUID = UUID(),
        name: String = "",
        username: String,
        authMethod: AuthMethod = .deviceKey,
        sessionName: String = "",
        routes: [HostRoute]
    ) {
        precondition(!routes.isEmpty, "A Host needs at least one route")
        self.id = id
        self.name = name
        self.username = username
        self.authMethod = authMethod
        self.sessionName = sessionName
        self.routes = routes
    }

    /// A Host with a single route, as every Host was before Routes.
    init(
        id: UUID = UUID(),
        name: String = "",
        address: String,
        port: Int = 22,
        username: String,
        authMethod: AuthMethod = .deviceKey,
        sessionName: String = "",
        jumpAddress: String = "",
        jumpPort: Int = 22,
        jumpUsername: String = "",
        overlayNetworkID: UUID? = nil
    ) {
        self.init(
            id: id,
            name: name,
            username: username,
            authMethod: authMethod,
            sessionName: sessionName,
            routes: [
                HostRoute(
                    id: id,
                    address: address,
                    port: port,
                    jumpAddress: jumpAddress,
                    jumpPort: jumpPort,
                    jumpUsername: jumpUsername,
                    overlayNetworkID: overlayNetworkID)
            ])
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        username = try container.decode(String.self, forKey: .username)
        let authMethodValue = try container.decode(String.self, forKey: .authMethod)
        guard let decodedAuthMethod = AuthMethod(rawValue: authMethodValue) else {
            throw DecodingError.dataCorruptedError(
                forKey: .authMethod,
                in: container,
                debugDescription: "Unknown authentication method: \(authMethodValue)")
        }
        authMethod = decodedAuthMethod
        sessionName = try container.decodeIfPresent(String.self, forKey: .sessionName) ?? ""
        if let routes = try container.decodeIfPresent([HostRoute].self, forKey: .routes),
           !routes.isEmpty
        {
            self.routes = routes
        } else {
            // Saved before Routes, or since by a build without them (which
            // drops `routes`): the flat fields are the Host's one route. It
            // takes the Host's id, so decoding it again names the same route.
            routes = [
                HostRoute(
                    id: id,
                    address: try container.decode(String.self, forKey: .address),
                    port: try container.decode(Int.self, forKey: .port),
                    // Absent in Hosts saved before jump-host support; a blank
                    // address decodes as the direct connection they had.
                    jumpAddress: try container.decodeIfPresent(String.self, forKey: .jumpAddress)
                        ?? "",
                    jumpPort: try container.decodeIfPresent(Int.self, forKey: .jumpPort) ?? 22,
                    jumpUsername: try container.decodeIfPresent(
                        String.self, forKey: .jumpUsername) ?? "",
                    // Absent in Hosts saved before Overlay Networks.
                    overlayNetworkID: try container.decodeIfPresent(
                        UUID.self, forKey: .overlayNetworkID))
            ]
        }

        let trimmedSessionName = sessionName.trimmingCharacters(in: .whitespaces)
        guard trimmedSessionName.isEmpty || HerdrSessionName.isValid(trimmedSessionName) else {
            throw DecodingError.dataCorruptedError(
                forKey: .sessionName, in: container, debugDescription: "Invalid herdr session name")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(username, forKey: .username)
        try container.encode(authMethod, forKey: .authMethod)
        try container.encode(sessionName, forKey: .sessionName)
        try container.encode(routes, forKey: .routes)
        let primary = primaryRoute
        try container.encode(primary.address, forKey: .address)
        try container.encode(primary.port, forKey: .port)
        try container.encode(primary.jumpAddress, forKey: .jumpAddress)
        try container.encode(primary.jumpPort, forKey: .jumpPort)
        try container.encode(primary.jumpUsername, forKey: .jumpUsername)
        try container.encodeIfPresent(primary.overlayNetworkID, forKey: .overlayNetworkID)
    }

    /// The first route: the one that names the Host where a single address
    /// is shown.
    var primaryRoute: HostRoute {
        // `routes` is never empty; the fallback only satisfies the compiler.
        routes.first ?? HostRoute(id: id, address: "")
    }

    /// The primary route's address.
    var address: String { primaryRoute.address }

    /// The primary route's port.
    var port: Int { primaryRoute.port }

    /// The Jump Host account on `route`, falling back to the Host's own
    /// username.
    func jumpUsername(on route: HostRoute) -> String {
        let trimmed = route.jumpUsername.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? username : trimmed
    }

    /// Whether `address` names this Host on any of its routes, ignoring
    /// case and surrounding spaces.
    func answers(toAddress address: String) -> Bool {
        let wanted = address.trimmingCharacters(in: .whitespaces)
        return routes.contains {
            $0.address.trimmingCharacters(in: .whitespaces)
                .caseInsensitiveCompare(wanted) == .orderedSame
        }
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "\(username)@\(address)" : trimmed
    }

    /// The herdr socket this Host's session name points at.
    var socketLocation: HerdrSocketLocation {
        let trimmed = sessionName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? .defaultSession : .namedSession(trimmed)
    }
}
