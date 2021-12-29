# Twitch chat with MPV
Sync twitch's vod chat text with video url being watched in MPV.

## Dependencies
- notcurses (TODO: make optional)
- bearssl (comes with submodule)

## Quickstart
```console
$ git clone --recurse-submodules <repo>
$ zig build -Drelease-safe
$ mpv --input-ipc=/tmp/mpv-twitch-socket <video_url>
$ ./zig-cache/bin/twitch-vod-chat
```

## Build without build.zig on Nixos
TODO: currently doesn't work out of the box because nix adds flag -frandom-seed to $NIX_CFLAGS_COMPILE which makes the compiler fail. Have to remove flag manually or implement automatic way to remove it.
```console
zig build-exe src/main.zig $NIX_CFLAGS_COMPILE $NIX_LDFLAGS -lc -lssl -lcrypto -lnotcurses -Drelease-safe
```

## Testing

### Twitch API with curl
```console
curl -H 'Client-ID: yaoofm88l1kvv8i9zx7pyc44he2tcp' \
-X GET 'https://api.twitch.tv/v5/videos/762169747/comments?content_offset_seconds=1.0'
```

## Notes about Twitch API:
Using API funcionality that isn't documented by Twitch.
Have to use API version v5(kraken).
There is newer Twitch API but that doesn't support getting chat history/comments.


## TODO
* Wait for [issues](https://github.com/truemedian/zfetch/pull/8) to be resolve before continuing to
explore zfetch and other https client packages


## Helpful resources
[HTTP\1.1 Message Syntax and Routing](https://greenbytes.de/tech/webdav/rfc7230.html#message.body.length)
[HTTP header parsing](https://github.com/Vexu/routez/blob/master/src/routez/http/parser.zig)
[OpenSSL server/client example](https://aticleworld.com/ssl-server-client-using-openssl-in-c/)
[Zig openssl example](https://github.com/marler8997/ziget/blob/master/openssl/ssl.zig)



