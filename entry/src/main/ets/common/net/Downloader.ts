/*
 * svc_downloader - the concrete Downloader, mirroring app/src/main/java/org/schabi/newpipe/
 * DownloaderImpl.java (NewPipe, vendored source) on top of @ohos.net.http.
 *
 * THE single HTTP door of this app. Every endpoint in the Phase-2 logic contract section 3
 * (InnerTube's three hosts, suggestqueries, the YouTube feed RSS, SoundCloud api-v2 +
 * api-widget + the client_id bootstrap, api.media.ccc.de, PeerTube instances + sepiasearch,
 * bandcamp.com, the PO-token jnn endpoints, newpipe.net/api/data.json) goes through execute().
 * No other module opens an HTTP connection.
 *
 * Faithful to DownloaderImpl:
 *   - the fixed Firefox User-Agent,
 *   - restricted-mode + reCaptcha cookies merged, de-duplicated and joined with "; ",
 *   - request headers override the defaults,
 *   - HTTP 429 -> ReCaptchaException carrying the URL, which drives the reCaptcha screen,
 *   - a 30 s read timeout.
 * `httpRequest.destroy()` runs in `finally` on every path (Rule 8): the handle is native and
 * is not reclaimed by GC.
 */

import { http } from '@kit.NetworkKit';
import { Downloader, HeaderMap, Request, Response } from '../extractor/downloader/Downloader';
import { IOException, ReCaptchaException } from '../extractor/exceptions/Exceptions';

/** Verbatim from DownloaderImpl.USER_AGENT. */
export const USER_AGENT: string =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0';
/** Verbatim from DownloaderImpl. */
export const YOUTUBE_RESTRICTED_MODE_COOKIE_KEY: string = 'youtube_restricted_mode_key';
export const YOUTUBE_RESTRICTED_MODE_COOKIE: string = 'PREF=f2=8000000';
export const YOUTUBE_DOMAIN: string = 'youtube.com';
/** Verbatim from ReCaptchaActivity.RECAPTCHA_COOKIES_KEY. */
export const RECAPTCHA_COOKIES_KEY: string = 'recaptcha_cookies';

const READ_TIMEOUT_MS: number = 30000;

/**
 * OkHttp reports a reason phrase; @ohos.net.http reports only the status code. These are the
 * standard phrases for the codes NewPipe surfaces in its error reports.
 */
const REASON_PHRASES: Map<number, string> = new Map<number, string>([
  [200, 'OK'],
  [204, 'No Content'],
  [301, 'Moved Permanently'],
  [302, 'Found'],
  [400, 'Bad Request'],
  [401, 'Unauthorized'],
  [403, 'Forbidden'],
  [404, 'Not Found'],
  [410, 'Gone'],
  [429, 'Too Many Requests'],
  [500, 'Internal Server Error'],
  [502, 'Bad Gateway'],
  [503, 'Service Unavailable']
]);

function reasonPhrase(code: number): string {
  const phrase: string | undefined = REASON_PHRASES.get(code);
  return phrase === undefined ? '' : phrase;
}

function toRequestMethod(httpMethod: string): http.RequestMethod {
  const method: string = httpMethod.toUpperCase();
  if (method === 'GET') {
    return http.RequestMethod.GET;
  }
  if (method === 'POST') {
    return http.RequestMethod.POST;
  }
  if (method === 'HEAD') {
    return http.RequestMethod.HEAD;
  }
  if (method === 'PUT') {
    return http.RequestMethod.PUT;
  }
  if (method === 'DELETE') {
    return http.RequestMethod.DELETE;
  }
  if (method === 'OPTIONS') {
    return http.RequestMethod.OPTIONS;
  }
  if (method === 'TRACE') {
    return http.RequestMethod.TRACE;
  }
  throw new IOException(`Unsupported HTTP method ${httpMethod}`);
}

/**
 * @ohos.net.http hands the response headers back as a plain object whose values are either a
 * string or an array of strings (Set-Cookie). Normalised here into the extractor's
 * Map<string, string[]>, with the names lowercased the way OkHttp's toMultimap() does.
 */
function toHeaderMap(rawHeader: Object): HeaderMap {
  const headers: HeaderMap = new Map<string, string[]>();
  const record: Record<string, Object> = rawHeader as Record<string, Object>;
  for (const name of Object.keys(record)) {
    const value: Object = record[name];
    const values: string[] = [];
    if (Array.isArray(value)) {
      for (const item of value as Object[]) {
        values.push(`${item}`);
      }
    } else {
      values.push(`${value}`);
    }
    headers.set(name.toLowerCase(), values);
  }
  return headers;
}

export class DownloaderImpl extends Downloader {
  private static instance: DownloaderImpl | null = null;

  private readonly cookies: Map<string, string> = new Map<string, string>();
  private cacheInvalidator: (() => void) | null = null;

  /** Port of DownloaderImpl.init(): called exactly once for the lifetime of the app. */
  static init(): DownloaderImpl {
    const created: DownloaderImpl = new DownloaderImpl();
    DownloaderImpl.instance = created;
    return created;
  }

  static getInstance(): DownloaderImpl {
    let current: DownloaderImpl | null = DownloaderImpl.instance;
    if (current === null) {
      current = DownloaderImpl.init();
    }
    return current;
  }

