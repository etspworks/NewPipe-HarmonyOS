/*
 * svc_system_captions - the system's caption style, read defensively.
 *
 * accessibility.getCaptionsManager() is the direct counterpart of Android's CaptioningManager and
 * carries all six fields Android's caption screen exposes (fontFamily, fontScale, fontColor,
 * fontEdgeType, backgroundColor, windowColor). It needs no permission and its syscap,
 * SystemCapability.BarrierFree.Accessibility.Hearing, IS declared in the phone profile.
 *
 * BUT: getCaptionsManager() itself is @deprecated since 12 - and unlike every other deprecation in
 * that file it names no @useinstead. It was retired with no replacement, while the CaptionsManager
 * it returns kept its enabled/style fields all the way to @since 23. So the only route to the
 * system style is a function the SDK has given up on, and every call here is guarded: the syscap
 * first, then a try/catch, then each field. Returning null is a normal answer - the caller then
 * draws what this app has always drawn.
 *
 * Measured on the handset: docs/qa/evidence/fix-T-0190b/captions-probe.txt.
 */

import accessibility from '@ohos.accessibility';
import hilog from '@ohos.hilog';
import { CaptionBackground, normalizeFontScale, SystemCaptionStyle,
  UserCaptionStyle } from './CaptionStyle';
import { AppPreferences } from '../prefs/Preferences';
import { caption_user_set_key } from '../prefs/SettingsKeys';

const TAG: string = 'SystemCaptions';
const HEARING_SYSCAP: string = 'SystemCapability.BarrierFree.Accessibility.Hearing';

export function captionsSyscapAvailable(): boolean {
  return canIUse(HEARING_SYSCAP);
}

/** A colour from CaptionsStyle is `number | string`. Normalise to '#AARRGGBB', or '' if neither. */
function colorOf(value: number | string | undefined): string {
  if (typeof value === 'string') {
    return value.length > 0 ? value : '';
  }
  if (typeof value === 'number') {
    const hex: string = (value >>> 0).toString(16).padStart(8, '0').toUpperCase();
    return '#' + hex;
  }
  return '';
}

/**
 * The system caption style, or null when the platform will not give one. Null is a normal answer,
 * not an error: captions off, syscap absent, or the deprecated API gone.
 */
export function readSystemCaptionStyle(): SystemCaptionStyle | null {
  if (!captionsSyscapAvailable()) {
    hilog.info(0x0000, TAG, 'T0190B syscap=absent');
    return null;
  }
  try {
    const manager: accessibility.CaptionsManager = accessibility.getCaptionsManager();
    if (manager === null || manager === undefined) {
      hilog.info(0x0000, TAG, 'T0190B syscap=ok manager=null');
      return null;
    }
    const enabled: boolean = manager.enabled;
    const style: accessibility.CaptionsStyle = manager.style;
    if (style === null || style === undefined) {
      hilog.info(0x0000, TAG, 'T0190B syscap=ok enabled=' + enabled + ' style=null');
      return null;
    }
    const raw: number = typeof style.fontScale === 'number' ? style.fontScale : 1;
    const scale: number = normalizeFontScale(raw);
    const result: SystemCaptionStyle = {
      fontScale: scale,
      fontColor: colorOf(style.fontColor),
      backgroundColor: colorOf(style.backgroundColor)
    };
    hilog.info(0x0000, TAG, 'T0190B syscap=ok enabled=' + enabled + ' rawScale=' + raw + ' scale=' + result.fontScale
      + ' font=' + result.fontColor + ' back=' + result.backgroundColor
      + ' family=' + style.fontFamily + ' edge=' + style.fontEdgeType
      + ' window=' + colorOf(style.windowColor));
    // Captions switched off in the system is the system saying "do not restyle": the port keeps
    // its own look rather than applying a style the user is not looking at.
    return enabled ? result : null;
  } catch (err) {
    hilog.info(0x0000, TAG, 'T0190B THREW ' + JSON.stringify(err));
    return null;
  }
}

/**
 * The user override, or null when they have set nothing.
 *
 * Stored as one JSON string under caption_user_set_key - a key SettingsKeys.ts has declared since
 * the port landed and nothing has ever read. No new preference key is invented for this.
 *
 * These two live here rather than in CaptionStyle.ts on purpose: AppPreferences reaches @kit.ArkData,
 * and the host test suite that covers the resolver runs without kits. The resolver stays pure.
 */
export async function readUserCaptionStyle(): Promise<UserCaptionStyle | null> {
  const raw: string = await AppPreferences.getString(caption_user_set_key, '');
  if (raw.length === 0) {
    return null;
  }
  try {
    const parsed: UserCaptionStyle = JSON.parse(raw) as UserCaptionStyle;
    if (typeof parsed.scale !== 'number') {
      return null;
    }
    // A background written by an older build - or a hand-edited store - must not leave the cue
    // with an undefined ground.
    const background: CaptionBackground =
      parsed.background === CaptionBackground.TRANSPARENT ? CaptionBackground.TRANSPARENT
        : (parsed.background === CaptionBackground.NONE ? CaptionBackground.NONE
          : CaptionBackground.BLACK);
    const checked: UserCaptionStyle = { scale: parsed.scale, background: background };
    return checked;
  } catch (err) {
    return null;
  }
}

export async function writeUserCaptionStyle(style: UserCaptionStyle): Promise<void> {
  await AppPreferences.putString(caption_user_set_key, JSON.stringify(style));
}
