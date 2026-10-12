/*
 * Port of org.schabi.newpipe.extractor.services.media_ccc.linkHandler
 * .MediaCCCConferencesListLinkHandlerFactory (NewPipeExtractor v0.26.5).
 */

import { ListLinkHandlerFactory } from '../../../linkhandler/LinkHandlerFactory';

export class MediaCCCConferencesListLinkHandlerFactory extends ListLinkHandlerFactory {
  private static readonly INSTANCE: MediaCCCConferencesListLinkHandlerFactory =
    new MediaCCCConferencesListLinkHandlerFactory();

  private constructor() {
    super();
  }

  static getInstance(): MediaCCCConferencesListLinkHandlerFactory {
    return MediaCCCConferencesListLinkHandlerFactory.INSTANCE;
  }

  getId(conferencesUrl: string): string {
    return 'conferences';
  }

  getUrlWithFilters(id: string, contentFilter: string[], sortFilter: string,
    baseUrl: string | null): string {
    return 'https://media.ccc.de/public/conferences';
  }

  onAcceptUrl(conferencesUrl: string): boolean {
    return conferencesUrl === 'https://media.ccc.de/b/conferences'
      || conferencesUrl === 'https://media.ccc.de/public/conferences'
      || conferencesUrl === 'https://api.media.ccc.de/public/conferences';
  }
}
