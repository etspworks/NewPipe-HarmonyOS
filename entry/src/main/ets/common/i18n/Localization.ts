/*
 * svc_localization - port of app/src/main/java/org/schabi/newpipe/util/Localization.java.
 *
 * The Java class is a static utility that takes a Context on every call. Here the context and the
 * preference store are handed in once (ServiceLocator.init) and every method keeps the source's
 * signature minus the Context, so the call sites read the same.
 *
 * Mapping of what the source used:
 *   - NumberFormat / CompactDecimalFormat -> `Intl.NumberFormat` (`notation: 'compact'`).
 *   - Resources.getQuantityString(pluralId, count, arg) -> `resourceManager
 *     .getIntPluralStringByNameSync(name, count, arg)`, keyed by the source's own plural NAME,
 *     which the assets pass carried into resources/base/element/plural.json.
 *   - DateUtils.formatElapsedTime -> the same h:mm:ss / m:ss shape, written out below.
 *   - PrettyTime -> the port in common/i18n/PrettyTime.ts.
 *   - BidiFormatter.unicodeWrap -> the Unicode isolate characters it inserts (U+2068 / U+2069),
 *     which is what makes an RTL @username read naturally.
 *   - AppCompatDelegate.getApplicationLocales() has no analogue: the app language is the
 *     app_language_key preference (migrated by migrateAppLanguageSettingIfNecessary) falling
 *     back to the system locale.
 */

import { common } from '@kit.AbilityKit';
import { i18n, intl } from '@kit.LocalizationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppPreferences } from '../prefs/Preferences';
import { PrettyTime, TimeUnitKind } from './PrettyTime';
import {
  app_language_key,
  content_country_key,
  content_language_key,
  default_localization_key,
  show_original_time_ago_key
} from '../prefs/SettingsKeys';

/** ListExtractor.ITEM_COUNT_UNKNOWN / _INFINITE / _MORE_THAN_100, verbatim. */
export const ITEM_COUNT_UNKNOWN: number = -1;
export const ITEM_COUNT_INFINITE: number = -2;
export const ITEM_COUNT_MORE_THAN_100: number = -3;

/** Localization.DOT_SEPARATOR, verbatim. */
export const DOT_SEPARATOR: string = ' • ';

const FIRST_STRONG_ISOLATE: string = '⁨';
const POP_DIRECTIONAL_ISOLATE: string = '⁩';

export class Localization {
  private static context: common.Context | null = null;
  private static prefs: AppPreferences | null = null;
  private static prettyTime: PrettyTime | null = null;
  private static debug: boolean = false;

  /** Called once from EntryAbility through ServiceLocator. */
  static init(context: common.Context, prefs: AppPreferences, debug: boolean = false): void {
    Localization.context = context;
    Localization.prefs = prefs;
    Localization.debug = debug;
    Localization.initPrettyTime(Localization.resolvePrettyTime());
  }

  private static requireContext(): common.Context {
    const ctx: common.Context | null = Localization.context;
    if (ctx === null) {
      throw new Error('Localization used before ServiceLocator.init()');
    }
    return ctx;
  }

