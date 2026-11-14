"""Real HTTP routes; Modal, image processing and provider calls are offline fixtures."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import sys
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import patch
from fastapi.testclient import TestClient


class CheckInTests(unittest.TestCase):
    def setUp(self):
        self.environment = patch.dict(os.environ, {"API_KEY": "test-only-key"})
        self.environment.start(); self.addCleanup(self.environment.stop)
        self.events, self.calls, self.email_deliveries = {}, [], {}

        async def put(key, value):
            self.events[key] = json.loads(json.dumps(value))

        async def get(key):
            value = self.events.get(key)
            return json.loads(json.dumps(value)) if value else None

        class Image:
            @classmethod
            def debian_slim(cls, **kwargs): return cls()
            def uv_pip_install(self, *args): return self

        class App:
            def __init__(self, *args): pass
            def function(self, **kwargs): return lambda f: f

        modal = ModuleType("modal")
        modal.App, modal.Image = App, Image
        def dictionary(name, **kwargs):
            if name == "fall-events":
                return SimpleNamespace(put=SimpleNamespace(aio=put), get=SimpleNamespace(aio=get))
            async def put_delivery(key, value, skip_if_exists=False):
                if skip_if_exists and key in self.email_deliveries:
                    return False
                self.email_deliveries[key] = json.loads(json.dumps(value))
                return True
            async def get_delivery(key):
                return self.email_deliveries.get(key)
            return SimpleNamespace(put=SimpleNamespace(aio=put_delivery), get=SimpleNamespace(aio=get_delivery))
        modal.Dict = SimpleNamespace(from_name=dictionary)
        modal.Secret = SimpleNamespace(from_name=lambda *a: None)
        modal.concurrent = modal.asgi_app = lambda **k: lambda f: f
        modules = patch.dict(sys.modules, {"modal": modal})
        modules.start(); self.addCleanup(modules.stop)
        source = Path(__file__).resolve().parents[1] / "fall_server.py"
        spec = importlib.util.spec_from_file_location("check_in_backend_fixture", source)
        self.backend = importlib.util.module_from_spec(spec); spec.loader.exec_module(self.backend)
        self.fail_provider = False
        self.vision_verdict = "SI"
        self.answer_status = "needs_help"
        self.consent_decision = "yes"

        def provider(**kwargs):
            self.calls.append(kwargs)
            if self.fail_provider: raise TimeoutError("offline fixture")
            value = ({"decision": self.consent_decision} if "decision" in kwargs["extra_body"]["output_config"]["format"]["schema"]["properties"] else
                {"answer_status": self.answer_status, "summary": "Reports arm pain", "confidence": 0.9}
                if "system" in kwargs else {"caduta": self.vision_verdict, "confidenza": 0.9, "motivo": "Fixture"})
            return SimpleNamespace(content=[SimpleNamespace(type="text", text=json.dumps(value))],
                usage=SimpleNamespace(input_tokens=1, output_tokens=1))

        self.backend._anthropic = lambda: SimpleNamespace(messages=SimpleNamespace(create=provider))
        self.backend._decode = lambda data: data[0]
        self.backend.quality = lambda image: {"usable": True, "sharpness": image}
        self.backend.blur_faces = lambda image: (image, 0)
        self.backend.to_jpeg = lambda image: bytes([image])
        self.backend.notify = lambda *args: self.fail("New check-in must never notify")
        self.client = TestClient(self.backend.build_web_app())
        self.addCleanup(self.client.close)
        self.headers = {"x-api-key": "test-only-key"}
        self.events["event-1"] = {"event_id": "event-1", "vision": {"caduta": "SI"},
            "vision_error": None, "status": "awaiting_answer", "level": 1}

    def post(self, **kwargs):
        body = {"event_id": "event-1", "outcome": "response", "transcript": "Yes, but my arm hurts", "language": "en"}
        body.update(kwargs)
        return self.client.post("/event/event-1/check-in", headers=self.headers, json=body)

    def test_full_reply_sent_to_llm_and_asks_for_contact_consent(self):
        response = self.post()
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["analysis"]["answer_status"], "needs_help")
        self.assertEqual(response.json()["next_action"], "ask_contact")
        payload = json.loads(self.calls[0]["messages"][0]["content"])
        self.assertEqual(payload["transcript"], "Yes, but my arm hurts")
        self.assertEqual(self.events["event-1"]["status"], "check_in_ask_contact")
        self.assertEqual(self.events["event-1"]["level"], 1)

    def test_legacy_silence_without_two_listening_windows_requires_manual_review(self):
        response = self.post(outcome="no_response", transcript=None)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["status"], "no_response")
        self.assertIsNone(response.json()["analysis"])
        self.assertEqual(self.calls, [])
        self.assertEqual(self.events["event-1"]["status"], "check_in_manual_review")

    def test_duplicate_transcript_returns_same_analysis(self):
        first, second = self.post(), self.post()
        self.assertEqual(first.json(), second.json())
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.post(transcript="Changed reply").status_code, 409)

    def test_provider_failure_retains_transcript_for_retry(self):
        self.fail_provider = True
        self.assertEqual(self.post().status_code, 503)
        self.assertEqual(self.events["event-1"]["check_in"]["transcript"], "Yes, but my arm hurts")
        self.assertEqual(self.events["event-1"]["check_in"]["status"], "analysis_pending")
        self.fail_provider = False
        self.assertEqual(self.post().json()["status"], "analyzed")

    def test_invalid_llm_output_is_not_a_completed_check_in(self):
        bad = SimpleNamespace(content=[SimpleNamespace(type="text", text=json.dumps({
            "answer_status": "fine", "summary": "Fixture", "confidence": 2}))])
        self.backend._anthropic = lambda: SimpleNamespace(messages=SimpleNamespace(create=lambda **k: bad))
        self.assertEqual(self.post().status_code, 503)
        self.assertEqual(self.events["event-1"]["check_in"]["status"], "analysis_pending")

    def test_no_or_unknown_fall_never_starts_check_in_analysis(self):
        for value in ["NO", None]:
            self.events["event-1"]["vision"]["caduta"] = value
            self.assertEqual(self.post().status_code, 409)
        self.assertEqual(self.calls, [])

    def test_invalid_empty_or_conflicting_silence_payload_is_rejected(self):
        self.assertEqual(self.post(transcript=" ").status_code, 422)
        self.assertEqual(self.post(outcome="no_response").status_code, 422)
        self.assertEqual(self.post(event_id="other").status_code, 422)
        self.assertEqual(self.post(transcript="a" * 4001).status_code, 422)

    def test_endpoints_require_existing_api_key(self):
        self.assertEqual(self.client.get("/check-in/prompt").status_code, 401)
        self.assertEqual(self.client.post("/event/event-1/check-in", json={
            "event_id": "event-1", "outcome": "no_response"}).status_code, 401)
        with patch.dict(os.environ, {"API_KEY": ""}):
            self.assertEqual(self.client.get("/check-in/prompt", headers=self.headers).status_code, 503)

    def test_elevenlabs_question_returns_audio_and_configuration_failure_is_explicit(self):
        self.backend.check_in_audio = lambda language: b"offline-audio-fixture"
        response = self.client.get("/check-in/prompt?language=en", headers=self.headers)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.headers["content-type"], "audio/mpeg")
        self.assertEqual(self.client.get("/check-in/prompt?language=xx", headers=self.headers).status_code, 422)
        def failed(language): raise RuntimeError("Not configured")
        self.backend.check_in_audio = failed
        self.assertEqual(self.client.get("/check-in/prompt", headers=self.headers).status_code, 503)

    def test_seven_frames_still_reach_one_vision_request_in_order(self):
        response = self.client.post("/analyze", headers=self.headers,
            data={"event_id": "new-event", "duration_s": "1", "imu_level": "1"},
            files=[("frames", (f"{i}.jpg", bytes([i + 1]), "image/jpeg")) for i in range(7)])
        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(self.calls), 1)
        content = self.calls[0]["messages"][0]["content"]
        markers = [base64.b64decode(x["source"]["data"])[0] for x in content if x["type"] == "image"]
        self.assertEqual(markers, list(range(1, 8)))

    def test_negative_visual_result_closes_event_and_unavailable_is_not_false(self):
        def analyze():
            return self.client.post("/analyze", headers=self.headers, data={"event_id": "visual-result"},
                files=[("frames", ("frame.jpg", bytes([1]), "image/jpeg"))]).json()
        self.vision_verdict = "NO"
        response = analyze()
        self.assertIs(response["fall_detected"], False)
        self.assertEqual(response["status"], "no_fall")
        self.fail_provider = True
        response = analyze()
        self.assertIsNone(response["fall_detected"])
        self.assertEqual(response["status"], "analysis_unavailable")


if __name__ == "__main__": unittest.main()
