/*
 * Port of the "lockup" / "show" info-item extractors (NewPipeExtractor v0.26.5):
 *   YoutubeShortsLockupInfoItemExtractor, YoutubeBaseShowInfoItemExtractor,
 *   YoutubeShowRendererInfoItemExtractor, YoutubeMixOrPlaylistLockupInfoItemExtractor.
 *
 * These four read YouTube's newer viewModel-shaped rows. They share a module because they are
 * only ever constructed from the same renderers, by the same extractors.
 *
 * `null` uploader name/url in the source become '' here, since the ported
 * Stream/PlaylistInfoItemExtractor declare those non-null.
 */

import { JsonObject } from '../../../json/NanoJson';
import { StreamInfoItemExtractor } from '../../../info/StreamInfoItemExtractor';
import { PlaylistInfoItemExtractor } from '../../../info/PlaylistExtractor';
import { ITEM_COUNT_INFINITE } from '../../../core/ListExtractor';
import { ParsingException } from '../../../exceptions/Exceptions';
import { DateWrapper } from '../../../localization/DateWrapper';
import {
  isNullOrEmpty,
  mixedNumberWordToLong,
  removeNonDigitCharacters
} from '../../../core/Utils';
import { Image } from '../../../../../model/extractor/Image';
import { PlaylistType } from '../../../../../model/extractor/PlaylistType';
import { StreamType } from '../../../../../model/enums/StreamType';
import {
  extractPlaylistTypeFromPlaylistId,
  getImagesFromThumbnailsArray,
  getTextFromObject,
  getThumbnailsFromInfoItem,
  getUrlFromNavigationEndpoint,
  getUrlFromObject,
  hasArtistOrVerifiedIconBadgeAttachment
} from '../YoutubeParsingHelper';
import { YoutubePlaylistLinkHandlerFactory } from '../linkHandler/YoutubePlaylistLinkHandlerFactory';
import { YoutubeStreamLinkHandlerFactory } from '../linkHandler/YoutubeStreamLinkHandlerFactory';

export class YoutubeShortsLockupInfoItemExtractor extends StreamInfoItemExtractor {
  private readonly shortsLockupViewModel: JsonObject;

  constructor(shortsLockupViewModel: JsonObject) {
    super();
    this.shortsLockupViewModel = shortsLockupViewModel;
  }

  getName(): string {
    const name: string | null = this.shortsLockupViewModel.getObject('overlayMetadata')
      .getObject('primaryText')
      .getString('content');
    return name === null ? '' : name;
  }

  getUrl(): string {
    let videoId: string | null = this.shortsLockupViewModel.getObject('onTap')
      .getObject('innertubeCommand')
      .getObject('reelWatchEndpoint')
      .getString('videoId');

    if (isNullOrEmpty(videoId)) {
      videoId = this.shortsLockupViewModel.getObject('inlinePlayerData')
        .getObject('onVisible')
        .getObject('innertubeCommand')
        .getObject('watchEndpoint')
        .getString('videoId');
    }

    if (isNullOrEmpty(videoId)) {
      throw new ParsingException('Could not get video ID');
    }

    try {
      return YoutubeStreamLinkHandlerFactory.getInstance().getUrl(videoId as string);
    } catch (e) {
      throw new ParsingException('Could not get URL', e instanceof Error ? e as Error : null);
    }
  }

  getThumbnails(): Image[] {
    if (this.shortsLockupViewModel.has('thumbnail')) {
      return getImagesFromThumbnailsArray(
        this.shortsLockupViewModel.getObject('thumbnail').getArray('sources'));
    }
    return getImagesFromThumbnailsArray(this.shortsLockupViewModel
      .getObject('thumbnailViewModel')
      .getObject('thumbnailViewModel')
      .getObject('image')
      .getArray('sources'));
  }

  getStreamType(): StreamType {
    return StreamType.VIDEO_STREAM;
  }

  getViewCount(): number {
    const viewCountText: string | null = this.shortsLockupViewModel.getObject('overlayMetadata')
      .getObject('secondaryText')
      .getString('content');

    if (!isNullOrEmpty(viewCountText)) {
      const text: string = viewCountText as string;
      if (text.includes('✪')) {
        // A ✪ in the secondary text means a members-first or members-only short, whose view count
        // is not extractable
        return -1;
      }
      // This approach is language dependent
      if (text.toLowerCase().includes('no views')) {
        return 0;
      }
      return mixedNumberWordToLong(text);
    }
    throw new ParsingException('Could not get short view count');
  }

  isShortFormContent(): boolean {
    return true;
  }

  // Everything below cannot be obtained from a shortsLockupViewModel

