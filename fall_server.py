"""
Fall-detection backend on Modal.

The phone app triggers the glasses camera locally (Device Access Toolkit) after a detected fall,
then sends 1-5 JPEG frames here. The server:
  1. drops unusable frames (dark / blurred / lens covered)
  2. blurs faces before any frame leaves the server
  3. asks Claude (vision) for place + hazards as schema-validated JSON
  4. fuses the visual level with the IMU level (vision can only RAISE the level)
  5. stores the event; the app later posts the user's spoken answer
  6. on alarm, notifies the emergency contact (webhook, e.g. ntfy.sh) with a link to a view page

Setup:
  pip install modal && modal setup
  modal secret create fall-secrets ANTHROPIC_API_KEY=... API_KEY=<random string for the app> \
      NOTIFY_WEBHOOK_URL=https://ntfy.sh/<your-topic>      # optional
Dev:    modal serve fall_server.py      (hot reload, temporary URL)
Deploy: modal deploy fall_server.py     (stable URL)
"""
import os
import modal

app = modal.App("fall-detection-backend")

image = (
    modal.Image.debian_slim(python_version="3.12")
    .uv_pip_install(
        "fastapi[standard]",
        "python-multipart",
        "opencv-python-headless<5",   # 4.x ships the Haar face cascades
        "numpy",
        "pydantic",
        "httpx",
        "anthropic",
    )
)

events = modal.Dict.from_name("fall-events", create_if_missing=True)

CLAUDE_MODEL = os.environ.get("CLAUDE_MODEL", "claude-sonnet-5-5")   # faster/cheaper: claude-haiku-5-5

VISION_PROMPT = """I am showing you {n} frames extracted in chronological order from a video \
recorded by smart glasses worn by a person. The camera is therefore the \
person's point of view, at eye level.

The video was triggered automatically AFTER a sensor detected a possible \
fall event. This means that the moment of impact is often NOT captured: \
the video may start when the fall has already occurred. The video lasts \
about {durata:.1f} seconds and each frame is preceded by its timestamp.

Your task is NOT to see the moment of the fall, but to determine from the \
person's state whether a fall has occurred.

Answer "YES" if you see clues that the person ended up on the ground, for example:
- the camera is at ground level or very close to the floor
- the framing is tilted, rotated sideways, or upside down in an unnatural \
way and remains so (the person is lying down or slumped)
- you see the floor, shoes, legs, or objects from the bottom up, from a \
position that is not that of a standing or sitting person
- the scene is still and low throughout the video, or there are slow, \
clumsy movements of someone trying to get back up
- other people arrive and bend down or assist the person on the ground
- if the fall is visible: framing plummeting or rotating abruptly toward \
the ground

Answer "NO" if the camera remains at a normal height for a person standing \
or sitting on a chair, with natural movements (walking, turning their head, \
bending down briefly and standing back up, sitting down in a controlled manner) \
and no clues of having ended up on the ground.

If the person is on the ground but it clearly appears to be a voluntary and \
calm choice (e.g., doing push-ups, lying down to rest with controlled \
movements), answer "NO" and explain this in the reason. When in doubt \
between the two answers, choose "YES" and lower the confidence.

Respond ONLY with a JSON object, with no other text, in this format:
{{"caduta": "YES" or "NO", "confidenza": number between 0 and 1, \
"motivo": "a short sentence mentioning what you saw"}}"""


# ----------------------------------------------------------------------------- image utilities
def _decode(b: bytes):
    import cv2, numpy as np
    return cv2.imdecode(np.frombuffer(b, np.uint8), cv2.IMREAD_COLOR)


def quality(img) -> dict:
    """Cheap checks, no AI: brightness, sharpness, uniformity (lens on the floor)."""
    import cv2
    g = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    b, s, u = float(g.mean()), float(cv2.Laplacian(g, cv2.CV_64F).var()), float(g.std())
    ok = b >= 35 and s >= 40 and u >= 12
    return {"brightness": round(b, 1), "sharpness": round(s, 1), "contrast": round(u, 1), "usable": ok}


def blur_faces(img):
    import cv2
    cascade = cv2.CascadeClassifier(cv2.data.haarcascades + "haarcascade_frontalface_default.xml")
    if cascade.empty():   # detector missing: privacy first, blur the whole frame lightly
        return cv2.GaussianBlur(img, (0, 0), sigmaX=6), -1
    g = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    faces = cascade.detectMultiScale(g, scaleFactor=1.1, minNeighbors=5, minSize=(30, 30))
    for (x, y, w, h) in faces:
        roi = img[y:y + h, x:x + w]
        img[y:y + h, x:x + w] = cv2.GaussianBlur(roi, (0, 0), sigmaX=max(w, h) / 6)
    return img, len(faces)


def to_jpeg(img, max_side=768, q=80) -> bytes:
    import cv2
    h, w = img.shape[:2]
    k = max_side / max(h, w)
    if k < 1:
        img = cv2.resize(img, (int(w * k), int(h * k)), interpolation=cv2.INTER_AREA)
    return cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, q])[1].tobytes()


