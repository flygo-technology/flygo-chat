# TTS tiếng Việt cho phòng họp Flygo (edge-tts; "google-vi" = giọng Google Dịch, không cần khoá API). Chỉ trong LAN:
# flygo-push gọi POST /tts rồi tự phục vụ tệp mp3.
#   POST /tts {text, voice?, rate?} -> {file, duration_ms}   (tệp ở /out/<file>, nhớ theo băm nội dung)
import asyncio, hashlib, json, os, re, shutil, urllib.parse
import aiohttp
from aiohttp import web
import edge_tts

OUT = os.environ.get("OUT", "/out")
VOICES = {"vi-VN-HoaiMyNeural", "vi-VN-NamMinhNeural", "google-vi"}
FFMPEG = shutil.which("ffmpeg")

def chunks(text, n=190):
    """Google Dịch nhận tối đa ~200 ký tự mỗi lần: cắt theo câu, rồi dấu phẩy, rồi từ."""
    out = []
    for part in re.findall(r"[^.!?…;:]+[.!?…;:]*", text) or [text]:
        part = part.strip()
        while len(part) > n:
            cut = max(part.rfind(",", 0, n), part.rfind(" ", 0, n))
            cut = cut if cut > 20 else n
            out.append(part[:cut + 1].strip()); part = part[cut + 1:].strip()
        if part:
            if out and len(out[-1]) + len(part) + 1 <= n: out[-1] += " " + part
            else: out.append(part)
    return out

async def google(text, rate, tmp):
    buf = b""
    async with aiohttp.ClientSession(headers={"User-Agent": "Mozilla/5.0"}) as s:
        for i, c in enumerate(chunks(text)):
            q = urllib.parse.urlencode({"ie": "UTF-8", "client": "tw-ob", "tl": "vi", "q": c, "total": 1, "idx": 0, "textlen": len(c)})
            async with s.get(f"https://translate.google.com/translate_tts?{q}", timeout=aiohttp.ClientTimeout(total=20)) as r:
                if r.status != 200: raise RuntimeError(f"google {r.status}")
                buf += await r.read()
    speed = 1 + int(rate[1:-1]) / 100 * (1 if rate[0] == "+" else -1)
    if FFMPEG and abs(speed - 1) > 0.01:
        # Google không đổi được tốc độ: tăng / giảm bằng ffmpeg (giữ cao độ), ghi lại 64 kbps.
        src = tmp + ".src.mp3"
        open(src, "wb").write(buf)
        p = await asyncio.create_subprocess_exec(FFMPEG, "-y", "-v", "error", "-i", src, "-filter:a", f"atempo={max(0.5, min(2.0, speed)):.2f}", "-ar", "24000", "-ac", "1", "-b:a", "64k", "-f", "mp3", tmp)
        await p.wait(); os.remove(src)
        if p.returncode != 0: raise RuntimeError("ffmpeg lỗi")
    else:
        open(tmp, "wb").write(buf)
lock = asyncio.Semaphore(3)

async def tts(req):
    try:
        b = await req.json()
    except Exception:
        return web.json_response({"error": "body không phải JSON"}, status=400)
    text = " ".join(str(b.get("text") or "").split())[:3000]
    if not text:
        return web.json_response({"error": "text trống"}, status=400)
    voice = b.get("voice") or "vi-VN-HoaiMyNeural"
    if voice not in VOICES:
        voice = "vi-VN-HoaiMyNeural"
    rate = str(b.get("rate") or "+0%")
    if not (rate[:1] in "+-" and rate[1:-1].isdigit() and rate.endswith("%")):
        rate = "+0%"
    name = hashlib.sha256(f"{voice}|{rate}|{text}".encode()).hexdigest()[:24] + ".mp3"
    path = os.path.join(OUT, name)
    if not os.path.exists(path):
        async with lock:
            tmp = path + ".tmp"
            err = None
            for i in range(4):  # dịch vụ Edge đôi khi trả 429 / ngắt: thử lại 0.5s, 1.5s, 3.5s
                try:
                    if voice == "google-vi": await google(text, rate, tmp)
                    else: await edge_tts.Communicate(text, voice, rate=rate).save(tmp)
                    err = None
                    break
                except Exception as e:
                    err = e
                    await asyncio.sleep([0.5, 1.5, 3.5, 0][i])
            if err:
                return web.json_response({"error": f"tts lỗi: {str(err)[:120]}"}, status=502)
            os.replace(tmp, path)
    # edge-tts: mp3 24kHz 48kbps mono -> 6 byte / ms; Google: 64 kbps -> 8 byte / ms
    return web.json_response({"file": name, "duration_ms": int(os.path.getsize(path) / (8 if voice == "google-vi" else 6))})

async def prune():
    while True:
        await asyncio.sleep(3600)
        try:
            files = sorted((os.path.join(OUT, f) for f in os.listdir(OUT) if f.endswith(".mp3")), key=os.path.getmtime)
            for f in files[:-2000]:
                os.remove(f)
        except Exception:
            pass

async def start(app):
    app["prune"] = asyncio.create_task(prune())

app = web.Application()
app.router.add_post("/tts", tts)
app.router.add_get("/health", lambda r: web.json_response({"status": "OK"}))
app.on_startup.append(start)
web.run_app(app, host="0.0.0.0", port=8067, print=None)
