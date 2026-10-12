/*
 * Port of app/src/main/java/org/schabi/newpipe/settings/preferencesearch/ - the settings search:
 *   PreferenceSearcher.java              -> PreferenceSearcher
 *   PreferenceSearchConfiguration.java   -> PreferenceSearchConfiguration
 *   PreferenceFuzzySearchFunction.java   -> PreferenceFuzzySearchFunction (+ fuzzyScore)
 *   PreferenceParser.java                -> PREFERENCE_SEARCH_INDEX + buildPreferenceSearcher
 *
 * WHAT CHANGED, AND WHY
 * ---------------------
 * PreferenceParser INFLATED res/xml/*_settings.xml with an XmlPullParser to discover the searchable
 * preferences. This port has no XML preference resources - every settings screen is an ArkUI page -
 * so there is nothing to parse. The index below is the same information stated statically: one
 * entry per row a MIGRATED settings page actually renders, keyed by the same preference key
 * (SettingsKeys.ts), carrying the title/summary/breadcrumb strings that screen's XML pointed at,
 * and naming the settings screen that hosts it.
 *
 * Everything downstream of the parser is a faithful port: the scoring (Apache commons-text
 * FuzzyScore, which NewPipe uses through `org.apache.commons.text.similarity.FuzzyScore`), the
 * 0.3-of-maxScore general filter, the title/summary/entries weight map, the descending sort and the
 * 20-result limit are the source's own, thresholds and weights unchanged.
 *
 * Divergences, all deliberate:
 *  - PreferenceSearchConfiguration's `parserIgnoreElements` / `parserContainerElements` are dropped.
 *    They existed only to steer the XmlPullParser (which tags to skip, which push a breadcrumb);
 *    with a static index there is no consumer for them. `searcher` - the half that is live - stays.
 *  - `entries` (a ListPreference's human-readable options) is filled only where the port carries the
 *    option list as a string-array resource. Most option lists live inline in their settings page's
 *    dialog rather than in resources, so those entries are ''. That weakens ranking for those rows
 *    exactly as an empty field does in the source; it invents nothing.
 *  - SettingsResourceRegistry's two non-searchable screens are simply absent from the index
 *    (MainSettingsFragment, DebugSettingsFragment). ensureSearchRepresentsApplicationState() also
 *    drops update_settings unless the APK carries NewPipe's release signature, and this build
 *    never does - the Updates row is not in the menu either (MainSettingsFragmentPage's
 *    SHOW_UPDATE_CATEGORY), so its two rows are out of the index as well: a search hit that opens
 *    a screen the menu does not list is worse than no hit.
 */

import { PreferenceSearchItem } from '../../model/app/PreferenceSearchItem';
import { Localization } from '../i18n/Localization';
import { PrefValue } from '../prefs/Preferences';

/*//////////////////////////////////////////////////////////////////////////
// FuzzyScore - org.apache.commons.text.similarity.FuzzyScore, Locale.ROOT
//////////////////////////////////////////////////////////////////////////*/

/**
 * One point per matched query character, plus two more when it matches the term position directly
 * after the previous match. Verbatim behaviour of commons-text FuzzyScore#fuzzyScore.
 */
export function fuzzyScore(term: string, query: string): number {
  const termLowerCase: string = term.toLowerCase();
  const queryLowerCase: string = query.toLowerCase();

  let score: number = 0;
  // The position in the term which will be scanned next for potential query character matches.
  let termIndex: number = 0;
  // Index of the previously matched character in the term (Integer.MIN_VALUE in the source).
  let previousMatchingCharacterIndex: number = -2147483648;

  for (let queryIndex: number = 0; queryIndex < queryLowerCase.length; queryIndex++) {
    const queryChar: string = queryLowerCase.charAt(queryIndex);

    let termCharacterMatchFound: boolean = false;
    for (; termIndex < termLowerCase.length && !termCharacterMatchFound; termIndex++) {
      const termChar: string = termLowerCase.charAt(termIndex);

      if (queryChar === termChar) {
        // Simple character matches result in one point.
        score++;

        // Subsequent character matches further improve the score.
        if (previousMatchingCharacterIndex + 1 === termIndex) {
          score += 2;
        }

        previousMatchingCharacterIndex = termIndex;

        // Every character in the query can match at most one character in the term.
        termCharacterMatchFound = true;
      }
    }
  }

  return score;
}

