// The five visible states of the right-lens UI, mirroring the server-side
// state machine in PROJECT_CONTEXT.md:
//
//   IDLE -> FALL_DETECTED -> CHECKING_IN -> ESCALATED -> ANALYSING -> ALERT_SENT
//                                                    -> CANCELLED
//
// From the wearer's point of view we collapse FALL_DETECTED and CHECKING_IN
// into one visible screen (the "are you okay?" check-in), and ESCALATED /
// ANALYSING into one "getting help" screen. The on-glass UI only needs to
// surface distinctions the wearer can act on.

export type LensState =
  | 'idle'
  | 'checking_in'
  | 'escalated'
  | 'alert_sent'
  | 'cancelled';

export const LENS_STATES: ReadonlyArray<{ id: LensState; label: string; blurb: string }> = [
  { id: 'idle',        label: 'IDLE',        blurb: 'Armed, nothing detected' },
  { id: 'checking_in', label: 'CHECKING_IN', blurb: 'Possible fall — asking the wearer' },
  { id: 'escalated',   label: 'ESCALATED',   blurb: 'Recording + analysing' },
  { id: 'alert_sent',  label: 'ALERT_SENT',  blurb: 'Contacts notified' },
  { id: 'cancelled',   label: 'CANCELLED',   blurb: 'False alarm or wearer okay' },
];
