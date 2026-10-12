/*
 * Port of org.schabi.newpipe.extractor.services.youtube.extractors.YoutubeStreamInfoItemExtractor
 * (NewPipeExtractor v0.26.5).
 *
 * THE stream row reader: every field StreamInfoItemsCollector.extract() reads comes from here, so
 * a getter dropped here renders as a blank thumbnail or a 0 count on every list in the app. Every
 * one of the source's getters is present.
 *
 * java.time.Instant becomes Date (milliseconds), and the premiere date is formatted as
 * `yyyy-MM-dd HH:mm` by hand — HarmonyOS has no DateTimeFormatter pattern API and this string is
 * parsed straight back by the caller, so its shape is load-bearing.
 */

import { JsonObject } from '../../../json/NanoJson';
import { StreamInfoItemExtractor } from '../../../info/StreamInfoItemExtractor';
import { JsonUtils } from '../../../core/JsonUtils';
import { Parser } from '../../../core/Parser';
import { ParsingException } from '../../../exceptions/Exceptions';
import { DateWrapper } from '../../../localization/DateWrapper';
import { TimeAgoParser } from '../../../localization/TimeAgoParser';
import {
  isNullOrEmpty,
  mixedNumberWordToLong,
  removeNonDigitCharacters
} from '../../../core/Utils';
import { ContentAvailability } from '../../../../../model/extractor/ContentAvailability';
import { Image } from '../../../../../model/extractor/Image';
import { StreamType } from '../../../../../model/enums/StreamType';
import {
  getImagesFromThumbnailsArray,
  getTextFromObject,
  getThumbnailsFromInfoItem,
  getUrlFromNavigationEndpoint,
  isVerified,
  parseDurationString
} from '../YoutubeParsingHelper';
import { YoutubeStreamLinkHandlerFactory } from '../linkHandler/YoutubeStreamLinkHandlerFactory';

const ACCESSIBILITY_DATA_VIEW_COUNT_REGEX: RegExp = new RegExp('([\\d,]+) views$');
const NO_VIEWS_LOWERCASE: string = 'no views';

/** Pad to two digits, for the premiere date string. */
function pad2(value: number): string {
  return value < 10 ? '0' + value : '' + value;
}

export class YoutubeStreamInfoItemExtractor extends StreamInfoItemExtractor {
  private readonly videoInfo: JsonObject;
  private readonly timeAgoParser: TimeAgoParser | null;
  private cachedStreamType: StreamType | null = null;
  private premiere: boolean | null = null;

  constructor(videoInfoItem: JsonObject, timeAgoParser: TimeAgoParser | null) {
    super();
    this.videoInfo = videoInfoItem;
    this.timeAgoParser = timeAgoParser;
  }

  getStreamType(): StreamType {
    if (this.cachedStreamType !== null) {
      return this.cachedStreamType;
    }

    for (const badgeRenderer of this.videoInfo.getArray('badges').streamAsJsonObjects()) {
      const renderer: JsonObject = badgeRenderer.getObject('metadataBadgeRenderer');
      if (renderer.getString('style', '') === 'BADGE_STYLE_TYPE_LIVE_NOW'
        || renderer.getString('label', '') === 'LIVE NOW') {
        this.cachedStreamType = StreamType.LIVE_STREAM;
        return this.cachedStreamType;
      }
    }

    for (const overlay of this.videoInfo.getArray('thumbnailOverlays').streamAsJsonObjects()) {
      const style: string = overlay.getObject('thumbnailOverlayTimeStatusRenderer')
        .getString('style', '') as string;
      if (style.toUpperCase() === 'LIVE') {
        this.cachedStreamType = StreamType.LIVE_STREAM;
        return this.cachedStreamType;
      }
    }

    this.cachedStreamType = StreamType.VIDEO_STREAM;
    return this.cachedStreamType;
  }

  isAd(): boolean {
    return this.isPremium() || this.getName() === '[Private video]'
      || this.getName() === '[Deleted video]';
  }

  getUrl(): string {
    try {
      const videoId: string = this.videoInfo.getString('videoId', '') as string;
      return YoutubeStreamLinkHandlerFactory.getInstance().getUrl(videoId);
    } catch (e) {
      throw new ParsingException('Could not get url', e instanceof Error ? e as Error : null);
    }
  }

