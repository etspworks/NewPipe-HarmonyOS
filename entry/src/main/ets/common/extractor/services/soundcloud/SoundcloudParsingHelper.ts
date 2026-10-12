/*
 * Port of org.schabi.newpipe.extractor.services.soundcloud.SoundcloudParsingHelper
 * (NewPipeExtractor v0.26.5).
 *
 * Everything SoundCloud does needs a `client_id`, and SoundCloud does not publish one: it is
 * scraped out of the site's own asset JS (reached from https://soundcloud.com/) and appended to
 * every API call. That bootstrap is ported verbatim below - without it every SoundCloud request
 * fails authorization.
 *
 * ArkTS deviations from the Java source:
 *  - every method that touches the network is a Promise (phase2-logic-contract.md §1);
 *  - `ServiceList.SoundCloud` cannot be imported (it is the C1 lane's module and would make an
 *    init-time cycle), so SoundcloudService registers itself here with setService() and
 *    getLocalization() reads it back;
 *  - the id/url resolutions are memoized, because LinkHandlerFactory.getId()/getUrl() are
 *    SYNCHRONOUS in the ported core while SoundCloud resolves both over the network. The async
 *    resolvers below fill those caches; the factories read them synchronously.
 */

import { Image } from '../../../../model/extractor/Image';
import { ResolutionLevel } from '../../../../model/enums/ImageResolutionLevel';
import { ChannelInfoItemsCollector } from '../../info/ChannelExtractor';
import { StreamInfoItemsCollector } from '../../info/StreamInfoItemsCollector';
import { ImageSuffix } from '../../core/ImageSuffix';
import { JsonUtils } from '../../core/JsonUtils';
import { NewPipe } from '../../core/NewPipe';
import { Parser, RegexException } from '../../core/Parser';
import { StreamingService } from '../../core/StreamingService';
import {
  encodeUrlUtf8,
  isNullOrEmpty,
  removeMAndWWWFromUrl,
  replaceHttpWithHttps,
  stringToURL
} from '../../core/Utils';
import { Downloader, HeaderMap, Response } from '../../downloader/Downloader';
import { Localization } from '../../downloader/Localization';
import { ExtractionException, IOException, ParsingException } from '../../exceptions/Exceptions';
import { Document, Element, Jsoup } from '../../html/Jsoup';
import { JsonArray, JsonObject, JsonParser, JsonParserException } from '../../json/NanoJson';
import { DateWrapper } from '../../localization/DateWrapper';
import { MultiInfoItemsCollector } from '../../core/MultiInfoItemsCollector';
import { SoundcloudChannelInfoItemExtractor } from './extractors/SoundcloudChannelInfoItemExtractor';
import { SoundcloudLikesInfoItemExtractor } from './extractors/SoundcloudLikesInfoItemExtractor';
import { SoundcloudPlaylistInfoItemExtractor } from './extractors/SoundcloudPlaylistInfoItemExtractor';
import { SoundcloudStreamInfoItemExtractor } from './extractors/SoundcloudStreamInfoItemExtractor';

/** The SoundCloud API v2 base every modern endpoint hangs off. */
export const SOUNDCLOUD_API_V2_URL: string = 'https://api-v2.soundcloud.com/';

/*
 SoundCloud avatars and artworks are almost always squares.

 When we get non-square pictures, all these images variants are still squares, except the
 original and the crop versions provides images which are respecting aspect ratios.
 The websites only use the square variants.

 t2400x2400 and t3000x3000 variants also exists, but are not returned as several images are
 uploaded with a lower size than these variants: in this case, these variants return an upscaled
 version of the original image.
 */
