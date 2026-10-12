/*
 * Port of org.schabi.newpipe.extractor.services.youtube.extractors
 * .YoutubeStreamInfoItemLockupExtractor (NewPipeExtractor v0.26.5).
 *
 * The newer, viewModel-shaped video row (`lockupViewModel`) that channel tabs and playlists now
 * return instead of `videoRenderer`.
 *
 * Two shape changes:
 *  - `JsonObject.getObject(key, null)` returns an EMPTY JsonObject in this port, never null, so
 *    the source's null checks become `has(...)` checks;
 *  - DateTimeFormatter `dd/MM/yyyy, HH:mm` at UTC is parsed by hand — HarmonyOS has no pattern
 *    parser and `new Date(string)` does not accept that format.
 */

import { JsonArray, JsonObject } from '../../../json/NanoJson';
import { StreamInfoItemExtractor } from '../../../info/StreamInfoItemExtractor';
import { JsonUtils } from '../../../core/JsonUtils';
import { ParsingException } from '../../../exceptions/Exceptions';
import { DateWrapper } from '../../../localization/DateWrapper';
import { TimeAgoParser } from '../../../localization/TimeAgoParser';
import { isNullOrEmpty, mixedNumberWordToLong } from '../../../core/Utils';
import { ContentAvailability } from '../../../../../model/extractor/ContentAvailability';
import { Image } from '../../../../../model/extractor/Image';
import { StreamType } from '../../../../../model/enums/StreamType';
import {
  getImagesFromThumbnailsArray,
  hasArtistOrVerifiedIconBadgeAttachment,
  parseDurationString
} from '../YoutubeParsingHelper';
import { YoutubeChannelLinkHandlerFactory } from '../linkHandler/YoutubeChannelLinkHandlerFactory';
import { YoutubeStreamLinkHandlerFactory } from '../linkHandler/YoutubeStreamLinkHandlerFactory';

const NO_VIEWS_LOWERCASE: string = 'no views';
// These two are language dependent (en-GB); the trailing space is deliberate
const PREMIERES_VIDEOS_TEXT: string = 'Premieres ';
const PREMIERES_LIVES_TEXT: string = 'Scheduled for ';
/** The source's DateTimeFormatter "dd/MM/yyyy, HH:mm". */
const PREMIERES_DATE_PATTERN: RegExp =
  new RegExp('^(\\d{2})/(\\d{2})/(\\d{4}), (\\d{2}):(\\d{2})$');

/** Where a lockup item's channel avatar and uploader link live, single- or multi-channel. */
abstract class ChannelImageViewModel {
  protected viewModel: JsonObject;

  constructor(viewModel: JsonObject) {
    this.viewModel = viewModel;
  }

  abstract forUploaderUrlExtraction(): JsonObject;

  abstract forAvatarExtraction(): JsonObject;
}

class SingleChannelImageViewModel extends ChannelImageViewModel {
  forUploaderUrlExtraction(): JsonObject {
    return this.viewModel;
  }

  forAvatarExtraction(): JsonObject {
    return this.viewModel.getObject('avatar');
  }
}

class MultiChannelImageViewModel extends ChannelImageViewModel {
  forUploaderUrlExtraction(): JsonObject {
    const listItems: JsonArray = this.viewModel.getObject('rendererContext')
      .getObject('commandContext')
      .getObject('onTap')
      .getObject('innertubeCommand')
      .getObject('showDialogCommand')
      .getObject('panelLoadingStrategy')
      .getObject('inlineContent')
      .getObject('dialogViewModel')
      .getObject('customContent')
      .getObject('listViewModel')
      .getArray('listItems');
    for (const item of listItems.streamAsJsonObjects()) {
      return item.getObject('listItemViewModel');
    }
    return new JsonObject();
  }

  forAvatarExtraction(): JsonObject {
    return this.viewModel.getArray('avatars').getObject(0);
  }
}

