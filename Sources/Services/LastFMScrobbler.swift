import CryptoKit
import Foundation

struct LastFMCredentials: Equatable {
    let apiKey: String
    let apiSecret: String
    let sessionKey: String
}

struct LastFMSession: Equatable {
    let name: String
    let key: String
}

actor LastFMScrobbler {
    private let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!

    func fetchAuthorizationToken(apiKey: String) async throws -> String {
        let requestURL = try makeURL(
            from: [
                "method": "auth.getToken",
                "api_key": apiKey,
                "format": "json",
            ]
        )
        let (data, _) = try await URLSession.shared.data(from: requestURL)
        let decoded = try JSONDecoder().decode(LastFMTokenResponse.self, from: data)
        if let errorCode = decoded.error {
            throw LastFMError.api(code: errorCode, message: decoded.message ?? "Unknown Last.fm error")
        }
        guard let token = decoded.token, !token.isEmpty else {
            throw LastFMError.missingToken
        }
        return token
    }

    func fetchSession(apiKey: String, apiSecret: String, token: String) async throws -> LastFMSession {
        var signedParameters: [String: String] = [
            "method": "auth.getSession",
            "api_key": apiKey,
            "token": token,
        ]
        let signature = signedParameters
            .sorted { $0.key < $1.key }
            .map { "\($0.key)\($0.value)" }
            .joined() + apiSecret
        signedParameters["api_sig"] = md5(signature)
        signedParameters["format"] = "json"

        let requestURL = try makeURL(from: signedParameters)
        let (data, _) = try await URLSession.shared.data(from: requestURL)
        let decoded = try JSONDecoder().decode(LastFMSessionResponse.self, from: data)
        if let errorCode = decoded.error {
            throw LastFMError.api(code: errorCode, message: decoded.message ?? "Unknown Last.fm error")
        }
        guard let session = decoded.session else {
            throw LastFMError.missingSession
        }
        return LastFMSession(name: session.name, key: session.key)
    }

    func updateNowPlaying(
        credentials: LastFMCredentials,
        track: Track,
        duration: TimeInterval
    ) async throws {
        var parameters: [String: String] = [
            "artist": track.artist,
            "track": track.title,
        ]
        if !track.album.isEmpty, track.album != "Unknown Album" {
            parameters["album"] = track.album
        }
        if duration.isFinite, duration > 0 {
            parameters["duration"] = String(Int(duration.rounded()))
        }
        _ = try await call(
            method: "track.updateNowPlaying",
            parameters: parameters,
            credentials: credentials
        )
    }

    func scrobble(
        credentials: LastFMCredentials,
        track: Track,
        startedAt: Date,
        duration: TimeInterval
    ) async throws {
        var parameters: [String: String] = [
            "artist": track.artist,
            "track": track.title,
            "timestamp": String(Int(startedAt.timeIntervalSince1970)),
        ]
        if !track.album.isEmpty, track.album != "Unknown Album" {
            parameters["album"] = track.album
        }
        if duration.isFinite, duration > 0 {
            parameters["duration"] = String(Int(duration.rounded()))
        }
        _ = try await call(
            method: "track.scrobble",
            parameters: parameters,
            credentials: credentials
        )
    }

    private func call(
        method: String,
        parameters: [String: String],
        credentials: LastFMCredentials
    ) async throws -> LastFMResponse {
        var signedParameters = parameters
        signedParameters["method"] = method
        signedParameters["api_key"] = credentials.apiKey
        signedParameters["sk"] = credentials.sessionKey

        let signature = signedParameters
            .sorted { $0.key < $1.key }
            .map { "\($0.key)\($0.value)" }
            .joined() + credentials.apiSecret

        var bodyParameters = signedParameters
        bodyParameters["api_sig"] = md5(signature)
        bodyParameters["format"] = "json"

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = percentEncodedBody(from: bodyParameters)

        let (data, _) = try await URLSession.shared.data(for: request)
        let decoded = try JSONDecoder().decode(LastFMResponse.self, from: data)
        if let errorCode = decoded.error {
            throw LastFMError.api(code: errorCode, message: decoded.message ?? "Unknown Last.fm error")
        }
        return decoded
    }

    private func percentEncodedBody(from parameters: [String: String]) -> Data? {
        var components = URLComponents()
        components.queryItems = parameters
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.percentEncodedQuery?.data(using: .utf8)
    }

    private func makeURL(from parameters: [String: String]) throws -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = parameters
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else {
            throw LastFMError.invalidRequest
        }
        return url
    }

    private func md5(_ value: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private struct LastFMResponse: Decodable {
    let error: Int?
    let message: String?
}

private struct LastFMTokenResponse: Decodable {
    let token: String?
    let error: Int?
    let message: String?
}

private struct LastFMSessionResponse: Decodable {
    let session: LastFMSessionPayload?
    let error: Int?
    let message: String?
}

private struct LastFMSessionPayload: Decodable {
    let name: String
    let key: String
}

enum LastFMError: LocalizedError {
    case api(code: Int, message: String)
    case missingToken
    case missingSession
    case invalidRequest

    var errorDescription: String? {
        switch self {
        case let .api(code, message):
            return "Last.fm error \(code): \(message)"
        case .missingToken:
            return "Last.fm did not return an authorization token."
        case .missingSession:
            return "Last.fm did not return a session key."
        case .invalidRequest:
            return "Unable to build Last.fm authorization request."
        }
    }
}
