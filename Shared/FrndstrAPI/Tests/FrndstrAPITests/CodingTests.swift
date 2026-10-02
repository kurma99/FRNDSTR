import Foundation
import Testing
@testable import FrndstrAPI

@Test func postRoundTripsThroughSharedCoders() throws {
    let user = UserDTO(id: UUID(), username: "anna", displayName: "Anna",
                       createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    let media = MediaDTO(id: UUID(), kind: .video, displayPath: "/api/media/x/display",
                         thumbnailPath: "/api/media/x/thumb", width: 1080, height: 1920, duration: 12.5)
    let post = PostDTO(id: UUID(), author: user, caption: "Hi", createdAt: user.createdAt, media: [media])

    let data = try API.makeEncoder().encode(post)
    let decoded = try API.makeDecoder().decode(PostDTO.self, from: data)

    #expect(decoded == post)
    #expect(abs(decoded.media[0].aspectRatio - 0.5625) < 0.0001)
}

@Test func paletteNormalization() {
    #expect(API.normalizedPalette(["❤️", " 😂 ", "😂", "a", "12", "👍🏽", "🇩🇪"]) == ["❤️", "😂", "👍🏽", "🇩🇪"])
    #expect(API.normalizedPalette(["abc", ""]) == nil)
    #expect(API.normalizedPalette(Array(repeating: "🔥", count: 3)) == ["🔥"])
    let many = ["😀", "😃", "😄", "😁", "😆", "😅", "🤣", "😂", "🙂", "🙃", "😉", "😊", "😇"]
    #expect(API.normalizedPalette(many) == nil)
}

@Test func momentLocationIsOptionalAndRoundTrips() throws {
    // Older clients send no location; older servers return none.
    let request = try API.makeDecoder().decode(CreateMomentRequest.self,
                                               from: Data(#"{"recipientIDs":[]}"#.utf8))
    #expect(request.location == nil)

    let user = UserDTO(id: UUID(), username: "anna", displayName: "Anna",
                       createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    let moment = MomentDTO(id: UUID(), sender: user, caption: nil, createdAt: user.createdAt,
                           expiresAt: user.createdAt.addingTimeInterval(86_400), isLocked: false,
                           backPath: "/b", frontPath: "/f", recipients: nil,
                           location: PostLocation(latitude: 53.55, longitude: 9.99, placeName: "Hamburg"))
    let decoded = try API.makeDecoder().decode(MomentDTO.self, from: API.makeEncoder().encode(moment))
    #expect(decoded == moment)
    #expect(decoded.location?.placeName == "Hamburg")
}
