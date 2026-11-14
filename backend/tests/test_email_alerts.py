"""SMTP is mocked: these tests never send email or disclose real credentials."""
import os
import smtplib
import unittest
from unittest.mock import patch
import test_check_in as fixtures


class EmailAlertTests(unittest.TestCase):
    setUp = fixtures.CheckInTests.setUp

    def configure(self):
        environment = patch.dict(os.environ, {
            "NOTIFY_CHANNEL": "email", "ALERT_EMAIL_FROM": "sender@gmail.com",
            "ALERT_EMAIL_TO": "recipient@example.com", "ALERT_EMAIL_APP_PASSWORD": "test-only-password",
            "ALERT_PERSON_NAME": "POC Wearer",
        })
        environment.start(); self.addCleanup(environment.stop)
        smtp = patch("smtplib.SMTP_SSL")
        self.smtp = smtp.start(); self.addCleanup(smtp.stop)
        self.smtp.return_value.send_message.return_value = {}

    def alarm(self):
        return self.client.post("/event/event-1/alarm", headers=self.headers)

    def turn(self, stage="initial", transcript="No, I injured my leg", **extra):
        return self.client.post("/event/event-1/check-in", headers=self.headers, json={
            "event_id": "event-1", "stage": stage, "outcome": "response" if transcript is not None else "no_response",
            "transcript": transcript, "language": "en", **extra})

    def test_injury_email_yes_then_call_no_sends_exactly_one_email(self):
        self.configure()
        self.assertEqual(self.turn().json()["next_action"], "ask_contact")
        self.smtp.assert_not_called()
        result = self.turn("contact", "Yes, please email them").json()
        self.assertEqual(result["next_action"], "ask_call")
        self.assertEqual(result["notification"]["status"], "submitted")
        self.consent_decision = "no"
        result = self.turn("call", "No, don't call").json()
        self.assertEqual(result["next_action"], "done")
        self.assertFalse(self.events["event-1"]["call_requested"])
        self.smtp.return_value.send_message.assert_called_once()
        body = self.smtp.return_value.send_message.call_args.args[0].get_content()
        self.assertIn("No, I injured my leg", body)

    def test_injury_email_yes_then_call_yes_requests_phone_handoff_only(self):
        self.configure()
        self.turn()
        self.turn("contact", "Yes")
        result = self.turn("call", "Yes").json()
        self.assertEqual(result["next_action"], "phone_call_handoff")
        self.assertTrue(self.events["event-1"]["call_requested"])
        self.assertNotIn("call_connected", self.events["event-1"])
        self.smtp.return_value.send_message.assert_called_once()

    def test_fine_then_yes_to_not_contacting_cancels_email(self):
        self.configure()
        self.answer_status = "fine"
        self.assertEqual(self.turn(transcript="I'm okay, no help needed").json()["next_action"], "ask_decline")
        self.assertEqual(self.turn("decline", "Yes, I'm sure").json()["next_action"], "done")
        self.smtp.assert_not_called()

    def test_clear_email_refusal_does_not_contact(self):
        self.configure()
        self.turn()
        self.consent_decision = "no"
        self.assertEqual(self.turn("contact", "No, don't email").json()["next_action"], "done")
        self.smtp.assert_not_called()

    def test_two_healthy_unanswered_questions_email_without_claiming_unconsciousness(self):
        self.configure()
        result = self.turn(transcript=None, unanswered_prompts=2).json()
        self.assertEqual(result["next_action"], "done")
        self.assertEqual(result["notification"]["status"], "submitted")
        self.assertEqual(self.calls, [])
        self.smtp.return_value.send_message.assert_called_once()
        self.assertIn("Consciousness is unknown", self.smtp.return_value.send_message.call_args.args[0].get_content())

    def test_silence_to_contact_question_keeps_earlier_injury_report(self):
        self.configure()
        self.turn()
        result = self.turn("contact", None, unanswered_prompts=2).json()
        self.assertEqual(result["notification"]["status"], "submitted")
        message = self.smtp.return_value.send_message.call_args.args[0].get_content()
        self.assertIn("No, I injured my leg", message)
        self.assertIn("Consciousness is unknown", message)

    def test_ambiguous_consent_reasks_once_then_requires_manual_review(self):
        self.configure()
        self.turn()
        self.consent_decision = "uncertain"
        self.assertEqual(self.turn("contact", "Maybe").json()["next_action"], "ask_contact_again")
        self.assertEqual(self.turn("contact_retry", "I don't know").json()["next_action"], "manual_review")
        self.smtp.assert_not_called()

    def test_call_and_contact_cannot_skip_prior_conversation_stages(self):
        self.configure()
        for stage in ["contact", "decline", "call", "contact_retry"]:
            self.assertEqual(self.turn(stage, "Yes").status_code, 409)
        self.smtp.assert_not_called()

    def test_phone_location_and_person_name_reach_email(self):
        import time
        self.configure()
        location = {"latitude": 60.1, "longitude": 24.9, "accuracy": 40, "captured_at": time.time()}
        self.assertEqual(self.turn(person_name="Test Person", location=location).status_code, 200)
        self.turn("contact", "Yes")
        email = self.smtp.return_value.send_message.call_args.args[0]
        self.assertEqual(email["Subject"], "Emergency Needed — Test Person")
        self.assertIn("https://maps.google.com/?q=60.1,24.9", email.get_content())
        self.assertIn("40.0", email.get_content())

    def test_invalid_or_stale_location_never_masquerades_as_current(self):
        import time
        self.configure()
        for latitude, timestamp in [(95, time.time()), (60, time.time() - 1000)]:
            response = self.turn(location={"latitude": latitude, "longitude": 24, "accuracy": 10, "captured_at": timestamp})
            self.assertEqual(response.status_code, 422)
        self.smtp.assert_not_called()

    def test_old_silence_result_does_not_send_a_stale_alert(self):
        import time
        self.configure()
        self.events["event-1"]["created"] = time.time() - 360
        self.assertEqual(self.turn(transcript=None, unanswered_prompts=2).json()["next_action"], "expired")
        self.smtp.assert_not_called()

    def test_silence_in_an_active_conversation_uses_recent_step_not_old_fall_time(self):
        import time
        self.configure()
        self.turn()
        self.events["event-1"]["created"] = time.time() - 600
        self.assertEqual(self.turn("contact", None, unanswered_prompts=2).json()["notification"]["status"], "submitted")

    def test_delayed_consent_silence_does_not_send_after_abandoned_conversation(self):
        import time
        self.configure()
        self.turn()
        self.events["event-1"]["check_in_updated_at"] = time.time() - 600
        self.assertEqual(self.turn("contact", None, unanswered_prompts=2).json()["next_action"], "expired")
        self.smtp.assert_not_called()

    def test_replayed_consent_uses_same_email_receipt(self):
        self.configure()
        self.turn()
        first = self.turn("contact", "Yes").json()
        second = self.turn("contact", "Yes").json()
        self.assertEqual(first, second)
        self.assertEqual(self.turn("contact", "No").status_code, 409)
        self.smtp.return_value.send_message.assert_called_once()

    def test_gmail_submission_includes_reply_location_and_truthful_receipt(self):
        self.configure()
        self.events["event-1"].update(lat=60.1, lon=24.9, check_in={
            "transcript": "My arm hurts", "analysis": {"summary": "Reports arm pain"}})
        response = self.alarm()
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["notification"]["status"], "submitted")
        self.assertTrue(response.json()["notified"])
        args = self.smtp.call_args
        self.assertEqual(args.args, ("smtp.gmail.com", 465))
        self.assertTrue(args.kwargs["context"].check_hostname)
        message = self.smtp.return_value.send_message.call_args.args[0]
        self.assertEqual(message["To"], "recipient@example.com")
        self.assertEqual(message["Subject"], "Emergency Needed — POC Wearer")
        self.assertIn("My arm hurts", message.get_content())
        self.assertIn("https://maps.google.com/?q=60.1,24.9", message.get_content())

    def test_repeated_alarm_sends_only_once(self):
        self.configure()
        self.assertEqual(self.alarm().json()["notification"]["status"], "submitted")
        self.assertEqual(self.alarm().json()["notification"]["status"], "submitted")
        self.smtp.return_value.send_message.assert_called_once()

    def test_cross_container_claim_prevents_replay_when_send_is_in_progress(self):
        self.configure()
        self.email_deliveries["event-1"] = {"channel": "email", "status": "sending"}
        response = self.alarm().json()
        self.assertFalse(response["notified"])
        self.assertEqual(response["notification"]["status"], "sending")
        self.smtp.assert_not_called()

    def test_missing_password_can_be_configured_then_retried_without_consuming_claim(self):
        self.configure()
        with patch.dict(os.environ, {"ALERT_EMAIL_APP_PASSWORD": ""}):
            response = self.alarm().json()
        self.assertEqual(response["notification"]["status"], "not_configured")
        self.assertEqual(self.email_deliveries, {})
        self.smtp.assert_not_called()
        self.assertEqual(self.alarm().json()["notification"]["status"], "submitted")

    def test_header_injection_or_multiple_recipients_fail_closed(self):
        self.configure()
        for bad in ["recipient@example.com\nBcc: other@example.com", "one@example.com,two@example.com"]:
            with patch.dict(os.environ, {"ALERT_EMAIL_TO": bad}):
                self.assertEqual(self.alarm().json()["notification"]["status"], "not_configured")
        self.smtp.assert_not_called()

    def test_timeout_after_send_is_unknown_and_never_automatically_resent(self):
        self.configure()
        self.smtp.return_value.send_message.side_effect = TimeoutError("private provider detail")
        first, second = self.alarm().json(), self.alarm().json()
        self.assertEqual(first["notification"]["status"], "delivery_unknown")
        self.assertFalse(first["notified"])
        self.assertEqual(first["notification"], second["notification"])
        self.smtp.return_value.send_message.assert_called_once()

    def test_auth_failure_is_failed_and_not_falsely_submitted(self):
        self.configure()
        self.smtp.return_value.login.side_effect = smtplib.SMTPAuthenticationError(535, b"private")
        response = self.alarm().json()
        self.assertEqual(response["notification"]["status"], "failed")
        self.assertFalse(response["notified"])
        self.smtp.return_value.send_message.assert_not_called()

    def test_quit_failure_does_not_hide_successful_submission(self):
        self.configure()
        self.smtp.return_value.quit.side_effect = smtplib.SMTPServerDisconnected("closed")
        self.assertEqual(self.alarm().json()["notification"]["status"], "submitted")

    def test_silence_does_not_assert_unconsciousness_or_invent_location(self):
        self.configure()
        self.events["event-1"].update(answer="silence", lat=float("nan"), lon=24)
        self.alarm()
        text = self.smtp.return_value.send_message.call_args.args[0].get_content()
        self.assertIn("Consciousness is unknown", text)
        self.assertIn("Location supplied with event: Unavailable", text)
        self.assertNotIn("is unconscious", text)

    def test_health_reports_configuration_without_exposing_addresses_or_password(self):
        self.configure()
        response = self.client.get("/health")
        self.assertTrue(response.json()["email_configured"])
        self.assertNotIn("sender@gmail.com", response.text)
        self.assertNotIn("test-only-password", response.text)

    def test_unauthenticated_alarm_never_sends(self):
        self.configure()
        self.assertEqual(self.client.post("/event/event-1/alarm").status_code, 401)
        self.smtp.assert_not_called()