const ALBUMS_AND_ARTWORKS_IMAGE_SUFFIXES: ImageSuffix[] = [
  new ImageSuffix('mini', 16, 16, ResolutionLevel.LOW),
  new ImageSuffix('t20x20', 20, 20, ResolutionLevel.LOW),
  new ImageSuffix('small', 32, 32, ResolutionLevel.LOW),
  new ImageSuffix('badge', 47, 47, ResolutionLevel.LOW),
  new ImageSuffix('t50x50', 50, 50, ResolutionLevel.LOW),
  new ImageSuffix('t60x60', 60, 60, ResolutionLevel.LOW),
  // Seems to work also on avatars, even if it is written to be not the case in the old API docs
  new ImageSuffix('t67x67', 67, 67, ResolutionLevel.LOW),
  new ImageSuffix('t80x80', 80, 80, ResolutionLevel.LOW),
  new ImageSuffix('large', 100, 100, ResolutionLevel.LOW),
  new ImageSuffix('t120x120', 120, 120, ResolutionLevel.LOW),
  new ImageSuffix('t200x200', 200, 200, ResolutionLevel.MEDIUM),
  new ImageSuffix('t240x240', 240, 240, ResolutionLevel.MEDIUM),
  new ImageSuffix('t250x250', 250, 250, ResolutionLevel.MEDIUM),
  new ImageSuffix('t300x300', 300, 300, ResolutionLevel.MEDIUM),
  new ImageSuffix('t500x500', 500, 500, ResolutionLevel.MEDIUM)
];

const VISUALS_IMAGE_SUFFIXES: ImageSuffix[] = [
  new ImageSuffix('t1240x260', 1240, 260, ResolutionLevel.MEDIUM),
  new ImageSuffix('t2480x520', 2480, 520, ResolutionLevel.MEDIUM)
];

const ON_URL_PATTERN: RegExp = new RegExp('^https?://on.soundcloud.com/[0-9a-zA-Z]+$');

export class SoundcloudParsingHelper {
  private static clientIdValue: string = '';
  private static service: StreamingService | null = null;

  /** url -> resolved numeric id, filled by resolveIdWithWidgetApi(). */
  private static readonly idCache: Map<string, string> = new Map<string, string>();
  /** api url -> canonical permalink url, filled by resolveUrlWithEmbedPlayer(). */
  private static readonly urlCache: Map<string, string> = new Map<string, string>();

  /** SoundcloudService registers itself here; replaces `ServiceList.SoundCloud`. */
  static setService(service: StreamingService): void {
    SoundcloudParsingHelper.service = service;
  }

  /** Port of the source's `SoundCloud.getLocalization()` calls. */
  static getLocalization(): Localization {
    const service: StreamingService | null = SoundcloudParsingHelper.service;
    return service === null ? NewPipe.getPreferredLocalization() : service.getLocalization();
  }

  private static requireDownloader(): Downloader {
    const dl: Downloader | null = NewPipe.getDownloader();
    if (dl === null) {
      throw new ExtractionException('NewPipe was not initialised with a Downloader');
    }
    return dl;
  }

  /**
   * The client_id bootstrap. SoundCloud does not hand one out, so it is read out of the site's
   * own asset bundle: load https://soundcloud.com/, take the `sndcdn.com/assets/*.js` script
   * tags (the last one usually carries it), fetch the first 50 kB of each and match
   * `,client_id:"..."`. Memoized for the process, exactly as the Java `static String clientId`.
   */
  static async clientId(): Promise<string> {
    if (!isNullOrEmpty(SoundcloudParsingHelper.clientIdValue)) {
      return SoundcloudParsingHelper.clientIdValue;
    }

    const dl: Downloader = SoundcloudParsingHelper.requireDownloader();

    const download: Response = await dl.get('https://soundcloud.com');
    const responseBody: string = download.responseBody();
    const clientIdPattern: string = ',client_id:"(.*?)"';

    const doc: Document = Jsoup.parse(responseBody);
    const possibleScripts: Element[] = doc.select('script[src*="sndcdn.com/assets/"][src$=".js"]')
      .toArray();
    // The one containing the client id will likely be the last one
    possibleScripts.reverse();

    const headers: HeaderMap = new Map<string, string[]>();
    headers.set('Range', ['bytes=0-50000']);

    for (const element of possibleScripts) {
      const srcUrl: string = element.attr('src');
      if (!isNullOrEmpty(srcUrl)) {
        try {
          const scriptBody: string = (await dl.get(srcUrl, headers)).responseBody();
          SoundcloudParsingHelper.clientIdValue =
            Parser.matchGroup1OfString(clientIdPattern, scriptBody);
          return SoundcloudParsingHelper.clientIdValue;
        } catch (e) {
          if (!(e instanceof RegexException)) {
            throw e;
          }
          // Ignore it and proceed to try searching other script
        }
      }
    }

    // Officially give up
    throw new ExtractionException('Couldn\'t extract client id');
  }

