Note about Twitch API:
Using API request that isn't documented by Twitch.
Have to use API version v5(kraken).
There is newer Twitch API but that doesn't support getting chat history/comments.


Run MPV with socket file
mpv --input-ipc-server=/tmp/mpv-socket-test https://www.youtube.com/watch?v=Lo3rrP8u7Mw


Zig:
zig translate-c test.h $NIX_CFLAGS_COMPILE --verbose-cimport > output.zig

test.h content example:
#define GLFW_INCLUDE_VULKAN
#include <GLFW/glfw3.h>


Testing
curl -H 'Client-ID: yaoofm88l1kvv8i9zx7pyc44he2tcp' \
-X GET 'https://api.twitch.tv/v5/videos/591919628/comments?content_offset_seconds=1.0'

curl -H 'Client-ID: yaoofm88l1kvv8i9zx7pyc44he2tcp' \
-X GET 'https://api.twitch.tv/v5/videos/591919628/comments?content_offset_seconds=13028.249'


