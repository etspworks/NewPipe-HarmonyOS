/*
 * Port of org.schabi.newpipe.extractor.services.bandcamp.extractors.BandcampExtractorHelper
 * (NewPipeExtractor v0.26.5). Created by Fynn Godau 2019, GPL v3 or later.
 *
 * Bandcamp has no real API: it is `https://bandcamp.com` plus a handful of mobile endpoints
 * hung off `/api`, and HTML scraping of the artist pages for everything else. That is why the
 * gated endpoint literals for this service are PATH SUFFIXES onto BASE_URL rather than whole
 * URLs.
 *
 * ArkTS deviation: three lookups here do I/O but are called from methods the ported core
 * declares SYNCHRONOUS (LinkHandlerFactory.getId/getUrl/onAcceptUrl, InfoItemExtractor.getUrl,
 * InfoItemExtractor.getThumbnails). Each is therefore split into an async `resolve*` that does
 * the request and memoizes it, and a synchronous reader that serves the memo. The async callers
 * (onFetchPage, getInitialPage, the factories' *Async methods) prime the memo first.
 */

import { Image } from '../../../../../model/extractor/Image';
import { ResolutionLevel } from '../../../../../model/enums/ImageResolutionLevel';
import { ImageSuffix } from '../../../core/ImageSuffix';
import { NewPipe } from '../../../core/NewPipe';
import { isNullOrEmpty, replaceHttpWithHttps } from '../../../core/Utils';
import { Downloader, Request } from '../../../downloader/Downloader';
import { ExtractionException, ParsingException } from '../../../exceptions/Exceptions';
import { Element, Jsoup } from '../../../html/Jsoup';
import { JsonObject, JsonParser, JsonWriter } from '../../../json/NanoJson';
import { DateWrapper } from '../../../localization/DateWrapper';

/**
 * Image IDs which preserve aspect ratio, with their theoretical dimension known. Bandcamp
 * images are not always squares, so only aspect-ratio-preserving variants are used, and only
 * one dimension of each is known. Dimensions are theoretical: a smaller original is not upscaled.
 * IDs from the gist "Bandcamp File Format Parameters" by f2k1de.
 */
const IMAGE_URL_SUFFIXES_AND_RESOLUTIONS: ImageSuffix[] = [
  // ID | HEIGHT | WIDTH
  new ImageSuffix('10.jpg', Image.HEIGHT_UNKNOWN, 1200, ResolutionLevel.HIGH),
  new ImageSuffix('101.jpg', 90, Image.WIDTH_UNKNOWN, ResolutionLevel.LOW),
  new ImageSuffix('170.jpg', 422, Image.WIDTH_UNKNOWN, ResolutionLevel.MEDIUM),
  // 180 returns the same image aspect ratio and size as 171
  new ImageSuffix('171.jpg', 646, Image.WIDTH_UNKNOWN, ResolutionLevel.MEDIUM),
  new ImageSuffix('20.jpg', Image.HEIGHT_UNKNOWN, 1024, ResolutionLevel.HIGH),
  // 203 returns the same image aspect ratio and size as 200
  new ImageSuffix('200.jpg', 420, Image.WIDTH_UNKNOWN, ResolutionLevel.MEDIUM),
  new ImageSuffix('201.jpg', 280, Image.WIDTH_UNKNOWN, ResolutionLevel.MEDIUM),
  new ImageSuffix('202.jpg', 140, Image.WIDTH_UNKNOWN, ResolutionLevel.LOW),
  new ImageSuffix('204.jpg', 360, Image.WIDTH_UNKNOWN, ResolutionLevel.MEDIUM),
  new ImageSuffix('205.jpg', 240, Image.WIDTH_UNKNOWN, ResolutionLevel.MEDIUM),
  new ImageSuffix('206.jpg', 180, Image.WIDTH_UNKNOWN, ResolutionLevel.MEDIUM),
  new ImageSuffix('207.jpg', 120, Image.WIDTH_UNKNOWN, ResolutionLevel.LOW),
  new ImageSuffix('43.jpg', 100, Image.WIDTH_UNKNOWN, ResolutionLevel.LOW),
  new ImageSuffix('44.jpg', 200, Image.WIDTH_UNKNOWN, ResolutionLevel.MEDIUM)
];

// Bandcamp also serves '<id>_1x1_120.jpg'-style variants (recommended-album art); the whole
// suffix after the image ID has to go, or '<id>_1x1_10.jpg' comes back and 404s.
const IMAGE_URL_APPENDIX_AND_EXTENSION_REGEX: RegExp = new RegExp('_[\\dx_]+\\.\\w+');
const IMAGES_DOMAIN_AND_PATH: string = 'https://f4.bcbits.com/img/';

/** The single host the whole service hangs off. */
export const BASE_URL: string = 'https://bandcamp.com';
export const BASE_API_URL: string = BASE_URL + '/api';

/** The mobile endpoints, as path suffixes onto BASE_API_URL - never full-URL literals. */
const TRALBUM_DETAILS_PATH: string = '/mobile/22/tralbum_details';
const BAND_DETAILS_PATH: string = '/mobile/22/band_details';