  /**
   * The bootstrapped client_id if clientId() has already run, else null. The synchronous
   * LinkHandlerFactory.getUrl() overrides need it without being able to await.
   */
  static cachedClientId(): string | null {
    return isNullOrEmpty(SoundcloudParsingHelper.clientIdValue)
      ? null : SoundcloudParsingHelper.clientIdValue;
  }

  static parseDate(uploadDate: string | null): DateWrapper | null {
    if (uploadDate === null) {
      return null;
    }
    try {
      return DateWrapper.fromInstant(uploadDate);
    } catch (e) {
      // The second Java format is "yyyy/MM/dd HH:mm:ss +0000"; Date parses it once the date part
      // uses dashes and the offset carries a colon.
      const normalized: string = uploadDate.trim()
        .replace('/', '-')
        .replace('/', '-')
        .replace(' ', 'T')
        .replace(' +0000', '+00:00')
        .replace(' -0000', '+00:00');
      const parsed: Date = new Date(normalized);
      if (Number.isNaN(parsed.getTime())) {
        throw new ParsingException('Could not parse date: "' + uploadDate + '"');
      }
      return new DateWrapper(parsed);
    }
  }

  /**
   * Call the endpoint "/resolve" of the API.
   *
   * See https://developers.soundcloud.com/docs/api/reference#resolve
   */
  static async resolveFor(downloader: Downloader, url: string): Promise<JsonObject> {
    const apiUrl: string = SOUNDCLOUD_API_V2_URL + 'resolve'
      + '?url=' + encodeUrlUtf8(url)
      + '&client_id=' + await SoundcloudParsingHelper.clientId();

    const response: string = (await downloader.get(apiUrl, null,
      SoundcloudParsingHelper.getLocalization())).responseBody();
    try {
      return JsonParser.object().from(response);
    } catch (e) {
      throw new ParsingException('Could not parse json response',
        e instanceof Error ? e as Error : null);
    }
  }

  /**
   * Fetch the embed player with the apiUrl and return the canonical url (like the permalink_url
   * from the json API). Memoized so the SYNCHRONOUS LinkHandlerFactory.getUrl() can read it.
   */
  static async resolveUrlWithEmbedPlayer(apiUrl: string): Promise<string> {
    const cached: string | undefined = SoundcloudParsingHelper.urlCache.get(apiUrl);
    if (cached !== undefined) {
      return cached;
    }

    const dl: Downloader = SoundcloudParsingHelper.requireDownloader();
    const response: string = (await dl.get('https://w.soundcloud.com/player/?url='
      + encodeUrlUtf8(apiUrl), null, SoundcloudParsingHelper.getLocalization())).responseBody();

    const canonical: Element | null = Jsoup.parse(response).select('link[rel="canonical"]').first();
    if (canonical === null) {
      throw new ParsingException('Could not resolve url with embed player: ' + apiUrl);
    }
    const resolved: string = canonical.absUrl('href');
    SoundcloudParsingHelper.urlCache.set(apiUrl, resolved);
    return resolved;
  }

