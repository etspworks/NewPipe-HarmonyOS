/*
 * Port of org.schabi.newpipe.player.notification.NotificationConstants - the action table the
 * player notification and the notification-action settings screen both read.
 *
 * Two things the Java expresses with Android resource ids are expressed here as migrated resource
 * NAMES, because a `.ts` module cannot call `$r()` (it is an ETS build-time transform):
 *
 *   - ACTION_ICONS holds the base name of a migrated `resources/base/media/*` asset ('' where the
 *     source stores 0, i.e. `setImageDrawable(null)` - the slot draws no glyph). Same convention as
 *     common/router/DeepLinkRouter.ts `RouterChoice.iconResource`; the page turns a name into a
 *     Resource with a `$r('app.media....')` literal.
 *   - SLOT_PREF_KEYS / SLOT_COMPACT_PREF_KEYS hold the preference key STRINGS themselves (from
 *     common/prefs/SettingsKeys.ts). The source stores `R.string.*` ids and resolves each with
 *     context.getString() at the call site; that indirection exists only because Android keeps
 *     preference keys in a resource file.
 *
 * Two icons of the source table have no migrated asset: REWIND and FORWARD used ExoPlayer's own
 * exo_icon_rewind / exo_icon_fastforward, which ship with the player library, not with NewPipe, so
 * nothing was carried into resources/base/media. They are '' (no glyph) rather than a wrong glyph.
 * PREVIOUS/NEXT likewise had no `previous`/`next` string carried over, so getActionName() uses the
 * app's own previous_stream / next_stream ('Previous stream' / 'Next stream').
 */

import { Localization } from '../i18n/Localization';
import { AppPreferences } from '../prefs/Preferences';
import {
  notification_slot_0_key,
  notification_slot_1_key,
  notification_slot_2_key,
  notification_slot_3_key,
  notification_slot_4_key,
  notification_slot_compact_0_key,
  notification_slot_compact_1_key,
  notification_slot_compact_2_key
} from '../prefs/SettingsKeys';

/* //////////////////////////////////////////////////////////////////////////
// Intent actions
//
// App.PACKAGE_NAME is BuildConfig.APPLICATION_ID (buildSrc ProjectConfig.NEWPIPE_APPLICATION_ID_OLD).
// The doubled '.player.MainPlayer.' segment below is in the source verbatim - BASE_ACTION already
// ends with it - and these are opaque tokens compared with equals(), so the quirk is kept.
////////////////////////////////////////////////////////////////////////// */

const PACKAGE_NAME: string = 'org.schabi.newpipe';
const BASE_ACTION: string = PACKAGE_NAME + '.player.MainPlayer.';

export const ACTION_CLOSE: string = BASE_ACTION + 'CLOSE';
export const ACTION_PLAY_PAUSE: string = BASE_ACTION + '.player.MainPlayer.PLAY_PAUSE';
export const ACTION_REPEAT: string = BASE_ACTION + '.player.MainPlayer.REPEAT';
export const ACTION_PLAY_NEXT: string = BASE_ACTION + '.player.MainPlayer.ACTION_PLAY_NEXT';
export const ACTION_PLAY_PREVIOUS: string = BASE_ACTION + '.player.MainPlayer.ACTION_PLAY_PREVIOUS';
export const ACTION_FAST_REWIND: string = BASE_ACTION + '.player.MainPlayer.ACTION_FAST_REWIND';
export const ACTION_FAST_FORWARD: string = BASE_ACTION + '.player.MainPlayer.ACTION_FAST_FORWARD';
export const ACTION_SHUFFLE: string = BASE_ACTION + '.player.MainPlayer.ACTION_SHUFFLE';
export const ACTION_RECREATE_NOTIFICATION: string =
  BASE_ACTION + '.player.MainPlayer.ACTION_RECREATE_NOTIFICATION';

/* //////////////////////////////////////////////////////////////////////////
// @Action - what a notification slot can be set to
////////////////////////////////////////////////////////////////////////// */

export const NOTHING: number = 0;
export const PREVIOUS: number = 1;
export const NEXT: number = 2;
export const REWIND: number = 3;
export const FORWARD: number = 4;
export const SMART_REWIND_PREVIOUS: number = 5;
export const SMART_FORWARD_NEXT: number = 6;
export const PLAY_PAUSE: number = 7;
export const PLAY_PAUSE_BUFFERING: number = 8;
export const REPEAT: number = 9;
export const SHUFFLE: number = 10;
export const CLOSE: number = 11;

/** Every @Action, in the order the chooser dialog lists them. */
export const ALL_ACTIONS: number[] = [NOTHING, PREVIOUS, NEXT, REWIND, FORWARD,
  SMART_REWIND_PREVIOUS, SMART_FORWARD_NEXT, PLAY_PAUSE, PLAY_PAUSE_BUFFERING, REPEAT,
  SHUFFLE, CLOSE];