const ARTIST_SUBDOMAIN_PATTERN: RegExp = new RegExp('^https?://.+\\.bandcamp\\.com(/.*)?$');
const BANDCAMP_ROOT_PATTERN: RegExp = new RegExp('^https?://bandcamp\\.com(/.*)?$');
const RADIO_URL_PATTERN: RegExp = new RegExp('^https?://bandcamp\\.com/\\?show=\\d+$');

export class BandcampExtractorHelper {
  /** "bandId|itemId|itemType" -> the album/track URL the mobile API translates it to. */
  private static readonly streamUrlCache: Map<string, string> = new Map<string, string>();
  /** band id -> the band_details response. */
  private static readonly artistDetailsCache: Map<string, JsonObject> =
    new Map<string, JsonObject>();
  /** custom domain URL -> whether its footer links back to Bandcamp. */
  private static readonly artistDomainCache: Map<string, boolean> = new Map<string, boolean>();

  private static requireDownloader(): Downloader {
    const dl: Downloader | null = NewPipe.getDownloader();
    if (dl === null) {
      throw new ExtractionException('NewPipe was not initialised with a Downloader');
    }
    return dl;
  }

  private static streamUrlKey(bandId: number, itemId: number, itemType: string): string {
    return `${bandId}|${itemId}|${itemType}`;
  }

  /**
   * Translate all these parameters together to the URL of the corresponding album or track
   * using the mobile API. Memoized for the synchronous getStreamUrlFromIds() below.
   */
  static async resolveStreamUrlFromIds(bandId: number, itemId: number,
    itemType: string): Promise<string> {
    const key: string = BandcampExtractorHelper.streamUrlKey(bandId, itemId, itemType);
    const cached: string | undefined = BandcampExtractorHelper.streamUrlCache.get(key);
    if (cached !== undefined) {
      return cached;
    }

    try {
      const jsonString: string = (await BandcampExtractorHelper.requireDownloader().get(
        BASE_API_URL + TRALBUM_DETAILS_PATH + '?band_id=' + bandId
        + '&tralbum_id=' + itemId + '&tralbum_type=' + itemType.charAt(0))).responseBody();

      const url: string | null = replaceHttpWithHttps(
        JsonParser.object().from(jsonString).getString('bandcamp_url'));
      const resolved: string = url === null ? '' : url;
      BandcampExtractorHelper.streamUrlCache.set(key, resolved);
      return resolved;
    } catch (e) {
      throw new ParsingException('Ids could not be translated to URL',
        e instanceof Error ? e as Error : null);
    }
  }

  /** The synchronous reader the info-item extractors' getUrl() needs. */
  static getStreamUrlFromIds(bandId: number, itemId: number, itemType: string): string {
    const cached: string | undefined = BandcampExtractorHelper.streamUrlCache.get(
      BandcampExtractorHelper.streamUrlKey(bandId, itemId, itemType));
    if (cached === undefined) {
      throw new ParsingException('Ids could not be translated to URL: not resolved yet'
        + ' - await BandcampExtractorHelper.resolveStreamUrlFromIds() first');
    }
    return cached;
  }

  /**
   * Fetch artist details from the mobile endpoint. Memoized for the synchronous
   * getArtistDetails() below.
   */
  static async resolveArtistDetails(id: string): Promise<JsonObject> {
    const cached: JsonObject | undefined = BandcampExtractorHelper.artistDetailsCache.get(id);
    if (cached !== undefined) {
      return cached;
    }

    try {
      const body: ArrayBuffer = Request.utf8Body(JsonWriter.string()
        .object()
        .value('band_id', id)
        .end()
        .done());
      const details: JsonObject = JsonParser.object().from(
        (await BandcampExtractorHelper.requireDownloader().postWithContentTypeJson(
          BASE_API_URL + BAND_DETAILS_PATH, new Map<string, string[]>(), body)).responseBody());
      BandcampExtractorHelper.artistDetailsCache.set(id, details);
      return details;
    } catch (e) {
      throw new ParsingException('Could not download band details',
        e instanceof Error ? e as Error : null);
    }
  }

  /** The synchronous reader the channel link-handler factory's getUrl() needs. */
  static getArtistDetails(id: string): JsonObject {
    const cached: JsonObject | undefined = BandcampExtractorHelper.artistDetailsCache.get(id);
    if (cached === undefined) {
      throw new ParsingException('Could not download band details: not resolved yet'
        + ' - await BandcampExtractorHelper.resolveArtistDetails(id) first');
    }
    return cached;
  }

  /**
   * Generate an image url from an image ID.
   *
   * The image ID 10 was chosen because it provides images wide up to 1200px (when the original
   * image width is more than or equal this resolution).
   */
  static getImageUrl(id: number, isAlbum: boolean): string {
    return IMAGES_DOMAIN_AND_PATH + (isAlbum ? 'a' : '') + id + '_10.jpg';
  }

