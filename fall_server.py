"""
Fall-detection backend on Modal.

The phone app triggers the glasses camera locally (Device Access Toolkit) after a detected fall,
then sends 1-7 JPEG frames here. The server:
  1. drops unusable frames (dark / blurred / lens covered)
  2. blurs faces before any frame leaves the server
  3. asks Claude (vision) whether the wearer is on the ground (caduta SI/NO), schema-validated JSON
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

PROMPT_VERSION = "v3-caduta-it"
VISION_PROMPT = """Ti mostro {n} fotogrammi estratti in ordine cronologico da un video \
registrato da degli occhiali smart indossati da una persona. La telecamera \
e' quindi il punto di vista della persona, all'altezza dei suoi occhi.

Il video e' stato avviato automaticamente DOPO che un sensore ha rilevato \
un possibile evento di caduta. Questo significa che spesso il momento \
dell'impatto NON e' ripreso: il video puo' iniziare quando la caduta e' \
gia' avvenuta. Il video dura circa {durata:.1f} secondi e ogni fotogramma \
e' preceduto dal suo istante temporale.

Il tuo compito NON e' vedere l'istante della caduta, ma capire dallo \
stato in cui si trova la persona se una caduta e' avvenuta.

Rispondi "SI" se vedi indizi che la persona e' finita a terra, ad esempio:
- la telecamera e' a livello del suolo o molto vicina al pavimento
- l'inquadratura e' inclinata, ruotata di lato o capovolta in modo \
innaturale e resta cosi' (la persona e' sdraiata o accasciata)
- si vedono pavimento, scarpe, gambe o oggetti dal basso verso l'alto, \
da una posizione che non e' quella di una persona in piedi o seduta
- la scena e' ferma e bassa per tutto il video, oppure ci sono movimenti \
lenti e goffi di chi cerca di rialzarsi
- arrivano altre persone che si chinano o soccorrono chi e' a terra
- se la caduta e' visibile: inquadratura che precipita o ruota bruscamente \
verso il suolo

Rispondi "NO" se la telecamera resta a un'altezza normale da persona in \
piedi o seduta su una sedia, con movimenti naturali (camminare, girare la \
testa, chinarsi un attimo e rialzarsi, sedersi in modo controllato) e \
nessun indizio di essere finiti a terra.

Se la persona e' a terra ma appare chiaramente una scelta volontaria e \
tranquilla (es. sta facendo flessioni, si e' sdraiata per riposare con \
movimenti controllati), rispondi "NO" e spiegalo nel motivo. Nel dubbio \
tra le due risposte, scegli "SI" e abbassa la confidenza.

