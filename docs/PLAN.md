# Frndstr — Plan

Private, self-hosted family Instagram with BeReal-style Moments. This is a living document: update it when decisions change and log the *why* in [JOURNAL.md](JOURNAL.md).

## Goals
- **Posts**: images/videos, caption, recency feed, reactions, comments. Anyone can save them.
- **Moments**: front+back photo sent to friends, visible for 24h, builds a **friendship streak**. The sender keeps it; recipients can't save it.
- **Save to Photos** with caption and location embedded (readable in Apple Photos), after asking the user.
- **Takeout**, **notifications + reminders**, a **read-only web feed**.
- **Private & self-hosted**: one `docker compose` on your own server. The app asks for URL + port, and plain HTTP is allowed (Tailscale).

---

## 1. Server vs. phone

**Rule: the server is the source of truth for shared state and a short-lived relay for moments. The phone owns capture, metadata, and anything that is "yours forever".**

| Concern | Where | Why |
|---|---|---|
| Accounts, invites, friend graph | Server | Must be shared. Invite-only keeps it private. |
| Posts (media, caption, reactions, comments) | Server (permanent) | Everyone sees them; web viewer + takeout need them. |
| Thumbnails, video transcode (→ H.264 MP4) | Server (ffmpeg) | Uniform, web-compatible output; saves phone battery. |
| Feed ordering, pagination | Server | Cursor pagination by `createdAt`. |
| Moments media | Server = **relay only**, deleted after 24h | Recipients must not keep it, so the server can't either. |
| Highlights (M6.2) | Server (permanent), uploaded by the sender from their archive | The sender chose to keep them visible to friends. |
| Sender's moments archive | **Phone** (app storage + optional auto-save to Photos) + **private owner-only backup on the server** (M6.4) | "I keep it, my friends don't." The backup means a new phone, a reinstall or a changed app ID can't lose it. |
| Streak calculation | Server | Needs both sides' activity; tamper-free. |
| Notification events | Server: `/api/inbox?since=` | The phone polls now; APNs later pushes the same events. |
| Notification delivery (for now) | **Phone**: local notifications after an inbox sync | No APNs needed yet. |
| Daily moment reminder | Server picks a random family time → phone schedules it locally | Shared BeReal moment without push. |
| Streak-at-risk reminder | Phone: local notification at 20:00, cancelled once you send | The phone knows if you've sent. |
| Camera capture (front+back) | Phone | Hardware. |
| EXIF/IPTC/XMP writing, saving to Photos | **Phone** | PhotoKit and user consent live on the device. |
| Location | Phone, **opt-in per post/save** | Privacy. |
| Local cache | Phone (SwiftData + disk cache) | Fast scrolling, offline viewing. Disposable. |
| Takeout | **Both**: server zip (posts, comments, media, highlights) + phone's moments archive, packed into one zip on the phone (M6.2) | Each side exports what only it has. |

The server stays small (one process + SQLite + a media folder = trivial backups). Privacy decisions happen on the device, where the user makes them.

---

## 2. Architecture

**Stack:** Swift **Vapor** + **Fluent/SQLite** + **Leaf** (web viewer) + **ffmpeg**, in one container.

```
server/                    # self-contained; split into its own repo later (§6)
  Package.swift, Dockerfile, docker-compose.yml, .env.example, README.md
  Sources/App/{Models,Migrations,Controllers,Jobs}, Resources/Views (Leaf)
Shared/FrndstrAPI/      # dependency-free SwiftPM package: Codable DTOs + endpoints
Frndstr/                # iOS app (Xcode project), depends on FrndstrAPI
docs/PLAN.md, docs/JOURNAL.md
```

**Connectivity:** the onboarding screen takes `scheme://host:port` and validates it with `GET /api/health`. Info.plist sets `NSAllowsArbitraryLoads = YES` so plain HTTP works. The README recommends `tailscale serve` for free HTTPS.

**Auth:** the admin creates invite codes via CLI (`docker compose exec frndstr ./App invite`). The user enters code + name + password and gets a long-lived bearer token (stored hashed on the server, in the Keychain on the phone). The web viewer uses the same login with a cookie session.

