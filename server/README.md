# Frndstr Server

Self-hosted backend for the Frndstr family app: Swift (Vapor) + SQLite + ffmpeg, in one container.

> **Vibe coded, not audited:** host it behind Tailscale or Cloudflare Access, never directly on the internet.

## Run with Docker

The easiest way is the prebuilt image with the standalone [`docker-compose.yml`](../docker-compose.yml)
in the repo root, see the [main README](../README.md#run-the-server). To build from source:

```sh
cd server
cp .env.example .env        # optional: instance name, port, log level
docker compose up -d --build
```

Prebuilt image instead (built by GitHub Actions for amd64 + arm64): put
`FRNDSTR_IMAGE=ghcr.io/<owner>/frndstr-server:latest` in `.env`, then
`docker compose pull && docker compose up -d`. To update later, run the same two commands.

Then open `http://<server>:<FRNDSTR_PORT>/` in a browser. On the very first start it shows a
**setup page** where you create the admin account. Afterwards `/admin` is the admin dashboard
(admins log in with their normal Frndstr username and password):

- storage in total, per kind (originals, display copies, thumbnails, moments, profile photos, database) and per person
- people: log out everywhere, reset password, make/remove admin, delete an account with all its posts and media
- invite codes: create and revoke
- settings: reaction emoji, the daily moment time window

- The app connects to `http://<server-ip>:<FRNDSTR_PORT>` (default `8080`). Plain HTTP is fine on your LAN or over Tailscale.
- For HTTPS over Tailscale: `tailscale serve --bg 8080`, then use `https://<machine>.<tailnet>.ts.net` in the app.
- All data (SQLite + media) lives in `./data`. **Back up that folder.**

## Command line (optional)

Everything below is also in the dashboard. Invite codes (each works once):

```sh
docker compose exec frndstr ./App invite            # one invite code
docker compose exec frndstr ./App invite --count 5  # several
```

Admin rights:

```sh
docker compose exec frndstr ./App admin anna           # grant
docker compose exec frndstr ./App admin anna --revoke   # revoke
```

`TIME_ZONE` in `.env` (IANA name, default `Europe/Berlin`) defines "today" for the moments rule.

## Develop locally (macOS)

```sh
brew install ffmpeg
swift run App serve --hostname 0.0.0.0 --port 8080      # DATA_DIR defaults to ./data
swift test
```

> If the repo sits in an iCloud-synced folder, add `--scratch-path /tmp/frndstr-build/server`
> to `swift build/test/run`; synced extended attributes break code signing of test bundles.

### Demo server

```sh
scripts/demo.sh            # reuse last demo data, or create it
scripts/demo.sh --reset    # start over
```

Starts a throwaway server on port 8090 (data in `/tmp/frndstr-demo`; change with `PORT` / `DEMO_DIR`).
Sign in as `demo` / `demodemo`. It comes with friends `anna`, `ben`, `cleo` and `dani` (same password),
an open friend request from `emil`, two weeks of posts with comments and reactions, a streak with Anna,
and three live moments that unlock once you send one. All photos are colour gradients.
The data comes from `./App seed`, which only runs on a server without accounts.

## API (v1)

| Method | Path | Notes |
|---|---|---|
| GET | `/api/health` | public |
| POST | `/api/auth/register` | invite code + username + name + password → token |
| POST | `/api/auth/login` | → token |
| POST | `/api/auth/logout` | revokes the token |
| GET | `/api/me` | |
| POST | `/api/media` | raw body; `Content-Type` image/jpeg, image/png, video/mp4, video/quicktime |
| GET | `/api/media/:id/{display,thumb,original}` | Bearer header or `?token=`; supports Range |
| POST | `/api/posts` | `{caption, mediaIDs}` |
| GET | `/api/posts?cursor=&limit=&author=` | newest first, cursor pagination |
| GET | `/api/posts/:id` | |
| PATCH | `/api/posts/:id` | `{caption}`, author only |
| DELETE | `/api/posts/:id` | author only |
| PUT/DELETE | `/api/posts/:id/reaction` | `{emoji}` from the palette |
| GET/POST | `/api/posts/:id/comments` | |
| GET | `/api/users`, `/api/users/:id` | profile with counts + friendship |
| GET/POST/DELETE | `/api/friends`, `/api/friends/:id` | requests / accept / remove |
| GET | `/api/config` | instance name + reaction palette |
| GET/POST | `/api/moments` | feed / multipart upload (`back`, `front`, `payload`) |
| GET | `/api/moments/:id/{back,front}` | sender or unlocked recipient |
| GET | `/api/inbox?since=` | notification events |
| GET | `/api/moment-time` | today's and tomorrow's shared moment time |
| GET | `/api/streaks` | streaks with each friend |
| GET | `/api/users/:id/highlights` | friends only; moments show 24h after they were taken |
| POST/PATCH/DELETE | `/api/highlights`, `/api/highlights/:id` | create `{title}` / rename, set cover / delete |
| POST/DELETE | `/api/highlights/:id/items[/:itemID]` | multipart `image`, `thumbnail`, `payload` / remove |
| GET | `/api/highlights/:id/items/:itemID/{image,thumb}` | owner or friend |
| GET | `/api/memories` | your own Memories backup (owner only) |
| POST | `/api/memories` | multipart `back`, `front`, `composite`, `thumb`, `payload` (`MemoryDTO`); same ID again = no-op |
| GET/DELETE | `/api/memories/:id[/{back,front,composite,thumb}]` | owner only |
| GET | `/api/takeout` | zip of your own posts (+ comments/reactions) and highlights |

All endpoints except health/register/login need `Authorization: Bearer <token>`.
DTOs live in the shared `FrndstrAPI` package (`../Shared/FrndstrAPI`).