  /** The canonical url already resolved for this api url, or null when it has not been yet. */
  static cachedUrl(apiUrl: string): string | null {
    const cached: string | undefined = SoundcloudParsingHelper.urlCache.get(apiUrl);
    return cached === undefined ? null : cached;
  }

  /**
   * Fetch the widget API with the url and return the id (like the id from the json API).
   * Memoized under the ORIGINAL url string so the synchronous getId() can read it back.
   */
  static async resolveIdWithWidgetApi(urlString: string): Promise<string> {
    const cached: string | undefined = SoundcloudParsingHelper.idCache.get(urlString);
    if (cached !== undefined) {
      return cached;
    }

    let fixedUrl: string = urlString;

    // if URL is an on.soundcloud link, do a request to resolve the redirect
    if (ON_URL_PATTERN.test(fixedUrl)) {
      try {
        // ponytail: KNOWN CEILING - Response.latestUrl() cannot report the POST-REDIRECT url on
        // HarmonyOS. @ohos.net.http follows redirects internally and exposes no final url at
        // API 12 (maxRedirects is API 23), so the ported Response falls back to
        // Content-Location and then to the request url. When SoundCloud's on.soundcloud.com
        // shortener answers with a plain 30x that carries no Content-Location, latestUrl()
        // returns the SHORT url unchanged and the widget resolve below fails for that link.
        // Upgrade path: raise the target API to 23 and set maxRedirects: 0 in DownloaderImpl so
        // the Location header can be read directly.
        fixedUrl = (await SoundcloudParsingHelper.requireDownloader().head(fixedUrl)).latestUrl();
        // remove tracking params which are in the query string
        fixedUrl = fixedUrl.split('?')[0];
      } catch (e) {
        throw new ParsingException('Could not follow on.soundcloud.com redirect',
          e instanceof Error ? e as Error : null);
      }
    }

    // Remove the tailing slash from URLs due to issues with the SoundCloud API
    if (fixedUrl.charAt(fixedUrl.length - 1) === '/') {
      fixedUrl = fixedUrl.substring(0, fixedUrl.length - 1);
    }
    // Make URL lower case and remove m. and www. if it exists.
    // Without doing this, the widget API does not recognize the URL.
    fixedUrl = removeMAndWWWFromUrl(fixedUrl.toLowerCase());

    const url: string = stringToURL(fixedUrl).toString();

    try {
      const widgetUrl: string = 'https://api-widget.soundcloud.com/resolve?url='
        + encodeUrlUtf8(url)
        + '&format=json&client_id=' + await SoundcloudParsingHelper.clientId();
      const response: string = (await SoundcloudParsingHelper.requireDownloader().get(widgetUrl,
        null, SoundcloudParsingHelper.getLocalization())).responseBody();
      const o: JsonObject = JsonParser.object().from(response);
      const id: string = `${JsonUtils.getValue(o, 'id')}`;
      SoundcloudParsingHelper.idCache.set(urlString, id);
      return id;
    } catch (e) {
      if (e instanceof JsonParserException) {
        throw new ParsingException('Could not parse JSON response', e as Error);
      }
      throw new ParsingException(
        'Could not resolve id with embedded player. ClientId not extracted',
        e instanceof Error ? e as Error : null);
    }
  }

  /** The id already resolved for this url, or null when it has not been resolved yet. */
  static cachedId(urlString: string): string | null {
    const cached: string | undefined = SoundcloudParsingHelper.idCache.get(urlString);
    return cached === undefined ? null : cached;
  }

  /**
   * Fetch the users from the given API and commit each of them to the collector, returning only
   * once at least `minItems` have been collected.
   */
  static async getUsersFromApiMinItems(minItems: number, collector: ChannelInfoItemsCollector,
    apiUrl: string): Promise<string> {
    let nextPageUrl: string = await SoundcloudParsingHelper.getUsersFromApi(collector, apiUrl);

    while (nextPageUrl.length > 0 && collector.getItems().length < minItems) {
      nextPageUrl = await SoundcloudParsingHelper.getUsersFromApi(collector, nextPageUrl);
    }

    return nextPageUrl;
  }