  getName(): string {
    const title: JsonObject = this.videoInfo.getObject('title');
    const name: string | null = getTextFromObject(title);
    if (!isNullOrEmpty(name)) {
      return name as string;
    }
    // Videos can have no title, e.g. https://www.youtube.com/watch?v=nc1kN8ZSfGQ
    if (title.size() > 0 && !title.has('runs')) {
      return '';
    }
    throw new ParsingException('Could not get name');
  }

  getDuration(): number {
    if (this.getStreamType() === StreamType.LIVE_STREAM) {
      return -1;
    }

    let duration: string | null = getTextFromObject(this.videoInfo.getObject('lengthText'));
    if (isNullOrEmpty(duration)) {
      // Available in playlists for videos
      duration = this.videoInfo.getString('lengthSeconds');

      if (isNullOrEmpty(duration)) {
        for (const thumbnailOverlay of this.videoInfo.getArray('thumbnailOverlays')
          .streamAsJsonObjects()) {
          if (!thumbnailOverlay.has('thumbnailOverlayTimeStatusRenderer')) {
            continue;
          }
          const timeOverlayText: string | null = getTextFromObject(
            thumbnailOverlay.getObject('thumbnailOverlayTimeStatusRenderer').getObject('text'));
          if (isNullOrEmpty(timeOverlayText)) {
            continue;
          }
          try {
            return parseDurationString(timeOverlayText as string);
          } catch (ex) {
            // try the next overlay
          }
        }
      }

      if (isNullOrEmpty(duration)) {
        if (this.isPremiere()) {
          // Premieres can be livestreams, so their duration is not available
          return -1;
        }
        throw new ParsingException('Could not get duration');
      }
    }

    return parseDurationString(duration as string);
  }

  getUploaderName(): string {
    let name: string | null = getTextFromObject(this.videoInfo.getObject('longBylineText'));
    if (isNullOrEmpty(name)) {
      name = getTextFromObject(this.videoInfo.getObject('ownerText'));
      if (isNullOrEmpty(name)) {
        name = getTextFromObject(this.videoInfo.getObject('shortBylineText'));
        if (isNullOrEmpty(name)) {
          throw new ParsingException('Could not get uploader name');
        }
      }
    }
    return name as string;
  }

  getUploaderUrl(): string {
    let url: string | null = getUrlFromNavigationEndpoint(
      this.videoInfo.getObject('longBylineText').getArray('runs').getObject(0)
        .getObject('navigationEndpoint'));
    if (isNullOrEmpty(url)) {
      url = getUrlFromNavigationEndpoint(
        this.videoInfo.getObject('ownerText').getArray('runs').getObject(0)
          .getObject('navigationEndpoint'));
      if (isNullOrEmpty(url)) {
        url = getUrlFromNavigationEndpoint(
          this.videoInfo.getObject('shortBylineText').getArray('runs').getObject(0)
            .getObject('navigationEndpoint'));
        if (isNullOrEmpty(url)) {
          throw new ParsingException('Could not get uploader url');
        }
      }
    }
    return url as string;
  }

  getUploaderAvatars(): Image[] {
    if (this.videoInfo.has('channelThumbnailSupportedRenderers')) {
      return getImagesFromThumbnailsArray(JsonUtils.getArray(this.videoInfo,
        'channelThumbnailSupportedRenderers.channelThumbnailWithLinkRenderer.thumbnail'
        + '.thumbnails'));
    }
    if (this.videoInfo.has('channelThumbnail')) {
      return getImagesFromThumbnailsArray(
        JsonUtils.getArray(this.videoInfo, 'channelThumbnail.thumbnails'));
    }
    return [];
  }

  isUploaderVerified(): boolean {
    return isVerified(this.videoInfo.getArray('ownerBadges'));
  }

