/*
 * Port of org.schabi.newpipe.extractor.services.bandcamp.linkHandler
 * .BandcampPlaylistLinkHandlerFactory (NewPipeExtractor v0.26.5).
 * Created by Fynn Godau 2019, GPL v3 or later.
 *
 * Just as with streams, the album ids are essentially useless for us, so id = url.
 */

import { ListLinkHandlerFactory } from '../../../linkhandler/LinkHandlerFactory';
import { ListLinkHandler } from '../../../linkhandler/LinkHandler';
import { followGoogleRedirectIfNeeded, replaceHttpWithHttps } from '../../../core/Utils';
import { BandcampExtractorHelper } from '../extractors/BandcampExtractorHelper';

const ALBUM_URL_PATTERN: RegExp = new RegExp('^https?://.+\\..+/album/.+$');

export class BandcampPlaylistLinkHandlerFactory extends ListLinkHandlerFactory {
  private static readonly INSTANCE: BandcampPlaylistLinkHandlerFactory =
    new BandcampPlaylistLinkHandlerFactory();

  static getInstance(): BandcampPlaylistLinkHandlerFactory {
    return BandcampPlaylistLinkHandlerFactory.INSTANCE;
  }

  getId(url: string): string {
    return this.getUrl(url, null);
  }

  getUrlWithFilters(url: string, contentFilter: string[], sortFilter: string,
    baseUrl: string | null = null): string {
    const https: string | null = replaceHttpWithHttps(url);
    return https === null ? url : https;
  }

  /** Accepts all bandcamp URLs that contain /album/ behind their domain name. */
  onAcceptUrl(url: string): boolean {
    // Exclude URLs which do not lead to an album
    if (!ALBUM_URL_PATTERN.test(url.toLowerCase())) {
      return false;
    }

    // Test whether domain is supported
    return BandcampExtractorHelper.isArtistDomain(url);
  }

  /** Primes the custom-domain probe onAcceptUrl() needs, then builds the handler. */
  async fromUrlAsListAsync(url: string, baseUrl: string | null = null): Promise<ListLinkHandler> {
    const polishedUrl: string = followGoogleRedirectIfNeeded(url);
    if (ALBUM_URL_PATTERN.test(polishedUrl.toLowerCase())) {
      await BandcampExtractorHelper.resolveIsArtistDomain(polishedUrl);
    }
    return this.fromUrlAsList(polishedUrl, baseUrl);
  }
}