export class YoutubeStreamInfoItemLockupExtractor extends StreamInfoItemExtractor {
  private readonly lockupViewModel: JsonObject;
  private readonly timeAgoParser: TimeAgoParser | null;
  private readonly cachedMetadataRows: JsonArray;
  private cachedStreamType: StreamType | null = null;
  private cachedName: string | null = null;
  private cachedDateText: string | null = null;
  private cachedChannelImageViewModel: ChannelImageViewModel | null = null;

  constructor(lockupViewModel: JsonObject, timeAgoParser: TimeAgoParser | null) {
    super();
    this.lockupViewModel = lockupViewModel;
    this.timeAgoParser = timeAgoParser;
    this.cachedMetadataRows = lockupViewModel.getObject('metadata')
      .getObject('lockupMetadataViewModel')
      .getObject('metadata')
      .getObject('contentMetadataViewModel')
      .getArray('metadataRows');
  }

  /**
   * Whether this lockup item comes from a channel page or a course playlist, where YouTube omits
   * metadata rows a normal list would carry. Overridden by the channel-tab subclass.
   */
  protected isChannelOrCoursePlaylistLockupItem(): boolean {
    return false;
  }

  getStreamType(): StreamType {
    if (this.cachedStreamType === null) {
      this.cachedStreamType = this.determineStreamType();
    }
    return this.cachedStreamType;
  }

  private determineStreamType(): StreamType {
    const overlays: JsonArray =
      JsonUtils.getArray(this.lockupViewModel, 'contentImage.thumbnailViewModel.overlays');

    // thumbnailOverlayBadgeViewModel path (legacy/alternate overlay structure)
    for (const overlay of overlays.streamAsJsonObjects()) {
      for (const thumbnailBadge of overlay.getObject('thumbnailOverlayBadgeViewModel')
        .getArray('thumbnailBadges').streamAsJsonObjects()) {
        const vm: JsonObject = thumbnailBadge.getObject('thumbnailBadgeViewModel');
        if (vm.getString('badgeStyle') === 'THUMBNAIL_OVERLAY_BADGE_STYLE_LIVE') {
          return StreamType.LIVE_STREAM;
        }
        // Fallback: check for a live icon
        for (const source of vm.getObject('icon').getArray('sources').streamAsJsonObjects()) {
          if (source.getObject('clientResource').getString('imageName') === 'LIVE') {
            return StreamType.LIVE_STREAM;
          }
        }
      }
    }

    // thumbnailBottomOverlayViewModel path (the lockup format, for both duration and live)
    for (const overlay of overlays.streamAsJsonObjects()) {
      for (const badge of overlay.getObject('thumbnailBottomOverlayViewModel')
        .getArray('badges').streamAsJsonObjects()) {
        if (badge.getObject('thumbnailBadgeViewModel').getString('badgeStyle')
          === 'THUMBNAIL_OVERLAY_BADGE_STYLE_LIVE') {
          return StreamType.LIVE_STREAM;
        }
      }
    }

    return StreamType.VIDEO_STREAM;
  }

  isAd(): boolean {
    const name: string = this.getName();
    return name === '[Private video]' || name === '[Deleted video]';
  }

  getUrl(): string {
    try {
      let videoId: string | null = this.lockupViewModel.getString('contentId');
      if (isNullOrEmpty(videoId)) {
        videoId = JsonUtils.getString(this.lockupViewModel,
          'rendererContext.commandContext.onTap.innertubeCommand.watchEndpoint.videoId');
      }
      return YoutubeStreamLinkHandlerFactory.getInstance().getUrl(videoId as string);
    } catch (e) {
      throw new ParsingException('Could not get url', e instanceof Error ? e as Error : null);
    }
  }

  getName(): string {
    if (this.cachedName !== null) {
      return this.cachedName;
    }
    const name: string = JsonUtils.getString(this.lockupViewModel,
      'metadata.lockupMetadataViewModel.title.content');
    if (!isNullOrEmpty(name)) {
      this.cachedName = name;
      return name;
    }
    throw new ParsingException('Could not get name');
  }