  /**
   * Whether the given URL looks like it comes from a bandcamp custom domain or a
   * `*.bandcamp.com` subdomain. The custom-domain branch needs a request, so it is memoized by
   * resolveIsArtistDomain(); an unresolved custom domain reads as false here rather than
   * blocking - the factories' *Async entry points resolve it first.
   */
  static isArtistDomain(url: string): boolean {
    const lowercaseUrl: string = url.toLowerCase();

    // Accept all bandcamp.com URLs
    if (ARTIST_SUBDOMAIN_PATTERN.test(lowercaseUrl)) {
      return true;
    }

    // Reject non-artist bandcamp.com URLs
    if (BANDCAMP_ROOT_PATTERN.test(lowercaseUrl)) {
      return false;
    }

    const cached: boolean | undefined =
      BandcampExtractorHelper.artistDomainCache.get(lowercaseUrl);
    return cached === undefined ? false : cached;
  }

  /** Does the custom-domain footer probe and memoizes it for isArtistDomain(). */
  static async resolveIsArtistDomain(url: string): Promise<boolean> {
    const lowercaseUrl: string = url.toLowerCase();

    if (ARTIST_SUBDOMAIN_PATTERN.test(lowercaseUrl)) {
      return true;
    }
    if (BANDCAMP_ROOT_PATTERN.test(lowercaseUrl)) {
      return false;
    }

    const cached: boolean | undefined =
      BandcampExtractorHelper.artistDomainCache.get(lowercaseUrl);
    if (cached !== undefined) {
      return cached;
    }

    let isArtist: boolean;
    try {
      const https: string | null = replaceHttpWithHttps(lowercaseUrl);
      // Test other URLs for whether they contain a footer that links to bandcamp
      const body: string = (await BandcampExtractorHelper.requireDownloader()
        .get(https === null ? lowercaseUrl : https)).responseBody();
      const cart: Element | null = Jsoup.parse(body).getElementsByClass('cart-wrapper').first();
      const link: Element | null = cart === null ? null : cart.getElementsByTag('a').first();
      isArtist = link !== null && link.attr('href') === 'https://bandcamp.com/cart';
    } catch (e) {
      throw new ParsingException('Could not determine whether URL is custom domain '
        + '(not available? network error?)');
    }

    BandcampExtractorHelper.artistDomainCache.set(lowercaseUrl, isArtist);
    return isArtist;
  }

  /** Whether the URL points to a radio kiosk (`https://bandcamp.com/?show=SHOW_ID`). */
  static isRadioUrl(url: string): boolean {
    return RADIO_URL_PATTERN.test(url.toLowerCase());
  }

  /** Java parsed "dd MMM yyyy HH:mm:ss zzz"; Date accepts that spelling directly. */
  static parseDate(textDate: string | null): DateWrapper | null {
    if (textDate === null) {
      return null;
    }
    const parsed: Date = new Date(textDate);
    if (Number.isNaN(parsed.getTime())) {
      throw new ParsingException('Could not parse date \'' + textDate + '\'');
    }
    return new DateWrapper(parsed);
  }

  /**
   * The images of a search result element: the first non-empty `src` of an `img` inside its
   * `art` element, or an empty list when there is none.
   */
  static getImagesFromSearchResult(searchResult: Element): Image[] {
    for (const art of searchResult.getElementsByClass('art').toArray()) {
      for (const img of art.getElementsByTag('img').toArray()) {
        const imageUrl: string = img.attr('src');
        if (!isNullOrEmpty(imageUrl)) {
          return BandcampExtractorHelper.getImagesFromImageUrl(imageUrl);
        }
      }
    }
    return BandcampExtractorHelper.getImagesFromImageUrl('');
  }

  /**
   * All aspect-ratio-preserving resolutions of a full Bandcamp image URL: the image ID and its
   * extension are stripped off the end and the known suffixes appended instead.
   */
  static getImagesFromImageUrl(imageUrl: string | null): Image[] {
    if (isNullOrEmpty(imageUrl)) {
      return [];
    }

    return BandcampExtractorHelper.getImagesFromImageBaseUrl(
      (imageUrl as string).replace(IMAGE_URL_APPENDIX_AND_EXTENSION_REGEX, '_'));
  }

  /** All aspect-ratio-preserving resolutions of an image ID; empty when the ID is 0. */
  static getImagesFromImageId(id: number, isAlbum: boolean): Image[] {
    if (id === 0) {
      return [];
    }

    return BandcampExtractorHelper.getImagesFromImageBaseUrl(
      IMAGES_DOMAIN_AND_PATH + (isAlbum ? 'a' : '') + id + '_');
  }

  private static getImagesFromImageBaseUrl(baseUrl: string): Image[] {
    const images: Image[] = [];
    for (const imageSuffix of IMAGE_URL_SUFFIXES_AND_RESOLUTIONS) {
      images.push(new Image(baseUrl + imageSuffix.getSuffix(), imageSuffix.getHeight(),
        imageSuffix.getWidth(), imageSuffix.getResolutionLevel()));
    }
    return images;
  }
}