  getTextualUploadDate(): string | null {
    if (this.getStreamType() === StreamType.LIVE_STREAM) {
      return null;
    }

    if (this.isPremiere()) {
      // The source formats the premiere instant with DateTimeFormatter "yyyy-MM-dd HH:mm" in the
      // system zone; Date's local getters are already in the system zone
      const start: Date = this.getInstantFromPremiere();
      return start.getFullYear() + '-' + pad2(start.getMonth() + 1) + '-' + pad2(start.getDate())
        + ' ' + pad2(start.getHours()) + ':' + pad2(start.getMinutes());
    }

    let publishedTimeText: string | null =
      getTextFromObject(this.videoInfo.getObject('publishedTimeText'));
    if (isNullOrEmpty(publishedTimeText) && this.videoInfo.has('videoInfo')) {
      // Returned in playlists, in the form: view count, separator, upload date
      publishedTimeText = this.videoInfo.getObject('videoInfo')
        .getArray('runs')
        .getObject(2)
        .getString('text');
    }

    return isNullOrEmpty(publishedTimeText) ? null : publishedTimeText;
  }

  getUploadDate(): DateWrapper | null {
    if (this.getStreamType() === StreamType.LIVE_STREAM) {
      return null;
    }
    if (this.isPremiere()) {
      return new DateWrapper(this.getInstantFromPremiere());
    }

    const textualUploadDate: string | null = this.getTextualUploadDate();
    if (this.timeAgoParser !== null && !isNullOrEmpty(textualUploadDate)) {
      try {
        return this.timeAgoParser.parse(textualUploadDate as string);
      } catch (e) {
        throw new ParsingException('Could not get upload date',
          e instanceof Error ? e as Error : null);
      }
    }
    return null;
  }

  getViewCount(): number {
    if (this.isPremium() || this.isPremiere()) {
      return -1;
    }

    // Every failure below is ignored: creators can hide the view count, in which case none of
    // these shapes carries it
    const viewCountText: string | null =
      getTextFromObject(this.videoInfo.getObject('viewCountText'));
    if (!isNullOrEmpty(viewCountText)) {
      try {
        return this.getViewCountFromViewCountText(viewCountText as string, false);
      } catch (ignored) {
        // fall through
      }
    }

    // The accessibility data carries the real view count, except on a running livestream where it
    // is the current watcher count instead
    if (this.getStreamType() !== StreamType.LIVE_STREAM) {
      try {
        return this.getViewCountFromAccessibilityData();
      } catch (ignored) {
        // fall through
      }
    }

    // Fall back to a short view count, always used for livestreams (see above)
    if (this.videoInfo.has('videoInfo')) {
      // Returned in playlists, in the form: view count, separator, upload date
      try {
        return this.getViewCountFromViewCountText(this.videoInfo.getObject('videoInfo')
          .getArray('runs')
          .getObject(0)
          .getString('text', '') as string, true);
      } catch (ignored) {
        // fall through
      }
    }

    if (this.videoInfo.has('shortViewCountText')) {
      // Returned everywhere but in playlists; what the website shows
      try {
        const shortViewCountText: string | null =
          getTextFromObject(this.videoInfo.getObject('shortViewCountText'));
        if (!isNullOrEmpty(shortViewCountText)) {
          return this.getViewCountFromViewCountText(shortViewCountText as string, true);
        }
      } catch (ignored) {
        // fall through
      }
    }

    // No view count extracted: creators can hide it
    return -1;
  }

  private getViewCountFromViewCountText(viewCountText: string, isMixedNumber: boolean): number {
    // These approaches are language dependent
    const lowered: string = viewCountText.toLowerCase();
    if (lowered.includes(NO_VIEWS_LOWERCASE)) {
      return 0;
    }
    if (lowered.includes('recommended')) {
      return -1;
    }
    if (isMixedNumber) {
      return mixedNumberWordToLong(viewCountText);
    }
    const parsed: number = Number.parseInt(removeNonDigitCharacters(viewCountText), 10);
    if (Number.isNaN(parsed)) {
      throw new ParsingException('Could not parse view count: ' + viewCountText);
    }
    return parsed;
  }