  /** Fetch the user items from the given API; returns the next page url, empty if there is none. */
  static async getUsersFromApi(collector: ChannelInfoItemsCollector,
    apiUrl: string): Promise<string> {
    const response: string = (await SoundcloudParsingHelper.requireDownloader().get(apiUrl, null,
      SoundcloudParsingHelper.getLocalization())).responseBody();
    let responseObject: JsonObject;

    try {
      responseObject = JsonParser.object().from(response);
    } catch (e) {
      throw new ParsingException('Could not parse json response',
        e instanceof Error ? e as Error : null);
    }

    const responseCollection: JsonArray = responseObject.getArray('collection');
    for (const o of responseCollection.streamAsJsonObjects()) {
      collector.commit(new SoundcloudChannelInfoItemExtractor(o));
    }

    return SoundcloudParsingHelper.getNextPageUrl(responseObject);
  }

  /**
   * Fetch the streams from the given API and commit each of them to the collector, returning only
   * once at least `minItems` have been collected.
   */
  static async getStreamsFromApiMinItems(minItems: number, collector: StreamInfoItemsCollector,
    apiUrl: string): Promise<string> {
    let nextPageUrl: string = await SoundcloudParsingHelper.getStreamsFromApi(collector, apiUrl);

    while (nextPageUrl.length > 0 && collector.getItems().length < minItems) {
      nextPageUrl = await SoundcloudParsingHelper.getStreamsFromApi(collector, nextPageUrl);
    }

    return nextPageUrl;
  }

  /** Fetch the streams from the given API; returns the next page url, empty if there is none. */
  static async getStreamsFromApi(collector: StreamInfoItemsCollector, apiUrl: string,
    charts: boolean = false): Promise<string> {
    const response: Response = await SoundcloudParsingHelper.requireDownloader().get(apiUrl, null,
      SoundcloudParsingHelper.getLocalization());
    if (response.responseCode() >= 400) {
      throw new IOException('Could not get streams from API, HTTP ' + response.responseCode());
    }

    let responseObject: JsonObject;
    try {
      responseObject = JsonParser.object().from(response.responseBody());
    } catch (e) {
      throw new ParsingException('Could not parse json response',
        e instanceof Error ? e as Error : null);
    }

    const responseCollection: JsonArray = responseObject.getArray('collection');
    for (const o of responseCollection.streamAsJsonObjects()) {
      collector.commit(new SoundcloudStreamInfoItemExtractor(
        charts ? o.getObject('track') : o));
    }

    return SoundcloudParsingHelper.getNextPageUrl(responseObject);
  }

  private static async getNextPageUrl(response: JsonObject): Promise<string> {
    try {
      let nextPageUrl: string | null = response.getString('next_href');
      if (nextPageUrl === null || nextPageUrl.length === 0) {
        return '';
      }
      if (!nextPageUrl.includes('client_id=')) {
        nextPageUrl += '&client_id=' + await SoundcloudParsingHelper.clientId();
      }
      return nextPageUrl;
    } catch (e) {
      return '';
    }
  }

