# MPV twitch chat
Output twitch video (VOD) chat log to terminal from video playing in MPV.

**NOTE:**
Twitch will deprecate API (v5) that this application is using on February 28, 2022.

# Usage
```
$ mpv --input-ipc-server=<mpv-socket-location> <twitch-vod-url>
$ mpv-twitch-chat -socket-path <mpv-socket-location>
```

# Options
```
mpv-vod-chat [options]

Options:
  -h, -help        Print help text
  -socket-path     Default: '/tmp/mpv-twitch-socket'.
                   Set mpv players socket path
  -comments-delay  When comments are displayed compared to video time
  -output-mode     Default: stdout. Can enter one of three: stdout, direct, notcurses.
  -log-file        Default(output mode: stdout, direct): stdout.
  -log-file        Default(output mode: notcurses): '/tmp/mpv-twitch-chat.log'.
                   Can output application log messages to stdout, a file or tty.
```

# Build
```
$ zigmod fetch
$ zig build -Drelease-safe
# output: ./zig-out/bin/mpv-vod-chat
```
