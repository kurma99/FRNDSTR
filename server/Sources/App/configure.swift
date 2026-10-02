import Fluent
import FluentSQLiteDriver
import FrndstrAPI
import Leaf
import Vapor

/// Configures the application. Tests pass their own `config` (temporary data directory).
func configure(_ app: Application, config: AppConfig = .fromEnvironment()) async throws {
    app.appConfig = config
    try FileManager.default.createDirectory(atPath: config.mediaDirectory, withIntermediateDirectories: true)

    if app.environment == .testing {
        app.databases.use(.sqlite(.memory), as: .sqlite)
    } else {
        app.databases.use(.sqlite(.file(config.databasePath)), as: .sqlite)
    }

    app.migrations.add(CreateUsers())
    app.migrations.add(CreateUserTokens())
    app.migrations.add(CreateInvites())
    app.migrations.add(CreatePosts())
    app.migrations.add(CreatePostMedia())
    app.migrations.add(CreateReactions())
    app.migrations.add(CreateComments())
    app.migrations.add(CreateFriendships())
    app.migrations.add(AddPostLocation())
    app.migrations.add(AddUserAvatar())
    app.migrations.add(CreateInstanceSettings())
    app.migrations.add(AddUserAdmin())
    app.migrations.add(CreateMoments())
    app.migrations.add(AddMomentLayoutAndPost())
    app.migrations.add(CreateEvents())
    app.migrations.add(CreateMomentDays())
    app.migrations.add(AddMomentInsetSize())
    app.migrations.add(AddMomentLocation())
    app.migrations.add(CreateHighlights())

    // Same ISO-8601 dates as the app.
    ContentConfiguration.global.use(encoder: API.makeEncoder(), for: .json)
    ContentConfiguration.global.use(decoder: API.makeDecoder(), for: .json)

    app.asyncCommands.use(InviteCommand(), as: "invite")
    app.asyncCommands.use(AdminCommand(), as: "admin")
    app.lifecycle.use(MomentJanitor())

    app.views.use(.leaf)
    app.sessions.use(.memory)
    app.sessions.configuration.cookieName = "frndstr-admin"

    try await app.autoMigrate()
    try await Bootstrap.announceSetup(on: app)
    try routes(app)
}
