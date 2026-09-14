# Install and build

Requires macOS 15+. The release executable contains TDLib and OpenSSL; no Homebrew installation is needed to run it. Source builds require Swift 6.2+.

## Release archive

Download `assistantctl-macos-universal.tar.gz` from the latest GitHub release, then:

```sh
tar -xzf assistantctl-macos-universal.tar.gz
install assistantctl /usr/local/bin/assistantctl
```

Use an existing directory in your `PATH` if `/usr/local/bin` is unavailable.

## Build from source

```sh
brew install tdlib
swift build -c release --disable-build-manifest-caching
swift test
.build/release/assistantctl --help
```

To build the same statically linked executable used by CI, run:

```sh
brew install tdlib openssl@3
bash scripts/build-static.sh
.build/release/assistantctl --help
```

The script links TDLib and OpenSSL static archives into `.build/release/assistantctl`, checks its dynamic dependencies, and starts it. OAuth client configuration is supplied by each user at login. A private source build may embed a Telegram API ID and hash from `.assistantctl-private/telegram-app.json`; public release builds contain no Telegram app credentials. Neither configuration is required to build. See [provider setup](providers.md).

If `swift test` cannot locate the `Testing` framework on a Command Line Tools-only Mac, use the [alternate test command](testing.md#command-line-tools-testing).