  getDuration(): number {
    // Duration is only available for normal videos; premieres carry an approximation in their
    // accessibility label only
    if (this.isLive() || this.isPremiere()) {
      return -1;
    }

    const potentialDurations: string[] = [];
    for (const overlay of JsonUtils.getArray(this.lockupViewModel,
      'contentImage.thumbnailViewModel.overlays').streamAsJsonObjects()) {
      for (const badge of overlay.getObject('thumbnailBottomOverlayViewModel')
        .getArray('badges').streamAsJsonObjects()) {
        const text: string | null = badge.getObject('thumbnailBadgeViewModel').getString('text');
        if (text !== null) {
          potentialDurations.push(text);
        }
      }
    }

    if (potentialDurations.length === 0) {
      return -1;
    }

    let parsingException: ParsingException | null = null;
    for (const potentialDuration of potentialDurations) {
      if (!new RegExp('.*\\d.*').test(potentialDuration)) {
        continue;
      }
      try {
        return parseDurationString(potentialDuration);
      } catch (ex) {
        if (ex instanceof ParsingException) {
          parsingException = ex as ParsingException;
        } else {
          throw ex;
        }
      }
    }

    if (parsingException === null) {
      // e.g. only a "SHORTS" or "CC" badge was present, with no duration
      return -1;
    }
    throw new ParsingException('Could not get duration', parsingException);
  }

  getUploaderName(): string {
    const metadataRows: JsonArray[] = this.getMetadataPartsFromMetadataRows();
    if (metadataRows.length === 0) {
      throw new ParsingException('Could not get uploader name: no metadata row');
    }
    const uploaderName: string | null =
      this.getTextContentFromMetadataPart(metadataRows[0].getObject(0));
    if (isNullOrEmpty(uploaderName)) {
      throw new ParsingException('Could not get uploader name');
    }
    return uploaderName as string;
  }

  getUploaderUrl(): string {
    const innerTubeCommand: JsonObject = this.channelImageViewModel()
      .forUploaderUrlExtraction()
      .getObject('rendererContext')
      .getObject('commandContext')
      .getObject('onTap')
      .getObject('innertubeCommand');
    const browseEndpoint: JsonObject = innerTubeCommand.getObject('browseEndpoint');

    const channelId: string | null = browseEndpoint.getString('browseId');
    if (channelId !== null && channelId.startsWith('UC')) {
      return YoutubeChannelLinkHandlerFactory.getInstance().getUrl('channel/' + channelId);
    }

    const canonicalBaseUrl: string | null = browseEndpoint.getString('canonicalBaseUrl');
    if (!isNullOrEmpty(canonicalBaseUrl)) {
      return this.resolveUploaderUrlFromRelativeUrl(canonicalBaseUrl as string);
    }

    const webCommandMetadataUrl: string | null = innerTubeCommand.getObject('commandMetadata')
      .getObject('webCommandMetadata')
      .getString('url');
    if (!isNullOrEmpty(webCommandMetadataUrl)) {
      return this.resolveUploaderUrlFromRelativeUrl(webCommandMetadataUrl as string);
    }

    throw new ParsingException('Could not get uploader url');
  }

  private resolveUploaderUrlFromRelativeUrl(relativeUrl: string): string {
    return YoutubeChannelLinkHandlerFactory.getInstance().getUrl(
      relativeUrl.startsWith('/') ? relativeUrl.substring(1) : relativeUrl);
  }

  getUploaderAvatars(): Image[] {
    return getImagesFromThumbnailsArray(JsonUtils.getArray(
      this.channelImageViewModel().forAvatarExtraction(), 'avatarViewModel.image.sources'));
  }

  isUploaderVerified(): boolean {
    const metadataRows: JsonArray[] = this.getMetadataPartsFromMetadataRows();
    if (metadataRows.length === 0) {
      throw new ParsingException('Could not get uploader verified status: no metadata row');
    }
    return hasArtistOrVerifiedIconBadgeAttachment(metadataRows[0]
      .getObject(0)
      .getObject('text')
      .getArray('attachmentRuns'));
  }

