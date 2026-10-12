/*
 * Port of org.schabi.newpipe.extractor.localization.TimeAgoPatternsManager and
 * org.schabi.newpipe.extractor.timeago.PatternsManager (NewPipeExtractor v0.26.5).
 */

import { Localization } from '../downloader/Localization';
import { getPatterns, PatternsHolder } from './TimeAgoPatterns';
import { TimeAgoParser } from './TimeAgoParser';

export class TimeAgoPatternsManager {
  private static getPatternsFor(localization: Localization): PatternsHolder | null {
    return getPatterns(localization.getLanguageCode(), localization.getCountryCode());
  }

  /** Null when this localization has no ago-phrases, which is what the fallback keys on. */
  static getTimeAgoParserFor(localization: Localization,
    now: Date = new Date()): TimeAgoParser | null {
    const holder: PatternsHolder | null = TimeAgoPatternsManager.getPatternsFor(localization);
    return holder === null ? null : new TimeAgoParser(holder, now);
  }
}
