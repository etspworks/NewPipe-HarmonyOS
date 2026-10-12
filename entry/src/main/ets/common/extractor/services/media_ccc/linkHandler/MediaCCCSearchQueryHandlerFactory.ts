/*
 * Port of org.schabi.newpipe.extractor.services.media_ccc.linkHandler
 * .MediaCCCSearchQueryHandlerFactory (NewPipeExtractor v0.26.5).
 */

import { SearchQueryHandlerFactory } from '../../../linkhandler/LinkHandlerFactory';
import { encodeUrlUtf8 } from '../../../core/Utils';

export const ALL: string = 'all';
export const CONFERENCES: string = 'conferences';
export const EVENTS: string = 'events';

export class MediaCCCSearchQueryHandlerFactory extends SearchQueryHandlerFactory {
  private static readonly INSTANCE: MediaCCCSearchQueryHandlerFactory =
    new MediaCCCSearchQueryHandlerFactory();

  private constructor() {
    super();
  }

  static getInstance(): MediaCCCSearchQueryHandlerFactory {
    return MediaCCCSearchQueryHandlerFactory.INSTANCE;
  }

  getAvailableContentFilter(): string[] {
    return [ALL, CONFERENCES, EVENTS];
  }

  getAvailableSortFilter(): string[] {
    return [];
  }

  getUrlWithFilters(query: string, contentFilter: string[], sortFilter: string,
    baseUrl: string | null): string {
    // verbatim from the source: the search goes to the bare host, which redirects to the API
    return 'https://media.ccc.de/public/events/search?q=' + encodeUrlUtf8(query);
  }
}
