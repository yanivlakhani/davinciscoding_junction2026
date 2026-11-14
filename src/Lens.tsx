// The actual right-lens UI. This is what ships to the glasses.
// The whole thing is wrapped in the toolkit's <App>, which installs the
// theme tokens. Each state is one glanceable screen.

import { App, IconImage, TextView, TextStyle, TextColor } from '@wearables-ui-toolkit/mrbd';
import {
  shieldFilled,
  shieldCheckFilled,
  microphoneFilled,
  hourglassFilled,
  triangleAlertFilled,
  circleCheckFilled,
  heartActivityFilled,
  locationPinBadgeCheckFilled,
} from '@wearables-ui-toolkit/icons';

import type { LensState } from './stateMachine';
import './lens.css';

// Safety-signal colors. We override the theme here on purpose: these are
// functional accents (red = danger, green = success) that must survive theme
// changes or dark/light surroundings. The toolkit tints inline-SVG icons via
// CSS `color` on an ancestor, so a wrapping <span style={{ color }}> is the
// documented way to colour an IconImage.
const DANGER = '#FF3B30';     // iOS SF Red — high luminance on additive display
const SUCCESS = '#30D158';    // iOS SF Green
const WARNING = '#FFD60A';    // iOS SF Yellow
const SOFT_WHITE = '#F2F2F7';

function Tint({ color, children }: { color: string; children: React.ReactNode }) {
  return <span style={{ color, display: 'inline-flex' }}>{children}</span>;
}

// ---------------------------------------------------------------------------
// Individual state screens
// ---------------------------------------------------------------------------

function IdleScreen() {
  // Minimal corner indicator so the wearer knows safety mode is armed,
  // without putting a persistent panel in their field of view.
  return (
    <div className="lens-root lens-stack">
      <Tint color={SUCCESS}>
        <IconImage source={shieldFilled} style={{ width: 96, height: 96 }} />
      </Tint>
      <TextView textStyle={TextStyle.BODY1_EMPHASIZED}>
        Safety mode on
      </TextView>
    </div>
  );
}

function CheckingInScreen() {
  // Primary task: wearer confirms they're okay. Shown BIG because reading
  // under stress is hard. Hourglass + "cancel to cancel" and voice hint
  // provide two response channels; countdown ring communicates urgency.
  return (
    <div className="lens-root lens-stack">
      <Tint color={WARNING}>
        <div className="lens-icon-xl countdown-ring">
          <IconImage source={hourglassFilled} style={{ width: 120, height: 120 }} />
        </div>
      </Tint>
      <TextView textStyle={TextStyle.DISPLAY1} as="h1">
        Are you okay?
      </TextView>
      <div className="lens-row lens-hint">
        <Tint color={SOFT_WHITE}>
          <IconImage source={microphoneFilled} style={{ width: 28, height: 28 }} />
        </Tint>
        <TextView textStyle={TextStyle.BODY1} textColor={TextColor.SECONDARY}>
          Say "I'm fine"&nbsp;·&nbsp;or tap to cancel
        </TextView>
      </div>
    </div>
  );
}

function EscalatedScreen() {
  // The pitch's hazard moment. Big red triangle, short imperative copy.
  // Shape + colour + text all carry the "danger" signal, per Meta guidance
  // not to rely on colour alone (users may be colour-blind, or surroundings
  // may wash the signal out).
  return (
    <div className="lens-root lens-stack lens-alert">
      <Tint color={DANGER}>
        <div className="lens-icon-xl hazard-pulse">
          <IconImage source={triangleAlertFilled} style={{ width: 180, height: 180 }} />
        </div>
      </Tint>
      <TextView textStyle={TextStyle.DISPLAY1} as="h1">
        Getting help
      </TextView>
      <div className="lens-row lens-hint">
        <Tint color={DANGER}>
          <IconImage source={heartActivityFilled} style={{ width: 24, height: 24 }} />
        </Tint>
        <TextView textStyle={TextStyle.BODY1_EMPHASIZED}>
          Recording&nbsp;·&nbsp;Analysing
        </TextView>
      </div>
    </div>
  );
}

function AlertSentScreen() {
  // Payoff for the wearer. Who was notified + confirmation location went out.
  return (
    <div className="lens-root lens-stack">
      <Tint color={SUCCESS}>
        <IconImage source={circleCheckFilled} style={{ width: 160, height: 160 }} />
      </Tint>
      <TextView textStyle={TextStyle.DISPLAY1} as="h1">
        Help is coming
      </TextView>
      <div className="lens-rows">
        <div className="lens-row">
          <Tint color={SOFT_WHITE}>
            <IconImage source={shieldCheckFilled} style={{ width: 22, height: 22 }} />
          </Tint>
          <TextView textStyle={TextStyle.BODY1}>Mum&nbsp;·&nbsp;Elena notified</TextView>
        </div>
        <div className="lens-row">
          <Tint color={SOFT_WHITE}>
            <IconImage source={locationPinBadgeCheckFilled} style={{ width: 22, height: 22 }} />
          </Tint>
          <TextView textStyle={TextStyle.BODY1} textColor={TextColor.SECONDARY}>
            Location sent
          </TextView>
        </div>
      </div>
    </div>
  );
}

function CancelledScreen() {
  return (
    <div className="lens-root lens-stack">
      <Tint color={SUCCESS}>
        <IconImage source={shieldCheckFilled} style={{ width: 150, height: 150 }} />
      </Tint>
      <TextView textStyle={TextStyle.DISPLAY1} as="h1">
        Glad you're okay
      </TextView>
      <TextView textStyle={TextStyle.BODY1} textColor={TextColor.SECONDARY}>
        Safety mode re-arming
      </TextView>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Lens entry point
// ---------------------------------------------------------------------------

export function Lens({ state }: { state: LensState }) {
  return (
    <App className="lens-app">
      {state === 'idle' && <IdleScreen />}
      {state === 'checking_in' && <CheckingInScreen />}
      {state === 'escalated' && <EscalatedScreen />}
      {state === 'alert_sent' && <AlertSentScreen />}
      {state === 'cancelled' && <CancelledScreen />}
    </App>
  );
}
