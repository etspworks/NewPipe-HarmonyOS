/*
 * Port of the three YouTube Music info-item extractors (NewPipeExtractor v0.26.5):
 *   YoutubeMusicSongOrVideoInfoItemExtractor, YoutubeMusicAlbumOrPlaylistInfoItemExtractor,
 *   YoutubeMusicArtistInfoItemExtractor.
 *
 * One module: all three are built only by YoutubeMusicSearchExtractor, from the same
 * musicResponsiveListItemRenderer shape.
 */

import { JsonArray, JsonObject } from '../../../json/NanoJson';
import { StreamInfoItemExtractor } from '../../../info/StreamInfoItemExtractor';
import { PlaylistInfoItemExtractor } from '../../../info/PlaylistExtractor';
import { ChannelInfoItemExtractor } from '../../../info/ChannelExtractor';
import { ITEM_COUNT_UNKNOWN } from '../../../core/ListExtractor';
import { ParsingException } from '../../../exceptions/Exceptions';
import { DateWrapper } from '../../../localization/DateWrapper';
import { isNullOrEmpty, mixedNumberWordToLong } from '../../../core/Utils';
import { Image } from '../../../../../model/extractor/Image';
import { StreamType } from '../../../../../model/enums/StreamType';
import {
  getImagesFromThumbnailsArray,
  getTextFromObject,
  getUrlFromNavigationEndpoint,
  parseDurationString
} from '../YoutubeParsingHelper';
import { MUSIC_ALBUMS, MUSIC_SONGS, MUSIC_VIDEOS } from '../linkHandler/YoutubeSearchQueryHandlerFactory';

/** The thumbnails of any musicResponsiveListItemRenderer. */
function musicThumbnails(item: JsonObject): Image[] {
  try {
    return getImagesFromThumbnailsArray(item.getObject('thumbnail')
      .getObject('musicThumbnailRenderer')
      .getObject('thumbnail')
      .getArray('thumbnails'));
  } catch (e) {
    throw new ParsingException('Could not get thumbnails',
      e instanceof Error ? e as Error : null);
  }
}

/** The title text of the first flex column. */
function firstFlexColumnText(item: JsonObject): string | null {
  return getTextFromObject(item.getArray('flexColumns')
    .getObject(0)
    .getObject('musicResponsiveListItemFlexColumnRenderer')
    .getObject('text'));
}

/** The url behind the menu entry whose icon is ARTIST, or null. */
function artistMenuUrl(item: JsonObject): string | null {
  const items: JsonArray = item.getObject('menu').getObject('menuRenderer').getArray('items');
  for (const menuItem of items.streamAsJsonObjects()) {
    const menuNavigationItemRenderer: JsonObject =
      menuItem.getObject('menuNavigationItemRenderer');
    if (menuNavigationItemRenderer.getObject('icon').getString('iconType', '') === 'ARTIST') {
      return getUrlFromNavigationEndpoint(
        menuNavigationItemRenderer.getObject('navigationEndpoint'));
    }
  }
  return null;
}

export class YoutubeMusicSongOrVideoInfoItemExtractor extends StreamInfoItemExtractor {
  private readonly songOrVideoInfoItem: JsonObject;
  private readonly descriptionElements: JsonArray;
  private readonly searchType: string;

  constructor(songOrVideoInfoItem: JsonObject, descriptionElements: JsonArray,
    searchType: string) {
    super();
    this.songOrVideoInfoItem = songOrVideoInfoItem;
    this.descriptionElements = descriptionElements;
    this.searchType = searchType;
  }

  getUrl(): string {
    const id: string | null =
      this.songOrVideoInfoItem.getObject('playlistItemData').getString('videoId');
    if (!isNullOrEmpty(id)) {
      return 'https://music.youtube.com/watch?v=' + id;
    }
    throw new ParsingException('Could not get URL');
  }

  getName(): string {
    const name: string | null = firstFlexColumnText(this.songOrVideoInfoItem);
    if (!isNullOrEmpty(name)) {
      return name as string;
    }
    throw new ParsingException('Could not get name');
  }

  getStreamType(): StreamType {
    return StreamType.VIDEO_STREAM;
  }

  isAd(): boolean {
    return false;
  }

  getDuration(): number {
    const duration: string | null = this.descriptionElements
      .getObject(this.descriptionElements.size() - 1)
      .getString('text');
    if (!isNullOrEmpty(duration)) {
      return parseDurationString(duration as string);
    }
    throw new ParsingException('Could not get duration');
  }

  getUploaderName(): string {
    const name: string | null = this.descriptionElements.getObject(0).getString('text');
    if (!isNullOrEmpty(name)) {
      return name as string;
    }
    throw new ParsingException('Could not get uploader name');
  }

  getUploaderUrl(): string {
    if (this.searchType === MUSIC_VIDEOS) {
      const url: string | null = artistMenuUrl(this.songOrVideoInfoItem);
      return url === null ? '' : url;
    }

    const navigationEndpointHolder: JsonObject = this.songOrVideoInfoItem.getArray('flexColumns')
      .getObject(1)
      .getObject('musicResponsiveListItemFlexColumnRenderer')
      .getObject('text')
      .getArray('runs')
      .getObject(0);
    if (!navigationEndpointHolder.has('navigationEndpoint')) {
      return '';
    }
    const url: string | null =
      getUrlFromNavigationEndpoint(navigationEndpointHolder.getObject('navigationEndpoint'));
    if (!isNullOrEmpty(url)) {
      return url as string;
    }
    throw new ParsingException('Could not get uploader URL');
  }

  isUploaderVerified(): boolean {
    // YouTube Music does not expose this
    return false;
  }

  getTextualUploadDate(): string | null {
    return null;
  }

