/*
 * Port of org.schabi.newpipe.extractor.services.peertube.PeertubeParsingHelper
 * (NewPipeExtractor v0.26.5) — the paging constants, the error check, the next-page pointer and
 * the image builders.
 *
 * DEVIATION: the source's `collectItemsFrom(...)` overloads live in PeertubeItemCollector.ts.
 * They construct the per-item extractors, which import this module back for the image helpers,
 * and an ES-module cycle at init time is exactly what phase2-logic-contract.md §9 forbids. This
 * module stays a leaf.
 */

import { Image } from '../../../../model/extractor/Image';
import { Page } from '../../../../model/extractor/Page';
import { ResolutionLevel } from '../../../../model/enums/ImageResolutionLevel';
import { JsonArray, JsonObject } from '../../json/NanoJson';
import { Parser, RegexException } from '../../core/Parser';
import { isBlank, isNullOrEmpty } from '../../core/Utils';
import { ContentNotAvailableException } from '../../exceptions/Exceptions';

export const START_KEY: string = 'start';
export const COUNT_KEY: string = 'count';
export const ITEMS_PER_PAGE: number = 12;
export const START_PATTERN: RegExp = new RegExp('start=(\d*)');

/** NanoJson's getString() is nullable where the source's returns a nullable String too. */
export function nonNullString(value: string | null): string {
  return value === null ? '' : value;
}

export function validate(json: JsonObject): void {
  const error: string | null = json.getString('error');
  if (!isBlank(error)) {
    throw new ContentNotAvailableException(nonNullString(error));
  }
}

export function getNextPage(prevPageUrl: string, total: number): Page | null {
  let prevStart: string;
  try {
    prevStart = Parser.matchGroup1(START_PATTERN, prevPageUrl);
  } catch (e) {
    if (e instanceof RegexException) {
      return null;
    }
    throw e;
  }
  if (isBlank(prevStart)) {
    return null;
  }

  const parsedStart: number = Number.parseInt(prevStart, 10);
  if (Number.isNaN(parsedStart)) {
    return null;
  }
  const nextStart: number = parsedStart + ITEMS_PER_PAGE;

  if (nextStart >= total) {
    return null;
  }
  return new Page(prevPageUrl.replace(START_KEY + '=' + prevStart, START_KEY + '=' + nextStart));
}

/**
 * Avatars of an `ownerAccount` or a `videoChannel` object: the `avatars` array when it carries
 * anything, otherwise the single `avatar` object.
 */
export function getAvatarsFromOwnerAccountOrVideoChannelObject(baseUrl: string,
  ownerAccountOrVideoChannelObject: JsonObject): Image[] {
  return getImagesFromAvatarsOrBanners(baseUrl, ownerAccountOrVideoChannelObject,
    'avatars', 'avatar');
}

/** The same, for `banners` / `banner`. */
export function getBannersFromAccountOrVideoChannelObject(baseUrl: string,
  ownerAccountOrVideoChannelObject: JsonObject): Image[] {
  return getImagesFromAvatarsOrBanners(baseUrl, ownerAccountOrVideoChannelObject,
    'banners', 'banner');
}

/**
 * The two thumbnails PeerTube gives a playlist or a video item: `thumbnailPath` (low) and
 * `previewPath` (medium), both relative to the instance base url.
 */
export function getThumbnailsFromPlaylistOrVideoItem(baseUrl: string,
  playlistOrVideoItemObject: JsonObject): Image[] {
  const imageList: Image[] = [];

  const thumbnailPath: string | null = playlistOrVideoItemObject.getString('thumbnailPath');
  if (!isNullOrEmpty(thumbnailPath)) {
    imageList.push(new Image(baseUrl + nonNullString(thumbnailPath), Image.HEIGHT_UNKNOWN,
      Image.WIDTH_UNKNOWN, ResolutionLevel.LOW));
  }

  const previewPath: string | null = playlistOrVideoItemObject.getString('previewPath');
  if (!isNullOrEmpty(previewPath)) {
    imageList.push(new Image(baseUrl + nonNullString(previewPath), Image.HEIGHT_UNKNOWN,
      Image.WIDTH_UNKNOWN, ResolutionLevel.MEDIUM));
  }

  return imageList;
}

function getImagesFromAvatarsOrBanners(baseUrl: string,
  ownerAccountOrVideoChannelObject: JsonObject, jsonArrayName: string,
  jsonObjectName: string): Image[] {
  const images: JsonArray = ownerAccountOrVideoChannelObject.getArray(jsonArrayName);

  if (images.size() > 0) {
    return getImagesFromAvatarOrBannerArray(baseUrl, images);
  }

  const image: JsonObject = ownerAccountOrVideoChannelObject.getObject(jsonObjectName);
  const path: string | null = image.getString('path');
  if (!isNullOrEmpty(path)) {
    return [new Image(baseUrl + nonNullString(path), Image.HEIGHT_UNKNOWN,
      image.getInt('width', Image.WIDTH_UNKNOWN), ResolutionLevel.UNKNOWN)];
  }

  return [];
}

/** Only the width of an avatar or a banner is provided by the API, so height stays unknown. */
function getImagesFromAvatarOrBannerArray(baseUrl: string,
  avatarsOrBannersArray: JsonArray): Image[] {
  const images: Image[] = [];
  for (const image of avatarsOrBannersArray.streamAsJsonObjects()) {
    const path: string | null = image.getString('path');
    if (!isNullOrEmpty(path)) {
      images.push(new Image(baseUrl + nonNullString(path), Image.HEIGHT_UNKNOWN,
        image.getInt('width', Image.WIDTH_UNKNOWN), ResolutionLevel.UNKNOWN));
    }
  }
  return images;
}