/*//////////////////////////////////////////////////////////////////////////
// PreferenceFuzzySearchFunction
//////////////////////////////////////////////////////////////////////////*/

/** PreferenceSearchConfiguration.PreferenceSearchFunction - the Stream<> is an array here. */
export interface PreferenceSearchFunction {
  search(allAvailable: PreferenceSearchItem[], keyword: string): PreferenceSearchItem[];
}

/** One WEIGHT_MAP row of FuzzySearchSpecificDTO. */
class SpecificField {
  readonly value: string;
  readonly weight: number;

  constructor(value: string, weight: number) {
    this.value = value;
    this.weight = weight;
  }
}

/** FuzzySearchSpecificDTO - the item plus the weighted score that orders the results. */
class ScoredItem {
  readonly item: PreferenceSearchItem;
  readonly score: number;

  constructor(item: PreferenceSearchItem, score: number) {
    this.item = item;
    this.score = score;
  }
}

export class PreferenceFuzzySearchFunction implements PreferenceSearchFunction {
  /** Limit the amount of search results. */
  private static readonly RESULT_LIMIT: number = 20;
  /** `.filter(dto -> dto.getScore() / maxScore >= 0.3f)`. */
  private static readonly GENERAL_MATCH_RATIO: number = 0.3;

  search(allAvailable: PreferenceSearchItem[], keyword: string): PreferenceSearchItem[] {
    // First can't get +2 bonus score.
    const maxScore: number = (keyword.length + 1) * 3 - 2;

    // General search - check all fields if anyone contains something that kind of matches the
    // keyword (FuzzySearchGeneralDTO).
    const generalMatches: PreferenceSearchItem[] = [];
    for (const item of allAvailable) {
      const general: number = fuzzyScore(item.allRelevantSearchFields.join(';'), keyword);
      if (general / maxScore >= PreferenceFuzzySearchFunction.GENERAL_MATCH_RATIO) {
        generalMatches.push(item);
      }
    }

    // Specific search - used for determining order of search results (FuzzySearchSpecificDTO).
    const scored: ScoredItem[] = generalMatches.map((item: PreferenceSearchItem): ScoredItem => {
      return new ScoredItem(item, PreferenceFuzzySearchFunction.specificScore(item, keyword));
    });
    scored.sort((a: ScoredItem, b: ScoredItem): number => b.score - a.score);

    const ordered: PreferenceSearchItem[] =
      scored.map((entry: ScoredItem): PreferenceSearchItem => entry.item);
    return ordered.slice(0, PreferenceFuzzySearchFunction.RESULT_LIMIT);
  }

  /** Collectors.averagingDouble over the non-empty weighted fields; 0.0 when none is set. */
  private static specificScore(item: PreferenceSearchItem, keyword: string): number {
    const fields: SpecificField[] = [
      // The user will most likely look for the title -> prioritize it.
      new SpecificField(item.title, 1.5),
      // The summary is also important as it usually contains a larger desc.
      // Example: Searching for '4k' -> 'show higher resolution' is shown.
      new SpecificField(item.summary, 1),
      // Entries are also important as they provide all known/possible values.
      // Example: Searching where the resolution can be changed to 720p.
      new SpecificField(item.entries, 1)
    ];

    let sum: number = 0;
    let count: number = 0;
    for (const field of fields) {
      if (field.value.length === 0) {
        continue;
      }
      sum += fuzzyScore(field.value, keyword) * field.weight;
      count++;
    }
    return count === 0 ? 0 : sum / count;
  }
}

/*//////////////////////////////////////////////////////////////////////////
// PreferenceSearchConfiguration / PreferenceSearcher
//////////////////////////////////////////////////////////////////////////*/

export class PreferenceSearchConfiguration {
  private searcher: PreferenceSearchFunction = new PreferenceFuzzySearchFunction();

  setSearcher(searcher: PreferenceSearchFunction): void {
    this.searcher = searcher;
  }

