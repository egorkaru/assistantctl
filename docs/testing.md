# Check a local build

Use macOS 15+ with Swift 6.2 or later. From the repository root:

```sh
brew install tdlib openssl@3
swift test
bash scripts/build-static.sh
python3 Tests/mcp_smoke.py .build/release/assistantctl
```

`build-static.sh` builds the current Mac architecture, checks that the executable has no TDLib, OpenSSL, or Homebrew dynamic-library dependency, and runs `assistantctl --help`. The tests cover cache reads, ingestion, OAuth helpers, and MCP startup with fixtures. They do not sign in to provider accounts.

## Command Line Tools testing

If `swift test` reports `no such module 'Testing'`, use:

```sh
TEST_FRAMEWORKS="$(xcode-select -p)/Library/Developer/Frameworks"
swift test --scratch-path /tmp/assistantctl-swift-build \
  -Xswiftc -F -Xswiftc "$TEST_FRAMEWORKS" \
  -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
  -Xlinker -F -Xlinker "$TEST_FRAMEWORKS" \
  -Xlinker -rpath -Xlinker "$TEST_FRAMEWORKS"
```

The existing release workflow builds both architectures, merges them with `lipo`, and checks that the merged executable starts without installing TDLib in that job. Local `build-static.sh` produces only the current Mac's architecture.
