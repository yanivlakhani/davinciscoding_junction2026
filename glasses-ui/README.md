# glasses-ui

Right-lens UI for the AI Safety Glasses project (Junction 2026 — Meta AI glasses track).

Built on Meta's official Ray-Ban Display web toolkit (`@wearables-ui-toolkit/mrbd` / `foundation` / `icons`). It's a React 19 + Vite app that we iterate on in Chrome and later deploy to the glasses by URL.

## The five states

The UI mirrors the server-side escalation state machine:

| State         | What the wearer sees                                                  |
|---------------|-----------------------------------------------------------------------|
| `IDLE`        | Faint shield icon in a corner — safety mode armed, nothing detected   |
| `CHECKING_IN` | "Are you okay?" + hourglass with 15 s countdown ring, tap/voice to cancel |
| `ESCALATED`   | Red hazard triangle + "Getting help · Recording · Analysing"          |
| `ALERT_SENT`  | Green tick + "Help is coming" + contacts named + location confirmed   |
| `CANCELLED`   | Shield-check + "Glad you're okay" — safety mode re-arms               |

Screenshots in [`previews/`](./previews/).

## Run locally

```bash
cd glasses-ui
npm install
npm run dev
# open http://127.0.0.1:5173
```

Deep-link to any state with `?state=...`:

```
http://127.0.0.1:5173/?state=escalated
http://127.0.0.1:5173/?state=alert_sent
```

## Deploy to the glasses

Meta Ray-Ban Display loads web apps by URL through the paired phone. Build and serve the Vite output anywhere static:

```bash
npm run build
npm run preview        # local static server
# or: deploy ./dist to Vercel / Netlify / GitHub Pages / etc.
```

Then point the glasses at the URL from the Meta Wearables app.

## What's where

| File | Purpose |
|------|---------|
| `src/Lens.tsx` | The UI that ships to the glasses. One React component per state. |
| `src/lens.css` | In-lens layout + countdown-ring + hazard-pulse animations. |
| `src/stateMachine.ts` | The five visible states + their blurbs. The backend drives these. |
| `src/Preview.tsx` + `preview.css` | Dev-only harness with a state picker. **Not shipped to glasses.** |
| `src/main.tsx` | Mount point; imports the toolkit stylesheets. |
| `previews/*.png` | Screenshots of each state for quick visual reference. |

## Design notes

Meta Ray-Ban Display is an **additive-light** display: pure black is transparent, bright colours are visible. So:

- No full-screen bright backgrounds — only the UI itself glows.
- Signal via **shape + text + colour**, not colour alone (per Meta's accessibility guidelines).
- `DISPLAY1` for the primary message; `BODY1` / `LABEL` for support.
- Controls kept inside a 10 % safe margin from the edge (device shows focus feedback at the edges).
- 600 × 600 is a validation target, not a hard size — layout is responsive.

## Driving it from the backend

The lens component is purely controlled:

```tsx
<Lens state={currentState} />
```

Where `currentState: LensState` comes from the backend state machine. There is no input handling on the glasses side yet — tap-to-cancel will use the touchpad input API from `@wearables-ui-toolkit/foundation` once hooked up.

## Test on a simulated Meta Ray-Ban Display

Meta ships an official Chrome extension that recreates the 600×600 additive-light display frame, D-pad input, environment backgrounds, and a "View on Glasses" QR code for loading the app onto real glasses.

1. Install the [Meta Ray-Ban Display Simulator](https://chromewebstore.google.com/detail/meta-ray-ban-display-simu/jpjlmmodokemlepklkdbimceggpbjcll) from the Chrome Web Store.
2. Run `npm run dev` (fast dev loop) or `npm run build && npm run preview` (production-fidelity).
3. Open the app in Chrome in **glasses mode** — this hides the dev picker so the simulator only sees the Lens:

   ```
   http://127.0.0.1:5173/?mode=glasses
   http://127.0.0.1:5173/?mode=glasses&state=escalated
   ```
4. Click the extension icon in the Chrome toolbar to enable the simulator.
5. Use arrow keys (or on-screen D-pad) to step through states: ← / → cycle backwards and forwards.

The simulator supports additive blending, environment backgrounds (built-in scenes, custom images, or live webcam), brightness controls, and a viewport recorder for demo clips.

### Load on real glasses

For on-device testing you need:
- Developer Mode enabled in the Meta AI app (App Settings → Apps → Web Apps).
- The app served from a publicly accessible **HTTPS** URL (localhost will not load on the glasses). Options: Vercel, Netlify, GitHub Pages, or an ngrok tunnel for ad-hoc tests.
- The simulator's "View on Glasses" QR feature turns the current URL into a one-tap add on the paired phone.
