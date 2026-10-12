/*
 * Port of org.schabi.newpipe.extractor.services.bandcamp.linkHandler
 * .BandcampChannelLinkHandlerFactory (NewPipeExtractor v0.26.5).
 * Created by Fynn Godau 2019, GPL v3 or later.
 *
 * Artists do have IDs that are useful - but reading one costs a page download, and turning one
 * back into a URL costs a mobile-API call, while the ported core declares getId()/getUrl()
 * synchronous. Both are therefore memoized by an async resolver; use fromUrlAsListAsync().
 */

import { ListLinkHandlerFactory } from '../../../linkhandler/LinkHandlerFactory';
import { ListLinkHandler } from '../../../linkhandler/LinkHandler';
import { JsonUtils } from '../../../core/JsonUtils';
import { NewPipe } from '../../../core/NewPipe';
import { followGoogleRedirectIfNeeded, replaceHttpWithHttps } from '../../../core/Utils';
import { Downloader } from '../../../downloader/Downloader';
import { ExtractionException, ParsingException } from '../../../exceptions/Exceptions';
import { JsonObject } from '../../../json/NanoJson';
import { BandcampExtractorHelper } from '../extractors/BandcampExtractorHelper';

/** url -> band id, filled by resolveId(). */
const idCache: Map<string, string> = new Map<string, string>();

export class BandcampChannelLinkHandlerFactory extends ListLinkHandlerFactory {
  private static readonly INSTANCE: BandcampChannelLinkHandlerFactory =
    new BandcampChannelLinkHandlerFactory();

  static getInstance(): BandcampChannelLinkHandlerFactory {
    return BandcampChannelLinkHandlerFactory.INSTANCE;
  }

  /** Downloads the artist page and reads the band id embedded in it; memoized for getId(). */
  static async resolveId(url: string): Promise<string> {
    const cached: string | undefined = idCache.get(url);
    if (cached !== undefined) {
      return cached;
    }

    try {
      const dl: Downloader | null = NewPipe.getDownloader();
      if (dl === null) {
        throw new ExtractionException('NewPipe was not initialised with a Downloader');
      }
      const https: string | null = replaceHttpWithHttps(url);
      const response: string = (await dl.get(https === null ? url : https)).responseBody();

      // Use band data embedded in website to extract ID
      const bandData: JsonObject = JsonUtils.getJsonData(response, 'data-band');

      const id: string = `${bandData.getLong('id')}`;
      idCache.set(url, id);
      return id;
    } catch (e) {
      throw new ParsingException('Download failed', e instanceof Error ? e as Error : null);
    }
  }

  getId(url: string): string {
    const cached: string | undefined = idCache.get(url);
    if (cached === undefined) {
      throw new ParsingException('Download failed: band id for ' + url
        + ' is not resolved yet - use fromUrlAsListAsync(url)');
    }
    return cached;
  }

  /** Primes the mobile-endpoint "translator" from id to url that getUrl() reads. */
  static async resolveUrl(id: string): Promise<string> {
    await BandcampExtractorHelper.resolveArtistDetails(id);
    return BandcampChannelLinkHandlerFactory.getInstance().getUrlWithFilters(id, [], '', null);
  }

  /** Uses the mobile endpoint as a "translator" from id to url. */
  getUrlWithFilters(id: string, contentFilter: string[], sortFilter: string,
    baseUrl: string | null = null): string {
    const artistDetails: JsonObject = BandcampExtractorHelper.getArtistDetails(id);
    if (artistDetails.getBoolean('error')) {
      throw new ParsingException(
        'JSON does not contain a channel URL (invalid id?) or is otherwise invalid');
    }
    const url: string | null = replaceHttpWithHttps(artistDetails.getString('bandcamp_url'));
    return url === null ? '' : url;
  }

  /** Accepts only pages that lead to the root of an artist profile. Supports external pages. */
  onAcceptUrl(url: string): boolean {
    const lowercaseUrl: string = url.toLowerCase();

    // https: | | artist.bandcamp.com | releases - music - album - track ( | name)
    //  0      1           2                           3                    (4)
    const splitUrl: string[] = lowercaseUrl.split('/');

    // Java's String.split DISCARDS trailing empty strings and JS keeps them: the uploader url
    // BandcampPlaylistExtractor hands over always ends in '/', which split to four parts with an
    // empty tail and was refused as "URL not accepted".
    while (splitUrl.length > 0 && splitUrl[splitUrl.length - 1] === '') {
      splitUrl.pop();
    }

    // URL is too short
    if (splitUrl.length !== 3 && splitUrl.length !== 4) {
      return false;
    }

    // Must have "releases", "music", "album" or "track" as segment after URL or none at all
    if (splitUrl.length === 4 && !(splitUrl[3] === 'releases' || splitUrl[3] === 'music'
      || splitUrl[3] === 'album' || splitUrl[3] === 'track')) {
      return false;
    }
    if (splitUrl[2] === 'daily.bandcamp.com') {
      // Refuse links to daily.bandcamp.com as that is not an artist
      return false;
    }

    // Test whether domain is supported
    return BandcampExtractorHelper.isArtistDomain(lowercaseUrl);
  }

  /** Primes the custom-domain probe and the id, then builds the handler. */
  async fromUrlAsListAsync(url: string, baseUrl: string | null = null): Promise<ListLinkHandler> {
    const polishedUrl: string = followGoogleRedirectIfNeeded(url);
    await BandcampExtractorHelper.resolveIsArtistDomain(polishedUrl);
    const id: string = await BandcampChannelLinkHandlerFactory.resolveId(polishedUrl);
    await BandcampExtractorHelper.resolveArtistDetails(id);
    return this.fromUrlAsList(polishedUrl, baseUrl);
  }

  async fromIdAsListAsync(id: string, baseUrl: string | null = null): Promise<ListLinkHandler> {
    await BandcampExtractorHelper.resolveArtistDetails(id);
    return this.fromIdAsList(id, baseUrl);
  }
}
