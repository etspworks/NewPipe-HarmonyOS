/*
 * Port of the two `collectItemsFrom(...)` overloads of
 * org.schabi.newpipe.extractor.services.peertube.PeertubeParsingHelper (NewPipeExtractor v0.26.5).
 *
 * Two ArkTS-forced shape changes, and nothing else:
 *
 * 1. They live here rather than in PeertubeParsingHelper.ts. They construct the per-item
 *    extractors, which import PeertubeParsingHelper back for the image builders; keeping them
 *    together would make that an ES-module cycle resolved at init time, which
 *    phase2-logic-contract.md §9 forbids. PeertubeParsingHelper stays a leaf.
 *
 * 2. The source takes a RAW `InfoItemsCollector`, so one method serves both the mixed lists
 *    (search, channel tab) and the stream-only lists (trending, playlist, related). ArkTS has no
 *    raw types, so the two real call shapes get one function each. `collectStreamItemsFrom` SKIPS
 *    a playlist or channel item instead of committing it to a StreamInfoItemsCollector — which is
 *    what the raw-typed source would do, and it would then throw a ClassCastException out of
 *    extract(). Unreachable in practice: the endpoints that feed it return videos only.
 */

import { JsonArray, JsonObject } from '../../json/NanoJson';
import { JsonUtils } from '../../core/JsonUtils';
import { toError } from '../../core/Errors';
import { ParsingException } from '../../exceptions/Exceptions';
import { StreamInfoItemsCollector } from '../../info/StreamInfoItemsCollector';
import { MultiInfoItemsCollector } from '../../core/MultiInfoItemsCollector';
import { PeertubeChannelInfoItemExtractor } from './extractors/PeertubeChannelInfoItemExtractor';
import { PeertubePlaylistInfoItemExtractor } from './extractors/PeertubePlaylistInfoItemExtractor';
import {
  PeertubeSepiaStreamInfoItemExtractor
} from './extractors/PeertubeSepiaStreamInfoItemExtractor';
import { PeertubeStreamInfoItemExtractor } from './extractors/PeertubeStreamInfoItemExtractor';

function getContents(json: JsonObject): JsonArray {
  try {
    return JsonUtils.getArray(json, 'data');
  } catch (e) {
    throw new ParsingException('Unable to extract list info', toError(e));
  }
}

/** PeerTube playlists wrap the stream info in a `video` object. */
function unwrapItem(item: JsonObject): JsonObject {
  return item.has('video') ? item.getObject('video') : item;
}

/**
 * Collect streams, channels and playlists from the given JSON object.
 *
 * @param sepia use PeertubeSepiaStreamInfoItemExtractor for streams rather than
 *              PeertubeStreamInfoItemExtractor
 */
export function collectItemsFrom(collector: MultiInfoItemsCollector, json: JsonObject,
  baseUrl: string, sepia: boolean = false): void {
  const contents: JsonArray = getContents(json);

  for (const rawItem of contents.streamAsJsonObjects()) {
    const item: JsonObject = unwrapItem(rawItem);
    const isPlaylistInfoItem: boolean = item.has('videosLength');
    const isChannelInfoItem: boolean = item.has('followersCount');

    if (sepia) {
      collector.commit(new PeertubeSepiaStreamInfoItemExtractor(item, baseUrl));
    } else if (isPlaylistInfoItem) {
      collector.commit(new PeertubePlaylistInfoItemExtractor(item, baseUrl));
    } else if (isChannelInfoItem) {
      collector.commit(new PeertubeChannelInfoItemExtractor(item, baseUrl));
    } else {
      collector.commit(new PeertubeStreamInfoItemExtractor(item, baseUrl));
    }
  }
}

/** The stream-only call shape: trending, playlist contents and related streams. */
export function collectStreamItemsFrom(collector: StreamInfoItemsCollector, json: JsonObject,
  baseUrl: string): void {
  const contents: JsonArray = getContents(json);

  for (const rawItem of contents.streamAsJsonObjects()) {
    const item: JsonObject = unwrapItem(rawItem);
    if (item.has('videosLength') || item.has('followersCount')) {
      // not a stream; see the header note
      continue;
    }
    collector.commit(new PeertubeStreamInfoItemExtractor(item, baseUrl));
  }
}
