/*
 * Port of org.schabi.newpipe.extractor.services.soundcloud.linkHandler
 * .SoundcloudSearchQueryHandlerFactory (NewPipeExtractor v0.26.5).
 *
 * The search url carries the bootstrapped client_id, so - like the comments factory - the url
 * build is split into a synchronous override and an async fromSearchQueryAsync() that
 * bootstraps the client_id first.
 */

import { SearchQueryHandlerFactory } from '../../../linkhandler/LinkHandlerFactory';
import { SearchQueryHandler } from '../../../linkhandler/LinkHandler';
import { encodeUrlUtf8 } from '../../../core/Utils';
import { ParsingException } from '../../../exceptions/Exceptions';
import { SOUNDCLOUD_API_V2_URL, SoundcloudParsingHelper } from '../SoundcloudParsingHelper';

export const TRACKS: string = 'tracks';
export const USERS: string = 'users';
export const PLAYLISTS: string = 'playlists';
export const ALL: string = 'all';

export const ITEMS_PER_PAGE: number = 10;

export class SoundcloudSearchQueryHandlerFactory extends SearchQueryHandlerFactory {
  private static readonly INSTANCE: SoundcloudSearchQueryHandlerFactory =
    new SoundcloudSearchQueryHandlerFactory();

  static getInstance(): SoundcloudSearchQueryHandlerFactory {
    return SoundcloudSearchQueryHandlerFactory.INSTANCE;
  }

  private static buildUrl(id: string, contentFilter: string[], clientId: string): string {
    let url: string = SOUNDCLOUD_API_V2_URL + 'search';

    if (contentFilter.length > 0) {
      const filter: string = contentFilter[0];
      if (filter === TRACKS) {
        url += '/tracks';
      } else if (filter === USERS) {
        url += '/users';
      } else if (filter === PLAYLISTS) {
        url += '/playlists';
      }
      // ALL and anything else: no suffix
    }

    return url + '?q=' + encodeUrlUtf8(id)
      + '&client_id=' + clientId
      + '&limit=' + ITEMS_PER_PAGE + '&offset=0';
  }

  getUrlWithFilters(id: string, contentFilter: string[], sortFilter: string,
    baseUrl: string | null = null): string {
    const clientId: string | null = SoundcloudParsingHelper.cachedClientId();
    if (clientId === null) {
      throw new ParsingException('Could not get client id'
        + ' - use fromSearchQueryAsync(query, contentFilter, sortFilter)');
    }
    return SoundcloudSearchQueryHandlerFactory.buildUrl(id, contentFilter, clientId);
  }

  getAvailableContentFilter(): string[] {
    return [ALL, TRACKS, USERS, PLAYLISTS];
  }

  /** Bootstraps the client_id, then builds the search handler. */
  async fromSearchQueryAsync(query: string, contentFilter: string[] = [],
    sortFilter: string = ''): Promise<SearchQueryHandler> {
    await SoundcloudParsingHelper.clientId();
    return this.fromSearchQuery(query, contentFilter, sortFilter);
  }
}