  getSearcher(): PreferenceSearchFunction {
    return this.searcher;
  }
}

export class PreferenceSearcher {
  private readonly allEntries: PreferenceSearchItem[] = [];
  private readonly configuration: PreferenceSearchConfiguration;

  constructor(configuration: PreferenceSearchConfiguration) {
    this.configuration = configuration;
  }

  add(items: PreferenceSearchItem[]): void {
    for (const item of items) {
      this.allEntries.push(item);
    }
  }

  searchFor(keyword: string): PreferenceSearchItem[] {
    if (keyword.length === 0) {
      return [];
    }
    return this.configuration.getSearcher().search(this.allEntries, keyword);
  }

  clear(): void {
    this.allEntries.length = 0;
  }
}

/*//////////////////////////////////////////////////////////////////////////
// The index - PreferenceParser's output, stated statically
//////////////////////////////////////////////////////////////////////////*/

/**
 * One searchable settings row. Resource NAMES, not resources: a .ts module cannot call $r(), so the
 * page resolves them - the convention common/player/NotificationConstants.ts already uses.
 */
export class PreferenceSearchEntry {
  /** android:key, i.e. the same value the settings page puts on that row's .id(). */
  readonly key: string;
  /** android:title. */
  readonly titleRes: string;
  /** android:summary, or '' where the preference declares none. */
  readonly summaryRes: string;
  /** android:entries as a string-array resource name, or '' - see the header. */
  readonly entriesRes: string;
  /** The container titles the parser pushed, outermost first; joined with ' > '. */
  readonly breadcrumbRes: string[];
  /** searchIndexItemResId's role here: the settings fragment SettingsActivityPage holds. */
  readonly screen: string;

  constructor(key: string, titleRes: string, summaryRes: string, entriesRes: string,
    breadcrumbRes: string[], screen: string) {
    this.key = key;
    this.titleRes = titleRes;
    this.summaryRes = summaryRes;
    this.entriesRes = entriesRes;
    this.breadcrumbRes = breadcrumbRes;
    this.screen = screen;
  }
}

/** Root PreferenceScreen titles - the first breadcrumb of every row on that screen. */
const BC_APPEARANCE: string[] = ['settings_category_appearance_title'];
const BC_CONTENT: string[] = ['content'];
const BC_CONTENT_FEED: string[] = ['content', 'settings_category_feed_title'];
const BC_DOWNLOADS: string[] = ['settings_category_downloads_title'];
const BC_HISTORY: string[] = ['settings_category_history_title'];
const BC_HISTORY_CLEAR: string[] =
  ['settings_category_history_title', 'settings_category_clear_data_title'];
const BC_NOTIFICATIONS: string[] = ['notifications'];
const BC_PLAYER_NOTIFICATION: string[] = ['settings_category_player_notification_title'];
const BC_UPDATES: string[] = ['settings_category_updates_title'];
const BC_VIDEO_AUDIO: string[] = ['settings_category_video_audio_title'];
const BC_VA_PLAYER: string[] =
  ['settings_category_video_audio_title', 'settings_category_player_title'];
const BC_VA_BEHAVIOR: string[] =
  ['settings_category_video_audio_title', 'settings_category_player_behavior_title'];
const BC_EXOPLAYER: string[] = ['settings_category_exoplayer_title'];
const BC_BACKUP: string[] = ['settings_category_backup_restore_title'];

/** The fragment names SettingsActivityPage's settings_fragment_holder switches on. */
const S_APPEARANCE: string = 'AppearanceSettingsFragment';
const S_CONTENT: string = 'ContentSettingsFragment';
const S_DOWNLOADS: string = 'DownloadSettingsFragment';
const S_HISTORY: string = 'HistorySettingsFragment';
const S_NOTIFICATIONS: string = 'NotificationSettingsFragment';
const S_PLAYER_NOTIFICATION: string = 'PlayerNotificationSettingsFragment';
const S_UPDATES: string = 'UpdateSettingsFragment';
const S_VIDEO_AUDIO: string = 'VideoAudioSettingsFragment';
const S_EXOPLAYER: string = 'ExoPlayerSettingsFragment';
const S_BACKUP: string = 'BackupRestoreSettingsFragment';

