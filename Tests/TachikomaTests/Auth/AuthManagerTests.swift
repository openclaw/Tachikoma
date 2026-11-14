import Foundation
import Testing
@testable import Tachikoma
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite(.serialized)
struct AuthManagerTests {
    private func withIsolatedAuthState<T: Sendable>(
        _ body: @Sendable () async throws -> T,
    ) async rethrows
        -> T
    {
        try await TestEnvironmentMutex.shared.withLock {
            let originalProfileDirectory = TachikomaConfiguration.profileDirectoryName
            let isolatedProfileDirectory = ".tachikoma-auth-tests-\(UUID().uuidString)"
            let previousIgnoreEnvironment = TKAuthManager.shared.setIgnoreEnvironment(false)
            let previousIgnoreCredentialStore = TKAuthManager.shared.setIgnoreCredentialStore(false)
            let isolatedPath = NSString(string: "~/" + isolatedProfileDirectory).expandingTildeInPath

            TachikomaConfiguration.profileDirectoryName = isolatedProfileDirectory
            try? FileManager.default.removeItem(atPath: isolatedPath)

            defer {
                self.resetAuthEnv()
                TKAuthManager.shared.setIgnoreEnvironment(previousIgnoreEnvironment)
                TKAuthManager.shared.setIgnoreCredentialStore(previousIgnoreCredentialStore)
                TachikomaConfiguration.profileDirectoryName = originalProfileDirectory
                try? FileManager.default.removeItem(atPath: isolatedPath)
            }

            return try await body()
        }
    }

    private func resetAuthEnv() {
        unsetenv("XAI_API_KEY")
        unsetenv("X_AI_API_KEY")
        unsetenv("GROK_API_KEY")
        unsetenv("OPENAI_API_KEY")
        unsetenv("OPENAI_ACCESS_TOKEN")
        unsetenv("OPENAI_REFRESH_TOKEN")
        unsetenv("OPENAI_ACCESS_EXPIRES")
        unsetenv("ANTHROPIC_API_KEY")
        unsetenv("ANTHROPIC_ACCESS_TOKEN")
        unsetenv("GEMINI_API_KEY")
        unsetenv("GOOGLE_API_KEY")
        unsetenv("OPENROUTER_API_KEY")
    }

    @Test
    func `env preferred over creds`() async throws {
        try await self.withIsolatedAuthState {
            self.resetAuthEnv()
            setenv("OPENAI_API_KEY", "env-key", 1)
            defer { unsetenv("OPENAI_API_KEY") }
            try TKAuthManager.shared.setCredential(key: "OPENAI_API_KEY", value: "cred-key")
            let auth = TKAuthManager.shared.resolveAuth(for: .openai)
            guard case let .bearer(token, _) = auth else {
                Issue.record("Expected bearer from env")
                return
            }
            #expect(token == "env-key")
        }
    }

    @Test
    func `grok alias env`() async {
        await self.withIsolatedAuthState {
            self.resetAuthEnv()
            setenv("X_AI_API_KEY", "alias-key", 1)
            unsetenv("XAI_API_KEY")
            unsetenv("GROK_API_KEY")
            defer { unsetenv("X_AI_API_KEY") }
            let auth = TKAuthManager.shared.resolveAuth(for: .grok)
            guard case let .bearer(token, _) = auth else {
                Issue.record("Expected bearer from alias env")
                return
            }
            #expect(token == "alias-key")
        }
    }

    @Test
    func `openrouter resolves env and credential keys as bearer auth`() async throws {
        try await self.withIsolatedAuthState {
            self.resetAuthEnv()
            try TKAuthManager.shared.setCredential(key: "OPENROUTER_API_KEY", value: "credential-openrouter-key")

            guard case let .bearer(credentialToken, _)? = TKAuthManager.shared.resolveAuth(for: .openrouter) else {
                Issue.record("Expected OpenRouter bearer auth from credentials")
                return
            }
            #expect(credentialToken == "credential-openrouter-key")

            setenv("OPENROUTER_API_KEY", "env-openrouter-key", 1)
            defer { unsetenv("OPENROUTER_API_KEY") }

            guard case let .bearer(envToken, _)? = TKAuthManager.shared.resolveAuth(for: .openrouter) else {
                Issue.record("Expected OpenRouter bearer auth from environment")
                return
            }
            #expect(envToken == "env-openrouter-key")
        }
    }

