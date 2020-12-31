# Twitch chat with MPV
Sync twitch vod chat with video being watched in MPV.


## Setup
```console
git clone --recurse-submodules <repo>
```


## Build (debug)
```console
zig build
```


## Build without build.zig on Nixos
```console
zig build-exe src/main.zig $NIX_CFLAGS_COMPILE $NIX_LDFLAGS -lc -lssl -lcrypto --release-small
```


## Testing

### Twitch API with curl
```console
curl -H 'Client-ID: yaoofm88l1kvv8i9zx7pyc44he2tcp' \
-X GET 'https://api.twitch.tv/v5/videos/762169747/comments?content_offset_seconds=1.0'
```

### Run mpv with socket file
```console
mpv --input-ipc-server=/tmp/mpv-twitch <video-url>
```


## Certificate(s) (mozilla-bundle.pem)
Taken from https://curl.haxx.se/docs/caextract.html


# Notes about Twitch API:
Using API request that isn't documented by Twitch.
Have to use API version v5(kraken).
There is newer Twitch API but that doesn't support getting chat history/comments.


# Helpful resources
[HTTP\1.1 Message Syntax and Routing](https://greenbytes.de/tech/webdav/rfc7230.html#message.body.length)
[HTTP header parsing](https://github.com/Vexu/routez/blob/master/src/routez/http/parser.zig)
[OpenSSL server/client example](https://aticleworld.com/ssl-server-client-using-openssl-in-c/)
[Zig openssl example](https://github.com/marler8997/ziget/blob/master/openssl/ssl.zig)