/**
 * Indexed by @Action. A migrated media resource base name, or '' where the action draws no glyph.
 * REWIND and FORWARD are '' because their ExoPlayer icons were never part of the source app's own
 * resources (see the file header).
 */
export const ACTION_ICONS: string[] = [
  '',                 // NOTHING                - source 0, i.e. setImageDrawable(null)
  'ic_previous',      // PREVIOUS               - exo_icon_previous
  'ic_next',          // NEXT                   - exo_icon_next
  '',                 // REWIND                 - exo_icon_rewind, not migrated
  '',                 // FORWARD                - exo_icon_fastforward, not migrated
  'ic_previous',      // SMART_REWIND_PREVIOUS  - exo_icon_previous
  'ic_next',          // SMART_FORWARD_NEXT     - exo_icon_next
  'ic_pause',         // PLAY_PAUSE
  'ic_hourglass_top', // PLAY_PAUSE_BUFFERING
  'ic_repeat',        // REPEAT                 - exo_icon_repeat_all
  'ic_shuffle',       // SHUFFLE                - exo_icon_shuffle_on
  'ic_close'          // CLOSE
];

/** The action each of the five slots holds until the user changes it. */
export const SLOT_DEFAULTS: number[] = [
  SMART_REWIND_PREVIOUS,
  PLAY_PAUSE_BUFFERING,
  SMART_FORWARD_NEXT,
  REPEAT,
  CLOSE
];

/** The preference key each slot reads and writes, indexed by slot. */
export const SLOT_PREF_KEYS: string[] = [
  notification_slot_0_key,
  notification_slot_1_key,
  notification_slot_2_key,
  notification_slot_3_key,
  notification_slot_4_key
];

/** Which slots the compact notification shows before the user has chosen. */
export const SLOT_COMPACT_DEFAULTS: number[] = [0, 1, 2];

export const SLOT_COMPACT_PREF_KEYS: string[] = [
  notification_slot_compact_0_key,
  notification_slot_compact_1_key,
  notification_slot_compact_2_key
];

/** Java's Integer.MAX_VALUE - the "not populated yet" sentinel of the compact-slot preferences. */
const INT_MAX_VALUE: number = 2147483647;

/**
 * Port of getActionName(Context, @Action int): the human label of an action, as the slot summary
 * and the chooser row show it.
 */
export function getActionName(action: number): string {
  switch (action) {
    case PREVIOUS:
      return Localization.getString('previous_stream');
    case NEXT:
      return Localization.getString('next_stream');
    case REWIND:
      return Localization.getString('rewind');
    case FORWARD:
      return Localization.getString('forward');
    case SMART_REWIND_PREVIOUS:
      return Localization.concatenateStrings([
        Localization.getString('rewind'),
        Localization.getString('previous_stream')
      ]);
    case SMART_FORWARD_NEXT:
      return Localization.concatenateStrings([
        Localization.getString('forward'),
        Localization.getString('next_stream')
      ]);
    case PLAY_PAUSE:
      return Localization.concatenateStrings([
        Localization.getString('play'),
        Localization.getString('pause')
      ]);
    case PLAY_PAUSE_BUFFERING:
      return Localization.concatenateStrings([
        Localization.getString('play'),
        Localization.getString('pause'),
        Localization.getString('notification_action_buffering')
      ]);
    case REPEAT:
      return Localization.getString('notification_action_repeat');
    case SHUFFLE:
      return Localization.getString('notification_action_shuffle');
    case CLOSE:
      return Localization.getString('close');
    case NOTHING:
    default:
      return Localization.getString('notification_action_nothing');
  }
}

/**
 * Port of getCompactSlotsFromPreferences(): the sorted, de-duplicated indices of the slots the
 * compact notification shows. The source threads a SharedPreferences in; there is exactly one
 * preference store here, so this reads it directly.
 *
 * Java's TreeSet gives sorted + unique; a slot value below 0 means fewer than three checkboxes are
 * ticked and is skipped, and the sentinel means the settings were never populated, in which case
 * the defaults are returned (a copy, so a caller cannot mutate the exported array).
 */
export function getCompactSlotsFromPreferences(): number[] {
  const prefs: AppPreferences = AppPreferences.instance();
  const compactSlots: number[] = [];
  for (let i = 0; i < SLOT_COMPACT_PREF_KEYS.length; i++) {
    const compactSlot: number = prefs.getIntSync(SLOT_COMPACT_PREF_KEYS[i], INT_MAX_VALUE);
    if (compactSlot === INT_MAX_VALUE) {
      return SLOT_COMPACT_DEFAULTS.slice();
    }
    if (compactSlot >= 0 && compactSlots.indexOf(compactSlot) < 0) {
      compactSlots.push(compactSlot);
    }
  }
  compactSlots.sort((a: number, b: number): number => a - b);
  return compactSlots;
}
