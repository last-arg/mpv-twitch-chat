dev:
	ls src/* | entr -c -r zig build run
	
test-main:
	echo "src/main.zig" | entr -c -r zig test src/main.zig

test-mpv:
	echo "src/mpv.zig" | entr -c -r zig test src/mpv.zig
