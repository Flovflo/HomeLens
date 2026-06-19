import CryptoKit
import Foundation

/// Snapshot of whether the motion/person detection that TRIGGERS HomeKit Secure
/// Video is actually working, and the current state. Surfaced in diagnostics.
public struct DetectionProbe: Sendable {
    public let available: Bool
    public let source: String
    public let motion: Bool
    public let person: Bool
    public let detail: String
}

public final class ONVIFClient: @unchecked Sendable {
    public init() {}

    /// Probe the detection trigger (Reolink HTTP API preferred, ONVIF as fallback)
    /// so the UI can show whether HSV will actually be triggered by motion.
    public func detectionStatus(camera: CameraConfig, password: String?) async -> DetectionProbe {
        if let password, !password.isEmpty {
            do {
                let session = ReolinkSession()
                let state = try await reolinkDetectionState(camera: camera, password: password, session: session)
                return DetectionProbe(
                    available: true,
                    source: "Reolink HTTP (token)",
                    motion: state.motion,
                    person: state.person,
                    detail: "mouvement \(state.motion ? "actif" : "inactif"), personne \(state.person ? "détectée" : "non détectée")"
                )
            } catch let error as ReolinkFallbackError {
                switch error {
                case .locked(let seconds):
                    return DetectionProbe(available: false, source: "Reolink HTTP", motion: false, person: false,
                                          detail: "API verrouillée (\(Int(seconds))s) — trop d'échecs de connexion")
                case .notReolink:
                    break // try ONVIF below
                default:
                    return DetectionProbe(available: false, source: "Reolink HTTP", motion: false, person: false,
                                          detail: error.localizedDescription)
                }
            } catch {
                return DetectionProbe(available: false, source: "Reolink HTTP", motion: false, person: false,
                                      detail: error.localizedDescription)
            }
        }
        // Fallback: can we at least reach ONVIF? (events are unreliable on Reolink)
        if let deviceURL = camera.onvifURL, (try? await getCapabilities(camera: camera, password: password, url: deviceURL)) != nil {
            return DetectionProbe(available: true, source: "ONVIF", motion: false, person: false,
                                  detail: "ONVIF joignable (événements peu fiables sur Reolink)")
        }
        return DetectionProbe(available: false, source: "—", motion: false, person: false,
                              detail: "Aucune source de détection disponible")
    }

