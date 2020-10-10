dev:
	ls src/* | entr -c -r zig build run
	
test-main:
	echo "src/main.zig" | entr -c -r zig test src/main.zig

test-mpv:
	echo "src/mpv.zig" | entr -c -r zig test src/mpv.zig

test-comments:
	echo "src/comments.zig" | entr -c -r zig test src/comments.zig

test-twitch:
	echo "src/twitch.zig" | entr -c -r zig test src/twitch.zig	
