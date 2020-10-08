Note about Twitch API:
Using API request that isn't documented by Twitch.
Have to use API version v5(kraken).
There is newer Twitch API but that doesn't support getting chat history/comments.


Development:
ls src/* | entr -c -r zig build run


Build:
zig build-exe src/main.zig $NIX_CFLAGS_COMPILE $NIX_LDFLAGS -lc -lssl -lcrypto --release-small


Run MPV with socket file
mpv --input-ipc-server=/tmp/mpv-twitch https://www.youtube.com/watch?v=Lo3rrP8u7Mw
mpv --playlist=/home/ck/sources/music/songs.txt --input-ipc-server=/tmp/mpv-twitch --ytdl-format=worstvideo+bestaudio/best --loop-playlist --shuffle

Links:
HTTP\1.1 Message Syntax and Routing - https://greenbytes.de/tech/webdav/rfc7230.html#message.body.length
HTTP header parsing - https://github.com/Vexu/routez/blob/master/src/routez/http/parser.zig
OpenSSL server/client example - https://aticleworld.com/ssl-server-client-using-openssl-in-c/


Zig:
zig translate-c test.h $NIX_CFLAGS_COMPILE --verbose-cimport > output.zig

test.h content example:
#define GLFW_INCLUDE_VULKAN
#include <GLFW/glfw3.h>


Testing
curl -H 'Client-ID: yaoofm88l1kvv8i9zx7pyc44he2tcp' \
-X GET 'https://api.twitch.tv/v5/videos/762169747/comments?content_offset_seconds=1.0'

curl -H 'Client-ID: yaoofm88l1kvv8i9zx7pyc44he2tcp' \
-X GET 'https://api.twitch.tv/v5/videos/762169747/comments?content_offset_seconds=13028.249'


