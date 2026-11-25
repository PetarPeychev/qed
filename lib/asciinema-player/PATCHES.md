# asciinema-player (vendored)

Web player for the `.html` demo pages `tools/e2e.sh demo` writes; `tools/e2e/main.odin` `#load`s both files and inlines them into each page.

- **Upstream:** https://github.com/asciinema/asciinema-player (npm `asciinema-player`)
- **Version:** 3.18.0, npm tarball sha256 `18d9703510fae9209da9e26ce3d13c59f083b4abcff003a3bba958e03918a862`
- **License:** Apache-2.0 (`LICENSE`)

`dist/bundle/asciinema-player.min.js` and `dist/bundle/asciinema-player.css` copied unchanged. No patches.

## Updating

`npm pack asciinema-player@X.Y.Z`, copy the two bundle files and `LICENSE`, check neither contains `</script` or `</style`.