    public func test(camera: CameraConfig, password: String?) async -> ServiceTestResult {
        guard let url = camera.onvifURL else {
            return ServiceTestResult(ok: false, title: "Invalid ONVIF URL", detail: "Could not build an ONVIF URL from the camera config.")
        }

        do {
            let response = try await getCapabilities(camera: camera, password: password, url: url)
            if response.localizedCaseInsensitiveContains("GetCapabilitiesResponse") ||
                response.localizedCaseInsensitiveContains("Capabilities") {
                let eventAddress = extractFirst(pattern: #"<[^>]*XAddr[^>]*>([^<]*event[^<]*)</"#, from: response)
                let mediaAddress = extractFirst(pattern: #"<[^>]*XAddr[^>]*>([^<]*media[^<]*)</"#, from: response)
                let detail = [
                    "Device service answered.",
                    eventAddress.map { "Event service: \($0)" },
                    mediaAddress.map { "Media service: \($0)" }
                ]
                .compactMap { $0 }
                .joined(separator: " ")
                return ServiceTestResult(ok: true, title: "ONVIF reachable", detail: detail)
            }
            return ServiceTestResult(ok: false, title: "ONVIF unexpected response", detail: String(response.prefix(220)))
        } catch {
            return ServiceTestResult(ok: false, title: "ONVIF failed", detail: error.localizedDescription)
        }
    }

    public func runEventLoop(
        camera: CameraConfig,
        password: String?,
        logger: EventLogger,
        stopAfterOneCycle: Bool = false,
        onEvent: (@Sendable (DetectionEvent) -> Void)? = nil
    ) async {
        logger.log(.info, "Bridge", "Starting detection monitor for \(camera.name) at \(camera.host).")
        // Reolink's ONVIF pull-point events are unreliable on many firmwares
        // (PullMessages returns SOAP 400), so prefer the camera's native HTTP
        // detection API — token-authenticated, polled continuously, no
        // repeated-login lockouts. Fall back to ONVIF only if this isn't a
        // reachable Reolink HTTP endpoint.
        if let password, !password.isEmpty {
            if await runReolinkPolling(
                camera: camera, password: password, logger: logger,
                stopAfterOneCycle: stopAfterOneCycle, onEvent: onEvent
            ) {
                return
            }
            logger.log(.warning, "Detection", "Native Reolink API unavailable; falling back to ONVIF events.")
            if stopAfterOneCycle { return }
        }
        await runONVIFLoop(
            camera: camera, password: password, logger: logger,
            stopAfterOneCycle: stopAfterOneCycle, onEvent: onEvent
        )
    }

    /// Continuously polls the Reolink HTTP detection API (motion + AI person).
    /// Returns true if it ran (until cancellation / one cycle); false if the
    /// endpoint is not a usable Reolink API so the caller should try ONVIF.
    private func runReolinkPolling(
        camera: CameraConfig,
        password: String,
        logger: EventLogger,
        stopAfterOneCycle: Bool,
        onEvent: (@Sendable (DetectionEvent) -> Void)?
    ) async -> Bool {
        let session = ReolinkSession()
        var previous: ReolinkDetectionState?
        var announced = false
        var everSucceeded = false
        var earlyFailures = 0

        while !Task.isCancelled {
            do {
                let state = try await reolinkDetectionState(camera: camera, password: password, session: session)
                if !announced {
                    logger.log(.info, "Reolink", "Detection via native Reolink HTTP API (token).")
                    announced = true
                }
                everSucceeded = true
                earlyFailures = 0
                forwardReolinkChanges(previous: previous, current: state, onEvent: onEvent, logger: logger)
                previous = state
                if stopAfterOneCycle { return true }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            } catch let error as ReolinkFallbackError {
                switch error {
                case .locked(let seconds):
                    logger.log(.warning, "Reolink", "HTTP API locked (\(Int(seconds))s) — pausing before retry.")
                    session.invalidate()
                    if stopAfterOneCycle { return everSucceeded }
                    try? await Task.sleep(nanoseconds: UInt64(max(5, seconds)) * 1_000_000_000)
                case .notReolink:
                    return false
                case .tokenExpired:
                    session.invalidate()
                default:
                    earlyFailures += 1
                    if !everSucceeded && earlyFailures >= 3 { return false }
                    session.invalidate()
                    if stopAfterOneCycle { return everSucceeded }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            } catch {
                earlyFailures += 1
                if !everSucceeded && earlyFailures >= 3 { return false }
                if stopAfterOneCycle { return everSucceeded }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        return true
    }

    private func runONVIFLoop(
        camera: CameraConfig,
        password: String?,
        logger: EventLogger,
        stopAfterOneCycle: Bool,
        onEvent: (@Sendable (DetectionEvent) -> Void)?
    ) async {
        var backoffSeconds: UInt64 = 2
        while !Task.isCancelled {
            do {
                try await pullEvents(
                    camera: camera,
                    password: password,
                    logger: logger,
                    stopAfterOneCycle: stopAfterOneCycle,
                    onEvent: onEvent
                )
                backoffSeconds = 2
                if stopAfterOneCycle { return }
            } catch {
                logger.log(.warning, "ONVIF", "Event loop reconnecting after failure: \(error.localizedDescription)")
                if stopAfterOneCycle { return }
                try? await Task.sleep(nanoseconds: backoffSeconds * 1_000_000_000)
                backoffSeconds = min(backoffSeconds * 2, 60)
            }
        }
    }

    private func pullEvents(
        camera: CameraConfig,
        password: String?,
        logger: EventLogger,
        stopAfterOneCycle: Bool,
        onEvent: (@Sendable (DetectionEvent) -> Void)?
    ) async throws {
        guard let deviceURL = camera.onvifURL else {
            throw ONVIFError.invalidURL
        }

        logger.log(.debug, "ONVIF", "Requesting capabilities from \(deviceURL.absoluteString).")
        let capabilities = try await getCapabilities(camera: camera, password: password, url: deviceURL)
        let eventURLString = extractFirst(pattern: #"<[^>]*XAddr[^>]*>([^<]*event[^<]*)</"#, from: capabilities)
        let eventURL = eventURLString.flatMap(URL.init(string:)) ?? deviceURL

        logger.log(.debug, "ONVIF", "Creating pull-point subscription at \(eventURL.absoluteString).")
        let subscription = try await postSOAP(
            url: eventURL,
            action: "http://www.onvif.org/ver10/events/wsdl/EventPortType/CreatePullPointSubscriptionRequest",
            envelope: SOAPEnvelope.createPullPoint(username: camera.username, password: password ?? "")
        )

        let pullPointURLString = extractFirst(pattern: #"<[^>]*Address[^>]*>([^<]+)</"#, from: subscription)
        let pullPointURL = pullPointURLString.flatMap(URL.init(string:)) ?? eventURL
        logger.log(.info, "ONVIF", "Subscribed to pull-point events at \(pullPointURL.absoluteString).")

        while !Task.isCancelled {
            logger.log(.debug, "ONVIF", "Pulling event messages.")
            let messages = try await postSOAP(
                url: pullPointURL,
                action: "http://www.onvif.org/ver10/events/wsdl/PullPointSubscription/PullMessagesRequest",
                envelope: SOAPEnvelope.pullMessages(
                    username: camera.username,
                    password: password ?? "",
                    timeout: stopAfterOneCycle ? "PT3S" : "PT10S"
                ),
                timeout: stopAfterOneCycle ? 6 : 14
            )
            let events = parseDetectionEvents(from: messages)
            for event in events {
                onEvent?(event)
                logger.log(.info, "Event", "\(event.kind.rawValue) \(event.active ? "active" : "inactive")")
            }
            if stopAfterOneCycle {
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func getCapabilities(camera: CameraConfig, password: String?, url: URL) async throws -> String {
        try await postSOAP(
            url: url,
            action: "http://www.onvif.org/ver10/device/wsdl/GetCapabilities",
            envelope: SOAPEnvelope.getCapabilities(username: camera.username, password: password ?? "")
        )
    }

    private func postSOAP(url: URL, action: String, envelope: String, timeout: TimeInterval = 8) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/soap+xml; charset=utf-8; action=\"\(action)\"", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(addAddressing(to: envelope, action: action, url: url).utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ONVIFError.http(http.statusCode, body)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func addAddressing(to envelope: String, action: String, url: URL) -> String {
        let addressing = """
        <wsa:Action xmlns:wsa="http://www.w3.org/2005/08/addressing" s:mustUnderstand="1">\(action.xmlEscaped)</wsa:Action><wsa:To xmlns:wsa="http://www.w3.org/2005/08/addressing" s:mustUnderstand="1">\(url.absoluteString.xmlEscaped)</wsa:To>
        """
        return envelope.replacingOccurrences(of: "<s:Header>", with: "<s:Header>\(addressing)")
    }

    private func reolinkDetectionState(camera: CameraConfig, password: String, session: ReolinkSession) async throws -> ReolinkDetectionState {
        let token = try await reolinkToken(camera: camera, password: password, session: session)
        async let motionData = reolinkCommand("GetMdState", camera: camera, token: token)
        async let aiData = reolinkCommand("GetAiState", camera: camera, token: token)
        return try await ReolinkDetectionState(
            motion: parseReolinkMotion(try motionData),
            person: parseReolinkPerson(try aiData)
        )
    }

    /// Reolink's HTTP API needs a token login (inline user/password is refused and,
    /// after repeated failures, locks the account). Log in once, cache the token
    /// for its lease, and reuse it — no lockouts.
    private func reolinkToken(camera: CameraConfig, password: String, session: ReolinkSession) async throws -> String {
        if let token = session.token, Date() < session.expiry {
            return token
        }
        let url = try reolinkURL(camera: camera, query: [URLQueryItem(name: "cmd", value: "Login")])
        let body: [[String: Any]] = [[
            "cmd": "Login",
            "param": ["User": ["userName": camera.username, "password": password]],
        ]]
        let first = try await reolinkPOST(url: url, json: body)
        if let code = first["code"] as? Int, code != 0 {
            if let detail = recursiveValue(forAny: ["detail"], in: first) as? String,
               detail.lowercased().contains("lock") {
                let unlock = (recursiveValue(forAny: ["unlock_time"], in: first) as? NSNumber)?.doubleValue ?? 60
                throw ReolinkFallbackError.locked(unlock)
            }
            throw ReolinkFallbackError.invalidResponse
        }
        guard let value = first["value"],
              let token = recursiveValue(forAny: ["name"], in: value) as? String, !token.isEmpty else {
            throw ReolinkFallbackError.invalidResponse
        }
        let lease = (recursiveValue(forAny: ["leaseTime"], in: value) as? NSNumber)?.doubleValue ?? 3600
        session.token = token
        session.expiry = Date().addingTimeInterval(max(60, lease - 60))
        return token
    }

    private func reolinkCommand(_ command: String, camera: CameraConfig, token: String) async throws -> Any {
        let url = try reolinkURL(camera: camera, query: [
            URLQueryItem(name: "cmd", value: command),
            URLQueryItem(name: "token", value: token),
        ])
        let body: [[String: Any]] = [["cmd": command, "param": ["channel": 0]]]
        let first = try await reolinkPOST(url: url, json: body)
        if let code = first["code"] as? Int, code != 0 {
            throw ReolinkFallbackError.tokenExpired
        }
        return first["value"] ?? first
    }

    private func reolinkURL(camera: CameraConfig, query: [URLQueryItem]) throws -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = camera.host
        components.path = "/cgi-bin/api.cgi"
        components.queryItems = query
        guard let url = components.url else {
            throw ReolinkFallbackError.invalidURL
        }
        return url
    }

    private func reolinkPOST(url: URL, json: [[String: Any]]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 {
                throw ReolinkFallbackError.notReolink
            }
            if !(200..<300).contains(http.statusCode) {
                throw ReolinkFallbackError.http(http.statusCode)
            }
        }
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = array.first else {
            throw ReolinkFallbackError.notReolink
        }
        return first
    }
}

private final class ReolinkSession: @unchecked Sendable {
    var token: String?
    var expiry: Date = .distantPast
    func invalidate() {
        token = nil
        expiry = .distantPast
    }
}

private struct ReolinkDetectionState {
    let motion: Bool
    let person: Bool
}

private enum ReolinkFallbackError: LocalizedError {
    case missingCredentials
    case invalidURL
    case http(Int)
    case invalidResponse
    case locked(TimeInterval)
    case notReolink
    case tokenExpired

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Camera credentials are unavailable."
        case .invalidURL:
            "Could not build the Reolink API URL."
        case .http(let status):
            "Reolink API HTTP status \(status)."
        case .invalidResponse:
            "Reolink API returned an unexpected response."
        case .locked(let seconds):
            "Reolink login temporarily locked (\(Int(seconds))s)."
        case .notReolink:
            "Not a reachable Reolink HTTP API."
        case .tokenExpired:
            "Reolink session token expired."
        }
    }
}

private func forwardReolinkChanges(
    previous: ReolinkDetectionState?,
    current: ReolinkDetectionState,
    onEvent: (@Sendable (DetectionEvent) -> Void)?,
    logger: EventLogger
) {
    if previous?.motion != current.motion {
        let event = DetectionEvent(kind: .motion, active: current.motion)
        onEvent?(event)
        logger.log(.info, "Event", "motion \(current.motion ? "active" : "inactive") (Reolink fallback)")
    }
    if previous?.person != current.person {
        let event = DetectionEvent(kind: .person, active: current.person)
        onEvent?(event)
        logger.log(.info, "Event", "person \(current.person ? "active" : "inactive") (Reolink fallback)")
    }
}

private func parseReolinkMotion(_ object: Any) throws -> Bool {
    guard let state = recursiveValue(for: "state", in: object) else {
        throw ReolinkFallbackError.invalidResponse
    }
    return booleanValue(state)
}

private func parseReolinkPerson(_ object: Any) throws -> Bool {
    guard let person = recursiveValue(forAny: ["people", "person", "human"], in: object) else {
        return false
    }
    if let alarm = recursiveValue(forAny: ["alarm_state", "alarmState", "state"], in: person) {
        return booleanValue(alarm)
    }
    return booleanValue(person)
}

private func recursiveValue(for key: String, in object: Any) -> Any? {
    recursiveValue(forAny: [key], in: object)
}

private func recursiveValue(forAny keys: [String], in object: Any) -> Any? {
    let expected = Set(keys.map { $0.lowercased() })
    if let dictionary = object as? [String: Any] {
        for (key, value) in dictionary where expected.contains(key.lowercased()) {
            return value
        }
        for value in dictionary.values {
            if let match = recursiveValue(forAny: keys, in: value) {
                return match
            }
        }
    } else if let array = object as? [Any] {
        for value in array {
            if let match = recursiveValue(forAny: keys, in: value) {
                return match
            }
        }
    }
    return nil
}

private func booleanValue(_ value: Any) -> Bool {
    if let bool = value as? Bool {
        return bool
    }
    if let number = value as? NSNumber {
        return number.intValue != 0
    }
    if let string = value as? String {
        return ["1", "true", "active", "on"].contains(string.lowercased())
    }
    return false
}

private func parseDetectionEvents(from text: String) -> [DetectionEvent] {
    let lower = text.lowercased()
    guard lower.contains("motion") || lower.contains("person") || lower.contains("human") else {
        return []
    }

    let active = lower.contains(">true<") ||
        lower.contains("active") ||
        lower.contains("is motion") ||
        lower.contains("state\">true")

    var events = [DetectionEvent(kind: .motion, active: active)]
    if lower.contains("person") || lower.contains("human") {
        events.append(DetectionEvent(kind: .person, active: active))
    }
    return events
}

private func extractFirst(pattern: String, from text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
        return nil
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: range),
          match.numberOfRanges > 1,
          let swiftRange = Range(match.range(at: 1), in: text)
    else {
        return nil
    }
    return String(text[swiftRange])
}

public enum ONVIFError: LocalizedError {
    case invalidURL
    case http(Int, String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Invalid ONVIF URL."
        case .http(let status, let body):
            body.isEmpty ? "ONVIF HTTP status \(status)." : "ONVIF HTTP status \(status): \(summarizeONVIFFault(body))"
        }
    }
}

private func summarizeONVIFFault(_ body: String) -> String {
    if let reason = extractFirst(pattern: #"<[^>]*(?:Text|faultstring)[^>]*>([^<]+)</"#, from: body) {
        return String(reason.prefix(220))
    }
    if body.localizedCaseInsensitiveContains("Fault") {
        return "SOAP fault from camera; resubscribing."
    }
    return String(body.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).prefix(220))
}

private enum SOAPEnvelope {
    static func getCapabilities(username: String, password: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:tds="http://www.onvif.org/ver10/device/wsdl">
          <s:Header>\(securityHeader(username: username, password: password))</s:Header>
          <s:Body>
            <tds:GetCapabilities>
              <tds:Category>All</tds:Category>
            </tds:GetCapabilities>
          </s:Body>
        </s:Envelope>
        """
    }

    static func createPullPoint(username: String, password: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:tev="http://www.onvif.org/ver10/events/wsdl">
          <s:Header>\(securityHeader(username: username, password: password))</s:Header>
          <s:Body>
            <tev:CreatePullPointSubscription/>
          </s:Body>
        </s:Envelope>
        """
    }

    static func pullMessages(username: String, password: String, timeout: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:tev="http://www.onvif.org/ver10/events/wsdl">
          <s:Header>\(securityHeader(username: username, password: password))</s:Header>
          <s:Body>
            <tev:PullMessages>
              <tev:Timeout>\(timeout)</tev:Timeout>
              <tev:MessageLimit>10</tev:MessageLimit>
            </tev:PullMessages>
          </s:Body>
        </s:Envelope>
        """
    }

    private static func securityHeader(username: String, password: String) -> String {
        guard !username.isEmpty else { return "" }
        let nonceData = Data(UUID().uuidString.utf8)
        let created = ISO8601DateFormatter().string(from: Date())
        var digestInput = Data()
        digestInput.append(nonceData)
        digestInput.append(Data(created.utf8))
        digestInput.append(Data(password.utf8))
        let digest = Insecure.SHA1.hash(data: digestInput)
        let digestData = Data(digest)

        return """
        <wsse:Security s:mustUnderstand="1" xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd" xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">
          <wsse:UsernameToken>
            <wsse:Username>\(username.xmlEscaped)</wsse:Username>
            <wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">\(digestData.base64EncodedString())</wsse:Password>
            <wsse:Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">\(nonceData.base64EncodedString())</wsse:Nonce>
            <wsu:Created>\(created)</wsu:Created>
          </wsse:UsernameToken>
        </wsse:Security>
        """
    }
}

private extension String {
    var xmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
