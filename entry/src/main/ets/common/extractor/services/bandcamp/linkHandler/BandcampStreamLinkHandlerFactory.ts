/*
 * Port of org.schabi.newpipe.extractor.services.bandcamp.linkHandler
 * .BandcampStreamLinkHandlerFactory (NewPipeExtractor v0.26.5).
 * Created by Fynn Godau 2019, GPL v3 or later.
 *
 * Tracks don't have standalone ids, they are always in combination with the band id. That's why
 * id = url. Radio (bandcamp weekly) shows do have ids.
 *
 * onAcceptUrl() consults the custom-domain probe, which is a network call the ported core cannot
 * await here, so fromUrlAsync() primes it first.
 */

import { LinkHandlerFactory } from '../../../linkhandler/LinkHandlerFactory';
import { LinkHandler } from '../../../linkhandler/LinkHandler';
import { followGoogleRedirectIfNeeded, replaceHttpWithHttps } from '../../../core/Utils';
import { BASE_URL, BandcampExtractorHelper } from '../extractors/BandcampExtractorHelper';

const NUMERIC_PATTERN: RegExp = new RegExp('^\\d+$');
const TRACK_URL_PATTERN: RegExp = new RegExp('^https?://.+\\..+/track/.+$');

export class BandcampStreamLinkHandlerFactory extends LinkHandlerFactory {
  private static readonly INSTANCE: BandcampStreamLinkHandlerFactory =
    new BandcampStreamLinkHandlerFactory();

  static getInstance(): BandcampStreamLinkHandlerFactory {
    return BandcampStreamLinkHandlerFactory.INSTANCE;
  }

  getId(url: string): string {
    if (BandcampExtractorHelper.isRadioUrl(url)) {
      return url.split(new RegExp('bandcamp.com/\\?show='))[1];
    }
    return this.getUrl(url, null);
  }

  /** Clean up url. */
  getUrl(input: string, baseUrl: string | null = null): string {
    if (NUMERIC_PATTERN.test(input)) {
      return BASE_URL + '/?show=' + input;
    }
    const https: string | null = replaceHttpWithHttps(input);
    return https === null ? input : https;
  }

  /**
   * Accepts URLs that point to a bandcamp radio show or that are a bandcamp domain and point to
   * a track.
   */
  onAcceptUrl(url: string): boolean {
    // Accept Bandcamp radio
    if (BandcampExtractorHelper.isRadioUrl(url)) {
      return true;
    }

    // Don't accept URLs that don't point to a track
    if (!TRACK_URL_PATTERN.test(url.toLowerCase())) {
      return false;
    }

    // Test whether domain is supported
    return BandcampExtractorHelper.isArtistDomain(url);
  }

  /** Primes the custom-domain probe onAcceptUrl() needs, then builds the handler. */
  async fromUrlAsync(url: string, baseUrl: string | null = null): Promise<LinkHandler> {
    const polishedUrl: string = followGoogleRedirectIfNeeded(url);
    if (!BandcampExtractorHelper.isRadioUrl(polishedUrl)
      && TRACK_URL_PATTERN.test(polishedUrl.toLowerCase())) {
      await BandcampExtractorHelper.resolveIsArtistDomain(polishedUrl);
    }
    return this.fromUrl(polishedUrl, baseUrl);
  }
}
