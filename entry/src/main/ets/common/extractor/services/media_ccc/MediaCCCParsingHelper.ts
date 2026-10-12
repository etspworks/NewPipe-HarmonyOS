/*
 * Port of org.schabi.newpipe.extractor.services.media_ccc.extractors.MediaCCCParsingHelper
 * (NewPipeExtractor v0.26.5).
 *
 * DEVIATION: `fetchConferenceData` is the source's package-private static on
 * MediaCCCConferenceExtractor. MediaCCCChannelTabExtractor calls it while
 * MediaCCCConferenceExtractor builds a MediaCCCChannelTabExtractor, so leaving it there would be
 * an ES-module cycle resolved at init time (phase2-logic-contract.md §9). Same code, one module
 * lower.
 */

import { Downloader } from '../../downloader/Downloader';
import { Localization } from '../../downloader/Localization';
import { JsonArray, JsonObject, JsonParser } from '../../json/NanoJson';
import { isNullOrEmpty } from '../../core/Utils';
import { toError } from '../../core/Errors';
import { ExtractionException } from '../../exceptions/Exceptions';
import { Image } from '../../../../model/extractor/Image';
import { ResolutionLevel } from '../../../../model/enums/ImageResolutionLevel';
import { CONFERENCE_API_ENDPOINT } from './linkHandler/MediaCCCConferenceLinkHandlerFactory';

/** conference_slug/room_slug */
const LIVE_STREAM_ID_PATTERN: RegExp = new RegExp('\\w+/\\w+');

let liveStreams: JsonArray | null = null;

/** True when `id` is formatted like `{conference_slug}/{room_slug}`. */
export function isLiveStreamId(id: string): boolean {
  LIVE_STREAM_ID_PATTERN.lastIndex = 0;
  return LIVE_STREAM_ID_PATTERN.test(id);
}

/**
 * The currently available live streams. Cached, because the response can get quite big.
 * TODO: implement better caching policy (max-age: 3 min)
 */
export async function getLiveStreams(downloader: Downloader,
  localization: Localization): Promise<JsonArray> {
  if (liveStreams === null) {
    let site: string;
    try {
      site = (await downloader.get('https://streaming.media.ccc.de/streams/v2.json', null,
        localization)).responseBody();
    } catch (e) {
      throw new ExtractionException('Could not get live stream JSON.', toError(e));
    }
    try {
      liveStreams = JsonParser.array().from(site);
    } catch (e) {
      throw new ExtractionException('Could not parse JSON.', toError(e));
    }
  }
  return liveStreams;
}

/**
 * An Image list from a logo image URL: empty when the URL is null or empty, otherwise a
 * singleton whose height, width and resolution are unknown.
 */
export function getImageListFromLogoImageUrl(logoImageUrl: string | null): Image[] {
  if (isNullOrEmpty(logoImageUrl)) {
    return [];
  }
  return [new Image(logoImageUrl as string, Image.HEIGHT_UNKNOWN, Image.WIDTH_UNKNOWN,
    ResolutionLevel.UNKNOWN)];
}

/** A stream item carries `thumb_url` (medium) and `poster_url` (high in most cases). */
export function getThumbnailsFromStreamItem(streamItem: JsonObject): Image[] {
  return getThumbnailsFromObject(streamItem, 'thumb_url', 'poster_url');
}

/** A livestream item carries `thumb` (medium) and `poster` (high). */
export function getThumbnailsFromLiveStreamItem(liveStreamItem: JsonObject): Image[] {
  return getThumbnailsFromObject(liveStreamItem, 'thumb', 'poster');
}

function getThumbnailsFromObject(streamOrLivestreamItem: JsonObject, thumbUrlKey: string,
  posterUrlKey: string): Image[] {
  const imageList: Image[] = [];

  const thumbUrl: string | null = streamOrLivestreamItem.getString(thumbUrlKey);
  if (!isNullOrEmpty(thumbUrl)) {
    imageList.push(new Image(thumbUrl as string, Image.HEIGHT_UNKNOWN, Image.WIDTH_UNKNOWN,
      ResolutionLevel.MEDIUM));
  }

  const posterUrl: string | null = streamOrLivestreamItem.getString(posterUrlKey);
  if (!isNullOrEmpty(posterUrl)) {
    imageList.push(new Image(posterUrl as string, Image.HEIGHT_UNKNOWN, Image.WIDTH_UNKNOWN,
      ResolutionLevel.HIGH));
  }

  return imageList;
}

/** The conference JSON for one conference id, off api.media.ccc.de. */
export async function fetchConferenceData(downloader: Downloader,
  conferenceId: string): Promise<JsonObject> {
  const conferenceUrl: string = CONFERENCE_API_ENDPOINT + conferenceId;
  // the source lets an IOException from the request propagate and only wraps the parse failure
  const responseBody: string = (await downloader.get(conferenceUrl)).responseBody();
  try {
    return JsonParser.object().from(responseBody);
  } catch (e) {
    throw new ExtractionException('Could not parse json returned by URL: ' + conferenceUrl);
  }
}