  private static requirePrefs(): AppPreferences {
    const prefs: AppPreferences | null = Localization.prefs;
    if (prefs === null) {
      throw new Error('Localization used before ServiceLocator.init()');
    }
    return prefs;
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Resources
  ////////////////////////////////////////////////////////////////////////// */

  /** One migrated string, by the source's `<string name=...>`. */
  static getString(name: string): string {
    try {
      return Localization.requireContext().resourceManager.getStringByNameSync(name);
    } catch (err) {
      return name;
    }
  }

  /** One migrated string with format arguments. */
  /**
   * A button label the way the platform theme renders it. Widget.AppCompat.Button carries
   * android:textAllCaps="true", so every Button in the source shows its label uppercased -
   * "RETRY", not "Retry" - while the string resource itself stays sentence case. ArkUI has no
   * such attribute, so the screens ported the resource straight and lost the casing.
   *
   * Uppercasing is locale-aware, which is why this goes through the app locale rather than
   * String.toUpperCase(): the same rule AppCompat applies.
   */
  static buttonLabel(name: string): string {
    return Localization.getString(name).toLocaleUpperCase(Localization.getAppLocale());
  }

  static getStringArgs(name: string, args: Array<string | number>): string {
    try {
      return Localization.requireContext().resourceManager.getStringByNameSync(name, ...args);
    } catch (err) {
      return name;
    }
  }

  /**
   * Port of the private getQuantity(context, pluralId, zeroCaseStringId, count, formattedCount).
   * `zeroCaseName` is '' where the source passed 0 for the zero-case resource. Public here
   * because svc_notification needs the same plural lookup for `new_streams`.
   */
  static getQuantity(pluralName: string, zeroCaseName: string, count: number,
    formattedCount: string | number): string {
    if (count === 0 && zeroCaseName.length > 0) {
      return Localization.getString(zeroCaseName);
    }
    // as in the source: the already formatted count is substituted, and the count itself is
    // clamped into int range only to pick the plural form
    const safeCount: number = Math.max(-2147483648, Math.min(2147483647, Math.trunc(count)));
    try {
      return Localization.requireContext().resourceManager
        .getIntPluralStringByNameSync(pluralName, safeCount, formattedCount);
    } catch (err) {
      // The format argument has to match the plural's own placeholder: the %s plurals (views,
      // subscribers, new_streams...) take the pre-formatted string, the %d ones (days, hours,
      // minutes, seconds) take the number. A mismatch throws here, and falling back to the bare
      // count is how a whole duration lost its unit unnoticed - so it is reported now.
      hilog.warn(0x0000, 'Localization', 'plural %{public}s not formatted: %{public}s',
        pluralName, (err as Error).message);
      return `${formattedCount}`;
    }
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Locales
  ////////////////////////////////////////////////////////////////////////// */

  /** Port of getAppLocale(): the app_language_key preference, else the system locale. */
  static getAppLocale(): string {
    const custom: string = Localization.requirePrefs().getStringSync(app_language_key, '');
    if (custom.length > 0 && custom !== Localization.getString(default_localization_key)) {
      return custom;
    }
    return i18n.System.getSystemLocale();
  }

  /** Port of the private getLocaleFromPrefs(context, prefKey). */
  private static getLocaleFromPrefs(prefKey: string): string {
    const defaultKey: string = Localization.getString(default_localization_key);
    const languageCode: string = Localization.requirePrefs().getStringSync(prefKey, defaultKey);
    return languageCode === defaultKey ? i18n.System.getSystemLocale() : languageCode;
  }

  /** Port of getPreferredLocale(context). */
  static getPreferredLocale(): string {
    return Localization.getLocaleFromPrefs(content_language_key);
  }

  /**
   * Port of getPreferredLocalization(context): the extractor's Localization is a
   * languageCode[-countryCode] pair, which is exactly the BCP-47 tag the preference holds.
   */
  static getPreferredLocalization(): string {
    return Localization.getPreferredLocale();
  }

  /** Port of getPreferredContentCountry(context). */
  static getPreferredContentCountry(): string {
    const defaultKey: string = Localization.getString(default_localization_key);
    const contentCountry: string =
      Localization.requirePrefs().getStringSync(content_country_key, defaultKey);
    if (contentCountry === defaultKey) {
      return new intl.Locale(i18n.System.getSystemLocale()).region;
    }
    return contentCountry;
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Strings and numbers
  ////////////////////////////////////////////////////////////////////////// */

  /** Port of concatenateStrings(String...): joins the non-empty parts with DOT_SEPARATOR. */
  static concatenateStrings(strings: string[]): string {
    return Localization.concatenateStringsWith(DOT_SEPARATOR, strings);
  }

  /** Port of concatenateStrings(delimiter, List). */
  static concatenateStringsWith(delimiter: string, strings: string[]): string {
    const kept: string[] = [];
    for (const s of strings) {
      if (s.length > 0) {
        kept.push(s);
      }
    }
    return kept.join(delimiter);
  }

  /**
   * Port of localizeUserName(): wraps the name in Unicode isolates so a right-to-left
   * `@username` puts the @ on the right and reads naturally.
   */
  static localizeUserName(plainName: string): string {
    return `${FIRST_STRONG_ISOLATE}${plainName}${POP_DIRECTIONAL_ISOLATE}`;
  }

  /** Port of localizeNumber(long) / localizeNumber(double). */
  static localizeNumber(value: number): string {
    return new intl.NumberFormat(Localization.getAppLocale()).format(value);
  }

  /** Port of formatDate(OffsetDateTime) with FormatStyle.MEDIUM. */
  static formatDate(epochMillis: number): string {
    const options: intl.DateTimeOptions = {
      year: 'numeric', month: 'short', day: 'numeric'
    };
    return new intl.DateTimeFormat(Localization.getAppLocale(), options)
      .format(new Date(epochMillis));
  }

  /**
   * Port of shortCount(context, count) - CompactDecimalFormat.CompactStyle.SHORT.
   *
   * No fraction-digit option on purpose. Compact notation without one rounds to two SIGNIFICANT
   * digits, which is what CompactDecimalFormat does: 1200 -> 1.2K, 19_200_000 -> 19M. Naming
   * maximumFractionDigits overrides that significant-digit rule and pins a decimal on every
   * magnitude, which is where the extra ".2" in 19.2M came from.
   */
  static shortCount(count: number): string {
    const options: intl.NumberOptions = { notation: 'compact', compactDisplay: 'short' };
    return new intl.NumberFormat(Localization.getAppLocale(), options).format(count);
  }

  static localizeViewCount(viewCount: number): string {
    return Localization.getQuantity('views', 'no_views', viewCount,
      Localization.localizeNumber(viewCount));
  }

  static localizeStreamCount(streamCount: number): string {
    if (streamCount === ITEM_COUNT_UNKNOWN) {
      return '';
    }
    if (streamCount === ITEM_COUNT_INFINITE) {
      return Localization.getString('infinite_videos');
    }
    if (streamCount === ITEM_COUNT_MORE_THAN_100) {
      return Localization.getString('more_than_100_videos');
    }
    return Localization.getQuantity('videos', 'no_videos', streamCount,
      Localization.localizeNumber(streamCount));
  }

  static localizeStreamCountMini(streamCount: number): string {
    if (streamCount === ITEM_COUNT_UNKNOWN) {
      return '';
    }
    if (streamCount === ITEM_COUNT_INFINITE) {
      return Localization.getString('infinite_videos_mini');
    }
    if (streamCount === ITEM_COUNT_MORE_THAN_100) {
      return Localization.getString('more_than_100_videos_mini');
    }
    return `${streamCount}`;
  }

  static localizeWatchingCount(watchingCount: number): string {
    return Localization.getQuantity('watching', 'no_one_watching', watchingCount,
      Localization.localizeNumber(watchingCount));
  }

  static listeningCount(listeningCount: number): string {
    return Localization.getQuantity('listening', 'no_one_listening', listeningCount,
      Localization.shortCount(listeningCount));
  }

  static shortWatchingCount(watchingCount: number): string {
    return Localization.getQuantity('watching', 'no_one_watching', watchingCount,
      Localization.shortCount(watchingCount));
  }

  static shortViewCount(viewCount: number): string {
    return Localization.getQuantity('views', 'no_views', viewCount,
      Localization.shortCount(viewCount));
  }

  static shortSubscriberCount(subscriberCount: number): string {
    return Localization.getQuantity('subscribers', 'no_subscribers', subscriberCount,
      Localization.shortCount(subscriberCount));
  }

  static downloadCount(downloadCount: number): string {
    return Localization.getQuantity('download_finished_notification', '', downloadCount,
      Localization.shortCount(downloadCount));
  }

  static deletedDownloadCount(deletedCount: number): string {
    return Localization.getQuantity('deleted_downloads_toast', '', deletedCount,
      Localization.shortCount(deletedCount));
  }

  static replyCount(replyCount: number): string {
    return Localization.getQuantity('replies', '', replyCount, `${replyCount}`);
  }

  /** Port of likeCount(): '-' when the like count is unknown (negative). */
  static likeCount(likeCount: number): string {
    return likeCount < 0 ? '-' : Localization.shortCount(likeCount);
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Durations
  ////////////////////////////////////////////////////////////////////////// */

  /**
   * Port of getDurationString(long) -> DateUtils.formatElapsedTime: `m:ss` below an hour,
   * `h:mm:ss` above it, and `00:00` for zero.
   */
  static getDurationString(duration: number): string {
    const total: number = Math.max(Math.trunc(duration), 0);
    const hours: number = Math.trunc(total / 3600);
    const minutes: number = Math.trunc((total % 3600) / 60);
    const seconds: number = total % 60;
    const ss: string = seconds < 10 ? `0${seconds}` : `${seconds}`;
    if (hours > 0) {
      const mm: string = minutes < 10 ? `0${minutes}` : `${minutes}`;
      return `${hours}:${mm}:${ss}`;
    }
    const mm: string = minutes < 10 ? `0${minutes}` : `${minutes}`;
    return `${mm}:${ss}`;
  }

  /** Port of getDurationString(duration, isDurationComplete, showDurationPrefix). */
  static getDurationStringDetailed(duration: number, isDurationComplete: boolean,
    showDurationPrefix: boolean): string {
    const output: string = Localization.getDurationString(duration);
    const durationPrefix: string = showDurationPrefix ? '⏱ ' : '';
    const durationPostfix: string = isDurationComplete ? '' : '+';
    return `${durationPrefix}${output}${durationPostfix}`;
  }

  /** Port of localizeDuration(context, durationInSecs). */
  static localizeDuration(durationInSecs: number): string {
    if (durationInSecs < 0) {
      throw new Error('duration can not be negative');
    }
    const days: number = Math.trunc(durationInSecs / 86400);
    const hours: number = Math.trunc((durationInSecs % 86400) / 3600);
    const minutes: number = Math.trunc((durationInSecs % 86400 % 3600) / 60);
    const seconds: number = durationInSecs % 86400 % 3600 % 60;

    // days/hours/minutes/seconds are the '%d unit' plurals, so the count goes in as a NUMBER.
    // Handing them the formatted string made getIntPluralStringByNameSync throw, and getQuantity
    // then fell back to the bare count - which is why every duration on this screen and on
    // Settings > Notifications read '15' rather than '15 minutes'.
    if (days > 0) {
      return Localization.getQuantity('days', '', days, days);
    }
    if (hours > 0) {
      return Localization.getQuantity('hours', '', hours, hours);
    }
    if (minutes > 0) {
      return Localization.getQuantity('minutes', '', minutes, minutes);
    }
    return Localization.getQuantity('seconds', '', seconds, seconds);
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Relative time
  ////////////////////////////////////////////////////////////////////////// */

  /** Port of resolvePrettyTime(). */
  static resolvePrettyTime(): PrettyTime {
    return new PrettyTime(Localization.getAppLocale());
  }

  /** Port of initPrettyTime(): NewPipe removes DECADE, "as YouTube doesn't either". */
  static initPrettyTime(time: PrettyTime): void {
    time.removeUnit(TimeUnitKind.DECADE);
    Localization.prettyTime = time;
  }

  /** Port of relativeTime(OffsetDateTime); the argument is epoch milliseconds. */
  static relativeTime(epochMillis: number): string {
    let time: PrettyTime | null = Localization.prettyTime;
    if (time === null) {
      time = Localization.resolvePrettyTime();
      Localization.initPrettyTime(time);
    }
    return time.formatUnrounded(epochMillis);
  }

  /**
   * Port of relativeTimeOrTextual(context, parsed, textual): the parsed date when the extractor
   * could parse one, the service's own text otherwise; in debug mode with
   * show_original_time_ago_key enabled, both.
   */
  static relativeTimeOrTextual(parsedEpochMillis: number | null,
    textual: string | null): string | null {
    if (parsedEpochMillis === null) {
      return textual;
    }
    const relative: string = Localization.relativeTime(parsedEpochMillis);
    if (Localization.debug
      && Localization.requirePrefs().getBooleanSync(show_original_time_ago_key, false)) {
      return `${relative} (${textual})`;
    }
    return relative;
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Migration
  ////////////////////////////////////////////////////////////////////////// */

  /**
   * Port of migrateAppLanguageSettingIfNecessary(context). The source moved a custom app language
   * out of SharedPreferences into Android's per-app language API; HarmonyOS has no such API, so
   * the preference IS the app language here and the migration only has to normalise the
   * "system default" sentinel away so getAppLocale() falls through to the system locale.
   */
  static migrateAppLanguageSettingIfNecessary(): void {
    const prefs: AppPreferences = Localization.requirePrefs();
    const value: string = prefs.getStringSync(app_language_key, '');
    if (value.length === 0) {
      return;
    }
    if (value === Localization.getString(default_localization_key)) {
      prefs.remove(app_language_key);
      prefs.flush().catch((): void => {
        // a failed flush leaves the sentinel in place; it is re-normalised on the next launch
      });
    }
  }
}