  getTextualUploadDate(): string | null {
    // Live streams have no upload date
    if (this.isLive()) {
      return null;
    }
    const dateText: string = this.getDateText();
    if (this.isPremiere()) {
      return YoutubeStreamInfoItemLockupExtractor.getDateFromPremiere(dateText);
    }
    return dateText;
  }

  /** Strips the language-dependent premiere prefix off the upload-date metadata part. */
  private static getDateFromPremiere(dateText: string): string {
    return dateText.replace(PREMIERES_VIDEOS_TEXT, '').replace(PREMIERES_LIVES_TEXT, '');
  }

  getUploadDate(): DateWrapper | null {
    if (this.timeAgoParser === null) {
      return null;
    }
    const textualUploadDate: string | null = this.getTextualUploadDate();
    // null e.g. when a live stream is shown
    if (textualUploadDate === null) {
      return null;
    }

    if (this.isPremiere()) {
      const premiereDate: string =
        YoutubeStreamInfoItemLockupExtractor.getDateFromPremiere(this.getDateText());
      PREMIERES_DATE_PATTERN.lastIndex = 0;
      const match: RegExpExecArray | null = PREMIERES_DATE_PATTERN.exec(premiereDate);
      if (match === null) {
        throw new ParsingException('Could not parse premiere upload date');
      }
      // The request asks for a UTC offset of 0 minutes, so this is the UTC date
      const millis: number = Date.UTC(Number.parseInt(match[3], 10),
        Number.parseInt(match[2], 10) - 1, Number.parseInt(match[1], 10),
        Number.parseInt(match[4], 10), Number.parseInt(match[5], 10), 0);
      return new DateWrapper(new Date(millis), false);
    }

    return this.timeAgoParser.parse(textualUploadDate);
  }

  getViewCount(): number {
    if (this.isChannelsMembersOnlyOrFirst()) {
      // Members-only / members-first content does not report its view count. Checked first,
      // because a running members-only livestream on a channel has no metadata row at all.
      return -1;
    }

    const metadataPartsRows: JsonArray[] = this.getMetadataPartsFromMetadataRows();
    if (metadataPartsRows.length === 0) {
      // Running livestreams with no viewers on channels return no metadata part row (course
      // playlists should have no livestreams)
      if (this.isLive() && this.isChannelOrCoursePlaylistLockupItem()) {
        return 0;
      }
      throw new ParsingException('Could not get view count: no metadata part from metadata rows');
    }

    if (this.isPremiere()) {
      // For a premiere this number is the count of people currently waiting. Checked here because
      // isPremiere relies on metadataPartsRows.
      return -1;
    }

    if (this.isLive() && metadataPartsRows.length === 1
      && !this.isChannelOrCoursePlaylistLockupItem()) {
      // A single metadata part on a channel lockup item for a running livestream is the watching
      // count; otherwise this is a livestream with no viewer
      return 0;
    }

    const metadataPartsRow: JsonArray = metadataPartsRows[metadataPartsRows.length - 1];
    if (metadataPartsRow.size() === 0) {
      throw new ParsingException(
        'Could not get view count: no metadata part in the metadata parts array');
    }

    // The view count is always the first metadata part, then the date text. Members-only content
    // returns no view count, so its metadata row carries the date text only.
    const viewCountText: string | null =
      this.getTextContentFromMetadataPart(metadataPartsRow.getObject(0));
    if (isNullOrEmpty(viewCountText)) {
      throw new ParsingException('Could not get view count');
    }
    return YoutubeStreamInfoItemLockupExtractor.getViewCountFromViewCountText(
      viewCountText as string);
  }

  private static getViewCountFromViewCountText(viewCountText: string): number {
    // These approaches are language dependent
    const lowered: string = viewCountText.toLowerCase();
    if (lowered.includes(NO_VIEWS_LOWERCASE)) {
      return 0;
    }
    if (lowered.includes('recommended')) {
      return -1;
    }
    return mixedNumberWordToLong(viewCountText);
  }