  isAd(): boolean {
    return false;
  }

  getDuration(): number {
    return -1;
  }

  getUploaderName(): string {
    return '';
  }

  getUploaderUrl(): string {
    return '';
  }

  isUploaderVerified(): boolean {
    return false;
  }

  getTextualUploadDate(): string | null {
    return null;
  }

  getUploadDate(): DateWrapper | null {
    return null;
  }
}

export abstract class YoutubeBaseShowInfoItemExtractor extends PlaylistInfoItemExtractor {
  protected readonly showRenderer: JsonObject;

  constructor(showRenderer: JsonObject) {
    super();
    this.showRenderer = showRenderer;
  }

  getName(): string {
    const name: string | null = this.showRenderer.getString('title');
    return name === null ? '' : name;
  }

  getUrl(): string {
    const url: string | null =
      getUrlFromNavigationEndpoint(this.showRenderer.getObject('navigationEndpoint'));
    if (url === null) {
      throw new ParsingException('Could not get URL');
    }
    return url;
  }

  getThumbnails(): Image[] {
    return getThumbnailsFromInfoItem(this.showRenderer.getObject('thumbnailRenderer')
      .getObject('showCustomThumbnailRenderer'));
  }

  getStreamCount(): number {
    // For English localizations the stream count is always in the first text object, but the
    // complete text is parsed for reliability
    const streamCountText: string | null = getTextFromObject(
      this.showRenderer.getObject('thumbnailOverlays')
        .getObject('thumbnailOverlayBottomPanelRenderer')
        .getObject('text'));
    if (streamCountText === null) {
      throw new ParsingException('Could not get stream count');
    }
    // The value may be a shortened number, but no show with more than 1000 videos existed when
    // the source was written
    const parsed: number = Number.parseInt(removeNonDigitCharacters(streamCountText), 10);
    if (Number.isNaN(parsed)) {
      throw new ParsingException('Could not convert stream count to a long');
    }
    return parsed;
  }
}

export class YoutubeShowRendererInfoItemExtractor extends YoutubeBaseShowInfoItemExtractor {
  private readonly shortBylineText: JsonObject;
  private readonly longBylineText: JsonObject;

  constructor(showRenderer: JsonObject) {
    super(showRenderer);
    this.shortBylineText = showRenderer.getObject('shortBylineText');
    this.longBylineText = showRenderer.getObject('longBylineText');
  }

  getUploaderName(): string {
    let name: string | null = getTextFromObject(this.longBylineText);
    if (isNullOrEmpty(name)) {
      name = getTextFromObject(this.shortBylineText);
      if (isNullOrEmpty(name)) {
        throw new ParsingException('Could not get uploader name');
      }
    }
    return name as string;
  }

  getUploaderUrl(): string {
    let uploaderUrl: string | null = getUrlFromObject(this.longBylineText);
    if (uploaderUrl === null) {
      uploaderUrl = getUrlFromObject(this.shortBylineText);
      if (uploaderUrl === null) {
        throw new ParsingException('Could not get uploader URL');
      }
    }
    return uploaderUrl;
  }

  isUploaderVerified(): boolean {
    // showRenderers do not carry this information
    return false;
  }
}

export class YoutubeMixOrPlaylistLockupInfoItemExtractor extends PlaylistInfoItemExtractor {
  private readonly lockupViewModel: JsonObject;
  private readonly thumbnailViewModel: JsonObject;
  private readonly lockupMetadataViewModel: JsonObject;
  private readonly firstMetadataRow: JsonObject;
  private readonly playlistType: PlaylistType;

  constructor(lockupViewModel: JsonObject) {
    super();
    this.lockupViewModel = lockupViewModel;
    this.thumbnailViewModel = lockupViewModel.getObject('contentImage')
      .getObject('collectionThumbnailViewModel')
      .getObject('primaryThumbnail')
      .getObject('thumbnailViewModel');
    this.lockupMetadataViewModel = lockupViewModel.getObject('metadata')
      .getObject('lockupMetadataViewModel');

    /*
     * The metadata rows are structured as:
     *   1st part: uploader info, playlist type, playlist updated date
     *   2nd part: space row
     *   3rd element: first video
     *   4th (not always returned for playlists with fewer than 2 items?): second video
     *   5th element (always returned, at a different index for playlists with fewer than 2
     *   items?): Show full playlist
     * and the first metadata row as:
     *   1st array element: uploader info
     *   2nd element: playlist type (course, playlist, podcast)
     *   3rd element (not always returned): playlist updated date
     */
    this.firstMetadataRow = this.lockupMetadataViewModel.getObject('metadata')
      .getObject('contentMetadataViewModel')
      .getArray('metadataRows')
      .getObject(0);

    let resolvedType: PlaylistType;
    try {
      resolvedType = extractPlaylistTypeFromPlaylistId(this.getPlaylistId());
    } catch (e) {
      // Fall back to the normal type when the playlist type cannot be extracted
      resolvedType = PlaylistType.NORMAL;
    }
    this.playlistType = resolvedType;
  }

