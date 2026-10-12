/*
 * Port of org.schabi.newpipe.extractor.services.youtube.extractors
 * .{YoutubePlaylistInfoItemExtractor, YoutubeMixOrPlaylistInfoItemExtractor}
 * (NewPipeExtractor v0.26.5).
 *
 * Both read a playlist row; the mix variant reads the auto-generated shape, which has no uploader.
 * One module, because every caller that builds one can build the other.
 */

import { JsonArray, JsonObject } from '../../../json/NanoJson';
import { PlaylistInfoItemExtractor } from '../../../info/PlaylistExtractor';
import { ITEM_COUNT_INFINITE } from '../../../core/ListExtractor';
import { ParsingException } from '../../../exceptions/Exceptions';
import { isNullOrEmpty, removeNonDigitCharacters } from '../../../core/Utils';
import { Image } from '../../../../../model/extractor/Image';
import { PlaylistType } from '../../../../../model/extractor/PlaylistType';
import {
  extractPlaylistTypeFromPlaylistUrl,
  getImagesFromThumbnailsArray,
  getTextFromObject,
  getThumbnailsFromInfoItem,
  getUrlFromObject,
  isVerified
} from '../YoutubeParsingHelper';
import { YoutubePlaylistLinkHandlerFactory } from '../linkHandler/YoutubePlaylistLinkHandlerFactory';

export class YoutubePlaylistInfoItemExtractor extends PlaylistInfoItemExtractor {
  private readonly playlistInfoItem: JsonObject;

  constructor(playlistInfoItem: JsonObject) {
    super();
    this.playlistInfoItem = playlistInfoItem;
  }

  getThumbnails(): Image[] {
    try {
      let thumbnails: JsonArray = this.playlistInfoItem.getArray('thumbnails')
        .getObject(0)
        .getArray('thumbnails');
      if (thumbnails.size() === 0) {
        thumbnails = this.playlistInfoItem.getObject('thumbnail').getArray('thumbnails');
      }
      return getImagesFromThumbnailsArray(thumbnails);
    } catch (e) {
      throw new ParsingException('Could not get thumbnails',
        e instanceof Error ? e as Error : null);
    }
  }

  getName(): string {
    const name: string | null = getTextFromObject(this.playlistInfoItem.getObject('title'));
    if (name === null) {
      throw new ParsingException('Could not get name');
    }
    return name;
  }

  getUrl(): string {
    try {
      const id: string = this.playlistInfoItem.getString('playlistId', '') as string;
      return YoutubePlaylistLinkHandlerFactory.getInstance().getUrl(id);
    } catch (e) {
      throw new ParsingException('Could not get url', e instanceof Error ? e as Error : null);
    }
  }

  getUploaderName(): string {
    const name: string | null =
      getTextFromObject(this.playlistInfoItem.getObject('longBylineText'));
    return name === null ? '' : name;
  }

  getUploaderUrl(): string {
    const url: string | null = getUrlFromObject(this.playlistInfoItem.getObject('longBylineText'));
    return url === null ? '' : url;
  }

  isUploaderVerified(): boolean {
    try {
      return isVerified(this.playlistInfoItem.getArray('ownerBadges'));
    } catch (e) {
      throw new ParsingException('Could not get uploader verification info',
        e instanceof Error ? e as Error : null);
    }
  }

  getStreamCount(): number {
    let videoCountText: string | null = this.playlistInfoItem.getString('videoCount');
    if (videoCountText === null) {
      videoCountText = getTextFromObject(this.playlistInfoItem.getObject('videoCountText'));
    }
    if (videoCountText === null) {
      videoCountText = getTextFromObject(this.playlistInfoItem.getObject('videoCountShortText'));
    }
    if (videoCountText === null) {
      throw new ParsingException('Could not get stream count');
    }
    const parsed: number = Number.parseInt(removeNonDigitCharacters(videoCountText), 10);
    if (Number.isNaN(parsed)) {
      throw new ParsingException('Could not get stream count');
    }
    return parsed;
  }
}

export class YoutubeMixOrPlaylistInfoItemExtractor extends PlaylistInfoItemExtractor {
  private readonly mixInfoItem: JsonObject;

  constructor(mixInfoItem: JsonObject) {
    super();
    this.mixInfoItem = mixInfoItem;
  }

  getName(): string {
    const name: string | null = getTextFromObject(this.mixInfoItem.getObject('title'));
    if (isNullOrEmpty(name)) {
      throw new ParsingException('Could not get name');
    }
    return name as string;
  }

  getUrl(): string {
    const url: string | null = this.mixInfoItem.getString('shareUrl');
    if (isNullOrEmpty(url)) {
      throw new ParsingException('Could not get url');
    }
    return url as string;
  }

  getThumbnails(): Image[] {
    return getThumbnailsFromInfoItem(this.mixInfoItem);
  }

  getUploaderName(): string {
    // For a mix this is a list of uploaders
    const name: string | null = getTextFromObject(this.mixInfoItem.getObject('longBylineText'));
    return name === null ? '' : name;
  }

  getUploaderUrl(): string {
    // Mixes are auto-generated, so there is no uploader
    return '';
  }

  isUploaderVerified(): boolean {
    // Mixes are auto-generated, so there is no uploader
    return false;
  }

  getStreamCount(): number {
    const countString: string | null =
      getTextFromObject(this.mixInfoItem.getObject('videoCountShortText'));
    if (countString === null) {
      throw new ParsingException('Could not extract item count for playlist/mix info item');
    }
    const parsed: number = Number.parseInt(countString, 10);
    if (Number.isNaN(parsed)) {
      // an unparsable count is a mix with infinite items and "50+" as its count string (though
      // YouTube Music mixes do not necessarily have infinitely many songs)
      return ITEM_COUNT_INFINITE;
    }
    return parsed;
  }

  getPlaylistType(): PlaylistType {
    return extractPlaylistTypeFromPlaylistUrl(this.getUrl());
  }
}
