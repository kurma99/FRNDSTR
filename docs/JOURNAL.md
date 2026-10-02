# Friendster — Dev Journal

Newest entries on top. For each session: what was done, decisions made (and why), problems, next steps.

---

## 2026-10-02 — Memories backup on the server

**Problem**
- After installing the TestFlight build, all earlier Memories were gone. The bundle ID had changed (`cloud.mallwitz.friendster` → `cloud.mallwitz.frndstr`), so iOS treated it as a new app with an empty container, and Memories only lived on the phone. The old ones weren't rescued (decided not worth it).

**Done**
- Private owner-only Memories backup on the server (`memory_backups` + `data/media/memories/{owner}/{id}/`) with two-way sync in the app (`MemoryBackup`), a Settings switch (on by default), server-side delete when a memory is deleted, cleanup on account deletion, dashboard storage.
- Verified with uninstall → reinstall → login → Memories restored.

**Decisions**
- **The phone uploads its archive copy** instead of the server keeping the moment's files at expiry: one code path for new and old memories, the composite is exactly what the phone shows, and turning backup off simply stops uploads.
- **Sync by archive ID, no conflict handling needed**: memories never change after they're taken, only appear or get deleted. Deletes are queued until the server confirms, so a deleted memory doesn't come back from the server.
- **On by default**: losing Memories is the worse failure, and it's the user's own server.

---

## 2026-10-02 — Moments polish before TestFlight

**Done**
- The shared moment time on the Moments card is blurred until tapped.
- Moments can carry a location, all the way through: DTOs, server (new `AddMomentLocation` migration), send step, Memories archive, story player, cards, Photos save and takeout. The post a moment turns into keeps the place.
- Memories calendar: oldest month at the top, newest at the bottom, opens at the bottom.
- The location permission text now mentions moments too, since App Review checks that it matches what the app does.

**Decisions**
- **Moment location is on by default** (posts stay opt-in). Moments are only for friends, and "where were you" is part of the BeReal-style moment. It can be switched off per moment or in Settings › Moment defaults.
- **The place stays hidden while a moment is locked**, just like the photos, so it can't give anything away before you've posted.
- **The lookup starts as soon as the moment flow opens**, so the place is usually ready by the send step. Sending waits for a lookup that is still running (at most the 15 s location timeout).
- **Memories read like a timeline** (top = oldest): scrolling up goes back in time, which matches the calendar inside each month.

**Notes**
- `swift test` inside `~/Documents` fails to codesign the test bundle ("resource fork, Finder information, or similar detritus not allowed"). Use `--scratch-path /tmp/…`.

---

## 2026-09-29 — Getting ready for GitHub and TestFlight

