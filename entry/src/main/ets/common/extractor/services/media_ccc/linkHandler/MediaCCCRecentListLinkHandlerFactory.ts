/*
 * Port of org.schabi.newpipe.extractor.services.media_ccc.linkHandler
 * .MediaCCCRecentListLinkHandlerFactory (NewPipeExtractor v0.26.5).
 */

import { ListLinkHandlerFactory } from '../../../linkhandler/LinkHandlerFactory';

const PATTERN: RegExp = new RegExp('^(https?://)?media\\.ccc\\.de/recent/?$');

export class MediaCCCRecentListLinkHandlerFactory extends ListLinkHandlerFactory {
  private static readonly INSTANCE: MediaCCCRecentListLinkHandlerFactory =
    new MediaCCCRecentListLinkHandlerFactory();

  private constructor() {
    super();
  }

  static getInstance(): MediaCCCRecentListLinkHandlerFactory {
    return MediaCCCRecentListLinkHandlerFactory.INSTANCE;
  }

  getId(recentUrl: string): string {
    return 'recent';
  }

  onAcceptUrl(recentUrl: string): boolean {
    PATTERN.lastIndex = 0;
    return PATTERN.test(recentUrl);
  }

  getUrlWithFilters(id: string, contentFilter: string[], sortFilter: string,
    baseUrl: string | null): string {
    return 'https://media.ccc.de/recent';
  }
}