  getUploadDate(): DateWrapper | null {
    return null;
  }

  getViewCount(): number {
    if (this.searchType === MUSIC_SONGS) {
      return -1;
    }
    const viewCount: string | null = this.descriptionElements
      .getObject(this.descriptionElements.size() - 3)
      .getString('text');
    if (!isNullOrEmpty(viewCount)) {
      try {
        return mixedNumberWordToLong(viewCount as string);
      } catch (e) {
        // probably "No views" or similar
        return 0;
      }
    }
    throw new ParsingException('Could not get view count');
  }

  getThumbnails(): Image[] {
    return musicThumbnails(this.songOrVideoInfoItem);
  }
}

export class YoutubeMusicAlbumOrPlaylistInfoItemExtractor extends PlaylistInfoItemExtractor {
  private readonly albumOrPlaylistInfoItem: JsonObject;
  private readonly descriptionElementUploader: JsonObject;

  constructor(albumOrPlaylistInfoItem: JsonObject, descriptionElements: JsonArray,
    searchType: string) {
    super();
    this.albumOrPlaylistInfoItem = albumOrPlaylistInfoItem;
    // Albums: "Album/Single/EP", " • ", uploader, " • ", year — uploader at 2
    // Playlists: uploader, " • ", view count — uploader at 0
    this.descriptionElementUploader =
      descriptionElements.getObject(searchType === MUSIC_ALBUMS ? 2 : 0);
  }

  getThumbnails(): Image[] {
    return musicThumbnails(this.albumOrPlaylistInfoItem);
  }

  getName(): string {
    const name: string | null = firstFlexColumnText(this.albumOrPlaylistInfoItem);
    if (!isNullOrEmpty(name)) {
      return name as string;
    }
    throw new ParsingException('Could not get name');
  }

  getUrl(): string {
    let playlistId: string | null = this.albumOrPlaylistInfoItem.getObject('menu')
      .getObject('menuRenderer')
      .getArray('items')
      .getObject(4)
      .getObject('toggleMenuServiceItemRenderer')
      .getObject('toggledServiceEndpoint')
      .getObject('likeEndpoint')
      .getObject('target')
      .getString('playlistId');

    if (isNullOrEmpty(playlistId)) {
      playlistId = this.albumOrPlaylistInfoItem.getObject('overlay')
        .getObject('musicItemThumbnailOverlayRenderer')
        .getObject('content')
        .getObject('musicPlayButtonRenderer')
        .getObject('playNavigationEndpoint')
        .getObject('watchPlaylistEndpoint')
        .getString('playlistId');
    }

    if (!isNullOrEmpty(playlistId)) {
      return 'https://music.youtube.com/playlist?list=' + playlistId;
    }
    throw new ParsingException('Could not get URL');
  }

  getUploaderName(): string {
    const name: string | null = this.descriptionElementUploader.getString('text');
    if (!isNullOrEmpty(name)) {
      return name as string;
    }
    throw new ParsingException('Could not get uploader name');
  }

  getUploaderUrl(): string {
    // First try the menu (which does not work for MUSIC_PLAYLISTS)
    const menuUrl: string | null = artistMenuUrl(this.albumOrPlaylistInfoItem);
    if (menuUrl !== null) {
      return menuUrl;
    }

    // Then the uploader description element; no navigationEndpoint means the playlist/album is
    // most likely auto-generated
    if (!this.descriptionElementUploader.has('navigationEndpoint')) {
      return '';
    }
    const url: string | null = getUrlFromNavigationEndpoint(
      this.descriptionElementUploader.getObject('navigationEndpoint'));
    return url === null ? '' : url;
  }

  isUploaderVerified(): boolean {
    return false;
  }

  getStreamCount(): number {
    // YouTube Music album and playlist info items do not expose a stream count anywhere
    return ITEM_COUNT_UNKNOWN;
  }
}

export class YoutubeMusicArtistInfoItemExtractor extends ChannelInfoItemExtractor {
  private readonly artistInfoItem: JsonObject;

  constructor(artistInfoItem: JsonObject) {
    super();
    this.artistInfoItem = artistInfoItem;
  }

  getThumbnails(): Image[] {
    return musicThumbnails(this.artistInfoItem);
  }

  getName(): string {
    const name: string | null = firstFlexColumnText(this.artistInfoItem);
    if (!isNullOrEmpty(name)) {
      return name as string;
    }
    throw new ParsingException('Could not get name');
  }

  getUrl(): string {
    const url: string | null =
      getUrlFromNavigationEndpoint(this.artistInfoItem.getObject('navigationEndpoint'));
    if (!isNullOrEmpty(url)) {
      return url as string;
    }
    throw new ParsingException('Could not get URL');
  }

  getSubscriberCount(): number {
    const flexColumns: JsonArray = this.artistInfoItem.getArray('flexColumns');
    const runs: JsonArray = flexColumns
      .getObject(flexColumns.size() - 1)
      .getObject('musicResponsiveListItemFlexColumnRenderer')
      .getObject('text')
      .getArray('runs');
    // getTextFromObject would join every run; only the last one carries the subscriber count
    const subscriberCount: string | null = runs.getObject(runs.size() - 1).getString('text');
    if (!isNullOrEmpty(subscriberCount)) {
      try {
        return mixedNumberWordToLong(subscriberCount as string);
      } catch (ignored) {
        // probably "No subscribers" or similar
        return 0;
      }
    }
    throw new ParsingException('Could not get subscriber count');
  }

  getStreamCount(): number {
    return -1;
  }

  isVerified(): boolean {
    // An artist on YouTube Music is always verified
    return true;
  }

  getDescription(): string {
    return '';
  }
}
