import FriendsterAPI
import Vapor

// The shared DTOs are plain Codable; make them usable as Vapor request/response content.
extension HealthResponse: @retroactive Content {}
extension RegisterRequest: @retroactive Content {}
extension LoginRequest: @retroactive Content {}
extension AuthResponse: @retroactive Content {}
extension UserDTO: @retroactive Content {}
extension MediaDTO: @retroactive Content {}
extension CreatePostRequest: @retroactive Content {}
extension UpdatePostRequest: @retroactive Content {}
extension PostDTO: @retroactive Content {}
extension FeedPage: @retroactive Content {}
extension UpdateProfileRequest: @retroactive Content {}
extension ProfileDTO: @retroactive Content {}
extension FriendsOverview: @retroactive Content {}
extension ReactionRequest: @retroactive Content {}
extension ReactionSummary: @retroactive Content {}
extension ReactionDTO: @retroactive Content {}
extension CommentDTO: @retroactive Content {}
extension CreateCommentRequest: @retroactive Content {}
extension InstanceConfig: @retroactive Content {}
extension MomentDTO: @retroactive Content {}
extension MomentsFeed: @retroactive Content {}
extension InboxPage: @retroactive Content {}
extension MomentTimeDTO: @retroactive Content {}
extension MomentWindow: @retroactive Content {}
extension StreakDTO: @retroactive Content {}
extension HighlightDTO: @retroactive Content {}
extension CreateHighlightRequest: @retroactive Content {}
extension UpdateHighlightRequest: @retroactive Content {}
