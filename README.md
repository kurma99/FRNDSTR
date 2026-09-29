# Frndstr

> [!WARNING]
> **This project was vibe coded.** It was built almost entirely by an AI coding agent, with a human
> steering, testing and deciding. It works well for one family, but nobody has audited it.
>
> **So: host it behind [Tailscale](https://tailscale.com) (or another private network) and everything
> is fine.** Don't expose the server directly to the internet.
>
> **If you're suspicious, let your own coding agent do a security check before you run it.** That's a
> good idea for any code you didn't write yourself. A prompt like *"Review this repo for security
> issues: auth, file uploads, path handling, access control between users"* is a fine start.

A private, self-hosted family Instagram with BeReal-style **Moments**: an iOS app plus a small server
you run yourself with one `docker compose up`.

## What it does

- **Posts**: photos and videos (carousel), captions (editable), reactions, comments, a newest-first
  feed, profiles. Everyone on your server sees everyone's posts.
- **Moments**: front + back camera at the same time, sent to the friends you pick and gone after 24
  hours. Today's moments from friends stay locked until you've shared your own. Friendship streaks,
  a shared daily "moment time", a stories row, pinch to resize the small photo.
- **Memories**: your own moments stay on *your* iPhone as a calendar you can play back.
- **Highlights**: pick moments for your profile; your friends see them once each moment's 24 hours are over.
- **Save to Photos** with caption, place and date written into the file (you're asked first).
- **Takeout**: one zip with all your posts, highlights and moments.
- **Admin dashboard** in the browser: first-run setup, people, invite codes, storage, settings.
- **Private by design**: invite-only, no analytics, no third-party services. The app only talks to
  the server address you type in.

## Repository layout

| Path | What |
|---|---|
| `server/` | Swift (Vapor) + SQLite + ffmpeg server, Dockerfile, compose file. See [server/README.md](server/README.md). |
| `Shared/FrndstrAPI/` | Dependency-free Swift package with the API types shared by app and server. |
| `Frndstr/`, `Frndstr.xcodeproj` | The iOS app (SwiftUI, iOS 26+). |
| `docs/` | [PLAN.md](docs/PLAN.md) (design + milestones) and [JOURNAL.md](docs/JOURNAL.md) (dev log). |

## Run the server

On any machine with Docker (a NAS, a Raspberry Pi 5, an old laptop):

```sh
git clone <this repo> frndstr && cd frndstr/server
cp .env.example .env      # instance name, port, time zone
docker compose up -d --build
```

Or use the prebuilt image instead of building (amd64 + arm64, published by GitHub Actions): set
`FRNDSTR_IMAGE=ghcr.io/<owner>/frndstr-server:latest` in `.env`, then
`docker compose pull && docker compose up -d`.

Then:

1. Open `http://<server>:8080/` in a browser and create the admin account (first start only).
2. Put the machine on your tailnet. For HTTPS without certificates: `tailscale serve --bg 8080`.
3. In the dashboard, create invite codes for your family.
4. Back up `server/data/` (SQLite database + all media). That's everything.

## Run the app

The app isn't on the App Store. Open `Frndstr.xcodeproj` in Xcode, set **your own** team and bundle
identifier under *Signing & Capabilities*, and run it on your iPhone (or ship it to your family through
TestFlight). On first launch, enter your server's address (e.g. `https://box.tailnet.ts.net` or
`http://100.x.y.z:8080`) and an invite code.

Plain HTTP is allowed on purpose (`NSAllowsArbitraryLoads`), so Tailscale IPs work without certificates.
Traffic inside a tailnet is encrypted anyway.

## Development

```sh
cd server && swift test                 # needs ffmpeg (brew install ffmpeg)
cd Shared/FrndstrAPI && swift test
```

The app's tests run in Xcode (⌘U). CI runs the server and API tests on Linux for every push, and
publishes the Docker image from `main` and from `v*` tags (see `.github/workflows/`).

## License

[MIT](LICENSE): do what you like, no warranty.
