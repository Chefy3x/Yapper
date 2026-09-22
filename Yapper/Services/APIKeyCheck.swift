import Foundation

/// The verdict of an API key check, shared by every keyed provider.
///
/// `rejected` and `inconclusive` are deliberately separate. A flaky network or a provider outage
/// says nothing about the key, and telling someone their key is bad when it isn't sends them off
/// to regenerate a credential that was fine.
enum APIKeyCheck: Equatable {
    case valid
    case rejected
    case inconclusive(String)

    /// Maps an HTTP status to a verdict. Only the auth codes are the key's fault — a 429 means the
    /// key works and is busy, and a 5xx means the provider is having a bad day. Neither is grounds
    /// for accusing the credential.
    static func forStatus(_ code: Int) -> APIKeyCheck {
        switch code {
        case 200..<300: .valid
        case 401, 403:  .rejected
        default:        .inconclusive("The provider returned HTTP \(code).")
        }
    }

    /// Runs a GET against a provider's cheapest authenticated endpoint and turns every outcome
    /// into a verdict. Never throws: the UI has to render all of these, none of them are crashes.
    ///
    /// - Parameter authorize: applies the provider's auth header — the one thing that differs
    ///   between ElevenLabs (`xi-api-key`) and OpenAI (`Authorization: Bearer`).
    static func probe(url: URL,
                      key: String,
                      authorize: (inout URLRequest, String) -> Void) async -> APIKeyCheck {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .rejected }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        authorize(&request, trimmed)
        // Short, because someone is watching a button spin while this runs.
        request.timeoutInterval = 12

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .inconclusive("Couldn't read the provider's response.")
            }
            return .forStatus(http.statusCode)
        } catch {
            return .inconclusive(error.localizedDescription)
        }
    }
}