# ----------------------------------------------------------------------------- vision model
FALLBACK = {"usable_frames": 0, "place": "unknown", "possible_visible_cause": "uncertain", "hazards": [],
            "view": "uncertain", "people_nearby": "uncertain", "blood": "uncertain",
            "visual_hazard_level": 0, "confidence": 0.0, "reason": "Analisi visiva non disponibile."}

VISION_SCHEMA = {
    "type": "object",
    "properties": {
        "place": {"type": "string", "enum": ["bathroom", "kitchen", "stairs", "bedroom", "living_room",
                                             "street", "outdoor", "other", "unknown"]},
        "possible_visible_cause": {"type": "string", "enum": ["stairs", "object_on_floor", "wet_floor",
                                                              "none_visible", "uncertain"]},
        "hazards": {"type": "array", "items": {"type": "string", "enum": [
            "water", "stairs", "traffic", "fire", "glass", "sharp_edges", "fallen_objects"]}},
        "view": {"type": "string", "enum": ["floor", "ceiling", "horizontal", "uncertain"]},
        "people_nearby": {"type": "string", "enum": ["yes", "no", "uncertain"]},
        "blood": {"type": "string", "enum": ["yes", "no", "uncertain"]},
        "visual_hazard_level": {"type": "integer", "enum": [0, 1, 2, 3]},
        "confidence": {"type": "number"},
        "reason": {"type": "string"},
    },
    "required": ["place", "possible_visible_cause", "hazards", "view", "people_nearby", "blood",
                 "visual_hazard_level", "confidence", "reason"],
    "additionalProperties": False,
}


def analyze_with_claude(jpegs: list[bytes]) -> dict:
    import base64, json
    import anthropic

    client = anthropic.Anthropic()          # reads ANTHROPIC_API_KEY from the Modal secret
    content = [{"type": "image",
                "source": {"type": "base64", "media_type": "image/jpeg",
                           "data": base64.standard_b64encode(j).decode()}} for j in jpegs]
    content.append({"type": "text", "text": VISION_PROMPT})
    msg = client.messages.create(
        model=CLAUDE_MODEL,
        max_tokens=400,
        messages=[{"role": "user", "content": content}],
        # structured outputs: JSON guaranteed to match the schema (sent raw, works with any SDK version)
        extra_body={"output_config": {"format": {"type": "json_schema", "schema": VISION_SCHEMA}}},
    )
    data = json.loads(next(b.text for b in msg.content if b.type == "text"))
    out = {**FALLBACK, **{k: data[k] for k in FALLBACK if k in data}}
    out["visual_hazard_level"] = int(max(0, min(3, int(out["visual_hazard_level"]))))
    out["confidence"] = float(max(0.0, min(1.0, float(out["confidence"]))))
    return out


def fuse(imu_level: int, vis: dict) -> int:
    """Vision can only raise the level, and only when confident."""
    v = vis["visual_hazard_level"] if vis["confidence"] >= 0.5 else 0
    if vis.get("blood") == "yes" and vis["confidence"] >= 0.5:
        v = 3
    return max(int(imu_level), v)


def notify(event: dict, base_url: str):
    import httpx
    url = os.environ.get("NOTIFY_WEBHOOK_URL")
    if not url:
        print("[notify] no NOTIFY_WEBHOOK_URL, skipping", event["event_id"])
        return False
    lat, lon = event.get("lat"), event.get("lon")
    maps = f"https://maps.google.com/?q={lat},{lon}" if lat is not None and lon is not None else "posizione non disponibile"
    text = (f"CADUTA livello {event['level']}/3 - {event['vision']['reason']}\n"
            f"Risposta: {event.get('answer', 'in attesa')}\nPosizione: {maps}\n"
            f"Dettagli: {base_url}/event/{event['event_id']}/view")
    try:
        r = httpx.post(url, content=text.encode(), headers={"Title": "Allarme caduta", "Priority": "urgent"}, timeout=10)
        return r.status_code < 300
    except Exception as e:
        print("[notify] failed:", e)
        return False


