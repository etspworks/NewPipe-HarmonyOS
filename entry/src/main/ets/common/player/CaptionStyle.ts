/*
 * svc_caption_style - what a subtitle cue is drawn with.
 *
 * Android NewPipe does not author a caption style; it READS the system's through
 * CaptioningManager and applies it (CaptionStyleCompat). This port drew three literals instead -
 * fontSize(16), on_primary, '#CC000000' - so the system value never reached the cue. That, and not
 * "the Captions row opens the wrong screen", is the parity gap T-0190 is really about.
 *
 * Three layers, highest first: the user's own override, the system's style, then the values this
 * app has always shipped. Each layer overrides only what it actually carries.
 *
 * PURE: no kits, no I/O. SystemCaptions.ts does the reading and the settings page the writing;
 * both hand their result in here. Keep it that way - the host test runner has no device kits, and
 * one @ohos import in this file would take every test with it.
 */

/** The three attributes VideoDetailFragmentPage puts on the cue Text. */
export interface CueStyle {
  fontSizeFp: number;
  fontColor: string;
  backgroundColor: string;
}

/** The slice of accessibility.CaptionsStyle this port can actually draw. */
export interface SystemCaptionStyle {
  fontScale: number;
  /** '' when the platform gave nothing usable. */
  fontColor: string;
  backgroundColor: string;
}

/** What the in-app Caption appearance screen stores. */
export interface UserCaptionStyle {
  scale: number;
  background: CaptionBackground;
}

export enum CaptionBackground {
  BLACK = 'black',
  TRANSPARENT = 'transparent',
  NONE = 'none'
}

/**
 * Exactly what the cue is drawn with today. Changing these changes the look of every cue for
 * every user who has set nothing - do it only with a measurement.
 */
export const DEFAULT_CUE_STYLE: CueStyle = {
  fontSizeFp: 16,
  fontColor: '#FFFFFF',
  backgroundColor: '#CC000000'
};

const MIN_SCALE: number = 0.5;
const MAX_SCALE: number = 3.0;

function clampScale(scale: number): number {
  if (!(scale > 0)) {
    return 1;
  }
  if (scale < MIN_SCALE) {
    return MIN_SCALE;
  }
  return scale > MAX_SCALE ? MAX_SCALE : scale;
}

/**
 * CaptionsStyle.fontScale is a PERCENTAGE on this platform, not Android's float multiplier:
 * measured on the port handset, the untouched default reads 100, where Android's CaptioningManager
 * returns 1.0 (docs/qa/evidence/fix-T-0190b/captions-probe.txt). Nothing in the SDK says so - the
 * field is documented as a bare `number`. Treat anything above 10 as a percentage; a real
 * multiplier never reaches it, since the resolver clamps at 3.
 */
export function normalizeFontScale(raw: number): number {
  if (Number.isNaN(raw) || raw <= 0) {
    return 1;
  }
  return raw > 10 ? raw / 100 : raw;
}

function backgroundOf(choice: CaptionBackground): string {
  if (choice === CaptionBackground.TRANSPARENT) {
    return '#80000000';
  }
  if (choice === CaptionBackground.NONE) {
    return '#00000000';
  }
  return DEFAULT_CUE_STYLE.backgroundColor;
}

/**
 * @param system the system caption style, or null when there is none / the API refused
 * @param user   the in-app override, or null when the user has set nothing
 */
export function resolveCueStyle(system: SystemCaptionStyle | null,
  user: UserCaptionStyle | null): CueStyle {
  let scale: number = 1;
  let fontColor: string = DEFAULT_CUE_STYLE.fontColor;
  let background: string = DEFAULT_CUE_STYLE.backgroundColor;

  if (system !== null) {
    scale = clampScale(system.fontScale);
    if (system.fontColor.length > 0) {
      fontColor = system.fontColor;
    }
    if (system.backgroundColor.length > 0) {
      background = system.backgroundColor;
    }
  }
  if (user !== null) {
    // The user overrides only the two things the in-app screen offers. Colour keeps coming from
    // the system, which is what the reference does.
    scale = clampScale(user.scale);
    background = backgroundOf(user.background);
  }

  const resolved: CueStyle = {
    fontSizeFp: Math.round(DEFAULT_CUE_STYLE.fontSizeFp * scale),
    fontColor: fontColor,
    backgroundColor: background
  };
  return resolved;
}
