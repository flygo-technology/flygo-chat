#!/usr/bin/env bash
# Đóng gói runner trợ lý AI (flygo-agent) vào bản app máy tính — người dùng không phải cài gì bên ngoài.
# Dùng: tool/bundle_runner.sh <macos|linux-x64|windows-x64> <thư mục đích>
#   macos      : <đích> = "Flygo Chat.app"   → Contents/Resources/flygo-agent (universal arm64+x64), ký lại ad-hoc
#   linux-x64  : <đích> = thư mục bundle      → lib/flygo-agent
#   windows-x64: <đích> = thư mục Release     → flygo-agent.exe (cạnh flygo_chat.exe)
# Kèm file flygo-agent.version để app biết bản đóng gói mới hơn bản đã cài thì cập nhật.
# Nguồn: máy chủ gốc 192.168.2.4 (scp, tránh bản cũ do Cloudflare cache); không vào được thì tải https + chống cache.
set -euo pipefail
PLAT="$1"; DEST="$2"
ORIGIN=admin@192.168.2.4:/srv/apps/mattermost/client-plugins/flygo-agent
BASE=https://chat.flygo.vn/static/plugins/flygo-agent
PY=$(command -v python3 || command -v python)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# Git Bash trên Windows: Python (bản Windows) cần đường dẫn kiểu C:/...
PYTMP=$TMP; command -v cygpath >/dev/null && PYTMP=$(cygpath -m "$TMP")
fetch() { # fetch <tên file>
  if scp -q -o ConnectTimeout=5 -o BatchMode=yes "$ORIGIN/$1" "$TMP/$1" 2>/dev/null; then return 0; fi
  curl -sfL "$BASE/$1?v=$(date +%s)" -o "$TMP/$1"
}
fetch version.json
VER=$("$PY" -c "import json;print(json.load(open('$PYTMP/version.json'))['version'])")
check() { # check <tên file>
  local want got
  want=$("$PY" -c "import json;print(json.load(open('$PYTMP/version.json'))['files']['$1']['sha256'])")
  got=$( (sha256sum "$TMP/$1" 2>/dev/null || shasum -a 256 "$TMP/$1") | cut -d' ' -f1)
  [ "$want" = "$got" ] || { echo "sai sha256 $1" >&2; exit 1; }
}
case "$PLAT" in
  macos)
    for a in arm64 x64; do fetch flygo-agent-darwin-$a; check flygo-agent-darwin-$a; done
    R="$DEST/Contents/Resources"
    lipo -create "$TMP/flygo-agent-darwin-arm64" "$TMP/flygo-agent-darwin-x64" -output "$R/flygo-agent"
    chmod 755 "$R/flygo-agent"; echo "$VER" > "$R/flygo-agent.version"
    codesign --force --deep -s - "$DEST" >/dev/null 2>&1
    ;;
  linux-x64)
    fetch flygo-agent-linux-x64; check flygo-agent-linux-x64
    mkdir -p "$DEST/lib"; cp "$TMP/flygo-agent-linux-x64" "$DEST/lib/flygo-agent"; chmod 755 "$DEST/lib/flygo-agent"
    echo "$VER" > "$DEST/lib/flygo-agent.version"
    ;;
  windows-x64)
    fetch flygo-agent-windows-x64.exe; check flygo-agent-windows-x64.exe
    cp "$TMP/flygo-agent-windows-x64.exe" "$DEST/flygo-agent.exe"; echo "$VER" > "$DEST/flygo-agent.version"
    ;;
  *) echo "nền tảng không hỗ trợ: $PLAT" >&2; exit 2 ;;
esac
echo "runner $VER đã đóng gói ($PLAT)"
