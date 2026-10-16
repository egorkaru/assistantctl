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
brew install --HEAD tdlib
swift build -c release --disable-build-manifest-caching
swift test
.build/release/assistantctl --help
```

To build the same statically linked executable used by CI, run:

```sh
brew install --HEAD tdlib
bash scripts/build-static.sh
.build/release/assistantctl --help
```

If Homebrew reports that stable `tdlib` is already installed, run `brew unlink tdlib` and then `brew install --HEAD tdlib`. The script links the Homebrew TDLib and its OpenSSL dependency statically into `.build/release/assistantctl`, checks dynamic dependencies, and starts the executable. OAuth client configuration is supplied by each user at login. A private source build may embed a Telegram API ID and hash from `.assistantctl-private/telegram-app.json`; public release builds contain no Telegram app credentials. Neither configuration is required to build. See [provider setup](providers.md).

The build script sets `ASSISTANTCTL_QUIET_TDLIB`, `ASSISTANTCTL_QUIET_GMAIL`, and `ASSISTANTCTL_QUIET_MICROSOFT` when `LOGS` is unset, including for public release builds. Set `LOGS` to any value to build with TDLib's native logs and provider response details:

```sh
LOGS=1 bash scripts/build-static.sh
```

`LOGS` is read only by the build script. The three provider variables are read by `Package.swift` and can be set separately for a source build. Without `LOGS`, Gmail and Microsoft errors retain HTTP status and setup guidance but omit provider-supplied response text. Native TDLib logs can include credentials and message data; keep diagnostic builds local and do not share their output. Changing these variables when running an already built binary has no effect.

If `swift test` cannot locate the `Testing` framework on a Command Line Tools-only Mac, use the [alternate test command](testing.md#command-line-tools-testing).
