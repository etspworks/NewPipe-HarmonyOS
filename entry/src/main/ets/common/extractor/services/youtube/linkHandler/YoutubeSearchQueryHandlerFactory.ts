/*
 * Port of org.schabi.newpipe.extractor.services.youtube.linkHandler
 * .YoutubeSearchQueryHandlerFactory (NewPipeExtractor v0.26.5).
 *
 * The `sp` parameters are the source's, verbatim: they are opaque protobuf filters YouTube
 * checks, so a "cleaned up" value silently returns the wrong result set.
 */

import { SearchQueryHandlerFactory } from '../../../linkhandler/LinkHandlerFactory';
import { encodeUrlUtf8, isNullOrEmpty } from '../../../core/Utils';

export const ALL: string = 'all';
export const VIDEOS: string = 'videos';
export const CHANNELS: string = 'channels';
export const PLAYLISTS: string = 'playlists';

export const MUSIC_SONGS: string = 'music_songs';
export const MUSIC_VIDEOS: string = 'music_videos';
export const MUSIC_ALBUMS: string = 'music_albums';
export const MUSIC_PLAYLISTS: string = 'music_playlists';
export const MUSIC_ARTISTS: string = 'music_artists';

const SEARCH_URL: string = 'https://www.youtube.com/results?search_query=';
const MUSIC_SEARCH_URL: string = 'https://music.youtube.com/search?q=';

const MUSIC_CONTENT_FILTERS: string[] = [MUSIC_SONGS, MUSIC_VIDEOS, MUSIC_ALBUMS,
  MUSIC_PLAYLISTS, MUSIC_ARTISTS];

/** The `sp` search parameter for a content filter; `8AEB` is the default (everything). */
export function getSearchParameter(contentFilter: string | null): string {
  if (isNullOrEmpty(contentFilter)) {
    return '8AEB';
  }
  if (contentFilter === VIDEOS) {
    return 'EgIQAfABAQ%3D%3D';
  }
  if (contentFilter === CHANNELS) {
    return 'EgIQAvABAQ%3D%3D';
  }
  if (contentFilter === PLAYLISTS) {
    return 'EgIQA_ABAQ%3D%3D';
  }
  if (MUSIC_CONTENT_FILTERS.includes(contentFilter as string)) {
    return '';
  }
  return '8AEB';
}

export class YoutubeSearchQueryHandlerFactory extends SearchQueryHandlerFactory {
  private static instance: YoutubeSearchQueryHandlerFactory | null = null;

  static getInstance(): YoutubeSearchQueryHandlerFactory {
    let current: YoutubeSearchQueryHandlerFactory | null =
      YoutubeSearchQueryHandlerFactory.instance;
    if (current === null) {
      current = new YoutubeSearchQueryHandlerFactory();
      YoutubeSearchQueryHandlerFactory.instance = current;
    }
    return current;
  }

  getUrlWithFilters(searchString: string, contentFilters: string[], sortFilter: string,
    baseUrl: string | null): string {
    const contentFilter: string = contentFilters.length > 0 ? contentFilters[0] : '';
    if (contentFilter === VIDEOS) {
      return SEARCH_URL + encodeUrlUtf8(searchString) + '&sp=EgIQAfABAQ%253D%253D';
    }
    if (contentFilter === CHANNELS) {
      return SEARCH_URL + encodeUrlUtf8(searchString) + '&sp=EgIQAvABAQ%253D%253D';
    }
    if (contentFilter === PLAYLISTS) {
      return SEARCH_URL + encodeUrlUtf8(searchString) + '&sp=EgIQA_ABAQ%253D%253D';
    }
    if (MUSIC_CONTENT_FILTERS.includes(contentFilter)) {
      return MUSIC_SEARCH_URL + encodeUrlUtf8(searchString);
    }
    return SEARCH_URL + encodeUrlUtf8(searchString) + '&sp=8AEB';
  }

  getAvailableContentFilter(): string[] {
    // MUSIC_ARTISTS is deliberately not offered, exactly as in the source
    return [ALL, VIDEOS, CHANNELS, PLAYLISTS, MUSIC_SONGS, MUSIC_VIDEOS, MUSIC_ALBUMS,
      MUSIC_PLAYLISTS];
  }
}