    @Test
    func `OpenAI Codex JWT exposes account and expiration claims`() {
        let expiration = Date().addingTimeInterval(3600)
        let token = Self.openAIJWT(accountID: "account-123", expiration: expiration)

        #expect(TKOpenAICodexJWT.accountID(from: token) == "account-123")
        let parsedExpiration = TKOpenAICodexJWT.expiration(from: token)
        #expect(parsedExpiration != nil)
        #expect(abs((parsedExpiration?.timeIntervalSince1970 ?? 0) - expiration.timeIntervalSince1970) < 1)
    }

    @Test
    func `OpenAI Codex OAuth prefers a valid environment account`() async throws {
        try await self.withIsolatedAuthState {
            self.resetAuthEnv()
            let environmentToken = Self.openAIJWT(
                accountID: "environment-account",
                expiration: Date().addingTimeInterval(3600),
            )
            let storedToken = Self.openAIJWT(
                accountID: "stored-account",
                expiration: Date().addingTimeInterval(7200),
            )
            setenv("OPENAI_ACCESS_TOKEN", environmentToken, 1)
            try TKAuthManager.shared.setCredentials([
                "OPENAI_ACCESS_TOKEN": storedToken,
                "OPENAI_REFRESH_TOKEN": "stored-refresh-token",
            ])

            let auth = try await TKAuthManager.shared.resolveOpenAICodexAuth()

            #expect(auth == TKOpenAICodexAuth(
                accessToken: environmentToken,
                accountID: "environment-account",
            ))
        }
    }

    @Test
    @MainActor
    func `OpenAI Codex OAuth refresh rotates and persists credentials`() async throws {
        let session = URLSession.oauthMock()
        try await self.withIsolatedAuthState {
            self.resetAuthEnv()
            let expiredToken = Self.openAIJWT(
                accountID: "account-123",
                expiration: Date().addingTimeInterval(-3600),
            )
            try TKAuthManager.shared.setCredentials([
                "OPENAI_ACCESS_TOKEN": expiredToken,
                "OPENAI_REFRESH_TOKEN": "old-refresh-token",
                "OPENAI_ACCESS_EXPIRES": String(Int(Date().addingTimeInterval(-3600).timeIntervalSince1970)),
            ])

            let refreshedToken = Self.openAIJWT(
                accountID: "account-456",
                expiration: Date().addingTimeInterval(7200),
            )
            OAuthMockURLProtocol.reset()
            OAuthMockURLProtocol.responseData = try JSONSerialization.data(withJSONObject: [
                "access_token": refreshedToken,
                "refresh_token": "rotated-refresh-token",
            ])

            let auth = try await TKAuthManager.shared.resolveOpenAICodexAuth(
                timeout: 5,
                session: session,
            )

            #expect(auth == TKOpenAICodexAuth(accessToken: refreshedToken, accountID: "account-456"))
            let request = try #require(OAuthMockURLProtocol.lastRequest)
            #expect(request.url?.absoluteString == "https://auth.openai.com/oauth/token")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

            let body = try #require(OAuthMockURLProtocol.lastBody)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
            #expect(json["client_id"] == "app_EMoamEEZ73f0CkXaXp7hrann")
            #expect(json["grant_type"] == "refresh_token")
            #expect(json["refresh_token"] == "old-refresh-token")
            #expect(TKAuthManager.shared.credentialValue(for: "OPENAI_ACCESS_TOKEN") == refreshedToken)
            #expect(TKAuthManager.shared.credentialValue(for: "OPENAI_REFRESH_TOKEN") == "rotated-refresh-token")
        }
    }

    @Test
    @MainActor
    func `OpenAI Codex OAuth caches refreshed environment credentials without persisting`() async throws {
        let session = URLSession.oauthMock()
        try await self.withIsolatedAuthState {
            self.resetAuthEnv()
            let expiredToken = Self.openAIJWT(
                accountID: "account-env",
                expiration: Date().addingTimeInterval(-3600),
            )
            setenv("OPENAI_ACCESS_TOKEN", expiredToken, 1)
            setenv("OPENAI_REFRESH_TOKEN", "environment-refresh-token", 1)
            setenv(
                "OPENAI_ACCESS_EXPIRES",
                String(Int(Date().addingTimeInterval(-3600).timeIntervalSince1970)),
                1,
            )

            let refreshedToken = Self.openAIJWT(
                accountID: "account-env",
                expiration: Date().addingTimeInterval(7200),
            )
            OAuthMockURLProtocol.reset()
            OAuthMockURLProtocol.responseData = try JSONSerialization.data(withJSONObject: [
                "access_token": refreshedToken,
                "refresh_token": "rotated-refresh-token",
            ])

            let first = try await TKAuthManager.shared.resolveOpenAICodexAuth(timeout: 5, session: session)
            let second = try await TKAuthManager.shared.resolveOpenAICodexAuth(timeout: 5, session: session)

            #expect(first.accessToken == refreshedToken)
            #expect(second.accessToken == refreshedToken)
            #expect(OAuthMockURLProtocol.requestCount == 1)
            #expect(TKCredentialStore().load().isEmpty)
        }
    }

    @Test
    @MainActor
    func `OpenAI Codex OAuth continues an environment refresh chain in memory`() async throws {
        let session = URLSession.oauthMock()
        try await self.withIsolatedAuthState {
            self.resetAuthEnv()
            let expiredEnvironmentToken = Self.openAIJWT(
                accountID: "same-account",
                expiration: Date().addingTimeInterval(-3600),
            )
            setenv("OPENAI_ACCESS_TOKEN", expiredEnvironmentToken, 1)
            setenv("OPENAI_REFRESH_TOKEN", "original-refresh-token", 1)

            let shortLivedToken = Self.openAIJWT(
                accountID: "same-account",
                expiration: Date().addingTimeInterval(30),
            )
            OAuthMockURLProtocol.reset()
            OAuthMockURLProtocol.responseData = try JSONSerialization.data(withJSONObject: [
                "access_token": shortLivedToken,
                "refresh_token": "rotated-refresh-token",
            ])
            _ = try await TKAuthManager.shared.resolveOpenAICodexAuth(timeout: 5, session: session)

            let finalToken = Self.openAIJWT(
                accountID: "same-account",
                expiration: Date().addingTimeInterval(3600),
            )
            OAuthMockURLProtocol.responseData = try JSONSerialization.data(withJSONObject: [
                "access_token": finalToken,
                "refresh_token": "second-rotated-refresh-token",
            ])
            let auth = try await TKAuthManager.shared.resolveOpenAICodexAuth(timeout: 5, session: session)

            #expect(auth.accessToken == finalToken)
            #expect(OAuthMockURLProtocol.requestCount == 2)
            let body = try #require(OAuthMockURLProtocol.lastBody)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
            #expect(json["refresh_token"] == "rotated-refresh-token")
            #expect(TKCredentialStore().load().isEmpty)
        }
    }

    @Test
    @MainActor
    func `OpenAI Codex OAuth environment changes invalidate the in-memory refresh chain`() async throws {
        let session = URLSession.oauthMock()
        try await self.withIsolatedAuthState {
            self.resetAuthEnv()
            let firstExpiredToken = Self.openAIJWT(
                accountID: "first-account",
                expiration: Date().addingTimeInterval(-3600),
            )
            setenv("OPENAI_ACCESS_TOKEN", firstExpiredToken, 1)
            setenv("OPENAI_REFRESH_TOKEN", "first-refresh-token", 1)

            let firstRefreshedToken = Self.openAIJWT(
                accountID: "first-account",
                expiration: Date().addingTimeInterval(3600),
            )
            OAuthMockURLProtocol.reset()
            OAuthMockURLProtocol.responseData = try JSONSerialization.data(withJSONObject: [
                "access_token": firstRefreshedToken,
                "refresh_token": "first-rotated-refresh-token",
            ])
            let firstAuth = try await TKAuthManager.shared.resolveOpenAICodexAuth(timeout: 5, session: session)

            let secondExpiredToken = Self.openAIJWT(
                accountID: "second-account",
                expiration: Date().addingTimeInterval(-3600),
            )
            setenv("OPENAI_ACCESS_TOKEN", secondExpiredToken, 1)
            setenv("OPENAI_REFRESH_TOKEN", "second-refresh-token", 1)
            let secondRefreshedToken = Self.openAIJWT(
                accountID: "second-account",
                expiration: Date().addingTimeInterval(3600),
            )
            OAuthMockURLProtocol.responseData = try JSONSerialization.data(withJSONObject: [
                "access_token": secondRefreshedToken,
                "refresh_token": "second-rotated-refresh-token",
            ])
            let secondAuth = try await TKAuthManager.shared.resolveOpenAICodexAuth(timeout: 5, session: session)

            #expect(firstAuth.accountID == "first-account")
            #expect(secondAuth.accountID == "second-account")
            #expect(OAuthMockURLProtocol.requestCount == 2)
            let body = try #require(OAuthMockURLProtocol.lastBody)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
            #expect(json["refresh_token"] == "second-refresh-token")
            #expect(TKCredentialStore().load().isEmpty)
        }
    }

    @Test
    @MainActor
    func `OpenAI Codex OAuth ignore-environment changes invalidate the in-memory refresh chain`() async throws {
        let session = URLSession.oauthMock()
        try await self.withIsolatedAuthState {
            self.resetAuthEnv()
            let expiredToken = Self.openAIJWT(
                accountID: "ignored-environment-account",
                expiration: Date().addingTimeInterval(-3600),
            )
            setenv("OPENAI_ACCESS_TOKEN", expiredToken, 1)
            setenv("OPENAI_REFRESH_TOKEN", "ignored-environment-refresh-token", 1)

            let firstRefreshedToken = Self.openAIJWT(
                accountID: "ignored-environment-account",
                expiration: Date().addingTimeInterval(3600),
            )
            OAuthMockURLProtocol.reset()
            OAuthMockURLProtocol.responseData = try JSONSerialization.data(withJSONObject: [
                "access_token": firstRefreshedToken,
                "refresh_token": "rotated-refresh-token",
            ])
            _ = try await TKAuthManager.shared.resolveOpenAICodexAuth(timeout: 5, session: session)

            TKAuthManager.shared.setIgnoreEnvironment(true)
            TKAuthManager.shared.setIgnoreEnvironment(false)
            let secondRefreshedToken = Self.openAIJWT(
                accountID: "ignored-environment-account",
                expiration: Date().addingTimeInterval(7200),
            )
            OAuthMockURLProtocol.responseData = try JSONSerialization.data(withJSONObject: [
                "access_token": secondRefreshedToken,
                "refresh_token": "second-rotated-refresh-token",
            ])
            let auth = try await TKAuthManager.shared.resolveOpenAICodexAuth(timeout: 5, session: session)

            #expect(auth.accessToken == secondRefreshedToken)
            #expect(OAuthMockURLProtocol.requestCount == 2)
            let body = try #require(OAuthMockURLProtocol.lastBody)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
            #expect(json["refresh_token"] == "ignored-environment-refresh-token")
            #expect(TKCredentialStore().load().isEmpty)
        }
    }

    @Test
    @MainActor
    func `OpenAI Codex OAuth refreshes an explicit environment account over another stored account`() async throws {
        let session = URLSession.oauthMock()
        try await self.withIsolatedAuthState {
            self.resetAuthEnv()
            let expiredEnvironmentToken = Self.openAIJWT(
                accountID: "environment-account",
                expiration: Date().addingTimeInterval(-3600),
            )
            setenv("OPENAI_ACCESS_TOKEN", expiredEnvironmentToken, 1)
            setenv("OPENAI_REFRESH_TOKEN", "environment-refresh-token", 1)

            let storedToken = Self.openAIJWT(
                accountID: "stored-account",
                expiration: Date().addingTimeInterval(3600),
            )
            try TKAuthManager.shared.setCredentials([
                "OPENAI_ACCESS_TOKEN": storedToken,
                "OPENAI_REFRESH_TOKEN": "stored-refresh-token",
            ])

            let refreshedEnvironmentToken = Self.openAIJWT(
                accountID: "environment-account",
                expiration: Date().addingTimeInterval(3600),
            )
            OAuthMockURLProtocol.reset()
            OAuthMockURLProtocol.responseData = try JSONSerialization.data(withJSONObject: [
                "access_token": refreshedEnvironmentToken,
                "refresh_token": "rotated-environment-refresh-token",
            ])

            let auth = try await TKAuthManager.shared.resolveOpenAICodexAuth(timeout: 5, session: session)

            #expect(auth.accountID == "environment-account")
            let body = try #require(OAuthMockURLProtocol.lastBody)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
            #expect(json["refresh_token"] == "environment-refresh-token")
            let storedCredentials = TKCredentialStore().load()
            #expect(storedCredentials["OPENAI_ACCESS_TOKEN"] == storedToken)
            #expect(storedCredentials["OPENAI_REFRESH_TOKEN"] == "stored-refresh-token")
        }
    }

    @Test
    @MainActor
    func `OpenAI Codex OAuth refresh ignores an unrefreshable environment token`() async throws {
        let session = URLSession.oauthMock()
        try await self.withIsolatedAuthState {
            self.resetAuthEnv()
            setenv("OPENAI_ACCESS_TOKEN", "malformed-environment-token", 1)
            let storedExpiredToken = Self.openAIJWT(
                accountID: "stored-account",
                expiration: Date().addingTimeInterval(-3600),
            )
            try TKAuthManager.shared.setCredentials([
                "OPENAI_ACCESS_TOKEN": storedExpiredToken,
                "OPENAI_REFRESH_TOKEN": "stored-refresh-token",
            ])

            let refreshedToken = Self.openAIJWT(
                accountID: "refreshed-account",
                expiration: Date().addingTimeInterval(3600),
            )
            OAuthMockURLProtocol.reset()
            OAuthMockURLProtocol.responseData = try JSONSerialization.data(withJSONObject: [
                "access_token": refreshedToken,
                "refresh_token": "rotated-refresh-token",
            ])

            let auth = try await TKAuthManager.shared.resolveOpenAICodexAuth(timeout: 5, session: session)

            #expect(auth.accountID == "refreshed-account")
            let body = try #require(OAuthMockURLProtocol.lastBody)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
            #expect(json["refresh_token"] == "stored-refresh-token")
        }
    }

    @Test
    @MainActor
    func `OpenAI Codex OAuth refresh HTTP failure preserves credentials`() async throws {
        let session = URLSession.oauthMock()
        try await self.withIsolatedAuthState {
            self.resetAuthEnv()
            let expiredToken = Self.openAIJWT(
                accountID: "account-123",
                expiration: Date().addingTimeInterval(-3600),
            )
            let expiredAt = String(Int(Date().addingTimeInterval(-3600).timeIntervalSince1970))
            try TKAuthManager.shared.setCredentials([
                "OPENAI_ACCESS_TOKEN": expiredToken,
                "OPENAI_REFRESH_TOKEN": "original-refresh-token",
                "OPENAI_ACCESS_EXPIRES": expiredAt,
            ])

            OAuthMockURLProtocol.reset()
            OAuthMockURLProtocol.statusCode = 401
            OAuthMockURLProtocol.responseData = Data(#"{"error":"invalid_grant"}"#.utf8)

            await #expect(throws: TachikomaError.self) {
                _ = try await TKAuthManager.shared.resolveOpenAICodexAuth(
                    timeout: 5,
                    session: session,
                )
            }

            #expect(OAuthMockURLProtocol.requestCount == 1)
            #expect(TKAuthManager.shared.credentialValue(for: "OPENAI_ACCESS_TOKEN") == expiredToken)
            #expect(TKAuthManager.shared.credentialValue(for: "OPENAI_REFRESH_TOKEN") == "original-refresh-token")
            #expect(TKAuthManager.shared.credentialValue(for: "OPENAI_ACCESS_EXPIRES") == expiredAt)
        }
    }

    @Test
    @MainActor
    func `OpenAI Codex OAuth invalid refresh payload preserves credentials`() async throws {
        let session = URLSession.oauthMock()
        try await self.withIsolatedAuthState {
            self.resetAuthEnv()
            let expiredToken = Self.openAIJWT(
                accountID: "account-123",
                expiration: Date().addingTimeInterval(-3600),
            )
            let expiredAt = String(Int(Date().addingTimeInterval(-3600).timeIntervalSince1970))
            try TKAuthManager.shared.setCredentials([
                "OPENAI_ACCESS_TOKEN": expiredToken,
                "OPENAI_REFRESH_TOKEN": "original-refresh-token",
                "OPENAI_ACCESS_EXPIRES": expiredAt,
            ])

            OAuthMockURLProtocol.reset()
            OAuthMockURLProtocol.responseData = Data(#"{"refresh_token":"partial-rotation"}"#.utf8)

            await #expect(throws: TachikomaError.self) {
                _ = try await TKAuthManager.shared.resolveOpenAICodexAuth(
                    timeout: 5,
                    session: session,
                )
            }

            #expect(OAuthMockURLProtocol.requestCount == 1)
            #expect(TKAuthManager.shared.credentialValue(for: "OPENAI_ACCESS_TOKEN") == expiredToken)
            #expect(TKAuthManager.shared.credentialValue(for: "OPENAI_REFRESH_TOKEN") == "original-refresh-token")
            #expect(TKAuthManager.shared.credentialValue(for: "OPENAI_ACCESS_EXPIRES") == expiredAt)
        }
    }

    @Test
    @MainActor
    func `OpenAI Codex OAuth concurrent callers share one refresh`() async throws {
        let session = URLSession.oauthMock()
        try await self.withIsolatedAuthState {
            self.resetAuthEnv()
            let expiredToken = Self.openAIJWT(
                accountID: "account-123",
                expiration: Date().addingTimeInterval(-3600),
            )
            try TKAuthManager.shared.setCredentials([
                "OPENAI_ACCESS_TOKEN": expiredToken,
                "OPENAI_REFRESH_TOKEN": "original-refresh-token",
            ])

            let refreshedToken = Self.openAIJWT(
                accountID: "account-123",
                expiration: Date().addingTimeInterval(3600),
            )
            OAuthMockURLProtocol.reset()
            OAuthMockURLProtocol.responseDelayNanoseconds = 50_000_000
            OAuthMockURLProtocol.responseData = try JSONSerialization.data(withJSONObject: [
                "access_token": refreshedToken,
                "refresh_token": "rotated-refresh-token",
            ])

            let results = try await withThrowingTaskGroup(of: TKOpenAICodexAuth.self) { group in
                for _ in 0..<8 {
                    group.addTask {
                        try await TKAuthManager.shared.resolveOpenAICodexAuth(
                            timeout: 5,
                            session: session,
                        )
                    }
                }

                var authValues: [TKOpenAICodexAuth] = []
                for try await auth in group {
                    authValues.append(auth)
                }
                return authValues
            }

            #expect(results.count == 8)
            #expect(results.allSatisfy {
                $0 == TKOpenAICodexAuth(accessToken: refreshedToken, accountID: "account-123")
            })
            #expect(OAuthMockURLProtocol.requestCount == 1)
            #expect(TKAuthManager.shared.credentialValue(for: "OPENAI_ACCESS_TOKEN") == refreshedToken)
            #expect(TKAuthManager.shared.credentialValue(for: "OPENAI_REFRESH_TOKEN") == "rotated-refresh-token")
        }
    }

    @Test
    @MainActor
    func `validate success mock`() async throws {
        let session = URLSession.mock(status: 200)
        let req = try URLRequest(url: #require(URL(string: "https://api.openai.com/v1/models")))
        let result = await HTTP.perform(request: req, timeoutSeconds: 5, session: session)
        switch result {
        case .success: break
        default: Issue.record("Expected success")
        }
    }

    @Test
    @MainActor
    func `validate failure mock`() async throws {
        let session = URLSession.mock(status: 401)
        let req = try URLRequest(url: #require(URL(string: "https://api.openai.com/v1/models")))
        let result = await HTTP.perform(request: req, timeoutSeconds: 5, session: session)
        switch result {
        case let .failure(reason):
            #expect(reason.contains("401"))
        default:
            Issue.record("Expected failure")
        }
    }

    @Test
    @MainActor
    func `o auth token exchange uses form encoding`() async throws {
        OAuthMockURLProtocol.reset()
        let pkce = PKCE()
        let authorizeEndpoint = try #require(URL(string: "https://example.com/auth"))
        let tokenEndpoint = try #require(URL(string: "https://example.com/token"))
        let config = try #require(OAuthConfig(
            prefix: "TEST",
            authorizeEndpoint: authorizeEndpoint,
            tokenEndpoint: tokenEndpoint,
            clientId: "client-id",
            scope: "scope",
            redirect: "https://example.com/callback",
            extraAuthorize: [:],
            extraToken: [:],
            betaHeader: nil,
        ))
        let result = await OAuthTokenExchanger.exchange(
            config: config,
            code: "abc123",
            pkce: pkce,
            timeout: 5,
            session: .oauthMock(),
        )
        guard case .success = result else {
            Issue.record("Expected success but got \(result)")
            return
        }

        let request = try #require(OAuthMockURLProtocol.lastRequest, "No request captured")

        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")

        let bodyString = String(data: OAuthMockURLProtocol.lastBody ?? Data(), encoding: .utf8) ?? ""
        let items = URLComponents(string: "https://example.com?\(bodyString)")?.queryItems ?? []
        let params = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })

        #expect(params["grant_type"] == "authorization_code")
        #expect(params["client_id"] == "client-id")
        #expect(params["code"] == "abc123")
        #expect(params["redirect_uri"] == "https://example.com/callback")
        #expect(params["code_verifier"] == pkce.verifier)
    }

    @Test
    @MainActor
    func `o auth token exchange uses JSON encoding and state when required`() async throws {
        OAuthMockURLProtocol.reset()
        let pkce = PKCE()
        let authorizeEndpoint = try #require(URL(string: "https://example.com/auth"))
        let tokenEndpoint = try #require(URL(string: "https://example.com/token"))
        let config = try #require(OAuthConfig(
            prefix: "TEST",
            authorizeEndpoint: authorizeEndpoint,
            tokenEndpoint: tokenEndpoint,
            clientId: "client-id",
            scope: "scope",
            redirect: "https://example.com/callback",
            extraAuthorize: [:],
            extraToken: [:],
            betaHeader: nil,
            tokenEncoding: .json,
            requiresStateInTokenExchange: true,
        ))
        let result = await OAuthTokenExchanger.exchange(
            config: config,
            code: "abc123",
            state: "state123",
            pkce: pkce,
            timeout: 5,
            session: .oauthMock(),
        )
        guard case .success = result else {
            Issue.record("Expected success but got \(result)")
            return
        }

        let request = try #require(OAuthMockURLProtocol.lastRequest, "No request captured")

        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let bodyData = try #require(OAuthMockURLProtocol.lastBody, "No request body captured")
        let json = try #require(
            JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
            "Expected JSON request body",
        )

        #expect(json["grant_type"] as? String == "authorization_code")
        #expect(json["client_id"] as? String == "client-id")
        #expect(json["code"] as? String == "abc123")
        #expect(json["state"] as? String == "state123")
        #expect(json["redirect_uri"] as? String == "https://example.com/callback")
        #expect(json["code_verifier"] as? String == pkce.verifier)
    }

    @Test
    func `o auth authorization URL exposes challenge but not verifier`() throws {
        let pkce = PKCE()
        let authorizeEndpoint = try #require(URL(string: "https://example.com/auth"))
        let tokenEndpoint = try #require(URL(string: "https://example.com/token"))
        let config = try #require(OAuthConfig(
            prefix: "TEST",
            authorizeEndpoint: authorizeEndpoint,
            tokenEndpoint: tokenEndpoint,
            clientId: "client-id",
            scope: "scope",
            redirect: "https://example.com/callback",
            extraAuthorize: [:],
            extraToken: [:],
            betaHeader: nil,
        ))

        let url = try #require(config.authorizeURL(pkce: pkce))
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })
        #expect(query["code_challenge"] == pkce.challenge)
        #expect(query["state"] == pkce.state)
        #expect(!url.absoluteString.contains(pkce.verifier))
    }

    @Test
    @MainActor
    func `o auth config rejects cleartext token endpoint`() throws {
        OAuthMockURLProtocol.reset()
        let authorizeEndpoint = try #require(URL(string: "https://example.com/auth"))
        let tokenEndpoint = try #require(URL(string: "http://example.com/token"))
        let config = OAuthConfig(
            prefix: "TEST",
            authorizeEndpoint: authorizeEndpoint,
            tokenEndpoint: tokenEndpoint,
            clientId: "client-id",
            scope: "scope",
            redirect: "https://example.com/callback",
            extraAuthorize: [:],
            extraToken: [:],
            betaHeader: nil,
        )

        #expect(config == nil)
        #expect(OAuthMockURLProtocol.requestCount == 0)
    }

    @Test
    @MainActor
    func `gemini validation sends API key in header`() async throws {
        OAuthMockURLProtocol.reset()
        let validator = TKProviderValidator(timeoutSeconds: 5)

        let result = await validator.validate(
            provider: .gemini,
            secret: "test-gemini-key",
            session: .oauthMock(),
        )

        guard case .success = result else {
            Issue.record("Expected successful mock validation")
            return
        }
        let request = try #require(OAuthMockURLProtocol.lastRequest)
        #expect(request.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "test-gemini-key")
        #expect(request.url?.query == nil)
    }

    private static func openAIJWT(accountID: String, expiration: Date) -> String {
        let header = ["alg": "none", "typ": "JWT"]
        let payload: [String: Any] = [
            "exp": Int(expiration.timeIntervalSince1970),
            "https://api.openai.com/auth": ["chatgpt_account_id": accountID],
        ]
        return "\(self.base64URLJSON(header)).\(self.base64URLJSON(payload)).signature"
    }

    private static func base64URLJSON(_ value: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: value)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - URLSession mocking

