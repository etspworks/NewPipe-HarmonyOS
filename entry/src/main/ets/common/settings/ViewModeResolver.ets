/*
 * svc_view_mode - port of org.schabi.newpipe.util.ThemeHelper.getItemViewMode().
 *
 * Seven list screens each carried their own copy of
 *
 *     if (mode === grid) GRID; else if (mode === card) CARD; else LIST;
 *
 * which is the same decision written seven times, with seven chances to drift. This is the one
 * copy; the screens call it.
 *
 * WHAT `auto` MEANS, MEASURED - and it is not what this plan expected.
 * The expectation was that `tablet_mode = on` turns `auto` into GRID. It does not. On the
 * reference (org.schabi.newpipe 0.29.1, EPHUT20709003067) `auto` drew a LIST in every combination
 * that handset can produce: tablet_mode auto and on, before and after a full restart, at 360 dp
 * and at 720 dp of width. An explicit `grid` did draw grid items, so the preference path itself
 * works. Six verified runs, each with the two preferences screenshot-confirmed first:
 * docs/qa/evidence/tablet/reference-auto.md.
 *
 * So `auto` resolves to LIST here, and this function takes ONE argument. It does not take a
 * device class or tablet_mode, because nothing measured showed either changing the answer, and a
 * parameter that encodes an unmeasured guess is worse than no parameter: it reads as knowledge.
 *
 * WHAT IS STILL OPEN: a real tablet. No tablet hardware existed in the session that measured
 * this, and `wm density` widens the dp viewport without making Android report a tablet-class
 * screenLayout, so it is not a substitute. If `auto` turns out to draw GRID on a true tablet,
 * this is the one place that changes - add the device class here, with the measurement beside it.
 *
 * PURE: no kits, no I/O, so the host suite pins every arm.
 */

import { ItemViewMode } from '../../components/InfoListAdapter';
import { list_view_mode_card_key, list_view_mode_grid_key } from '../prefs/SettingsKeys';

/**
 * @param listViewMode the stored `list_view_mode` - `auto`, `list`, `grid` or `card`. Anything
 *   else (an empty store, a hand-edited value, a key from a newer build) is treated as `auto`.
 */
export function resolveItemViewMode(listViewMode: string): ItemViewMode {
  if (listViewMode === list_view_mode_grid_key) {
    return ItemViewMode.GRID;
  }
  if (listViewMode === list_view_mode_card_key) {
    return ItemViewMode.CARD;
  }
  // `list` and `auto` both land here, and so does anything unrecognised - LIST is what the
  // reference draws for `auto`, and it is the safe answer for a value nobody wrote on purpose.
  return ItemViewMode.LIST;
}
