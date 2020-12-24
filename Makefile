build:
	zig build run

dev:
	ls src/* | entr -c -r zig build run
	
test-main:
	ls src/*.zig | entr -c -r zig test src/main.zig $$NIX_CFLAGS_COMPILE $$NIX_LDFLAGS -lc -lssl -lcrypto

test-mpv:
	echo "src/mpv.zig" | entr -c -r zig test src/mpv.zig

test-comments:
	echo "src/comments.zig" | entr -c -r zig test src/comments.zig

test-twitch:
	ls src/*.zig | entr -c -r zig test src/twitch.zig $$NIX_CFLAGS_COMPILE $$NIX_LDFLAGS -lc -lssl -lcrypto

watch:
	watchexec -r -d 200 -w src/ -f '*.zig' 'zig build && ./zig-cache/bin/twitch-vod-chat -comments-offset -70 -socket-path /tmp/mpv-twitch-socket'