Rispondi SOLO con un oggetto JSON, senza altro testo, in questo formato:
{{"caduta": "SI" oppure "NO", "confidenza": numero tra 0 e 1, \
"motivo": "una frase breve che cita cosa hai visto"}}"""


# ----------------------------------------------------------------------------- image utilities
def _decode(b: bytes):
    import cv2, numpy as np
    return cv2.imdecode(np.frombuffer(b, np.uint8), cv2.IMREAD_COLOR)


# Gate only clearly unusable frames (black, lens covered, extreme blur). Override via env vars in the Modal secret.
Q_MIN_BRIGHT = float(os.environ.get("Q_MIN_BRIGHT", 20))
Q_MIN_SHARP = float(os.environ.get("Q_MIN_SHARP", 15))     # Laplacian variance at 768 px long side
Q_MIN_CONTRAST = float(os.environ.get("Q_MIN_CONTRAST", 10))


def quality(img) -> dict:
    """Cheap checks, no AI: brightness, sharpness, uniformity (lens on the floor)."""
    import cv2
    h, w = img.shape[:2]
    k = 768 / max(h, w)                 # same scale for every input: sharpness depends on resolution
    if k < 1:
        img = cv2.resize(img, (int(w * k), int(h * k)), interpolation=cv2.INTER_AREA)
    g = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    b, s, u = float(g.mean()), float(cv2.Laplacian(g, cv2.CV_64F).var()), float(g.std())
    ok = b >= Q_MIN_BRIGHT and s >= Q_MIN_SHARP and u >= Q_MIN_CONTRAST
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


IMG_MAX_SIDE = int(os.environ.get("IMG_MAX_SIDE", 512))   # smaller image = fewer input tokens = faster


def to_jpeg(img, max_side=None, q=80) -> bytes:
    max_side = max_side or IMG_MAX_SIDE
    import cv2
    h, w = img.shape[:2]
    k = max_side / max(h, w)
    if k < 1:
        img = cv2.resize(img, (int(w * k), int(h * k)), interpolation=cv2.INTER_AREA)
    return cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, q])[1].tobytes()


# ----------------------------------------------------------------------------- vision model
FALLBACK = {"usable_frames": 0, "on_ground": "uncertain", "caduta": None, "confidence": 0.0, "p_fall": None,
            "reason": "Analisi visiva non disponibile.", "place": "unknown", "hazards": [],
            "blood": "uncertain", "visual_hazard_level": 0}

VISION_SCHEMA = {
    "type": "object",
    "properties": {
        "caduta": {"type": "string", "enum": ["SI", "NO"]},
        "confidenza": {"type": "number"},
        "motivo": {"type": "string"},
    },
    "required": ["caduta", "confidenza", "motivo"],
    "additionalProperties": False,
}

ALLOWED_MODELS = {"claude-sonnet-5-5", "claude-haiku-5-5", "claude-opus-5-5"}
_client = None


def _anthropic():
    """One client per container: reuses the HTTPS connection (no new TLS handshake per request)."""
    global _client
    if _client is None:
        import anthropic
        _client = anthropic.Anthropic(max_retries=1, timeout=20)
    return _client


def analyze_with_claude(
    jpegs: list[bytes],
    duration_s: float = 0.0,
    model: str | None = None,
    frame_times: list[float] | None = None,
) -> dict:
    import base64, json
    n = len(jpegs)
    if frame_times is not None and len(frame_times) != n:
        raise ValueError("frame_times must contain one timestamp per frame")
    content = [{"type": "text", "text": VISION_PROMPT.format(n=n, durata=duration_s)}]
    for i, j in enumerate(jpegs):
        t = frame_times[i] if frame_times is not None else duration_s * i / (n - 1) if n > 1 else 0.0
        content.append({"type": "text", "text": f"t = {t:.1f} s"})
        content.append({"type": "image", "source": {"type": "base64", "media_type": "image/jpeg",
                                                     "data": base64.standard_b64encode(j).decode()}})
    msg = _anthropic().messages.create(
        model=model or CLAUDE_MODEL,
        max_tokens=150,                     # short JSON answer: fewer output tokens = lower latency
        messages=[{"role": "user", "content": content}],
        extra_body={"output_config": {"format": {"type": "json_schema", "schema": VISION_SCHEMA}}},
    )
    data = json.loads(next(b.text for b in msg.content if b.type == "text"))
    conf = float(max(0.0, min(1.0, float(data["confidenza"]))))
    fall = data["caduta"] == "SI"
    return {**FALLBACK, "caduta": data["caduta"], "on_ground": "yes" if fall else "no",
            "confidence": conf, "p_fall": round(conf if fall else 1 - conf, 4), "reason": data["motivo"],
            "input_tokens": msg.usage.input_tokens, "output_tokens": msg.usage.output_tokens}


def fuse(imu_level: int, vis: dict) -> int:
    """Vision can only RAISE the IMU level, never cancel an alarm."""
    v = 2 if vis.get("caduta") == "SI" and vis["confidence"] >= 0.7 else 0
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
    import asyncio, base64, time, uuid
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
        duration_s: float = Form(1.5),          # time span covered by the frames
        best_n: int = Form(7),
        x_api_key: str | None = Header(None),
    ):
        check_key(x_api_key)
        t0 = time.time()
        if not 1 <= len(frames) <= 7:
            raise HTTPException(400, "send 1-7 frames")
        if not 1 <= best_n <= 7:
            raise HTTPException(400, "best_n must be between 1 and 7")

        checked = []
        for index, f in enumerate(frames):
            img = _decode(await f.read())
            if img is None:
                continue
            q = quality(img)
            checked.append((index, q, img))
        usable = sorted(
            [c for c in checked if c[1]["usable"]], key=lambda c: -c[1]["sharpness"],
        )[:best_n]
        usable.sort(key=lambda c: c[0])

        jpegs, frame_times, n_faces = [], [], 0
        for index, _, img in usable:
            img, n = blur_faces(img)
            n_faces = -1 if n < 0 or n_faces < 0 else n_faces + n
            jpegs.append(to_jpeg(img))
            frame_times.append(duration_s * index / (len(frames) - 1) if len(frames) > 1 else 0.0)

        vision, error = dict(FALLBACK), None
        if jpegs:
            try:
                vision = await asyncio.to_thread(
                    analyze_with_claude, jpegs, duration_s, frame_times=frame_times,
                )
            except Exception as e:          # vision is optional: never block the alarm path
                error = f"{type(e).__name__}: {e}"
        vision["usable_frames"] = len(jpegs)

        eid = event_id or uuid.uuid4().hex[:12]
        event = {
            "event_id": eid, "created": time.time(), "imu_level": imu_level,
            "level": fuse(imu_level, vision), "vision": vision, "vision_error": error,
            "lat": lat, "lon": lon, "faces_blurred": n_faces,
            "quality": [c[1] for c in checked], "status": "awaiting_answer",
            "n_frames": len(frames), "best_n": best_n,
            "selected_frame_indices": [c[0] for c in usable],
            "selected_frame_times_s": frame_times,
            "frame_b64": base64.b64encode(jpegs[0]).decode() if jpegs else None,
            "processing_ms": int((time.time() - t0) * 1000),
        }
        await events.put.aio(eid, event)
        return {k: v for k, v in event.items() if k != "frame_b64"}

    @web.post("/classify")
    async def classify(
        images: list[UploadFile] = File(...),
        duration_s: float = Form(0.0),
        force: bool = Form(False),
        model: str | None = Form(None),
        x_api_key: str | None = Header(None),
    ):
        """Stateless evaluation (paper / tests): 1-8 frames of ONE clip, same pipeline as /analyze,
        nothing stored or notified. force=True skips the quality gate. model selects a Claude model."""
        check_key(x_api_key)
        t0 = time.time()
        if not 1 <= len(images) <= 8:
            raise HTTPException(400, "send 1-8 images")
        if model and model not in ALLOWED_MODELS:
            raise HTTPException(400, f"model must be one of {sorted(ALLOWED_MODELS)}")
        qs, jpegs, n_faces, h, w = [], [], 0, 0, 0
        for f in images:
            img = _decode(await f.read())
            if img is None:
                raise HTTPException(400, f"cannot decode {f.filename}")
            h, w = img.shape[:2]
            q = quality(img)
            qs.append(q)
            if q["usable"] or force:
                img, n = blur_faces(img)
                n_faces = -1 if n < 0 or n_faces < 0 else n_faces + n
                jpegs.append(to_jpeg(img))
        t_pre = int((time.time() - t0) * 1000)
        vision, error, t_llm = dict(FALLBACK), None, None
        if jpegs:
            t1 = time.time()
            try:
                vision = await asyncio.to_thread(analyze_with_claude, jpegs, duration_s, model)
            except Exception as e:
                error = f"{type(e).__name__}: {e}"
            t_llm = int((time.time() - t1) * 1000)
        vision.pop("usable_frames", None)
        return {
            "filename": images[0].filename, "n_frames": len(images), "frames_sent": len(jpegs),
            "model": model or CLAUDE_MODEL, "prompt_version": PROMPT_VERSION, "img_max_side": IMG_MAX_SIDE,
            "width": w, "height": h, "quality": qs[0] if len(qs) == 1 else qs, "sent_to_model": bool(jpegs),
            "faces_blurred": n_faces, "vision": vision, "error": error,
            "quality_thresholds": [Q_MIN_BRIGHT, Q_MIN_SHARP, Q_MIN_CONTRAST],
            "latency_preprocess_ms": t_pre, "latency_model_ms": t_llm,
            "latency_server_ms": int((time.time() - t0) * 1000),
        }

    class EventIn(BaseModel):
        imu_level: int = 1               # 0-3 from on-device model
        lat: float | None = None
        lon: float | None = None
        event_id: str | None = None
        fall_prob: float | None = None   # optional model score
        source: str | None = None        # e.g. "glasses", "neural_band"

    @web.post("/event")
    async def create_event(body: EventIn, x_api_key: str | None = Header(None)):
        """Metadata-only fall event: no images, camera stays off."""
        check_key(x_api_key)
        eid = body.event_id or uuid.uuid4().hex[:12]
        vision = {**FALLBACK, "reason": "Camera non usata."}
        level = int(max(0, min(3, body.imu_level)))
        event = {
            "event_id": eid, "created": time.time(), "imu_level": level, "level": level,
            "vision": vision, "vision_error": None, "lat": body.lat, "lon": body.lon,
            "fall_prob": body.fall_prob, "source": body.source, "faces_blurred": 0,
            "quality": [], "status": "awaiting_answer", "frame_b64": None, "processing_ms": 0,
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
            event["notified"] = await asyncio.to_thread(notify, event, base(request))
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
        event["notified"] = await asyncio.to_thread(notify, event, base(request))
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
<p><b>A terra (camera):</b> {v.get('caduta') or 'n/d'} &middot; <b>Confidenza:</b> {v['confidence']:.2f}</p>
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