  /**
   * The source calls InfoCache.getInstance().clearCache() when the restricted-mode cookie
   * changes. InfoCache is ported in a later wave; it registers itself here so the invalidation
   * still happens and is not silently dropped.
   */
  setCacheInvalidator(invalidator: () => void): void {
    this.cacheInvalidator = invalidator;
  }

  getCookie(key: string): string | null {
    const value: string | undefined = this.cookies.get(key);
    return value === undefined ? null : value;
  }

  setCookie(key: string, cookie: string): void {
    this.cookies.set(key, cookie);
  }

  removeCookie(key: string): void {
    this.cookies.delete(key);
  }

  /**
   * Port of DownloaderImpl.getCookies(): the YouTube restricted-mode cookie only on a
   * youtube.com URL, the reCaptcha cookies always, split on ';', de-duplicated, rejoined
   * with "; ".
   */
  getCookies(url: string): string {
    const youtubeCookie: string | null = url.includes(YOUTUBE_DOMAIN)
      ? this.getCookie(YOUTUBE_RESTRICTED_MODE_COOKIE_KEY)
      : null;
    const sources: Array<string | null> = [youtubeCookie, this.getCookie(RECAPTCHA_COOKIES_KEY)];

    const seen: Set<string> = new Set<string>();
    const distinct: string[] = [];
    for (const source of sources) {
      if (source === null) {
        continue;
      }
      for (const part of source.split(';')) {
        const cookie: string = part.trim();
        if (cookie.length > 0 && !seen.has(cookie)) {
          seen.add(cookie);
          distinct.push(cookie);
        }
      }
    }
    return distinct.join('; ');
  }

  /** Port of updateYoutubeRestrictedModeCookies(boolean). */
  updateYoutubeRestrictedModeCookies(youtubeRestrictedModeEnabled: boolean): void {
    if (youtubeRestrictedModeEnabled) {
      this.setCookie(YOUTUBE_RESTRICTED_MODE_COOKIE_KEY, YOUTUBE_RESTRICTED_MODE_COOKIE);
    } else {
      this.removeCookie(YOUTUBE_RESTRICTED_MODE_COOKIE_KEY);
    }
    const invalidate: (() => void) | null = this.cacheInvalidator;
    if (invalidate !== null) {
      invalidate();
    }
  }

  /** Port of getContentLength(): size of the resource, from a HEAD request. */
  async getContentLength(url: string): Promise<number> {
    const response: Response = await this.head(url);
    const raw: string | null = response.getHeader('Content-Length');
    const parsed: number = raw === null ? NaN : parseInt(raw, 10);
    if (isNaN(parsed)) {
      throw new IOException('Invalid content length');
    }
    return parsed;
  }

  /** Port of DownloaderImpl.execute(Request). */
  async execute(request: Request): Promise<Response> {
    const url: string = request.url();
    const headerObject: Record<string, string> = {};
    headerObject['User-Agent'] = USER_AGENT;

    const cookies: string = this.getCookies(url);
    if (cookies.length > 0) {
      headerObject['Cookie'] = cookies;
    }

    // The request's own headers override any default above. @ohos.net.http carries one value
    // per header name, so a multi-valued header is joined the way HTTP allows.
    request.headers().forEach((values: string[], name: string): void => {
      headerObject[name] = values.join(', ');
    });

    const options: http.HttpRequestOptions = {
      method: toRequestMethod(request.httpMethod()),
      header: headerObject,
      expectDataType: http.HttpDataType.STRING,
      readTimeout: READ_TIMEOUT_MS
    };
    const body: ArrayBuffer | null = request.dataToSend();
    if (body !== null) {
      options.extraData = body;
    }

    const httpRequest: http.HttpRequest = http.createHttp();
    try {
      // A transport failure rejects with the platform's own BusinessError, whose message is
      // whatever the stack says - "Failed to resolve the host name" and friends. Left alone it
      // travels all the way to the screen, where the user reads it instead of the app's own
      // wording. IOException is the type the extractor layer already uses for exactly this.
      let raw: http.HttpResponse;
      try {
        raw = await httpRequest.request(url, options);
      } catch (transport) {
        const failure: Error = transport as Error;
        throw new IOException(failure.message, failure);
      }
      const code: number = raw.responseCode as number;
      if (code === 429) {
        throw new ReCaptchaException('reCaptcha Challenge requested', url);
      }
      const responseBody: string = raw.resultType === http.HttpDataType.STRING
        ? raw.result as string
        : '';
      const headers: HeaderMap = toHeaderMap(raw.header);
      // OkHttp reports response.request().url() after redirects. @ohos.net.http follows
      // redirects internally and does not expose the final URL at this API level, so the
      // canonical URL is taken from Content-Location when the service sends it.
      const contentLocation: string | undefined = headers.get('content-location') !== undefined
        ? (headers.get('content-location') as string[])[0]
        : undefined;
      const latestUrl: string = contentLocation === undefined ? url : contentLocation;

      return new Response(code, reasonPhrase(code), headers, responseBody, latestUrl);
    } finally {
      httpRequest.destroy();
    }
  }
}
