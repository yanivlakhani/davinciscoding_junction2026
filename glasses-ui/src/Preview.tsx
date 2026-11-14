// Dev-only harness so we can see every lens state side-by-side before
// pointing the glasses at this URL. The glasses runtime will mount <Lens />
// directly instead of this wrapper.

import { useState } from 'react';
import { Lens } from './Lens';
import { LENS_STATES, type LensState } from './stateMachine';

function readInitialState(): LensState {
  if (typeof window === 'undefined') return 'idle';
  const q = new URLSearchParams(window.location.search).get('state') as LensState | null;
  return q && LENS_STATES.some((s) => s.id === q) ? q : 'idle';
}

export function Preview() {
  const [state, setState] = useState<LensState>(readInitialState);
  const current = LENS_STATES.find((s) => s.id === state)!;

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
