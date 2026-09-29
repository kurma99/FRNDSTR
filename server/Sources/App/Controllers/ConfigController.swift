import Fluent
import FRNDSAPI
import Vapor

/// Instance-wide settings: readable by everyone, writable by admins.
struct ConfigController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let protected = routes.grouped(TokenAuthenticator(), User.guardMiddleware())
        protected.get("config", use: config)
        // Instance settings are changed in the web dashboard (/admin), not through the app API.
    }

    @Sendable
    func config(req: Request) async throws -> InstanceConfig {
        InstanceConfig(instanceName: req.application.appConfig.instanceName,
                       reactionEmojis: try await InstanceSetting.reactionPalette(on: req.db),
                       momentWindow: try await MomentTime.window(on: req.db))
    }
}