**Data model (SQLite):**
- `users(id, name, avatarPath, passwordHash, timezone, createdAt)`
- `tokens(id, userId, hash)`, `invites(code, createdBy, usedBy)`, `devices(id, userId, apnsToken, env)` (M9)
- `friendships(userA, userB, status)` for moments/streaks. The feed shows everyone on the server.
- `posts(id, authorId, caption, lat?, lon?, placeName?, takenAt?, createdAt)`
- `post_media(id, postId, kind, originalPath, displayPath, thumbPath, w, h, duration, order)` (carousel)
- `reactions(postId, userId, emoji)`, `comments(id, postId, userId, text, createdAt)`
- `moments(id, senderId, backPath, frontPath, caption?, createdAt, expiresAt)` + `moment_recipients(momentId, userId, viewedAt?)`
- `streaks(userA, userB, count, lastDay)`
- `memory_backups(id = archive ID, ownerId, takenAt, caption?, recipientNames, layout…, lat?, lon?, placeName?)`; files in `data/media/memories/{ownerId}/{id}/` (owner-only, M6.4)
- `highlights(id, ownerId, title, coverItemId?, createdAt)` + `highlight_items(id, highlightId, sourceId, caption?, takenAt)`; files in `data/media/highlights/{itemId}/`
- `events(id, userId, type, refId, createdAt)` (notification inbox)

**Media:** `data/media/{posts|moments}/{uuid}/…`. GPS is stripped unless the author opted in.

---

## 3. Feature designs

**Moments:** `AVCaptureMultiCamSession` captures front + back at the same time; if multi-cam isn't available, it falls back to back then front. The back photo is full-screen with a draggable front picture-in-picture. **Unlimited sends per day.** Recipients are picked per send, with all friends preselected. **Friends' moments from today stay blurred until you've sent at least one today** (the server enforces this). Moments expire after 24h; a server job deletes the files and rows every 10 min. Recipients get no save/share action. Screenshots can't be blocked on iOS, so they are detected (`userDidTakeScreenshotNotification`) and the sender is notified. The sender's copy (both originals + composite) is stored locally *before* upload and can be auto-saved to Photos.

**Streak:** a day counts when **both** friends sent each other at least one moment that calendar day (server timezone, configurable). A missed day resets it.

**Save to Photos with metadata (phone-side):**
- Consent sheet: ☐ include caption ☐ include location, plus "remember my choice" in Settings.
- Images: ImageIO writes the caption to IPTC `Caption/Abstract`, XMP `dc:description` and EXIF `UserComment`; GPS into the GPS dictionary; the date into `DateTimeOriginal`.
- `PHAssetCreationRequest.location` / `creationDate` are set too, so the Photos map and timeline are right.
- Videos: passthrough export with `AVMetadataItem`s (description, ISO6709 location, creation date).
- Moments: save the composite (plus optionally both originals). No custom album: creating albums needs full library access, and we only ask for add-only.
- Uses add-only Photos permission.

**Notifications (local for now):**
- The server records events (new moment, comment, reaction, new post) → `GET /api/inbox?since=<cursor>`.
- The app syncs on launch/foreground and via `BGAppRefreshTask`, then posts local notifications. Taps deep-link to `frndstr://moment/{id}` and `frndstr://post/{id}`.
- `GET /api/moment-time` → the app schedules today's and tomorrow's family moment reminder.
- **Limitation:** iOS decides when background refresh runs, and never runs it after a force-quit. So "you got a photo" alerts can be delayed; scheduled reminders are always on time. APNs (M9) fixes the delay.

**Web viewer:** Leaf at `/`: login, paginated feed, post detail with comments/reactions. Read-only, no moments.

**Takeout:**
- Server: `POST /api/takeout` → a background job builds a zip with your post media (caption and location embedded via exiftool) plus `posts.json`, `comments.json` and `reactions.json`.
- App: Settings → "Export my Moments" → zip of the local archive via the share sheet.
- From M6.2: a single "Download my data" — the app downloads the server zip (now also with your highlights) and packs it together with its Memories archive (`moments/`) into one zip for the share sheet. The server zip stays nested because iOS can't unzip.

---

## 4. Milestones

Each milestone ends with something usable on a real phone and a JOURNAL entry.

