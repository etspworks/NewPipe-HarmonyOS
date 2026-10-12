/*
 * Port of org.schabi.newpipe.extractor.services.peertube.linkHandler
 * .PeertubeSearchQueryHandlerFactory (NewPipeExtractor v0.26.5).
 *
 * NOTE (phase2-logic-contract.md §3): PeerTube search does NOT run against the content instance.
 * A `sepia_` content filter sends the query to the global SepiaSearch index at
 * https://sepiasearch.org; everything else searches the user's own instance. The two roles must
 * stay distinct, or search breaks on a self-hosted instance.
 */

import { SearchQueryHandlerFactory } from '../../../linkhandler/LinkHandlerFactory';
import { encodeUrlUtf8 } from '../../../core/Utils';
import { getPeertubeBaseUrl } from '../PeertubeInstanceState';

export const VIDEOS: string = 'videos';
/** sepia is the global index */
export const SEPIA_VIDEOS: string = 'sepia_videos';
export const PLAYLISTS: string = 'playlists';
export const CHANNELS: string = 'channels';
export const SEPIA_BASE_URL: string = 'https://sepiasearch.org';
export const SEARCH_ENDPOINT_PLAYLISTS: string = '/api/v1/search/video-playlists';
export const SEARCH_ENDPOINT_VIDEOS: string = '/api/v1/search/videos';
export const SEARCH_ENDPOINT_CHANNELS: string = '/api/v1/search/video-channels';

export class PeertubeSearchQueryHandlerFactory extends SearchQueryHandlerFactory {
  private static readonly INSTANCE: PeertubeSearchQueryHandlerFactory =
    new PeertubeSearchQueryHandlerFactory();

  private constructor() {
    super();
  }

  static getInstance(): PeertubeSearchQueryHandlerFactory {
    return PeertubeSearchQueryHandlerFactory.INSTANCE;
  }

  getUrlWithFilters(searchString: string, contentFilters: string[], sortFilter: string,
    baseUrl: string | null): string {
    let resolvedBaseUrl: string;
    if (baseUrl === null) {
      // the source's three-argument getUrl(): sepia searches the global index, everything else
      // searches the instance the user configured
      resolvedBaseUrl = contentFilters.length > 0 && contentFilters[0].startsWith('sepia_')
        ? SEPIA_BASE_URL : getPeertubeBaseUrl();
    } else {
      resolvedBaseUrl = baseUrl;
    }

    let endpoint: string;
    if (contentFilters.length === 0 || contentFilters[0] === VIDEOS
      || contentFilters[0] === SEPIA_VIDEOS) {
      endpoint = SEARCH_ENDPOINT_VIDEOS;
    } else if (contentFilters[0] === CHANNELS) {
      endpoint = SEARCH_ENDPOINT_CHANNELS;
    } else {
      endpoint = SEARCH_ENDPOINT_PLAYLISTS;
    }
    return resolvedBaseUrl + endpoint + '?search=' + encodeUrlUtf8(searchString);
  }

  getAvailableContentFilter(): string[] {
    return [VIDEOS, PLAYLISTS, CHANNELS, SEPIA_VIDEOS];
  }
}