  getThumbnails(): Image[] {
    return getImagesFromThumbnailsArray(JsonUtils.getArray(this.lockupViewModel,
      'contentImage.thumbnailViewModel.image.sources'));
  }

  getContentAvailability(): ContentAvailability {
    if (this.isChannelsMembersOnlyOrFirst()) {
      // Checked before isLive: a running members-only livestream would otherwise report the wrong
      // availability. This case had not been observed when the source was written.
      return ContentAvailability.MEMBERSHIP;
    }
    if (this.isLive()) {
      // Checked before isPremiere: a livestream has no date text, so getDateText (called by
      // isPremiere) would throw
      return ContentAvailability.AVAILABLE;
    }
    if (this.isPremiere()) {
      return ContentAvailability.UPCOMING;
    }
    return ContentAvailability.AVAILABLE;
  }

  private channelImageViewModel(): ChannelImageViewModel {
    if (this.cachedChannelImageViewModel === null) {
      this.cachedChannelImageViewModel = this.determineChannelImageViewModel();
    }
    return this.cachedChannelImageViewModel;
  }

  private determineChannelImageViewModel(): ChannelImageViewModel {
    const image: JsonObject = this.lockupViewModel.getObject('metadata')
      .getObject('lockupMetadataViewModel')
      .getObject('image');

    if (image.has('decoratedAvatarViewModel')) {
      return new SingleChannelImageViewModel(image.getObject('decoratedAvatarViewModel'));
    }
    if (image.has('avatarStackViewModel')) {
      return new MultiChannelImageViewModel(image.getObject('avatarStackViewModel'));
    }
    throw new ParsingException('Failed to determine channel image view model');
  }

  private getTextContentFromMetadataPart(metadataPart: JsonObject): string | null {
    return metadataPart.getObject('text').getString('content');
  }

  private isLive(): boolean {
    return this.getStreamType() !== StreamType.VIDEO_STREAM;
  }

  private isChannelsMembersOnlyOrFirst(): boolean {
    for (const row of this.cachedMetadataRows.streamAsJsonObjects()) {
      for (const badge of row.getArray('badges').streamAsJsonObjects()) {
        // also returned for members-first content
        if (badge.getObject('badgeViewModel').getString('badgeStyle') === 'BADGE_MEMBERS_ONLY') {
          return true;
        }
      }
    }
    return false;
  }

  private isPremiere(): boolean {
    const dateText: string = this.getDateText();
    return dateText.includes(PREMIERES_VIDEOS_TEXT) || dateText.includes(PREMIERES_LIVES_TEXT);
  }

  private getDateText(): string {
    if (this.cachedDateText !== null) {
      return this.cachedDateText;
    }

    const metadataPartsRows: JsonArray[] = this.getMetadataPartsFromMetadataRows();
    if (metadataPartsRows.length === 0) {
      throw new ParsingException('Could not get date text: no metadata part from metadata rows');
    }

    const metadataPartsRow: JsonArray = metadataPartsRows[metadataPartsRows.length - 1];
    if (metadataPartsRow.size() === 0) {
      throw new ParsingException(
        'Could not get date text: no metadata part in the metadata parts array');
    }

    // The view count is always the first metadata part, then the date text. Members-only content
    // returns no view count, so its metadata row carries the date text only.
    const dateText: string | null = this.getTextContentFromMetadataPart(
      metadataPartsRow.getObject(metadataPartsRow.size() - 1));
    this.cachedDateText = dateText === null ? '' : dateText;
    return this.cachedDateText;
  }

  private getMetadataPartsFromMetadataRows(): JsonArray[] {
    const metadataParts: JsonArray[] = [];
    for (let i = 0; i < this.cachedMetadataRows.size(); i++) {
      const metadataRow: JsonObject = this.cachedMetadataRows.getObject(i);
      if (metadataRow.has('metadataParts')) {
        metadataParts.push(metadataRow.getArray('metadataParts'));
      }
    }
    return metadataParts;
  }
}