### M0 — Foundations ✅ (2026-09-27)
- [x] Repo layout: `server/`, `Shared/FrndstrAPI/`, `.gitignore`s
- [x] `FrndstrAPI` package (health, auth DTOs), linked into the app
- [x] Vapor skeleton, Dockerfile, `docker-compose.yml`, `.env.example`, `GET /api/health`
- [x] Users, invites, tokens + migrations; `invite` CLI command; register/login endpoints
- [x] iOS: onboarding (URL + port, HTTP allowed), register/login, token in Keychain
- **Done when:** `docker compose up` runs on the server, and the phone connects over Tailscale HTTP and logs in with an invite.
  - Verified: simulator ↔ native server over HTTP; `docker compose up` smoke test on the Mac. Still to do: the real home server + a real phone over Tailscale.

### M1 — Posts MVP ✅ (2026-09-27)
- [x] Upload 1–10 images/videos (PhotosPicker + camera) with caption
- [x] Server: store originals, thumbnails, ffmpeg transcode
- [x] Cursor-paginated feed, post detail, media cache
- [x] Profiles with a post grid (`?author=` filter), pulled forward from M2
- **Done when:** the family can post and scroll a feed.
  - Verified in the simulator with two accounts: 3-item carousel post (2 photos + video), single-photo post, profiles, logout/login.

### M2 — Social ✅ (2026-09-27)
- [x] Reactions (one per person per post, palette ❤️😂😮😢🔥👏, double-tap = ❤️), comments
- [x] Profiles/avatars, edit name, delete your own posts; comment author or post author can delete comments
- [x] Friend requests (needed for moments): send, accept, decline, cancel, unfriend; badge for pending requests
- **Done when:** comments and reactions round-trip across two phones.
  - Verified in the simulator with four test accounts.

