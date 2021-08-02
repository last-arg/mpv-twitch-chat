Features:
[ ] Track mpv video state to avoid unnecessary downloads. Happens during seek

Improve:
[ ] UI (NotCurses): resizing
    [?] Move info plane resizing to text plane's callback?
[ ] new json parsing option - https://github.com/ziglang/zig/issues/7906

Bugs:
[ ] Ui (NotCurses) on unexpected crash can't see cursor after

Fix:
[ ] Fix/Refactor after making changes so code works with latest zig compiler


Future/Explore:
- Can I share struct with C without allocating struct?
- GUI
- Certificate file (*.pem)
    - https://curl.haxx.se/docs/caextract.html

- OpenSSl
    - [OpenSSL server/client example](https://aticleworld.com/ssl-server-client-using-openssl-in-c/)
    - [Zig openssl example](https://github.com/marler8997/ziget/blob/master/openssl/ssl.zig)