  getUploaderName(): string {
    const name: string | null = this.firstMetadataRow.getArray('metadataParts')
      .getObject(0)
      .getObject('text')
      .getString('content');
    return name === null ? '' : name;
  }

  getUploaderUrl(): string {
    if (this.playlistType !== PlaylistType.NORMAL) {
      // Mixes are auto-generated, so there is no uploader
      return '';
    }
    const url: string | null = getUrlFromNavigationEndpoint(
      this.firstMetadataRow.getArray('metadataParts')
        .getObject(0)
        .getObject('text')
        .getArray('commandRuns')
        .getObject(0)
        .getObject('onTap')
        .getObject('innertubeCommand'));
    return url === null ? '' : url;
  }

  isUploaderVerified(): boolean {
    if (this.playlistType !== PlaylistType.NORMAL) {
      // Mixes are auto-generated, so there is no uploader
      return false;
    }
    return hasArtistOrVerifiedIconBadgeAttachment(
      this.firstMetadataRow.getArray('metadataParts')
        .getObject(0)
        .getObject('text')
        .getArray('attachmentRuns'));
  }

  getStreamCount(): number {
    if (this.playlistType !== PlaylistType.NORMAL) {
      // The stream count of a mix is not obtainable
      return ITEM_COUNT_INFINITE;
    }
    try {
      let badgeViewModel: JsonObject | null = null;
      for (const overlay of this.thumbnailViewModel.getArray('overlays').streamAsJsonObjects()) {
        if (overlay.has('thumbnailOverlayBadgeViewModel')) {
          badgeViewModel = overlay.getObject('thumbnailOverlayBadgeViewModel');
          break;
        }
      }
      if (badgeViewModel === null) {
        throw new ParsingException('Could not get thumbnailOverlayBadgeViewModel');
      }

      let thumbnailBadge: JsonObject | null = null;
      for (const badge of badgeViewModel.getArray('thumbnailBadges').streamAsJsonObjects()) {
        if (badge.has('thumbnailBadgeViewModel')) {
          thumbnailBadge = badge.getObject('thumbnailBadgeViewModel');
          break;
        }
      }
      if (thumbnailBadge === null) {
        throw new ParsingException('Could not get thumbnailBadgeViewModel');
      }

      const parsed: number = Number.parseInt(
        removeNonDigitCharacters(thumbnailBadge.getString('text', '') as string), 10);
      if (Number.isNaN(parsed)) {
        throw new ParsingException('Could not get playlist stream count');
      }
      return parsed;
    } catch (e) {
      throw new ParsingException('Could not get playlist stream count',
        e instanceof Error ? e as Error : null);
    }
  }

  getName(): string {
    const name: string | null = this.lockupMetadataViewModel.getObject('title')
      .getString('content');
    return name === null ? '' : name;
  }

  getUrl(): string {
    // A mix's playlist ID alone is not enough: mix playlists have no playlist page, so the watch
    // URL from the navigation endpoint is used instead
    if (this.playlistType === PlaylistType.NORMAL) {
      try {
        return YoutubePlaylistLinkHandlerFactory.getInstance().getUrl(this.getPlaylistId());
      } catch (ignored) {
        // fall through to the navigation endpoint
      }
    }
    const url: string | null = getUrlFromNavigationEndpoint(
      this.lockupViewModel.getObject('rendererContext')
        .getObject('commandContext')
        .getObject('onTap')
        .getObject('innertubeCommand'));
    if (url === null) {
      throw new ParsingException('Could not get URL');
    }
    return url;
  }

  getThumbnails(): Image[] {
    return getImagesFromThumbnailsArray(
      this.thumbnailViewModel.getObject('image').getArray('sources'));
  }

  getPlaylistType(): PlaylistType {
    return this.playlistType;
  }

  private getPlaylistId(): string {
    let id: string | null = this.lockupViewModel.getString('contentId');
    if (isNullOrEmpty(id)) {
      id = this.lockupViewModel.getObject('rendererContext')
        .getObject('commandContext')
        .getObject('watchEndpoint')
        .getString('playlistId');
    }
    if (isNullOrEmpty(id)) {
      throw new ParsingException('Could not get playlist ID');
    }
    return id as string;
  }
}