**Done**
- Removed personal data: real names in tests/docs → neutral ones (Anna, Alex), home city in test data → Hamburg, the "Created by" header, the tracked `xcuserdata`. No photos were ever in git (only the app icon). History restarted as a single commit so older commits can't leak anything; the old history is kept outside the repo as a git bundle.
- MIT LICENSE ("The Friendster contributors"), root README (vibe-coded warning first), server README (prebuilt image, new endpoints).
- GitHub Actions for tests and a multi-arch Docker image on ghcr.io.
- Running the CI steps locally in `swift:6.2-noble` found a Linux-only bug: the feed cursor (a date sent as text) lost a few ulps, so the last post of a page showed up again on the next one. The feed cursor is now the last post's ID, compared against its stored date inside SQL; the inbox cursor got a 0.1 ms margin against double notifications. 35/35 server tests pass on macOS and Linux; the Docker image builds and answers `/api/health`.
- Bundle ID `cloud.mallwitz.friendster` (from the domain mallwitz.cloud; can't change once the app exists in App Store Connect), privacy manifest, `ITSAppUsesNonExemptEncryption = NO`.

**Notes**
- The privacy manifest isn't about data shared with the developer: Apple requires every app to declare its "required reason" APIs (here only UserDefaults) and what it collects (nothing, since the only server is the user's own).
- `ITSAppUsesNonExemptEncryption` is unrelated to plain HTTP: it answers the export-compliance question (the app only uses the system's standard HTTPS/crypto), so TestFlight doesn't ask on every upload.

---

## 2026-09-28 — Plan change

**Decisions**
- "New post" stays in the tab bar (reverses that M6.1 item).
- New milestone M6.2: reactions/comments on the right of the post card, download only in the "…" menu, editable captions, Instagram-style moment highlights on profiles, tap a profile avatar to see that person's live moments, pinch to resize the small moment photo, tap left/right in the Memories player.

- Highlights: only highlighted moments stay on the server (uploaded from the sender's archive), friends-only, can't be saved by viewers, included in the takeout.
- Takeout becomes one zip that also contains your moments.

**Done (M6.2)**
- Feed: reactions + comments moved right, download button removed (still in "…"); "Edit caption" in "…" with `PATCH /api/posts/{id}`.
- Moments: pinch to resize the small photo (`MomentLayout.insetSize`, server column `inset_size`); shared `StoryPlayer` (tap left/right, swipe, hold to pause) used by Memories, live moments and highlights; ringed profile avatar opens the person's live moments.
- Highlights end to end: `highlights` + `highlight_items` tables, `HighlightController`, friends-only photos, account deletion + storage stats + takeout include them. App: covers row on the profile, player, editor (name, pick from Memories, cover, remove, delete).
- One "Download my data" zip: server zip nested + `moments/` + `moments.json` (captions embedded into `moment.jpg`).
- Tests: 35 server, 42 app, 2 API package — all green.

**Decision (after trying it)**
- Adding a highlight never needed the moment to be seen. But a live moment added to a highlight would have reached *all* friends early, so friends now only get a highlighted moment 24h after it was taken; the editor marks the ones still hidden.

**Final round**
- "Editing doesn't work" was the local dev server still running a build from the day before (no `PATCH /api/posts` or highlight routes → 404). Rebuilt and restarted it on the same data (backup `friendster.sqlite.bak-*`); everything worked afterwards.
- Moments tab reworked into an Instagram-style stories row (you first, then friends) with "+" in the top right, and more Liquid Glass (tinted status card, glass streak/today cards, glass badges).
- Simulator walkthrough by a UI agent: all checks passed. Small fixes: highlight titles wrap to two lines, red delete icon, better contrast on the yellow card.
- Memories and the highlight picker only contain moments sent **from this iPhone** (the archive is per device), so moments sent from another phone don't show up there.

**Notes**
- iOS can't unzip, so the server zip stays nested inside the takeout instead of being merged.
- Server tests: the repo sits in an iCloud-synced folder, whose Finder metadata breaks codesigning of the test bundle. Use `swift test --scratch-path "$TMPDIR/friendster-server-build"` (with `DEVELOPER_DIR` pointing at Xcode).
- Not yet checked by hand in the simulator: gestures, highlight editor, live-moment ring.

---

## 2026-09-27 (night 3) — M7 admin dashboard, M8 takeout

**Decisions (asked and answered)**
- The web is an admin dashboard, admin-only login with the normal credentials.
- Admin account is created in the browser on first start.
- Reaction emoji and moment time window move from the app to the web.
- Takeout: own posts only, with comments/reactions on them inside posts.json.

**Done**
- Leaf dashboard: setup, login, storage stats (per kind and per user), people management (log out everywhere, reset password, admin toggle with last-admin guard, delete with all data), invites, settings, unposted-upload cleanup. Sessions in memory (admins log in again after a restart), CSRF tokens on every form.
- Takeout zip built with `zip`; photos get caption/GPS/date via exiftool (both added to the Docker image). App: Settings › Your data (posts from the server, Memories zipped on the phone via NSFileCoordinator).
- App admin editors removed; admins get "Open admin dashboard".
- Verified in the Linux container and in Safari on the simulator (phone layout fixes applied). 33 server tests, 38 app tests.

**Notes**
- During the UI check the test agent briefly made a test account admin and reverted it; no other data changed.
- Takeout is built synchronously per request; fine for family-sized libraries.

**Next**
- M8 rest: backup/restore docs, TestFlight, Liquid Glass app icon. M9 APNs.

---

## 2026-09-27 (night 2) — M5 local notifications, M6 streaks

**Decisions (asked and answered)**
- Daily reminder: shared random family time, default window 9–21, admin can change it.
- Streak: both must send; one missed day per calendar week is forgiven.
- Notifications ON by default: new moments, new family posts (+ both reminders). OFF: comments/reactions, friend requests.

**Done**
- Server: `events` + `/api/inbox`, event hooks in moments/posts/comments/reactions/friends/janitor, shared moment time (stored per day in `instance_settings`, race-safe), admin window endpoint, `moment_days` + `StreakCalculator` + `/api/streaks`. 30 server tests; Docker OK.
- App: `Notifier` (inbox sync → local notifications, moment-time + streak reminders, tap routing), background refresh task, Notifications settings, admin window editor, streak badges/section, today's moment time on the Moments card. Cancelled requests no longer show error alerts. Feeds refresh when returning to the app. 38 app tests.

**Notes**
- Moments sent before this version aren't in the streak history (the table starts now).
- Background refresh timing is up to iOS; APNs (M9) is the real fix.
- DST: the moment time is computed as minutes after midnight, so on the two DST switch days it can be off by an hour (harmless).

**Next**
- M7 web viewer, M8 takeout + ops + app icon.

---

## 2026-09-27 (very late) — M4.1 Memories calendar & playback

**Done**
- Memories is now a calendar: month sections (newest first), MON … SUN header (weeks start Monday regardless of locale), date numbers, thumbnail on days with moments, count badge for several, gold outline for today.
- Archive saves a 360 px thumbnail per moment; older ones get theirs generated on first display.
- Play button per month → full-screen player: 3 s per moment, segmented progress bar, swipe left/right, touch-and-hold to pause, swipe down or X to close, closes after the last one. Tapping a day with several moments starts the player at that day.
- 32 app tests (calendar offsets, same-day ordering, progress fill, on-demand thumbnails). Simulator walkthrough passed.

---

## 2026-09-27 (late night) — Moment editing, delayed posts, yellow theme, dark mode

**Done**
- Flow is now capture → **edit** (drag inset with corner snapping, switch, flip selfie/back, caption) → **share** (All friends / Selected friends + list, share-as-post, save to Photos). Edit and share choices survive Back/Next.
- Layout is sent to the server; recipients see the sender's arrangement and can rearrange it locally. The composite follows the same layout.
- Share as post is delayed: the composite is uploaded with the moment, the server's janitor publishes it when the moment expires and backdates it to the capture time. Verified by a server test and on real data.
- Yellow primary colour, adaptive gold/yellow tint, Settings › Appearance (System/Light/Dark), Settings › Moment defaults.
- Library picking for moments is Simulator-only; on devices without camera permission there's an "Open Settings" button.
- 21 server tests, 28 app tests, Docker build OK. Simulator walkthrough passed (the Back/Next state loss it found was fixed and re-verified).

**Decisions**
- Released moment-posts keep the capture time as their date, so they appear where they belong chronologically (about 24h down the feed when published).

**Open**
- Real-device camera still untested.

---

## 2026-09-27 (night) — M4 Moments, admin palette, theme, likes removed

**Done**
- Server: `moments` + `moment_recipients`, multipart upload (two JPEGs + JSON), friends-only recipients, BeReal lock (today's received moments hidden until you post today, enforced on the photo URLs too), view/screenshot tracking, `MomentJanitor` purge (rows + files). Admin flag (earliest user migrated to admin, first sign-up on fresh servers), `admin` CLI, `instance_settings` with the reaction palette, `GET /api/config`, `PUT /api/admin/reactions`. 19 server tests; Docker image builds.
- App: Moments tab with badge, capture (multi-cam / sequential / photo-picker fallback), send screen with recipient picker, caption, opt-in "Also share as a post", "Save to my Photos"; received cards with lock, swap, time left; "Your moments" with seen count and screenshot notice; per-account Memories. Admin reaction-palette editor. Likes removed. New theme with an app-wide accent tint. 22 app unit tests.
- Simulator walkthrough (an admin and a second test account) covered the whole flow; bugs it found were fixed: Memories not loading (percent-encoded path), inset swap on local images, composite not matching the 3:4 preview, feed cropping 3:4 posts to 4:5, misleading camera text, shared archive between accounts, blue system tint leftovers.

**Decisions**
- The composite is always 3:4 (both photos center-cropped), so the post matches what you saw.
- Share-as-post is decided when sending and posts immediately; the post is permanent, unlike the moment.
- Memories are per account and never uploaded.

**Open**
- Real multi-cam capture and screenshot detection are untested (Simulator has no camera; simulated screenshots don't fire the notification).
- Viewed-moment badge state is per device, not per account.
- Not re-checked after the last fixes (the device sessions kept closing): login placeholder contrast, white close button on the camera screen, per-account Memories in the UI.
- Liquid Glass app icon (added to M8).

**Next**
- M5 local notifications.

---

## 2026-09-27 (evening) — M2 + M3 implemented

**Done**
- Server: reactions, comments, post deletion (files removed), profiles (`/api/users/:id` with counts + friendship status), name edit, avatars (versioned file names bust caches), friend requests, optional post location + capture date. Additive migrations upgraded the existing M1 database in place. 15 server tests pass; Docker image builds.
- App: action row (like, reaction picker, comments, save), double-tap like with heart burst, reaction list, comments sheet with glass composer, "…" menu with delete, profile with counts + friend button, edit profile (photo + name), Friends screen with request badge, Settings (save defaults, server, log out).
- M3: `MetadataWriter` losslessly embeds caption (IPTC/XMP/TIFF/EXIF), GPS and date into JPEGs and caption/location/date into videos; `PhotoSaver` uses add-only Photos access and also sets the asset's location/date. Opt-in location on posts. New unit-test target `FriendsterTests` (18 tests).
- Simulator run with 4 accounts; Apple Photos showed caption, map pin and date of a saved photo.

**Decisions**
- One reaction per person per post; fixed palette so the server can validate.
- Location only when the author opts in; place name shown on the post.
- No "Friendster" album in Photos (would need full library access).
- Opaque material for half-height sheets: Liquid Glass let bright photos make the text unreadable.

**Problems & fixes**
- `String(localized:)` doesn't apply `^[…](inflect: true)` → go through `AttributedString`.
- Location failed on first use: the timeout ran while the permission alert was up → timeout starts only after the prompt is answered; the update stream is restarted if it ends.
- Overlay badges don't render in Liquid Glass toolbars → `.badge(_:)`.
- Confirmation dialogs attached to parents pointed at the wrong place / didn't show from a closing `Menu` → anchor on the button, present after the menu closes.
- Xcode crashed mid-session; nothing was lost.

**Open**
- Friends list row separator only spans the accessory button (cosmetic).
- Real iPhone + home server over Tailscale still untested.

**Next**
- M4 Moments, including choosing recipients before sending.

---

## 2026-09-27 — M0 + M1 implemented

**Done**
- `Shared/FriendsterAPI`: dependency-free DTOs, endpoint paths, limits, ISO-8601 coders (+ round-trip test).
- `server/`: Vapor 4.122 + Fluent/SQLite. Invite-only register/login, hashed bearer tokens, `invite` CLI, first-boot invite logged. Streamed media upload, ffprobe/ffmpeg thumbnails, H.264 remux/transcode with rotation handling, range-capable media serving (`?token=` for AVPlayer). Cursor-paginated feed with `?author=`. 9 Swift Testing tests pass. Dockerfile + compose; the image builds.
- iOS app (target iOS 26): connect screen (URL + port, HTTP allowed via ATS), login/sign-up with Liquid Glass controls over an animated brand gradient, Instagram-style tab bar (Home / New Post sheet / Profile), feed with carousel (4:5–1.91:1 clamp, 1/N counter, dots), muted-autoplay looping video, profile grid, compose sheet (PhotosPicker up to 10 items + camera, background preparation, upload progress, discard confirmation).
- End-to-end run in the simulator against the local server, driven by a UI agent: two users, multi-item post, single post, profiles, logout/login.

**Decisions**
- **Phone prepares media before upload**: photos become upright JPEGs (≤2048 px) with **all metadata stripped** (no GPS leaks until M3's opt-in); videos go to H.264 MP4 ≤1080p with location metadata filtered out. The server still transcodes anything that isn't H.264, so non-app uploads (e.g. the web in M7) work too.
- **Two-step upload** (`POST /api/media` per file, then `POST /api/posts` with IDs): large videos stream to disk instead of sitting in memory, and a failed upload doesn't lose the whole post.
- **Media auth**: Bearer header, or `?token=` on media routes only (AVPlayer can't set headers).
- **Custom image loader** instead of `AsyncImage(request:)`, which needs iOS 27 (our target is 26).
- **Upload limits (provisional)**: 180 s video, 250 MB per file, 10 items per post.
- Deployment target lowered from the template's 27.0 to **26.0**, as decided.

**Problems & fixes**
- Command-line tools' `swift test` is broken → use `DEVELOPER_DIR=/Applications/Xcode.app/...`.
- iCloud-synced folder adds xattrs that break test-bundle signing → build with `--scratch-path /tmp/...`.
- `Invite()` silently used Fluent's empty initializer → explicit `Invite(code:)`.
- `PhotosPickerItem.itemIdentifier` is nil without photo library access → the compose model keys on the item itself.
- Linux compiler choked on the rotation expression → explicit types.
- The AddInfoPlist tool wrote ATS as an array → fixed to a dictionary with `plutil`.

**Open**
- Container verified locally (`docker compose up`, register, image + video upload with ffmpeg in the container, feed, range requests, `invite` command). Not yet tested: the real home server and a real iPhone over Tailscale.
- Console warning `glassEffect() tried to update multiple times per frame` (cosmetic, from the compose sheet/tab bar).
- The simulator tries IPv6 `::1` before IPv4 when connecting to `localhost`; harmless.

**Next**
- M2: reactions, comments, delete own post, friend requests.

---

## 2026-09-26 — Planning

**Done**
- Defined the goals and wrote [PLAN.md](PLAN.md): server/phone split, architecture, data model, milestones M0–M9.

**Decisions**
- **Server = shared state + short-lived relay; phone = capture, metadata, personal archive.** Moments are deleted from the server after 24h, so "I keep it, my friends don't" happens naturally: the sender's copy lives on the phone.
- **Vapor + SQLite + Leaf in one container.** One language across app and server, shared DTOs, a single `docker compose`, and trivial backups (just copy `./data`).
- **Local notifications first, APNs later (M9).** The server exposes an event inbox that the app polls. APNs will push the same events later, so nothing needs to be redesigned. Accepted downside: alerts about new photos can be delayed until the app is opened or iOS grants a background refresh.
- **Plain HTTP allowed** (`NSAllowsArbitraryLoads`) so Tailscale setups work without certificates.
- **No E2E encryption**: the server is trusted, which keeps thumbnails, the web viewer and takeout simple.
- **Feed visible to everyone on the server**: it's invite-only family anyway.
- **Moments:** unlimited per day, recipients picked per send, and you must post today before you can see friends' moments from today.
- **Minimum iOS 26**: newest SwiftUI / Liquid Glass, no compatibility code.
- **Monorepo for now.** `server/` is self-contained so it can be split with `git subtree split`. `FriendsterAPI` becomes its own tiny repo at that point.

**Open questions**
- Upload limits, location visibility, streak timezone rule, auth reset flow (see PLAN §7).

**Next**
- Start M0: repo layout, FriendsterAPI package, Vapor skeleton + compose, invite/register/login, iOS onboarding.
