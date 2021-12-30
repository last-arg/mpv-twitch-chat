build:
	zig build

watch-build:
	watchexec -c -w src/ -e zig zig build
	
dev:
	watchexec -r -c -w build.zig -w src/ -e zig zig build run
	
test-main:
	ls src/*.zig | entr -c -r zig test src/main.zig $$NIX_CFLAGS_COMPILE $$NIX_LDFLAGS -lc -lssl -lcrypto

watch-twitch:
	watchexec -w src -e zig -c -r 'zig build test -- src/twitch.zig'

watch:
	watchexec -r -d 200 -w src/ -e zig 'zig build && ./zig-cache/bin/twitch-vod-chat -comments-offset -70 -socket-path /tmp/mpv-twitch-socket'

