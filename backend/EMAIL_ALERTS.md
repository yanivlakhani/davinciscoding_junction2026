# Gmail alerts for the POC

Modal can submit an email through an existing Gmail account. Sender and recipient
may be the same account. This requires no Apple Critical Messaging entitlement
or separate transactional email subscription. Gmail limits, spam filtering and
the recipient's mail notification settings still apply.

## Configuration

1. Enable Google two-step verification and create an
   [app password](https://support.google.com/accounts/answer/185833).
   Some organizational or protected Google accounts do not offer app passwords.
2. In the Modal dashboard, create a Custom secret named `email-sending` in the
   same workspace/environment as the backend, and add the entries below.
   Leave the existing `fall-secrets` API, Anthropic and ElevenLabs values intact.

   | Key | Value |
   | --- | --- |
   | `NOTIFY_CHANNEL` | `email` |
   | `ALERT_EMAIL_FROM` | Sender's Gmail address |
   | `ALERT_EMAIL_TO` | One test recipient email address; may equal sender |
   | `ALERT_EMAIL_APP_PASSWORD` | Google app password, never the account password |
   | `ALERT_PERSON_NAME` | Wearer's name; optional, defaults to “The wearer” |

3. Save `email-sending`, then deploy from the repository root:
   `modal deploy backend/fall_server.py`. The backend attaches `email-sending`
   alongside `fall-secrets` and `elevenlabs-voice`; all three secrets must exist.
4. Check `/health`: `email_configured` should be `true`. This only checks presence
   and format; it does not sign in to Google or send a test email.

Addresses and credentials belong in private configuration, never source control,
phone code, terminal command arguments or chat. The sender connects to
`smtp.gmail.com:465` using certificate-verified TLS and an app password.

## Integration and verification

The existing authenticated `/event/{id}/alarm` route and non-`fine` legacy
`/event/{id}/answer` route use the selected email channel. With `NOTIFY_CHANNEL=email`,
missing/invalid email configuration fails closed without falling back to a webhook.
The `/check-in` voice flow also sends email after explicit contact consent or two
healthy unanswered questions. It confirms a refusal from a user who reports being
fine, and asks separately before requesting a phone-call handoff. See the
[staged conversation contract](../app/contracts/CHECK_IN.md).

The plain-text email contains “Emergency Needed”, the wearer's configured name,
the event ID, alert time in UTC, visual assessment, full available reply, analysis
summary and a map link when valid coordinates were supplied with that event.
It sends no images or unauthenticated event-page link. Missing location is
explicitly marked unavailable; the phone supplies an optional recent measured
fix with timestamp/accuracy after the user enables location permission.
Silence does not establish unconsciousness.

After an authorized controlled test, inspect `notification` in the authenticated
event response or the existing alarm response:

| Status | Meaning |
| --- | --- |
| `not_configured` | Missing/invalid email settings; no SMTP request made |
| `sending` | A request claimed this event; completion not yet recorded |
| `submitted` | Gmail accepted SMTP submission; inbox delivery/read status unknown |
| `failed` | Connection/authentication failed or SMTP explicitly rejected submission |
| `delivery_unknown` | Connection lost during submission; it may have been accepted |

`notified=true` means `submitted`, never human acknowledgment or dispatched help.
Modal logs contain only event ID, channel and status/reason, not addresses,
transcripts or credentials. A duplicate alarm reuses the stored receipt instead
of sending another email. Atomic Modal Dict claims cover concurrent containers;
after a claimed attempt, failed/unknown sends are not automatically retried to
avoid duplicate mail. A crashed `sending` attempt needs manual investigation.
Missing configuration does not consume a claim and can be corrected and retried.
Claims use Modal Dict retention (entries expire after seven inactive days).

Legacy webhooks remain available when the email channel is not selected.

## Offline tests

```sh
pip install -r backend/requirements-test.txt
python -m unittest discover -s backend/tests -v
```

All SMTP/Modal/provider calls are fixtures; running the tests sends no email.
Live Gmail authentication, Modal egress and inbox receipt must still be tested
after configuring the app password and deploying.