/**
 * Every preference row a migrated settings page renders, for the ten screens
 * SettingsResourceRegistry marks searchable. Key/title/summary/entries/breadcrumb come from that
 * screen's res/xml/*_settings.xml; each key was checked against the .id() the generated page puts on
 * the row, so nothing is indexed that the port does not render.
 */
export const PREFERENCE_SEARCH_INDEX: PreferenceSearchEntry[] = [
  // -- appearance_settings.xml -> AppearanceSettingsFragmentPage --------------------------------
  new PreferenceSearchEntry('theme', 'theme_title', '', '',
    BC_APPEARANCE, S_APPEARANCE),
  new PreferenceSearchEntry('night_theme', 'night_theme_title', 'night_theme_summary', '',
    BC_APPEARANCE, S_APPEARANCE),
  new PreferenceSearchEntry('show_hold_to_append', 'show_hold_to_append_title',
    'show_hold_to_append_summary', '', BC_APPEARANCE, S_APPEARANCE),
  new PreferenceSearchEntry('tablet_mode', 'tablet_mode_title', '', '',
    BC_APPEARANCE, S_APPEARANCE),
  new PreferenceSearchEntry('list_view_mode', 'list_view_mode', '', '',
    BC_APPEARANCE, S_APPEARANCE),
  new PreferenceSearchEntry('caption_settings_key', 'caption_setting_title',
    'caption_setting_description', '', BC_APPEARANCE, S_APPEARANCE),
  new PreferenceSearchEntry('main_tabs_position', 'main_tabs_position_title',
    'main_tabs_position_summary', '', BC_APPEARANCE, S_APPEARANCE),

  // -- content_settings.xml -> ContentSettingsFragmentPage --------------------------------------
  new PreferenceSearchEntry('app_language_key', 'app_language_title', '', '',
    BC_CONTENT, S_CONTENT),
  new PreferenceSearchEntry('app_language_android_13_and_up_key', 'app_language_title', '', '',
    BC_CONTENT, S_CONTENT),
  new PreferenceSearchEntry('content_language', 'content_language_title', '', '',
    BC_CONTENT, S_CONTENT),
  new PreferenceSearchEntry('content_country', 'default_content_country_title', '', '',
    BC_CONTENT, S_CONTENT),
  new PreferenceSearchEntry('main_page_content', 'main_page_content', 'main_page_content_summary',
    '', BC_CONTENT, S_CONTENT),
  new PreferenceSearchEntry('channel_tabs', 'show_channel_tabs', 'show_channel_tabs_summary', '',
    BC_CONTENT, S_CONTENT),
  new PreferenceSearchEntry('peertube_instance_setup', 'peertube_instance_url_title',
    'peertube_instance_url_summary', '', BC_CONTENT, S_CONTENT),
  new PreferenceSearchEntry('show_age_restricted_content', 'show_age_restricted_content_title',
    'show_age_restricted_content_summary', '', BC_CONTENT, S_CONTENT),
  new PreferenceSearchEntry('youtube_restricted_mode_enabled',
    'youtube_restricted_mode_enabled_title', 'youtube_restricted_mode_enabled_summary', '',
    BC_CONTENT, S_CONTENT),
  new PreferenceSearchEntry('show_search_suggestions', 'show_search_suggestions_title',
    'show_search_suggestions_summary', '', BC_CONTENT, S_CONTENT),
  new PreferenceSearchEntry('image_quality_key', 'image_quality_title', 'image_quality_summary', '',
    BC_CONTENT, S_CONTENT),
  new PreferenceSearchEntry('show_comments', 'show_comments_title', 'show_comments_summary', '',
    BC_CONTENT, S_CONTENT),
  new PreferenceSearchEntry('show_next_video', 'show_next_and_similar_title', '', '',
    BC_CONTENT, S_CONTENT),
  new PreferenceSearchEntry('show_description', 'show_description_title', 'show_description_summary',
    '', BC_CONTENT, S_CONTENT),
  new PreferenceSearchEntry('show_meta_info', 'show_meta_info_title', 'show_meta_info_summary', '',
    BC_CONTENT, S_CONTENT),
  new PreferenceSearchEntry('feed_update_threshold_key', 'feed_update_threshold_title',
    'feed_update_threshold_summary', '', BC_CONTENT_FEED, S_CONTENT),
  new PreferenceSearchEntry('feed_use_dedicated_fetch_method',
    'feed_use_dedicated_fetch_method_title', 'feed_use_dedicated_fetch_method_summary', '',
    BC_CONTENT_FEED, S_CONTENT),
  new PreferenceSearchEntry('feed_fetch_channel_tabs', 'feed_fetch_channel_tabs',
    'feed_fetch_channel_tabs_summary', '', BC_CONTENT_FEED, S_CONTENT),

  // -- download_settings.xml -> DownloadSettingsFragmentPage ------------------------------------
  new PreferenceSearchEntry('downloads_storage_ask', 'downloads_storage_ask_title',
    'downloads_storage_ask_unavailable_note', '', BC_DOWNLOADS, S_DOWNLOADS),
  new PreferenceSearchEntry('storage_use_saf', 'downloads_storage_use_saf_title',
    'storage_saf_unavailable_note', '', BC_DOWNLOADS, S_DOWNLOADS),
  new PreferenceSearchEntry('download_path', 'download_path_title', 'download_path_summary', '',
    BC_DOWNLOADS, S_DOWNLOADS),
  new PreferenceSearchEntry('download_path_audio', 'download_path_audio_title',
    'download_path_audio_summary', '', BC_DOWNLOADS, S_DOWNLOADS),
  new PreferenceSearchEntry('file_rename_charset', 'settings_file_charset_title', '', '',
    BC_DOWNLOADS, S_DOWNLOADS),
  new PreferenceSearchEntry('file_replacement_character',
    'settings_file_replacement_character_title', 'settings_file_replacement_character_summary', '',
    BC_DOWNLOADS, S_DOWNLOADS),
  new PreferenceSearchEntry('downloads_max_retry', 'max_retry_msg', 'max_retry_desc', '',
    BC_DOWNLOADS, S_DOWNLOADS),
  new PreferenceSearchEntry('cross_network_downloads', 'pause_downloads_on_mobile',
    'pause_downloads_on_mobile_desc', '', BC_DOWNLOADS, S_DOWNLOADS),
  new PreferenceSearchEntry('downloads_queue_limit', 'enable_queue_limit', 'enable_queue_limit_desc',
    '', BC_DOWNLOADS, S_DOWNLOADS),

  // -- history_settings.xml -> HistorySettingsFragmentPage --------------------------------------
  new PreferenceSearchEntry('enable_watch_history', 'enable_watch_history_title',
    'enable_watch_history_summary', '', BC_HISTORY, S_HISTORY),
  new PreferenceSearchEntry('enable_playback_resume', 'enable_playback_resume_title',
    'enable_playback_resume_summary', '', BC_HISTORY, S_HISTORY),
  new PreferenceSearchEntry('enable_playback_state_lists', 'enable_playback_state_lists_title',
    'enable_playback_state_lists_summary', '', BC_HISTORY, S_HISTORY),
  new PreferenceSearchEntry('enable_search_history', 'enable_search_history_title',
    'enable_search_history_summary', '', BC_HISTORY, S_HISTORY),
  new PreferenceSearchEntry('cache_wipe_key', 'metadata_cache_wipe_title',
    'metadata_cache_wipe_summary', '', BC_HISTORY_CLEAR, S_HISTORY),
  new PreferenceSearchEntry('clear_play_history', 'clear_views_history_title',
    'clear_views_history_summary', '', BC_HISTORY_CLEAR, S_HISTORY),
  new PreferenceSearchEntry('clear_playback_states', 'clear_playback_states_title',
    'clear_playback_states_summary', '', BC_HISTORY_CLEAR, S_HISTORY),
  new PreferenceSearchEntry('clear_search_history', 'clear_search_history_title',
    'clear_search_history_summary', '', BC_HISTORY_CLEAR, S_HISTORY),
  new PreferenceSearchEntry('clear_cookie', 'clear_cookie_title', 'clear_cookie_summary', '',
    BC_HISTORY_CLEAR, S_HISTORY),

  // -- notifications_settings.xml -> NotificationSettingsFragmentPage ---------------------------
  new PreferenceSearchEntry('player_notification_screen',
    'settings_category_player_notification_title', 'settings_category_player_notification_summary',
    '', BC_NOTIFICATIONS, S_NOTIFICATIONS),
  new PreferenceSearchEntry('enable_streams_notifications', 'enable_streams_notifications_title',
    'enable_streams_notifications_summary', '', BC_NOTIFICATIONS, S_NOTIFICATIONS),
  new PreferenceSearchEntry('streams_notifications_interval', 'streams_notifications_interval_title',
    '', '', BC_NOTIFICATIONS, S_NOTIFICATIONS),
  new PreferenceSearchEntry('streams_notifications_network', 'streams_notifications_network_title',
    '', '', BC_NOTIFICATIONS, S_NOTIFICATIONS),
  new PreferenceSearchEntry('streams_notifications_channels', 'channels', '', '',
    BC_NOTIFICATIONS, S_NOTIFICATIONS),

  // -- player_notification_settings.xml -> PlayerNotificationSettingsFragmentPage ---------------
  new PreferenceSearchEntry('scale_to_square_image_in_notifications',
    'notification_scale_to_square_image_title', 'notification_scale_to_square_image_summary', '',
    BC_PLAYER_NOTIFICATION, S_PLAYER_NOTIFICATION),
  new PreferenceSearchEntry('notification_colorize_key', 'notification_colorize_title',
    'notification_colorize_unavailable_note', '', BC_PLAYER_NOTIFICATION, S_PLAYER_NOTIFICATION),
  new PreferenceSearchEntry('show_thumbnail_key', 'show_thumbnail_title', 'show_thumbnail_summary',
    '', BC_PLAYER_NOTIFICATION, S_PLAYER_NOTIFICATION),

  // -- update_settings.xml -> UpdateSettingsFragmentPage ----------------------------------------
  // Dropped with the menu row, the way ensureSearchRepresentsApplicationState() drops it on a
  // build that is not the release APK.

  // -- video_audio_settings.xml -> VideoAudioSettingsFragmentPage -------------------------------
  new PreferenceSearchEntry('default_resolution', 'default_resolution_title', '', '',
    BC_VIDEO_AUDIO, S_VIDEO_AUDIO),
  new PreferenceSearchEntry('default_popup_resolution', 'default_popup_resolution_title', '', '',
    BC_VIDEO_AUDIO, S_VIDEO_AUDIO),
  new PreferenceSearchEntry('limit_mobile_data_usage', 'limit_mobile_data_usage_title', '',
    'limit_data_usage_description_list', BC_VIDEO_AUDIO, S_VIDEO_AUDIO),
  new PreferenceSearchEntry('show_higher_resolutions', 'show_higher_resolutions_title',
    'show_higher_resolutions_summary', '', BC_VIDEO_AUDIO, S_VIDEO_AUDIO),
  new PreferenceSearchEntry('default_video_format', 'default_video_format_title', '', '',
    BC_VIDEO_AUDIO, S_VIDEO_AUDIO),
  new PreferenceSearchEntry('default_audio_format', 'default_audio_format_title', '', '',
    BC_VIDEO_AUDIO, S_VIDEO_AUDIO),
  new PreferenceSearchEntry('prefer_original_audio', 'prefer_original_audio_title',
    'prefer_original_audio_summary', '', BC_VIDEO_AUDIO, S_VIDEO_AUDIO),
  new PreferenceSearchEntry('prefer_descriptive_audio', 'prefer_descriptive_audio_title',
    'prefer_descriptive_audio_summary', '', BC_VIDEO_AUDIO, S_VIDEO_AUDIO),
  new PreferenceSearchEntry('exoplayer_settings_key', 'settings_category_exoplayer_title',
    'settings_category_exoplayer_summary', '', BC_VIDEO_AUDIO, S_VIDEO_AUDIO),
  new PreferenceSearchEntry('use_external_video_player', 'use_external_video_player_title',
    'use_external_video_player_summary', '', BC_VA_PLAYER, S_VIDEO_AUDIO),
  new PreferenceSearchEntry('use_external_audio_player', 'use_external_audio_player_title', '', '',
    BC_VA_PLAYER, S_VIDEO_AUDIO),
  new PreferenceSearchEntry('show_play_with_kodi', 'show_play_with_kodi_title',
    'show_play_with_kodi_summary', '', BC_VA_PLAYER, S_VIDEO_AUDIO),
  new PreferenceSearchEntry('seekbar_preview_thumbnail_key', 'seekbar_preview_thumbnail_title', '',
    '', BC_VA_PLAYER, S_VIDEO_AUDIO),
  new PreferenceSearchEntry('preferred_open_action_key', 'preferred_open_action_settings_title',
    'preferred_open_action_settings_summary', '', BC_VA_BEHAVIOR, S_VIDEO_AUDIO),
  new PreferenceSearchEntry('minimize_on_exit_key', 'minimize_on_exit_title',
    'minimize_on_exit_summary', '', BC_VA_BEHAVIOR, S_VIDEO_AUDIO),
  new PreferenceSearchEntry('start_main_player_fullscreen_key',
    'start_main_player_fullscreen_title', 'start_main_player_fullscreen_summary', '',
    BC_VA_BEHAVIOR, S_VIDEO_AUDIO),
  new PreferenceSearchEntry('autoplay_key', 'autoplay_title', 'autoplay_summary', '',
    BC_VA_BEHAVIOR, S_VIDEO_AUDIO),
  new PreferenceSearchEntry('auto_queue_key', 'auto_queue_title', 'auto_queue_summary', '',
    BC_VA_BEHAVIOR, S_VIDEO_AUDIO),
  new PreferenceSearchEntry('resume_on_audio_focus_gain', 'resume_on_audio_focus_gain_title',
    'resume_on_audio_focus_gain_summary', '', BC_VA_BEHAVIOR, S_VIDEO_AUDIO),
  new PreferenceSearchEntry('left_gesture_control', 'left_gesture_control_title',
    'left_gesture_control_summary', '', BC_VA_BEHAVIOR, S_VIDEO_AUDIO),
  new PreferenceSearchEntry('right_gesture_control', 'right_gesture_control_title',
    'right_gesture_control_summary', '', BC_VA_BEHAVIOR, S_VIDEO_AUDIO),
  new PreferenceSearchEntry('popup_remember_size_pos_key', 'popup_remember_size_pos_title',
    'popup_remember_size_pos_summary', '', BC_VA_BEHAVIOR, S_VIDEO_AUDIO),
  new PreferenceSearchEntry('use_inexact_seek_key', 'use_inexact_seek_title',
    'use_inexact_seek_summary', '', BC_VA_BEHAVIOR, S_VIDEO_AUDIO),
  new PreferenceSearchEntry('seek_duration', 'seek_duration_title', '', '',
    BC_VA_BEHAVIOR, S_VIDEO_AUDIO),
  new PreferenceSearchEntry('clear_queue_confirmation_key', 'clear_queue_confirmation_title',
    'clear_queue_confirmation_summary', '', BC_VA_BEHAVIOR, S_VIDEO_AUDIO),
  new PreferenceSearchEntry('ignore_hardware_media_buttons_key',
    'ignore_hardware_media_buttons_title', 'ignore_hardware_media_buttons_summary', '',
    BC_VA_BEHAVIOR, S_VIDEO_AUDIO),

  // -- exoplayer_settings.xml -> ExoPlayerSettingsFragmentPage ----------------------------------
  new PreferenceSearchEntry('progressive_load_interval', 'progressive_load_interval_title',
    'progressive_load_interval_summary', 'progressive_load_interval_descriptions',
    BC_EXOPLAYER, S_EXOPLAYER),
  new PreferenceSearchEntry('use_exoplayer_decoder_fallback_key',
    'use_exoplayer_decoder_fallback_title', 'use_exoplayer_decoder_fallback_summary', '',
    BC_EXOPLAYER, S_EXOPLAYER),
  new PreferenceSearchEntry('disable_media_tunneling_key', 'disable_media_tunneling_title',
    'disable_media_tunneling_summary', '', BC_EXOPLAYER, S_EXOPLAYER),
  new PreferenceSearchEntry('always_use_exoplayer_set_output_surface_workaround_key',
    'always_use_exoplayer_set_output_surface_workaround_title',
    'avplayer_switch_unavailable_note', '',
    BC_EXOPLAYER, S_EXOPLAYER),

  // -- backup_restore_settings.xml -> BackupRestoreSettingsFragmentPage -------------------------
  new PreferenceSearchEntry('import_data', 'import_data_title', 'import_data_summary', '',
    BC_BACKUP, S_BACKUP),
  new PreferenceSearchEntry('export_data', 'export_data_title', 'export_data_summary', '',
    BC_BACKUP, S_BACKUP),
  new PreferenceSearchEntry('reset_settings', 'reset_settings_title', 'reset_settings_summary', '',
    BC_BACKUP, S_BACKUP),
  new PreferenceSearchEntry('export_subscriptions_key', 'export_subscriptions_title',
    'export_subscriptions_summary', '', BC_BACKUP, S_BACKUP),
  new PreferenceSearchEntry('import_subscriptions_key', 'import_subscriptions_title',
    'import_subscriptions_summary', '', BC_BACKUP, S_BACKUP)
];

