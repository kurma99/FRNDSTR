# Build context is the repository root (see docker-compose.yml) because the server
# depends on ../Shared/FriendsterAPI until the repos are split.

# ---------- Build ----------
FROM swift:6.2-noble AS build
WORKDIR /build

COPY Shared/FriendsterAPI /Shared/FriendsterAPI
COPY server/Package.swift server/Package.resolved ./
RUN swift package resolve

COPY server/Sources ./Sources
# SwiftPM validates all targets, so the test sources must be present too.
COPY server/Tests ./Tests
RUN swift build -c release --product App --static-swift-stdlib \
    && mkdir /staging \
    && cp "$(swift build -c release --show-bin-path)/App" /staging/

# ---------- Run ----------
FROM ubuntu:noble
RUN export DEBIAN_FRONTEND=noninteractive \
    && apt-get -q update \
    && apt-get -q install -y --no-install-recommends ca-certificates tzdata ffmpeg zip libimage-exiftool-perl \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --user-group --create-home --home-dir /app friendster
WORKDIR /app
COPY --from=build --chown=friendster:friendster /staging /app
# Admin dashboard templates.
COPY --chown=friendster:friendster server/Resources /app/Resources
RUN mkdir -p /data && chown friendster:friendster /data

USER friendster:friendster
ENV DATA_DIR=/data
EXPOSE 8080
ENTRYPOINT ["./App"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
