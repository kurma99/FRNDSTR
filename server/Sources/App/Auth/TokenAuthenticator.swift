import Fluent
import FrndstrAPI
import Vapor

/// Authenticates `Authorization: Bearer <token>`. For media routes the token may also come
/// from the `?token=` query item, because AVPlayer can't set custom headers.
struct TokenAuthenticator: AsyncRequestAuthenticator {
    var allowQueryToken = false

    func authenticate(request: Request) async throws {
        let raw = request.headers.bearerAuthorization?.token
            ?? (allowQueryToken ? request.query[String.self, at: API.mediaTokenQueryItem] : nil)
        guard let raw, !raw.isEmpty else { return }

        guard let token = try await UserToken.query(on: request.db)
            .filter(\.$tokenHash == UserToken.hash(raw))
            .with(\.$user)
            .first()
        else { return }

        request.auth.login(token.user)
        request.auth.login(token)
    }
}

extension UserToken: Authenticatable {}
