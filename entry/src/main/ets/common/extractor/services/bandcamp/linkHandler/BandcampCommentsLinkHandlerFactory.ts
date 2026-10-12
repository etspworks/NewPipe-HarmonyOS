/*
 * Port of org.schabi.newpipe.extractor.services.bandcamp.linkHandler
 * .BandcampCommentsLinkHandlerFactory (NewPipeExtractor v0.26.5).
 *
 * Like in BandcampStreamLinkHandlerFactory, tracks have no meaningful IDs except their URLs.
 */

import { ListLinkHandlerFactory } from '../../../linkhandler/LinkHandlerFactory';
import { ListLinkHandler } from '../../../linkhandler/LinkHandler';
import { followGoogleRedirectIfNeeded, replaceHttpWithHttps } from '../../../core/Utils';
import { BandcampExtractorHelper } from '../extractors/BandcampExtractorHelper';

const TRACK_OR_ALBUM_URL_PATTERN: RegExp = new RegExp('^https?://.+\\..+/(track|album)/.+$');

export class BandcampCommentsLinkHandlerFactory extends ListLinkHandlerFactory {
  private static readonly INSTANCE: BandcampCommentsLinkHandlerFactory =
    new BandcampCommentsLinkHandlerFactory();

  static getInstance(): BandcampCommentsLinkHandlerFactory {
    return BandcampCommentsLinkHandlerFactory.INSTANCE;
  }

  getId(url: string): string {
    const https: string | null = replaceHttpWithHttps(url);
    return https === null ? url : https;
  }

  onAcceptUrl(url: string): boolean {
    if (BandcampExtractorHelper.isRadioUrl(url)) {
      return true;
    }

    // Don't accept URLs that don't point to a track
    if (!TRACK_OR_ALBUM_URL_PATTERN.test(url.toLowerCase())) {
      return false;
    }

    // Test whether domain is supported
    return BandcampExtractorHelper.isArtistDomain(url);
  }

  getUrlWithFilters(id: string, contentFilter: string[], sortFilter: string,
    baseUrl: string | null = null): string {
    const https: string | null = replaceHttpWithHttps(id);
    return https === null ? id : https;
  }

  /** Primes the custom-domain probe onAcceptUrl() needs, then builds the handler. */
  async fromUrlAsListAsync(url: string, baseUrl: string | null = null): Promise<ListLinkHandler> {
    const polishedUrl: string = followGoogleRedirectIfNeeded(url);
    if (!BandcampExtractorHelper.isRadioUrl(polishedUrl)
      && TRACK_OR_ALBUM_URL_PATTERN.test(polishedUrl.toLowerCase())) {
      await BandcampExtractorHelper.resolveIsArtistDomain(polishedUrl);
    }
    return this.fromUrlAsList(polishedUrl, baseUrl);
  }
}
