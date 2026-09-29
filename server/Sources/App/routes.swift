import FRNDSAPI
import Vapor

func routes(_ app: Application) throws {
    // Admin dashboard (first-run setup at /setup, then /admin).
    try app.register(collection: WebController(sessions: app.sessions.middleware))

    let api = app.grouped("api")
    api.get("health") { req in
        HealthResponse(status: "ok", instanceName: req.application.appConfig.instanceName, apiVersion: API.version)
    }

    try api.register(collection: AuthController())
    try api.register(collection: PostController())
    try api.register(collection: MediaController())
    try api.register(collection: SocialController())
    try api.register(collection: UserController())
    try api.register(collection: FriendController())
    try api.register(collection: ConfigController())
    try api.register(collection: MomentController())
    try api.register(collection: InboxController())
    try api.register(collection: HighlightController())
}
