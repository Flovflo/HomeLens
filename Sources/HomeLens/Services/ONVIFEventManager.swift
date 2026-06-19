import CryptoKit
import Foundation

@MainActor
final class ONVIFEventManager {
    private var task: Task<Void, Never>?

    func test(camera: CameraConfig, password: String?) async -> ServiceTestResult {
        guard let url = camera.onvifURL else {
            return ServiceTestResult(ok: false, title: "Invalid ONVIF URL", detail: "Could not build an ONVIF URL from the camera config.")
        }

        do {
            let envelope = SOAPEnvelope.getCapabilities(username: camera.username, password: password ?? "")
            let response = try await postSOAP(url: url, action: "http://www.onvif.org/ver10/device/wsdl/GetCapabilities", envelope: envelope)
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
            return ServiceTestResult(ok: false, title: "ONVIF unexpected response", detail: response.prefix(180).description)
        } catch {
            return ServiceTestResult(ok: false, title: "ONVIF failed", detail: error.localizedDescription)
        }
    }

    func start(camera: CameraConfig, password: String?, logger: AppLogger, onEvent: @escaping @MainActor (DetectionEvent) -> Void) {
        stop()
        task = Task {
            await MainActor.run {
                logger.info("ONVIF", "Starting ONVIF event loop for \(camera.host).")
            }
            var backoffSeconds: UInt64 = 2
            while !Task.isCancelled {
                do {
                    try await pullEvents(camera: camera, password: password, logger: logger, onEvent: onEvent)
                    backoffSeconds = 2
                } catch {
                    await MainActor.run {
                        logger.warning("ONVIF", "Event loop reconnecting after failure: \(error.localizedDescription)")
                    }
                    try? await Task.sleep(nanoseconds: backoffSeconds * 1_000_000_000)
                    backoffSeconds = min(backoffSeconds * 2, 60)
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func pullEvents(
        camera: CameraConfig,
        password: String?,
        logger: AppLogger,
        onEvent: @escaping @MainActor (DetectionEvent) -> Void
    ) async throws {
        guard let deviceURL = camera.onvifURL else {
            throw ONVIFError.invalidURL
        }

        let capabilities = try await postSOAP(
            url: deviceURL,
            action: "http://www.onvif.org/ver10/device/wsdl/GetCapabilities",
            envelope: SOAPEnvelope.getCapabilities(username: camera.username, password: password ?? "")
        )

        let eventURLString = extractFirst(pattern: #"<[^>]*XAddr[^>]*>([^<]*event[^<]*)</"#, from: capabilities)
        let eventURL = eventURLString.flatMap(URL.init(string:)) ?? deviceURL

        let subscription = try await postSOAP(
            url: eventURL,
            action: "http://www.onvif.org/ver10/events/wsdl/EventPortType/CreatePullPointSubscriptionRequest",
            envelope: SOAPEnvelope.createPullPoint(username: camera.username, password: password ?? "")
        )

        let pullPointURLString = extractFirst(pattern: #"<[^>]*Address[^>]*>([^<]+)</"#, from: subscription)
        let pullPointURL = pullPointURLString.flatMap(URL.init(string:)) ?? eventURL

        await MainActor.run {
            logger.info("ONVIF", "Subscribed to ONVIF pull-point events at \(pullPointURL.host ?? camera.host).")
        }

        while !Task.isCancelled {
            let messages = try await postSOAP(
                url: pullPointURL,
                action: "http://www.onvif.org/ver10/events/wsdl/PullPointSubscription/PullMessagesRequest",
                envelope: SOAPEnvelope.pullMessages(username: camera.username, password: password ?? "")
            )
            let events = parseDetectionEvents(from: messages)
            for event in events {
                await MainActor.run {
                    onEvent(event)
                    logger.info("ONVIF", "\(event.kind.rawValue) \(event.active ? "active" : "inactive")")
                }
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func postSOAP(url: URL, action: String, envelope: String) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/soap+xml; charset=utf-8; action=\"\(action)\"", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(envelope.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ONVIFError.http(http.statusCode)
        }
        return String(data: data, encoding: .utf8) ?? ""
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
}

enum ONVIFError: LocalizedError {
    case invalidURL
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Invalid ONVIF URL."
        case .http(let status):
            "ONVIF HTTP status \(status)."
        }
    }
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

    static func pullMessages(username: String, password: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:tev="http://www.onvif.org/ver10/events/wsdl">
          <s:Header>\(securityHeader(username: username, password: password))</s:Header>
          <s:Body>
            <tev:PullMessages>
              <tev:Timeout>PT10S</tev:Timeout>
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
