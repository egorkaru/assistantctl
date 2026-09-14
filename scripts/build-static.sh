#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if ! command -v brew >/dev/null 2>&1; then
  echo 'Homebrew is required to build TDLib and OpenSSL statically.' >&2
  exit 1
fi

tdlib_root="$(brew --prefix tdlib)"
openssl_root="$(brew --prefix openssl@3)"
linker_flags=()

for library in \
  tdjson_static tdjson_private tdclient tdcore tdapi tdnet \
  tddb tdactor tdsqlite tdutils; do
  archive="${tdlib_root}/lib/lib${library}.a"
  if [[ ! -f "$archive" ]]; then
    echo "Missing $archive; run: brew install tdlib openssl@3" >&2
    exit 1
  fi
  linker_flags+=(-Xlinker "$archive")
done

for library in ssl crypto; do
  archive="${openssl_root}/lib/lib${library}.a"
  if [[ ! -f "$archive" ]]; then
    echo "Missing $archive; run: brew install tdlib openssl@3" >&2
    exit 1
  fi
  linker_flags+=(-Xlinker "$archive")
done

linker_flags+=(-Xlinker -lz -Xlinker -lc++)

ASSISTANTCTL_STATIC_TDLIB=1 swift build -c release --disable-build-manifest-caching "$@" \
  -Xcc "-I${tdlib_root}/include" "${linker_flags[@]}"

executable=".build/release/assistantctl"
dependencies="$(otool -L "$executable")"
if echo "$dependencies" | grep -E 'tdjson|libssl|libcrypto|/opt/homebrew/|/usr/local/(Cellar|opt)/'; then
  echo 'Release executable still depends on Homebrew libraries' >&2
  exit 1
fi

"$executable" --help >/dev/null
echo "Runnable static build: $repo_root/$executable"
