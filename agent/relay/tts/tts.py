# TTS tiếng Việt cho phòng họp Flygo (edge-tts). Chỉ trong LAN: flygo-push gọi POST /tts rồi tự phục vụ tệp mp3.
#   POST /tts {text, voice?, rate?} -> {file, duration_ms}   (tệp ở /out/<file>, nhớ theo băm nội dung)
import asyncio, hashlib, json, os
from aiohttp import web
import edge_tts

OUT = os.environ.get("OUT", "/out")
VOICES = {"vi-VN-HoaiMyNeural", "vi-VN-NamMinhNeural"}
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
                    await edge_tts.Communicate(text, voice, rate=rate).save(tmp)
                    err = None
                    break
                except Exception as e:
                    err = e
                    await asyncio.sleep([0.5, 1.5, 3.5, 0][i])
            if err:
                return web.json_response({"error": f"tts lỗi: {str(err)[:120]}"}, status=502)
            os.replace(tmp, path)
    # edge-tts: mp3 24kHz 48kbps mono -> 6 byte / ms
    return web.json_response({"file": name, "duration_ms": int(os.path.getsize(path) / 6)})

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
