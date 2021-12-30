# MPV twitch chat
Output twitch video (VOD) chat log to terminal from video playing in MPV.

**NOTE:**
Twitch will deprecate API (v5) that this application is using on February 28, 2022.

# Usage
```
$ mpv --input-ipc-server=<mpv-socket-location> <twitch-vod-url>
$ mpv-twitch-chat -socket-path <mpv-socket-location>
```

# Build
```
$ zig build -Drelease-safe
# output: ./zig-out/bin/mpv-vod-chat
```
