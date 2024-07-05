import Foundation
import OpenAPIRuntime
import TuistSupport

public enum ServerClientAuthenticationError: FatalError, Equatable {
    case notAuthenticated
    case tokensExpiredOrInvalid

    public var type: ErrorType {
        switch self {
        case .notAuthenticated, .tokensExpiredOrInvalid:
            return .abort
        }
    }

    public var description: String {
        switch self {
        case .notAuthenticated:
            return "No Tuist authentication token found. Authenticate by running `tuist auth`."
        case .tokensExpiredOrInvalid:
            return "Your Tuist credentials are expired or invalid. Run `tuist auth` to reauthenticate"
        }
    }
}

/// Injects an authorization header to every request.
struct ServerClientAuthenticationMiddleware: ClientMiddleware {
    private let serverAuthenticationController: ServerAuthenticationControlling
    private let serverCredentialsStore: ServerCredentialsStoring
    private let refreshAuthTokenService: RefreshAuthTokenServicing
    private let dateService: DateServicing

    init() {
        self.init(
            serverAuthenticationController: ServerAuthenticationController(),
            serverCredentialsStore: ServerCredentialsStore(),
            refreshAuthTokenService: RefreshAuthTokenService(),
            dateService: DateService()
        )
    }

    init(
        serverAuthenticationController: ServerAuthenticationControlling,
        serverCredentialsStore: ServerCredentialsStoring,
        refreshAuthTokenService: RefreshAuthTokenServicing,
        dateService: DateServicing
    ) {
        self.serverAuthenticationController = serverAuthenticationController
        self.serverCredentialsStore = serverCredentialsStore
        self.refreshAuthTokenService = refreshAuthTokenService
        self.dateService = dateService
    }

    func intercept(
        _ request: Request,
        baseURL: URL,
        operationID _: String,
        next: (Request, URL) async throws -> Response
    ) async throws -> Response {
        var request = request
        guard  let token = try serverAuthenticationController.authenticationToken(serverURL: baseURL)
        else {
            throw ServerClientAuthenticationError.notAuthenticated
        }

        let tokenValue: String
        switch token {
        case let .project(token):
            tokenValue = token
        case let .user(legacyToken: legacyToken, accessToken: accessToken, refreshToken: refreshToken):
            if let legacyToken {
                tokenValue = legacyToken
            } else if let accessToken, let refreshToken {
                // We consider a token to be expired if the expiration date is in the past or 30 seconds from now
                let isExpired = accessToken.expiryDate
                    .timeIntervalSince(dateService.now()) < 30

                if refreshToken.expiryDate.compare(dateService.now()) == .orderedAscending {
                    throw ServerClientAuthenticationError.tokensExpiredOrInvalid
                }

                if isExpired {
                    let newTokens = try await refreshAuthTokenService.refreshTokens(
                        serverURL: baseURL,
                        refreshToken: refreshToken.token
                    )
                    try serverCredentialsStore
                        .store(
                            credentials: ServerCredentials(
                                token: nil,
                                accessToken: newTokens.accessToken,
                                refreshToken: newTokens.refreshToken
                            ),
                            serverURL: baseURL
                        )
                    tokenValue = newTokens.accessToken
                } else {
                    tokenValue = accessToken.token
                }
            } else {
                throw ServerClientAuthenticationError.tokensExpiredOrInvalid
            }
        }

        request.headerFields.append(.init(
            name: "Authorization", value: "Bearer \(tokenValue)"
        ))
        return try await next(request, baseURL)
    }
}
