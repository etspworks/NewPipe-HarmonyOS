/*
 * svc_preferred_height - a stored resolution preference, as a height the player can be asked for.
 *
 * `Default resolution` and `Default popup resolution` both store a label: `480p`, `720p60`, or the
 * sentinel `best_resolution`. PlayerService.prepare() wants a number, where 0 means "no ceiling".
 *
 * The detail page already does this conversion inside defaultQualityIndex(), against the stream's
 * own rendition list. The popup has no such list - it prepares the stream before any quality
 * control exists - so it needs the preference alone, and that is this. T-0197: the popup called
 * prepare() with no height at all, so `Default popup resolution` was read by nothing and the
 * resolver picked its own rendition; measured on the handset, the port served 360p where the
 * reference served the configured 480p.
 *
 * PURE: no kits, no I/O, host-tested.
 */

import { best_resolution_key } from '../prefs/SettingsKeys';

/**
 * @param preference the stored label - `480p`, `720p60`, `best_resolution`, or anything a hand
 *   edit or an older build left behind
 * @returns the height to cap at, or 0 for "no ceiling" - which is what `best_resolution` asks for
 *   and the only safe answer to a value nobody wrote on purpose
 */
export function preferredHeightOf(preference: string): number {
  if (preference.length === 0 || preference === best_resolution_key) {
    return 0;
  }
  // '720p60' -> 720. The fps suffix only ever distinguished two rows of the same height.
  const height: number = Number.parseInt(preference, 10);
  return Number.isNaN(height) || height <= 0 ? 0 : height;
}
