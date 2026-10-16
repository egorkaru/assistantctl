#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if ! command -v brew >/dev/null 2>&1; then
  echo 'Homebrew is required to build TDLib and OpenSSL statically.' >&2
  exit 1
fi

tdlib_root="$(brew --prefix tdlib)"
openssl_formula="$(brew deps --1 tdlib | grep -E '^openssl(@[0-9]+)?$' | head -n 1)"
openssl_root="$(brew --prefix "$openssl_formula")"
linker_flags=()

for library in \
  tdjson_static tdjson_private tdclient tdcore tdapi tdnet \
  tddb tdactor tdsqlite tdutils tdmtproto tde2e; do
  archive="${tdlib_root}/lib/lib${library}.a"
  if [[ ! -f "$archive" ]]; then
    echo "Missing $archive; run: brew install --HEAD tdlib" >&2
    exit 1
  fi
  linker_flags+=(-Xlinker "$archive")
done

for library in ssl crypto; do
  archive="${openssl_root}/lib/lib${library}.a"
  if [[ ! -f "$archive" ]]; then
    echo "Missing $archive; run: brew install --HEAD tdlib" >&2
    exit 1
  fi
  linker_flags+=(-Xlinker "$archive")
done

linker_flags+=(-Xlinker -lz -Xlinker -lc++)

if [[ -z ${LOGS+x} ]]; then
  export ASSISTANTCTL_QUIET_TDLIB=1
  export ASSISTANTCTL_QUIET_GMAIL=1
  export ASSISTANTCTL_QUIET_MICROSOFT=1
fi

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
