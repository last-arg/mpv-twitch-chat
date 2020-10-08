dev:
	ls src/* | entr -c -r zig build run
	
test-run:
	echo "src/main.zig" | entr -c -r zig test src/main.zig