  private getViewCountFromAccessibilityData(): number {
    // These approaches are language dependent
    const videoInfoTitleAccessibilityData: string = this.videoInfo.getObject('title')
      .getObject('accessibility')
      .getObject('accessibilityData')
      .getString('label', '') as string;

    if (videoInfoTitleAccessibilityData.toLowerCase().endsWith(NO_VIEWS_LOWERCASE)) {
      return 0;
    }

    const parsed: number = Number.parseInt(removeNonDigitCharacters(
      Parser.matchGroup1(ACCESSIBILITY_DATA_VIEW_COUNT_REGEX, videoInfoTitleAccessibilityData)),
      10);
    if (Number.isNaN(parsed)) {
      throw new ParsingException('Could not parse view count from accessibility data');
    }
    return parsed;
  }

  getThumbnails(): Image[] {
    return getThumbnailsFromInfoItem(this.videoInfo);
  }

  private isPremium(): boolean {
    for (const badge of this.videoInfo.getArray('badges').streamAsJsonObjects()) {
      if (badge.getObject('metadataBadgeRenderer').getString('label', '') === 'Premium') {
        return true;
      }
    }
    return false;
  }

  private isPremiere(): boolean {
    if (this.premiere === null) {
      this.premiere = this.videoInfo.has('upcomingEventData');
    }
    return this.premiere;
  }

  private getInstantFromPremiere(): Date {
    const upcomingEventData: JsonObject = this.videoInfo.getObject('upcomingEventData');
    const startTime: string = upcomingEventData.getString('startTime', '') as string;
    const epochSeconds: number = Number.parseInt(startTime, 10);
    if (Number.isNaN(epochSeconds)) {
      throw new ParsingException('Could not parse date from premiere: \"' + startTime + '\"');
    }
    return new Date(epochSeconds * 1000);
  }

  getShortDescription(): string | null {
    if (this.videoInfo.has('detailedMetadataSnippets')) {
      return getTextFromObject(this.videoInfo.getArray('detailedMetadataSnippets')
        .getObject(0)
        .getObject('snippetText'));
    }
    if (this.videoInfo.has('descriptionSnippet')) {
      return getTextFromObject(this.videoInfo.getObject('descriptionSnippet'));
    }
    return null;
  }

  isShortFormContent(): boolean {
    try {
      const webPageType: string | null = this.videoInfo.getObject('navigationEndpoint')
        .getObject('commandMetadata')
        .getObject('webCommandMetadata')
        .getString('webPageType');
      let isShort: boolean = !isNullOrEmpty(webPageType)
        && webPageType === 'WEB_PAGE_TYPE_SHORTS';

      if (!isShort) {
        isShort = this.videoInfo.getObject('navigationEndpoint').has('reelWatchEndpoint');
      }

      if (!isShort && this.videoInfo.has('thumbnailOverlays')) {
        for (const thumbnailOverlay of this.videoInfo.getArray('thumbnailOverlays')
          .streamAsJsonObjects()) {
          if (!thumbnailOverlay.has('thumbnailOverlayTimeStatusRenderer')) {
            continue;
          }
          const timeOverlay: JsonObject =
            thumbnailOverlay.getObject('thumbnailOverlayTimeStatusRenderer');
          const style: string = timeOverlay.getString('style', '') as string;
          const iconType: string = timeOverlay.getObject('icon')
            .getString('iconType', '') as string;
          if (style.toUpperCase() === 'SHORTS' || iconType.toLowerCase().includes('shorts')) {
            isShort = true;
            break;
          }
        }
      }

      return isShort;
    } catch (e) {
      throw new ParsingException('Could not determine if this is short-form content',
        e instanceof Error ? e as Error : null);
    }
  }

  private isMembersOnly(): boolean {
    for (const badge of this.videoInfo.getArray('badges').streamAsJsonObjects()) {
      if (badge.getObject('metadataBadgeRenderer').getString('style')
        === 'BADGE_STYLE_TYPE_MEMBERS_ONLY') {
        return true;
      }
    }
    return false;
  }

  getContentAvailability(): ContentAvailability {
    if (this.isPremiere()) {
      return ContentAvailability.UPCOMING;
    }
    if (this.isMembersOnly()) {
      return ContentAvailability.MEMBERSHIP;
    }
    if (this.isPremium()) {
      return ContentAvailability.PAID;
    }
    return ContentAvailability.AVAILABLE;
  }
}