# ----------------------------------------------------------------------------- web app
def build_web_app():
    import base64, time, uuid
    from fastapi import FastAPI, File, Form, Header, HTTPException, Request, UploadFile
    from fastapi.responses import HTMLResponse
    from pydantic import BaseModel

    web = FastAPI(title="Fall detection backend")

    def check_key(x_api_key: str | None):
        expected = os.environ.get("API_KEY")
        if expected and x_api_key != expected:
            raise HTTPException(401, "invalid api key")

    def base(request: Request) -> str:
        return str(request.base_url).rstrip("/")

    @web.get("/health")
    def health():
        return {"ok": True, "model": CLAUDE_MODEL}

    @web.post("/analyze")
    async def analyze(
        request: Request,
        frames: list[UploadFile] = File(...),
        imu_level: int = Form(1),
        lat: float | None = Form(None),
        lon: float | None = Form(None),
        event_id: str | None = Form(None),
        x_api_key: str | None = Header(None),
    ):
        check_key(x_api_key)
        t0 = time.time()
        if not 1 <= len(frames) <= 5:
            raise HTTPException(400, "send 1-5 frames")

        checked = []
        for f in frames:
            img = _decode(await f.read())
            if img is None:
                continue
            q = quality(img)
            checked.append((q, img))
        usable = sorted([c for c in checked if c[0]["usable"]], key=lambda c: -c[0]["sharpness"])[:4]

        jpegs, n_faces = [], 0
        for _, img in usable:
            img, n = blur_faces(img)
            n_faces = -1 if n < 0 or n_faces < 0 else n_faces + n
            jpegs.append(to_jpeg(img))

        vision, error = dict(FALLBACK), None
        if jpegs:
            try:
                vision = analyze_with_claude(jpegs)
            except Exception as e:          # vision is optional: never block the alarm path
                error = f"{type(e).__name__}: {e}"
        vision["usable_frames"] = len(jpegs)

        eid = event_id or uuid.uuid4().hex[:12]
        event = {
            "event_id": eid, "created": time.time(), "imu_level": imu_level,
            "level": fuse(imu_level, vision), "vision": vision, "vision_error": error,
            "lat": lat, "lon": lon, "faces_blurred": n_faces,
            "quality": [c[0] for c in checked], "status": "awaiting_answer",
            "frame_b64": base64.b64encode(jpegs[0]).decode() if jpegs else None,
            "processing_ms": int((time.time() - t0) * 1000),
        }
        await events.put.aio(eid, event)
        return {k: v for k, v in event.items() if k != "frame_b64"}

    class Answer(BaseModel):
        answer: str              # fine | help | confused | silence
        transcript: str | None = None

    @web.post("/event/{eid}/answer")
    async def answer(eid: str, body: Answer, request: Request, x_api_key: str | None = Header(None)):
        check_key(x_api_key)
        event = await events.get.aio(eid)
        if event is None:
            raise HTTPException(404, "unknown event")
        event["answer"], event["transcript"] = body.answer, body.transcript
        if body.answer == "fine":
            event["status"] = "cancelled"
        else:
            event["level"] = max(event["level"], 3 if body.answer in ("help", "silence") else 2)
            event["status"] = "alarm"
            event["notified"] = notify(event, base(request))
        await events.put.aio(eid, event)
        return {"event_id": eid, "status": event["status"], "level": event["level"],
                "notified": event.get("notified", False)}

    @web.post("/event/{eid}/alarm")
    async def alarm_now(eid: str, request: Request, x_api_key: str | None = Header(None)):
        """Manual 'Chiama aiuto' button: alarm immediately, no waiting."""
        check_key(x_api_key)
        event = await events.get.aio(eid)
        if event is None:
            raise HTTPException(404, "unknown event")
        event.update(status="alarm", level=3, answer=event.get("answer", "help_button"))
        event["notified"] = notify(event, base(request))
        await events.put.aio(eid, event)
        return {"event_id": eid, "status": "alarm", "notified": event["notified"]}

    @web.get("/event/{eid}")
    async def get_event(eid: str, x_api_key: str | None = Header(None)):
        check_key(x_api_key)
        event = await events.get.aio(eid)
        if event is None:
            raise HTTPException(404, "unknown event")
        return {k: v for k, v in event.items() if k != "frame_b64"}

    @web.get("/event/{eid}/view", response_class=HTMLResponse)
    async def view(eid: str):
        """Page for the emergency contact (link in the notification). Event ids are random, not guessable."""
        e = await events.get.aio(eid)
        if e is None:
            return HTMLResponse("<h3>Evento non trovato</h3>", 404)
        v = e["vision"]
        img = f'<img src="data:image/jpeg;base64,{e["frame_b64"]}" style="max-width:100%;border-radius:8px">' if e.get("frame_b64") else "<p>Nessuna immagine utilizzabile.</p>"
        maps = (f'<a href="https://maps.google.com/?q={e["lat"]},{e["lon"]}">Apri posizione su mappa</a>'
                if e.get("lat") is not None else "Posizione non disponibile")
        when = time.strftime("%H:%M:%S", time.localtime(e["created"]))
        return f"""<!doctype html><meta name=viewport content="width=device-width,initial-scale=1">
<body style="font-family:system-ui;max-width:640px;margin:20px auto;padding:0 14px">
<h2 style="color:#b42318">Caduta rilevata - livello {e['level']}/3</h2>
<p><b>Ora:</b> {when} &middot; <b>Stato:</b> {e['status']} &middot; <b>Risposta:</b> {e.get('answer','in attesa')}</p>
<p><b>Situazione:</b> {v['reason']}</p>
<p><b>Luogo:</b> {v['place']} &middot; <b>Pericoli:</b> {', '.join(v['hazards']) or 'nessuno visibile'}</p>
<p>{maps}</p>{img}
<p style="color:#666;font-size:13px">Volti sfocati automaticamente. L'analisi visiva è indicativa, non una diagnosi.</p></body>"""

    return web


@app.function(
    image=image,
    secrets=[modal.Secret.from_name("fall-secrets")],
    min_containers=1,        # keep one warm during the demo: no cold start on the first fall
    scaledown_window=300,
    timeout=60,
)
@modal.concurrent(max_inputs=20)
@modal.asgi_app()
def fastapi_app():
    return build_web_app()
