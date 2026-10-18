#!/bin/sh
# Đăng bản cập nhật cho app tự cập nhật: tool/publish_update.sh <build> "<ghi chú>" [android=<apk>] [macos=<zip>] [windows=<zip>] [linux=<tar.gz>]
# Tệp được đặt vào thư mục tĩnh mà app đọc (lib/update/updater.dart), qua SSH tới máy chủ đó.
# Cấu hình FLYGO_UPDATE_HOST=<user@máy> và FLYGO_UPDATE_DIR=<thư mục> trong môi trường hoặc tool/local.env (không đưa vào git). version.json giữ tệp cũ của nền tảng không có trong lần đăng này.
set -e
BUILD=$1; NOTES=$2; shift 2
VERSION=$(grep '^version:' "$(dirname "$0")/../pubspec.yaml" | sed 's/version: //; s/+.*//')
[ -f "$(dirname "$0")/local.env" ] && . "$(dirname "$0")/local.env"
HOST=${FLYGO_UPDATE_HOST:?Chưa đặt FLYGO_UPDATE_HOST (xem đầu tệp)}
DIR=${FLYGO_UPDATE_DIR:?Chưa đặt FLYGO_UPDATE_DIR (xem đầu tệp)}
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
# Dung lượng từng tệp: Cloudflare không gửi Content-Length nên app dùng số này để hiện tiến độ tải.
sizes={k:os.path.getsize(os.path.join(d,v)) for k,v in files.items() if os.path.exists(os.path.join(d,v))}
json.dump({'build':min(builds.values()) if builds else int(build),'builds':builds,'version':version,'notes':notes,'files':files,'sizes':sizes},open(p,'w'),ensure_ascii=False,indent=1)
os.chown(p,2000,2000)
# Dọn bản cũ (tránh đầy đĩa): chỉ giữ tệp đang trỏ trong version.json và 3 bản gần nhất.
import re
keep=set(files.values()); lo=int(build)-3
for f in os.listdir(d):
    m=re.match(r'flygo-chat-(\d+)-',f)
    if m and f not in keep and int(m.group(1))<lo: os.remove(os.path.join(d,f))
print(open(p).read())
PY
