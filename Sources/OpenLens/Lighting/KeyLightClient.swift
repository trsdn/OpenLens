import Foundation
import OSLog

/// Talks to one Key Light over its local HTTP API.
///
/// The protocol is unauthenticated plain HTTP on port 9123 and the lamps live
/// on the local network only, which is why no credentials appear anywhere here.
struct KeyLightClient {
    /// Short on purpose. These calls happen while a scene is being switched,
    /// sometimes mid-call, and a lamp that has been unplugged must not hold up
    /// the picture — better to report it unreachable and move on.
    static let timeout: TimeInterval = 2

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = Self.timeout
            configuration.timeoutIntervalForResource = Self.timeout
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    // MARK: - Wire format

    /// `{"numberOfLights":1,"lights":[{"on":1,"brightness":25,"temperature":154}]}`
    ///
    /// Every field is optional because a `PUT` may carry only what is changing,
    /// and because firmware versions differ in what they echo back.
    struct LightsPayload: Codable, Equatable {
        var numberOfLights: Int?
        var lights: [Light]

        struct Light: Codable, Equatable {
            /// 0 or 1 rather than a JSON boolean.
            var on: Int?
            var brightness: Int?
            /// Mired.
            var temperature: Int?
        }
    }

    struct AccessoryInfo: Codable, Equatable {
        var productName: String?
        var displayName: String?
        var serialNumber: String?
        var firmwareVersion: String?
    }

    // MARK: - Requests

    func accessoryInfo(host: String, port: Int) async throws -> AccessoryInfo {
        try await get(AccessoryInfo.self, url: Self.url(host: host, port: port, path: "/elgato/accessory-info"))
    }

    func state(host: String, port: Int) async throws -> KeyLightState {
        let payload = try await get(LightsPayload.self, url: Self.lightsURL(host: host, port: port))
        guard let light = payload.lights.first else { throw KeyLightError.emptyResponse }
        return Self.state(from: light)
    }

    /// Sends only the fields given, so changing brightness cannot silently
    /// reset the colour temperature to whatever the app last read.
    @discardableResult
    func apply(
        host: String,
        port: Int,
        isOn: Bool? = nil,
        brightness: Int? = nil,
        mired: Int? = nil
    ) async throws -> KeyLightState {
        let light = LightsPayload.Light(
            on: isOn.map { $0 ? 1 : 0 },
            brightness: brightness.map(KeyLightState.clampBrightness),
            temperature: mired.map(KeyLightState.clampMired)
        )
        let body = LightsPayload(numberOfLights: 1, lights: [light])

        var request = URLRequest(url: Self.lightsURL(host: host, port: port))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = Self.timeout

        let (data, response) = try await session.data(for: request)
        try Self.check(response)

        // The lamp echoes its resulting state. Trusting that rather than the
        // values just sent keeps the display honest when firmware clamps
        // something to a value the app did not ask for.
        guard
            let payload = try? JSONDecoder().decode(LightsPayload.self, from: data),
            let echoed = payload.lights.first
        else {
            return try await state(host: host, port: port)
        }
        return Self.state(from: echoed)
    }

    // MARK: - Plumbing

    static func state(from light: LightsPayload.Light) -> KeyLightState {
        KeyLightState(
            isOn: (light.on ?? 0) == 1,
            brightness: light.brightness ?? 0,
            mired: light.temperature ?? KeyLightState.miredRange.lowerBound
        )
    }

    static func lightsURL(host: String, port: Int) -> URL {
        url(host: host, port: port, path: "/elgato/lights")
    }

    static func url(host: String, port: Int, path: String) -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = path
        if let url = components.url { return url }
        // A bare IPv6 literal has to be bracketed, and Bonjour hands back IPv6
        // on plenty of networks, so falling back on the string form matters.
        guard let url = URL(string: "http://[\(host)]:\(port)\(path)") else {
            preconditionFailure("Could not build a URL for \(host):\(port)\(path)")
        }
        return url
    }

    private func get<T: Decodable>(_ type: T.Type, url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.timeout
        let (data, response) = try await session.data(for: request)
        try Self.check(response)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw KeyLightError.malformedResponse
        }
    }

    static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw KeyLightError.httpStatus(http.statusCode)
        }
    }
}

enum KeyLightError: LocalizedError, Equatable {
    case emptyResponse
    case malformedResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .emptyResponse: "The light reported no lamps."
        case .malformedResponse: "The light sent something this app could not read."
        case .httpStatus(let code): "The light answered with HTTP \(code)."
        }
    }
}