  /** The mixed user/track/playlist/like feed shape - search results and channel tabs. */
  static async getInfoItemsFromApi(collector: MultiInfoItemsCollector,
    apiUrl: string): Promise<string> {
    const response: Response = await SoundcloudParsingHelper.requireDownloader().get(apiUrl, null,
      SoundcloudParsingHelper.getLocalization());
    if (response.responseCode() >= 400) {
      throw new IOException('Could not get streams from API, HTTP ' + response.responseCode());
    }

    let responseObject: JsonObject;
    try {
      responseObject = JsonParser.object().from(response.responseBody());
    } catch (e) {
      throw new ParsingException('Could not parse json response',
        e instanceof Error ? e as Error : null);
    }

    for (const searchResult of responseObject.getArray('collection').streamAsJsonObjects()) {
      const kind: string | null = searchResult.getString('kind', '');
      if (kind === 'user') {
        collector.commit(new SoundcloudChannelInfoItemExtractor(searchResult));
      } else if (kind === 'track') {
        collector.commit(new SoundcloudStreamInfoItemExtractor(searchResult));
      } else if (kind === 'playlist') {
        collector.commit(new SoundcloudPlaylistInfoItemExtractor(searchResult));
      } else if (kind === 'like') {
        // Soundcloud users can like tracks or playlists and all end up in the `Likes` feed, so
        // they should be handled by the correct extractor.
        const likedPlaylist: JsonObject | null = searchResult.has('playlist')
          ? searchResult.getObject('playlist') : null;
        collector.commit(likedPlaylist === null
          ? new SoundcloudLikesInfoItemExtractor(searchResult)
          : new SoundcloudPlaylistInfoItemExtractor(likedPlaylist));
      }
    }

    return SoundcloudParsingHelper.getNextPageUrl(responseObject);
  }

  static getUploaderUrl(object: JsonObject): string {
    const url: string | null = object.getObject('user').getString('permalink_url', '');
    const https: string | null = replaceHttpWithHttps(url);
    return https === null ? '' : https;
  }

  static getAvatarUrl(object: JsonObject): string {
    const url: string | null = object.getObject('user').getString('avatar_url', '');
    const https: string | null = replaceHttpWithHttps(url);
    return https === null ? '' : https;
  }

  static getUploaderName(object: JsonObject): string {
    const name: string | null = object.getObject('user').getString('username', '');
    return name === null ? '' : name;
  }

  static getAllImagesFromTrackObject(trackObject: JsonObject): Image[] {
    const artworkUrl: string | null = trackObject.getString('artwork_url');
    if (artworkUrl !== null) {
      return SoundcloudParsingHelper.getAllImagesFromArtworkOrAvatarUrl(artworkUrl);
    }
    const avatarUrl: string | null = trackObject.getObject('user').getString('avatar_url');
    if (avatarUrl !== null) {
      return SoundcloudParsingHelper.getAllImagesFromArtworkOrAvatarUrl(avatarUrl);
    }

    throw new ParsingException('Could not get track or track user\'s thumbnails');
  }

  static getAllImagesFromArtworkOrAvatarUrl(
    originalArtworkOrAvatarUrl: string | null): Image[] {
    if (isNullOrEmpty(originalArtworkOrAvatarUrl)) {
      return [];
    }

    // Artwork and avatars are originally returned with the "large" resolution, which is 100px wide
    return SoundcloudParsingHelper.getAllImagesFromImageUrlReturned(
      (originalArtworkOrAvatarUrl as string).replace('-large.', '-%s.'),
      ALBUMS_AND_ARTWORKS_IMAGE_SUFFIXES);
  }

  static getAllImagesFromVisualUrl(originalVisualUrl: string | null): Image[] {
    if (isNullOrEmpty(originalVisualUrl)) {
      return [];
    }

    // Images are originally returned with the "original" resolution, which may be huge so don't
    // include it for size purposes
    return SoundcloudParsingHelper.getAllImagesFromImageUrlReturned(
      (originalVisualUrl as string).replace('-original.', '-%s.'),
      VISUALS_IMAGE_SUFFIXES);
  }

  private static getAllImagesFromImageUrlReturned(baseImageUrlFormat: string,
    imageSuffixes: ImageSuffix[]): Image[] {
    const images: Image[] = [];
    for (const imageSuffix of imageSuffixes) {
      images.push(new Image(baseImageUrlFormat.replace('%s', imageSuffix.getSuffix()),
        imageSuffix.getHeight(), imageSuffix.getWidth(), imageSuffix.getResolutionLevel()));
    }
    return images;
  }
}