/*//////////////////////////////////////////////////////////////////////////
// buildPreferenceSearcher - PreferenceParser's job, over the static index
//////////////////////////////////////////////////////////////////////////*/

/**
 * The one resource lookup svc_localization does not cover. Strings go through
 * Localization.getString (which owns the context and falls back safely); a string-ARRAY has no
 * helper, so the caller hands in `resourceManager.getStringArrayByNameSync`.
 */
export type StringArrayResolver = (name: string) => string[];

/**
 * PreferenceParser#tryFillInPreferenceValue: a title/summary carrying a format specifier gets the
 * preference's CURRENT value substituted, so a summary reads '480p' rather than '%s'.
 */
function tryFillInPreferenceValue(text: string, key: string,
  values: Map<string, PrefValue>): string {
  if (text.length === 0) {
    return text;
  }
  const prefValue: PrefValue | undefined = values.get(key);
  if (prefValue === undefined) {
    return text;
  }
  const asText: string = `${prefValue}`;
  return text.replace('%1$s', asText).replace('%s', asText);
}

/**
 * SettingsActivity#initSearch: build the configuration, parse every searchable settings screen and
 * hand the items to a PreferenceSearcher. Here the parse is a walk over PREFERENCE_SEARCH_INDEX.
 *
 * `values` is `new PreferenceParser(searchContext, config)`'s
 * `PreferenceManager.getDefaultSharedPreferences(context).getAll()` - the snapshot the parser
 * substitutes into a title/summary carrying a format specifier. The caller supplies it exactly as
 * the activity supplies the parser's context; an empty map only costs that substitution, never the
 * search itself.
 */
