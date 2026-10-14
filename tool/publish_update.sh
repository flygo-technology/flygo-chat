#!/bin/sh
# Đăng bản cập nhật cho app tự cập nhật: tool/publish_update.sh <build> "<ghi chú>" [android=<apk>] [macos=<zip>] [windows=<zip>] [linux=<tar.gz>]
# Tệp được đặt ở https://chat.flygo.vn/static/plugins/flygo-update/ (thư mục client-plugins của Mattermost trên internal-host,
# được gắn từ ổ máy chủ nên không mất khi tạo lại container). version.json giữ tệp cũ của nền tảng không có trong lần đăng này.
set -e
BUILD=$1; NOTES=$2; shift 2
VERSION=$(grep '^version:' "$(dirname "$0")/../pubspec.yaml" | sed 's/version: //; s/+.*//')
HOST=admin@internal-host
DIR=/srv/apps/mattermost/client-plugins/flygo-update
for a in "$@"; do
  key=${a%%=*}; src=${a#*=}; ext=${src##*.}; [ "${src%.tar.gz}" != "$src" ] && ext=tar.gz
  name="flygo-chat-$BUILD-$key.$ext"
  scp -q "$src" "$HOST:/tmp/$name" && ssh $HOST "sudo mv /tmp/$name $DIR/$name && sudo chown 2000:2000 $DIR/$name"
  FILES="$FILES $key=$name"
done
ssh $HOST "sudo python3 - '$DIR' '$BUILD' '$VERSION' '$NOTES' $FILES" <<'PY'
import json,sys,os
d,build,version,notes=sys.argv[1:5]
p=os.path.join(d,'version.json')
cur=json.load(open(p)) if os.path.exists(p) else {}
files=cur.get('files',{})
builds=cur.get('builds',{k:cur.get('build',0) for k in files})
for kv in sys.argv[5:]:
    k,v=kv.split('=',1); files[k]=v; builds[k]=int(build)
# "build" chung = bản thấp nhất giữa các nền tảng: app cũ (chỉ đọc "build") không cập nhật vòng lặp.
json.dump({'build':min(builds.values()) if builds else int(build),'builds':builds,'version':version,'notes':notes,'files':files},open(p,'w'),ensure_ascii=False,indent=1)
os.chown(p,2000,2000)
print(open(p).read())
PY
