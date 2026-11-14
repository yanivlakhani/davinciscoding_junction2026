// Dev-only harness so we can see every lens state side-by-side before
// pointing the glasses at this URL. The glasses runtime will mount <Lens />
// directly instead of this wrapper.

import { useEffect, useState } from 'react';
import { Lens } from './Lens';
import { LENS_STATES, type LensState } from './stateMachine';

function readInitialState(): LensState {
  if (typeof window === 'undefined') return 'idle';
  const q = new URLSearchParams(window.location.search).get('state') as LensState | null;
  return q && LENS_STATES.some((s) => s.id === q) ? q : 'idle';
}

function isGlassesMode(): boolean {
  if (typeof window === 'undefined') return false;
  const mode = new URLSearchParams(window.location.search).get('mode');
  if (mode === 'glasses') return true;
  if (mode === 'preview') return false;
  // Default: production builds (the ones that ship to the glasses via a
  // hosted HTTPS URL) skip the dev picker. Local `npm run dev` still shows
  // the full preview harness. Override either way with ?mode=glasses or
  // ?mode=preview.
  return import.meta.env.PROD;
}

function demoIntervalMs(): number | null {
  if (typeof window === 'undefined') return null;
  const demo = new URLSearchParams(window.location.search).get('demo');
  if (demo === null) return null;
  const seconds = Number(demo);
  return (Number.isFinite(seconds) && seconds > 0 ? seconds : 4) * 1000;
}

export function Preview() {
  const [state, setState] = useState<LensState>(readInitialState);
  const current = LENS_STATES.find((s) => s.id === state)!;
  const glasses = isGlassesMode();

  const step = (delta: number) =>
    setState((prev) => {
      const i = LENS_STATES.findIndex((s) => s.id === prev);
      return LENS_STATES[(i + delta + LENS_STATES.length) % LENS_STATES.length].id;
    });

  useEffect(() => {
    const ms = glasses ? demoIntervalMs() : null;
    if (ms === null) return;
    const id = window.setInterval(() => step(1), ms);
    return () => window.clearInterval(id);
  }, [glasses]);

  // Glasses mode: strip the dev chrome and let the Lens fill the viewport,
  // so the Meta Ray-Ban Display Simulator Chrome extension can overlay its
  // 600×600 additive-light frame directly on it. On device there is no
  // keyboard: the whole lens is one button, so a Neural Band pinch / tap
  // advances the state. Arrow keys still work in the simulator, `?state=`
  // deep-links, and `?demo` (or `?demo=6`) auto-cycles every N seconds.
  if (glasses) {
    return (
      <button
        type="button"
        aria-label={`Lens state ${current.label}. Activate for next state.`}
        style={{
          position: 'fixed',
          inset: 0,
          width: '100%',
          height: '100%',
          margin: 0,
          padding: 0,
          border: 'none',
          background: '#000',
          overflow: 'hidden',
          cursor: 'pointer',
          outline: 'none',
        }}
        onClick={() => step(1)}
        onKeyDown={(e) => {
          if (e.key === 'ArrowRight' || e.key === 'ArrowDown') {
            e.preventDefault();
            step(1);
          } else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') {
            e.preventDefault();
            step(-1);
          }
        }}
        ref={(el) => el?.focus()}
      >
        <Lens state={state} />
      </button>
    );
  }

  return (
    <div className="preview">
      <header className="preview-header">
        <div>
          <h1>AI Safety Glasses · Right-lens preview</h1>
          <p>
            Each screen inside the 600×600 frame is what the wearer sees in
            their right eye. Additive-light display: black is transparent, so
            on the real device everything you see here floats over the world.
          </p>
        </div>
      </header>

      <div className="preview-body">
        <div className="preview-lens-column">
          <div className="lens-frame">
            {/* The 600×600 frame is only a validation scaffold. Lens itself
                lays out responsively. */}
            <div className="lens-canvas">
              <Lens state={state} />
            </div>
          </div>
          <div className="lens-caption">
            <span className="lens-caption-dim">State</span>
            <span className="lens-caption-strong">{current.label}</span>
            <span className="lens-caption-dim">· {current.blurb}</span>
          </div>
        </div>

        <aside className="state-picker">
          <div className="state-picker-label">Switch state</div>
          {LENS_STATES.map((s) => (
            <button
              key={s.id}
              className={'state-picker-btn' + (s.id === state ? ' is-active' : '')}
              onClick={() => setState(s.id)}
            >
              <span className="state-picker-btn-code">{s.label}</span>
              <span className="state-picker-btn-blurb">{s.blurb}</span>
            </button>
          ))}

          <div className="preview-notes">
            <h3>Design notes</h3>
            <ul>
              <li>No full-screen backgrounds — black = transparent on device.</li>
              <li>Signal via shape + text + colour, not colour alone.</li>
              <li>DISPLAY1 text for primary message, BODY1 for support.</li>
              <li>Controls kept inside a 10% safe margin.</li>
            </ul>
          </div>
        </aside>
      </div>
    </div>
  );
}