export function buildPreferenceSearcher(values: Map<string, PrefValue>,
  getStringArray: StringArrayResolver): PreferenceSearcher {
  const configuration: PreferenceSearchConfiguration = new PreferenceSearchConfiguration();
  const searcher: PreferenceSearcher = new PreferenceSearcher(configuration);

  const items: PreferenceSearchItem[] = [];
  for (const entry of PREFERENCE_SEARCH_INDEX) {
    const title: string =
      tryFillInPreferenceValue(Localization.getString(entry.titleRes), entry.key, values);
    const summary: string = entry.summaryRes.length === 0
      ? '' : tryFillInPreferenceValue(Localization.getString(entry.summaryRes), entry.key, values);
    const entries: string =
      entry.entriesRes.length === 0 ? '' : getStringArray(entry.entriesRes).join(',');
    // Localization.concatenateStrings(" > ", breadcrumbs) - the source's own join.
    const breadcrumbs: string = Localization.concatenateStringsWith(' > ',
      entry.breadcrumbRes.map((name: string): string => Localization.getString(name)));

    const item: PreferenceSearchItem = new PreferenceSearchItem(
      entry.key, title, summary, entries, breadcrumbs, entry.screen);
    // `result.hasData()` - the parser only kept items carrying both a key and a title.
    if (item.hasData()) {
      items.push(item);
    }
  }
  searcher.add(items);

  return searcher;
}
