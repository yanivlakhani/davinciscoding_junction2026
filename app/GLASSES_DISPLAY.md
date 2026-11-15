# Glasses event display

The iOS app renders native lens content using `MWDATDisplay` from the existing Meta DAT SDK. The visual reference is the repository's `glasses-ui` branch at commit `34e3cbe`. Its browser demo, preview controls, generated files and dependencies are not included in the app.

## States

| Design state | Real pipeline behavior |
| --- | --- |
| Idle | Blank during ordinary sensor monitoring, capture and visual analysis. |
| Checking in | Begins only after a fresh, positive server assessment. Shows the actual spoken question and listening state. |
| Escalated | Shows reply processing, pending follow-up or a failure; does not claim help is coming. |
| Alert sent | Shows email submission only when the server reports `submitted`. Submission does not prove inbox delivery. |
| Cancelled | Confirms the contact flow ended without sending an alert. |

Voice remains the input. Lens presentation cannot authorize an email or call. A call handoff explicitly says confirmation is needed on the iPhone; it never claims a call connected.

Result screens stay for 1.5 seconds after the SDK accepts the image. A following question waits for that hold to finish; otherwise the lens clears. A new event or disconnect supersedes the hold. Generation checks prevent an older timer from clearing a newer question. Display failures do not stop sensor processing.

The lens controller attaches to the existing device session and creates its display capability only when needed. It runs presentation independently from motion inference. Pausing stops presentation; disconnect releases its references. This adds no force-quit recovery guarantee.

## Assets

The hourglass, alert, check, shield and microphone SVGs come from the reference branch's `@wearables-ui-toolkit/icons` package. Original license and notice text are included in `LensIconNotices.dataset`. Rendering preserves the black background, colored icons and centered text while replacing demo text with actual pipeline status. No reference fonts or camera imagery are copied.

## Verification

Portable tests cover confirmation gating, question stages, listening deadlines, truthful email states and stale dismissal timers. The iOS build checks SDK integration and asset compilation.

On hardware, connect the Display glasses and use the Debug button **Test lens display · no voice or alert**. It requests an authenticated synthetic event and shows a TEST-marked screen without opening the microphone, sending an email or initiating a call. Confirm that it appears and clears after 1.5 seconds.

Then test the real voice flow: positive visual assessment, question, spoken reply, contact consent, server email result, separate call choice, and return to a blank lens. Check a negative assessment remains blank. Repeat with the phone backgrounded and locked. These hardware behaviors require physical confirmation; passing unit tests does not establish them.
