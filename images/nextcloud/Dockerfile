# Official Nextcloud image plus the binaries it does not ship: ffmpeg/ffprobe
# (video previews, Memories transcoding) and exiftool (Memories metadata).
# The image tag published to GHCR is the tag on this FROM line, so Renovate
# bumping the base also bumps the published image.
FROM docker.io/library/nextcloud:35.0.2-fpm-alpine

LABEL org.opencontainers.image.source="https://github.com/mmalyska/home-ops"

RUN apk add --no-cache ffmpeg exiftool