@MainActor
private final class AuthMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var statusCode: Int = 200

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: self.request.url!,
            statusCode: Self.statusCode,
            httpVersion: nil,
            headerFields: nil,
        )!
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: Data())
        self.client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
extension URLSession {
    fileprivate static func mock(status: Int) -> URLSession {
        AuthMockURLProtocol.statusCode = status
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AuthMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    fileprivate static func oauthMock() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OAuthMockURLProtocol.self]
        return URLSession(configuration: config)
    }
}

@MainActor
private final class OAuthMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var responseDelayNanoseconds: UInt64 = 0
    nonisolated(unsafe) static var responseData = try! JSONSerialization.data(withJSONObject: [
        "access_token": "access",
        "refresh_token": "refresh",
        "expires_in": 3600,
    ])

    nonisolated static func reset() {
        self.lastRequest = nil
        self.lastBody = nil
        self.requestCount = 0
        self.statusCode = 200
        self.responseDelayNanoseconds = 0
        self.responseData = try! JSONSerialization.data(withJSONObject: [
            "access_token": "access",
            "refresh_token": "refresh",
            "expires_in": 3600,
        ])
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        OAuthMockURLProtocol.requestCount += 1
        OAuthMockURLProtocol.lastRequest = self.request
        if let body = self.request.httpBody {
            OAuthMockURLProtocol.lastBody = body
        } else if let stream = self.request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 1024
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: bufferSize)
                if read > 0 {
                    data.append(buffer, count: read)
                } else {
                    break
                }
            }
            OAuthMockURLProtocol.lastBody = data
        }
        let statusCode = Self.statusCode
        let responseData = Self.responseData
        let responseDelayNanoseconds = Self.responseDelayNanoseconds
        if responseDelayNanoseconds > 0 {
            Thread.sleep(forTimeInterval: TimeInterval(responseDelayNanoseconds) / 1_000_000_000)
        }
        let response = HTTPURLResponse(
            url: self.request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"],
        )!
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: responseData)
        self.client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