### M3 — Save + metadata ✅ (2026-09-27)
- [x] Consent sheet (caption / location / remember) + defaults in Settings
- [x] ImageIO / AVFoundation metadata writer (+ unit tests: IPTC/XMP caption, GPS both hemispheres, EXIF date, video description + ISO 6709)
- [x] PhotoKit save (add-only access); opt-in location on posts (photo's own GPS first, else current location, reverse-geocoded)
- **Done when:** a saved image shows the caption and a map pin in Apple Photos.
  - Verified: Apple Photos shows the caption, the map pin and the capture date.

### M4 — Moments ✅ (2026-09-27, camera still to test on a real iPhone)
- [x] Multi-cam capture (`AVCaptureMultiCamSession`) + sequential fallback; picking photos from the library exists only in Simulator builds (testing); 3:4 composite
- [x] Editing step before sharing: drag the small photo to any corner (snaps), tap/Switch to swap, flip selfie/back, caption; recipients see the sender's arrangement first and can rearrange it for themselves
- [x] Share step: "All friends" or "Selected friends" (then a checklist, remembering last time's picks)
- [x] Send to the chosen friends only (server checks they're friends), "post to see" lock, 24h viewer with "Xh left", tap inset to swap
- [x] Server expiry job (startup + every 10 min, deletes rows and files); per-account Memories archive on the phone; "Save to my Photos" option (default in Settings); screenshot notice to the sender; "Seen by X of Y"
- [x] Opt-in "Share as a post when it's over" (off by default): the composite is uploaded with the moment but the server only publishes it when the moment expires, dated to when it was taken
- [x] Defaults in Settings › Moment defaults: share with, small-photo corner, flip selfie, share as post, save to Photos
- **Done when:** a friend sees the moment for 24h, then it's gone from the server, and the sender still has it.
  - Verified in the simulator (photo-picker path) and by server tests (lock/unlock, friends-only, expiry purge). Real dual-camera capture needs a physical iPhone.

### M4.1 — Memories calendar & playback (BeReal-style) ✅ (2026-09-27)
- [x] Memories as a calendar: one section per month ("September 2026"), weeks as rows of 7 with a MON … SUN header (week starts Monday), each day shows its date number and, if you shared a moment that day, a small thumbnail of it (several moments that day → newest + count)
- [x] Thumbnails: a small JPEG is saved next to each archived moment (generated once for older ones) so the grid never decodes full-size images
- [x] Play button next to each month title: full-screen playback of that month's moments one after another (≈3 s each), date shown on top
- [x] Segmented progress bar at the bottom, one divider per moment; the current segment fills up
- [x] Swipe left → next moment, swipe right → previous; tap a day in the grid to open that moment
- **Done when:** a month with several moments shows as a calendar with thumbnails and plays through with a working progress bar and swipe navigation.
  - Verified in the simulator with two months of test memories (count badge, day tap, auto-advance, swipe both ways, auto-close). Touch-and-hold pauses playback.

### M5 — Local notifications ✅ (2026-09-27)
- [x] Server events (moment, post incl. released moment-posts, comment, reaction, friend request/accept), `/api/inbox?since=` (first call only returns a cursor, no flood), events pruned after 30 days
- [x] Shared daily moment time: one random time per day for everyone, window 9–21 by default, admin can change it (Settings › Admin › Moment time window); `/api/moment-time` gives today + tomorrow
- [x] App sync on foreground + `BGAppRefreshTask`; local notifications; taps route to Moments, a post, or Friends
- [x] Settings › Notifications: per-type switches. Defaults ON: new moments for me, new family posts, daily moment time, streak reminder. OFF: comments & reactions, friend requests
- **Done when:** "Anna sent you a moment" appears after a sync, and the daily reminder fires on schedule.
  - Verified: banners + Notification Center entries for a real post and moment. Tapping a notification couldn't be automated; check by hand.

### M6 — Streaks ✅ (2026-09-27)
- [x] `moment_days` history (outlives the 24h moments); `StreakCalculator` with fixed-clock tests: both must send each other a moment on a day; one missed day per calendar week (Mon–Sun) is forgiven; today never breaks a streak
- [x] `/api/streaks`; 🔥 badges in Friends, on the share list and a Streaks row in Moments (orange + hourglass when it would end at midnight); local reminder at 20:00 if you still need to send
- **Done when:** two test accounts build a 3-day streak correctly.
  - Verified with seeded history (4 days) → sending today made it 5.

### M6.1 — Navigation & Memories polish
- [ ] Rename the "Home" tab to "Feed" (tab label and screen title)
- [ ] ~~Remove "New post" from the bottom tab bar~~ — dropped (2026-09-28): "New post" stays in the tab bar
- [ ] Memories calendar: days with more than one moment show a badge with the number of moments. M4.1 may already do this ("newest + count") — first check that it's there with a test (e.g. a day with 3 archived moments renders a "3" badge) and only change code if it isn't
- [ ] New post: the "Add location" toggle doesn't follow the location default in Settings — it should start on/off (and fetch the location) based on that setting
- [x] Moments: add the same location option (default from Settings, can be turned off per moment). Done 2026-10-02: **on by default**; the place is shown to recipients only once the moment is unlocked, kept in Memories, written into Photos saves and the takeout, and carried into the post if the moment becomes one
- [ ] Moments: remove the flip options ("Flip selfie" / "Flip back" in the edit step and the flip-selfie default in Settings › Moment defaults); keep only the switch-position button
- [ ] Moments UI: make the Moments screens (tab, capture, edit, send, viewer) match the look of the rest of the app — same `Theme` colors, fonts, spacing, card/list styles and toolbar buttons
- [ ] "You shared your moment today" / "Time for your moment" card (`MomentsView`): keep the yellow, but rebuild it with Liquid Glass (glass effect tinted yellow, glass buttons) so it stops looking like BeReal or a stock Google-style card. Look up the current Liquid Glass APIs (`glassEffect`, `GlassEffectContainer`, `.buttonStyle(.glass)`) before building it
- [ ] Rename the "Your moments" section in the Moments tab to "Today's moments"
- [ ] Profiles: make them look more like Apple's own apps. Suggested direction (to confirm with the user): large centered round avatar with name and username below it (like the Apple Account / Contacts card), stats and actions as Liquid Glass buttons, the rest in an inset-grouped list, system fonts and SF Symbols
- **Done when:** the tab bar still has "New post" and the first tab is called "Feed", a test proves a day with 3 moments shows a "3" badge, new posts and moments start with location on when the default is on, the moment editor has no flip buttons, the moment status card uses yellow-tinted Liquid Glass, the section says "Today's moments", and the Moments and Profile screens look like the rest of the app.

### M6.3 — Moments polish ✅ (2026-10-02)
- [x] The shared daily moment time on the Moments status card is blurred until you tap it (tap again to hide), so it stays a surprise; VoiceOver only reads it once revealed
- [x] Moment location (see M6.1): "Add location" in the send step and Settings › Moment defaults, on by default. Server: `latitude`/`longitude`/`place_name` on `moments`, same validation as posts
- [x] Memories calendar runs chronologically: oldest month at the top, newest at the bottom, and it opens scrolled to the newest month
- **Done when:** the moment time is hidden until tapped, a friend sees where a moment was taken after unlocking it, and Memories reads top to bottom in time order.
  - Verified by tests (server: location hidden while locked, invalid coordinates rejected, carried into the published post; API: old payloads without location still decode; app: old archive entries still load, month order) and in the simulator with two accounts.

### M6.4 — Memories backup on the server ✅ (2026-10-02)
- [x] Why: changing the bundle ID (`friendster` → `frndstr`) gave the TestFlight app a fresh, empty container, and every Memory that only lived on the phone was lost
- [x] The phone uploads every archived moment (back, front, composite, thumbnail + caption, recipients, layout, place) to `POST /api/memories`; re-uploads are no-ops. Existing local Memories are uploaded on the first sync
- [x] Two-way sync by archive ID: on opening Memories (always), after sending, and on refresh (at most every 10 min). Memories missing on the phone are downloaded, so a new iPhone or reinstall gets everything back
- [x] Owner-only: `GET /api/memories`, `GET /api/memories/:id/{back,front,composite,thumb}`, `DELETE /api/memories/:id`; anyone else gets 404 (409 on an ID clash). Deleting a memory in the app deletes the server copy (retried until confirmed); deleting the account removes the folder; the dashboard shows the storage
- [x] Settings › "Back up Memories to server", on by default
- **Done when:** after uninstalling and reinstalling the app, logging in brings the Memories back.
  - Verified by tests (server: owner-only access, idempotent upload, delete + account deletion remove files, validation; app: archive ↔ backup mapping) and in the simulator: send → on server → uninstall → reinstall → Memories restored → delete removes the server copy.

### M6.2 — Feed actions, moment highlights & gestures ✅ (2026-09-28, verified in the simulator)
**Feed / posts**
- [x] Post card action row: reaction and comment buttons on the **right**; the separate download button is gone. "Save to Photos" is only in the "…" menu
- [x] Edit caption: "Edit caption" in the "…" menu (own posts only) opens a small editor prefilled with the current caption; empty = remove the caption. Server: `PATCH /api/posts/{id}` (author only, same length limit as on create); feed/detail/profile update in place. No notification
**Moments**
- [x] Highlights (like Instagram): on your profile you group your own moments into named highlights. Picked from your Memories archive, so older moments work too. Round covers under the profile header ("New" button for yourself); tap → full-screen player (same player as Memories). Touch and hold a cover → Edit: rename, add/remove moments, pick the cover, delete
  - Server keeps only highlighted moments (the phone uploads the composite + thumbnail from its archive), friends-only (others get an empty list / 404 on the photos), each moment only once its 24h are over (highlights with no such moment yet are hidden from friends; future `takenAt` is clamped to now), no save action for viewers. `GET /api/users/{id}/highlights`, `POST/PATCH/DELETE /api/highlights[/{id}]`, `POST /api/highlights/{id}/items` (multipart), `DELETE …/items/{itemID}`. Deleting an account removes its highlights; the dashboard shows their storage
- [x] Takeout: one "Download my data" zip. iOS has no unzip API, so it holds `posts-and-highlights.zip` (the server's zip, now with `highlights/` + `highlights.json`) next to `moments/` (one dated folder per moment: `moment.jpg` with caption/date embedded, `back.jpg`, `front.jpg`) and `moments.json`
- [x] Active moments on a profile: if a person has moments sent to you that haven't expired yet (or on your own profile: your live ones), the avatar gets a thicker ring; tapping it plays them, newest first. The "post to see" lock still applies; opened ones count as seen and screenshots are reported
- [x] Edit step: pinch with two fingers to resize the small photo (20–50 % of the width); it still drags and snaps to corners. The size is stored in `MomentLayout.insetSize` (optional, so older moments/clients still work), sent to the server for recipients, and used for the archived composite
- [x] Moments tab like Instagram stories: a row of round bubbles on top ("Your moment" first with a + badge, then each friend with live moments; gradient ring = new, grey = seen, lock = post first), tapping plays them; "+" (yellow glass) in the top-right toolbar next to Memories takes a new moment; yellow-tinted Liquid Glass status card, glass streak and "Today's moments" cards
- [x] Story player (Memories, live moments, highlights): tap the right side → next, left third → previous, in addition to the swipes. Touch-and-hold still pauses
- **Done when:** the feed shows reactions/comments on the right and no separate download button; a caption can be edited from "…" and the change shows for everyone; a highlight made from old moments appears on the profile and plays for a friend; tapping a friend's ringed avatar plays their live moments; the small photo can be pinched to a new size that the recipient sees; tapping left/right in Memories steps back/forward.
  - Verified by tests: server (caption edit rights/limits, highlight friends-only access/owner-only edits/dedupe/cover/file cleanup, takeout contains highlights) and app (inset size clamping + decoding old layouts, composite uses the pinched size, moments export with embedded caption, highlight cover fallback). Simulator walkthrough (2026-09-28): feed row + menu, caption edit (persists after refresh, friend sees it), stories row + player stepping, + opens capture, Memories tap stepping, highlight create/play/rename (friend sees it via the API). Pinch confirmed by the user.

### M7 — Admin web dashboard ✅ (2026-09-27, replaces the planned read-only web feed)
- [x] First start: the browser opens a setup page to create the admin account (no invite code in the logs anymore)
- [x] Login for admins only (same username/password as the app), cookie session, CSRF-protected forms, no JavaScript
- [x] Storage: total, per kind (originals, display copies, thumbnails, live moments, profile photos, database) with file counts and sizes; posts/comments/reactions; unposted uploads + cleanup
- [x] People: per-user posts, photos, videos, live moments, storage, sessions; log out everywhere, reset password, make/remove admin (never the last one), delete account with all posts, media and moments
- [x] Invite codes: create (1/3/5), revoke, used/unused lists
- [x] Settings moved here from the app: reaction emoji, daily moment time window (the app only links to the dashboard for admins)
- [x] Works on a phone (tables scroll inside their card, sticky messages, no input zoom)
- **Done when:** an admin sets up a fresh server in the browser and manages people, invites and settings there.
  - Verified in the Linux container (fresh data → setup → dashboard → invites) and in Safari on the simulator.

### M8 — Takeout + ops
- [x] Server takeout zip (your posts only: original files with caption/place/date written into photos, posts.json with comments & reactions on them, profile.json, README) — synchronous download from Settings › Your data
- [x] On-device Memories export (zip of the local archive via the share sheet)
- [ ] Backup/restore docs (copy `./data`); admin CLI (reset password and remove user are already in the web dashboard)
- [x] Public-repo prep (2026-09-29): personal names/places removed from code, tests and docs, fresh git history, MIT LICENSE, README with the "vibe coded → run it behind Tailscale, let your agent do a security check" note
- [x] GitHub Actions: `ci.yml` (server + FrndstrAPI tests on Linux in `swift:6.2-noble` with ffmpeg/exiftool/zip), `docker.yml` (native amd64 + arm64 builds → multi-arch `ghcr.io/<owner>/frndstr-server`, `latest` on main, semver on `v*` tags); compose can use it via `FRNDSTR_IMAGE`
- [x] App Store prerequisites: bundle ID `cloud.mallwitz.frndstr` (iPhone only), `PrivacyInfo.xcprivacy` (no tracking, no collected data, UserDefaults reason CA92.1), `ITSAppUsesNonExemptEncryption = NO`
- [x] TestFlight distribution: developer account enrolled, app record created, build 1.0 (1) archived and uploaded with `xcodebuild` (2026-10-02). Next: internal testing group, test on a real iPhone (dual camera)
- [ ] Liquid Glass app icon made in Icon Composer: the standard SF Symbols camera glyph on the lime → citrus gradient, with light, dark, clear and tinted variants
- **Done when:** a user can export everything they own, and restore from backup has been tested.

### M9 — APNs (later)
- [ ] Server pushes the existing events via APNs (.p8 key as a compose secret)
- [ ] App registers its device token; local sync stays as a fallback
- **Done when:** a closed or force-quit app gets the alert instantly.

---

## 5. Verification
- **Server:** Swift Testing / XCTVapor tests per controller (auth, pagination, moment expiry, streak logic with a fixed clock). Smoke test: `docker compose up` + `curl /api/health`.
- **iOS:** Swift Testing for the metadata writer (write → read back → assert IPTC caption + GPS) and the API client (mocked `URLProtocol`); XCUIAutomation for onboarding + posting. Multi-cam needs a physical device. Local notifications and background refresh can be tested in the simulator/debugger.
- **End-to-end:** two accounts on two devices against the real compose deployment over Tailscale.

## 6. Splitting the server into its own repo
- `server/` is fully self-contained (own `Package.swift`, `Dockerfile`, compose file, README, `.gitignore` for `data/`, `.env`, `*.p8`) and never references `../`.
- `Shared/FrndstrAPI/` has no dependencies.
- To split: `git subtree split --prefix=server` → new repo (history preserved). `FrndstrAPI` becomes its own small repo, which the server and the app both depend on by git URL + version tag.
- Secrets never go in git; only `.env.example` is committed.

## 7. Decisions

**Decided (2026-09-26)**
- Notifications: local now, APNs in M9.
- Stack: Vapor + SQLite + Leaf, one container.
- Clients: iOS + read-only web viewer. Minimum **iOS 26**.
- No E2E encryption: the server is trusted; TLS or Tailscale protects data in transit.
- Feed: everyone on the server sees all posts.
- Moments: unlimited, recipients picked per send, "post to see today's moments".
- Shared DTOs: separate `FrndstrAPI` repo after the split.
- Location visibility (M3): only when the author turns on "Add location"; the place name is shown under the author's name, coordinates are used for saving to Photos.
- Reactions (M2): one reaction per person per post (reacting again replaces it). **No separate "like"** (removed in M4 round): the reaction button is the only one.
- Reaction palette: the server stores it; **admins edit it in the web dashboard** (moved out of the app in M7). The admin account is created on the web setup page at first start; `./App admin <user> [--revoke]` still works.
- Theme: **yellow is the primary colour** (`Theme.primary` fills with dark labels via `primaryButtonStyle()`); tint is deep gold in light mode and bright yellow in dark mode so text-like controls stay readable; soft yellow-centred lime → citrus gradient.
- Appearance follows the system; Settings › Appearance can force Light or Dark.
- Moments are camera-only on devices (no library upload); the photo-picker path is compiled only for the Simulator.
- A moment shared as a post appears in the feed when the moment ends, with the moment's original date (so it sorts where it happened).
- Moments "today", streak days and the shared moment time use the server's `TIME_ZONE` (e.g. `Europe/Berlin`).
- Streak rule (M6): both send each other; one forgiven missed day per calendar week.
- Daily moment time (M5): shared random time, window admin-configurable in the web dashboard (default 9–21).
- Web (M7): an admin dashboard, not a feed. Admin-only login with the normal account.
- Takeout (M8): own posts only; comments and reactions on them are included in posts.json.
- Highlights (M6.2, 2026-09-28): the only moments the server keeps past 24h. The sender's phone uploads the moments they put in a highlight from its archive; everything else still expires. Visible to **friends only**, and each moment only **24h after it was taken** (while it's live it stays with its recipients; the owner sees everything, with a "friends see it in …" badge). Viewers **can't save** them, and they're part of the takeout.
- Memories backup (M6.4, 2026-10-02): the server also keeps a **private, owner-only** copy of each sender's Memories. This doesn't change the core rule: recipients still lose access after 24h and can't save anything. It only means the sender's own copy no longer depends on one phone.
- Takeout includes moments (M6.2, 2026-09-28): "Download my data" gives **one zip** with your posts, highlights **and your moments** (the server's zip nested next to the phone's Memories archive), instead of two separate exports.

**Open (decide at the listed milestone)**
| Decision | Proposal | By |
|---|---|---|
| Auth model | Invite code + password; resets only via the admin CLI | M0 |
| Upload limits | Implemented provisionally: video ≤ 180 s, 250 MB per file, 10 items per post (`API.Limits`). Confirm or change. | M1 |
| Screenshot handling | Detect + notify the sender (blocking is impossible) | M4 |
| Streak rule | Both send on the same calendar day, using the server timezone | M6 |