/*
 * PreferenceSearchResultHighlighter's recyclerView.scrollToPosition(): the settings screen on
 * show binds its list to this one Scroller, so the settings host can scroll a search result into
 * view without a hook in every settings page.
 */
export const settingsListScroller: Scroller = new Scroller();
