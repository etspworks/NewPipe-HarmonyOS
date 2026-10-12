/*
 * Port of org.schabi.newpipe.extractor.downloader (NewPipeExtractor v0.26.5, vendored at
 * input/source/NewPipeExtractor): Request + Request.Builder, Response, and the abstract
 * Downloader every extractor calls through.
 *
 * Two shape changes forced by the platform, and nothing else:
 *   - every method is async (Promise<Response>), because @ohos.net.http has no blocking form;
 *   - byte[] becomes ArrayBuffer, which is what http's `extraData` accepts.
 *
 * Java's checked `throws IOException, ReCaptchaException` becomes a rejected Promise carrying
 * IOException / ReCaptchaException from ../exceptions/Exceptions; callers discriminate with
 * `instanceof`.
 */

import { util } from '@kit.ArkTS';
import { Localization } from './Localization';

/** A header map. Java's Map<String, List<String>>; index signatures are banned in ArkTS. */
export type HeaderMap = Map<string, string[]>;

export class Request {
  private readonly httpMethodValue: string;
  private readonly urlValue: string;
  private readonly headersValue: HeaderMap;
  private readonly dataToSendValue: ArrayBuffer | null;
  private readonly localizationValue: Localization | null;

  constructor(httpMethod: string, url: string, headers: HeaderMap | null = null,
    dataToSend: ArrayBuffer | null = null, localization: Localization | null = null,
    automaticLocalizationHeader: boolean = true) {
    if (httpMethod.length === 0) {
      throw new Error("Request's httpMethod is null");
    }
    if (url.length === 0) {
      throw new Error("Request's url is null");
    }
    this.httpMethodValue = httpMethod;
    this.urlValue = url;
    this.dataToSendValue = dataToSend;
    this.localizationValue = localization;

    const actualHeaders: HeaderMap = new Map<string, string[]>();
    if (headers !== null) {
      headers.forEach((value: string[], key: string): void => {
        actualHeaders.set(key, value);
      });
    }
    if (automaticLocalizationHeader && localization !== null) {
      Request.getHeadersFromLocalization(localization)
        .forEach((value: string[], key: string): void => {
          actualHeaders.set(key, value);
        });
    }
    this.headersValue = actualHeaders;
  }

  /** A http method (i.e. GET, POST, HEAD). */
  httpMethod(): string {
    return this.httpMethodValue;
  }

  /** The URL that is pointing to the wanted resource. */
  url(): string {
    return this.urlValue;
  }

  /** Headers that override any default header the Downloader implementation may have. */
  headers(): HeaderMap {
    return this.headersValue;
  }

  /** The body, very commonly used in POST requests. */
  dataToSend(): ArrayBuffer | null {
    return this.dataToSendValue;
  }

  localization(): Localization | null {
    return this.localizationValue;
  }

  static newBuilder(): RequestBuilder {
    return new RequestBuilder();
  }

  /**
   * Port of Request.getHeadersFromLocalization(): `Accept-Language: <language>` when there is
   * no country, otherwise `<localizationCode>, <language>;q=0.9`.
   */
  static getHeadersFromLocalization(localization: Localization | null): HeaderMap {
    const headers: HeaderMap = new Map<string, string[]>();
    if (localization === null) {
      return headers;
    }
    const languageCode: string = localization.getLanguageCode();
    const value: string = localization.getCountryCode().length === 0
      ? languageCode
      : localization.getLocalizationCode() + ', ' + languageCode + ';q=0.9';
    headers.set('Accept-Language', [value]);
    return headers;
  }

  /** Encodes a request body the way the extractor's `byte[]` bodies are always built: UTF-8. */
  static utf8Body(text: string): ArrayBuffer {
    const encoded: Uint8Array = new util.TextEncoder().encodeInto(text);
    return encoded.buffer.slice(encoded.byteOffset,
      encoded.byteOffset + encoded.byteLength) as ArrayBuffer;
  }
}

/** Port of Request.Builder. */
export class RequestBuilder {
  private httpMethodValue: string = '';
  private urlValue: string = '';
  private readonly headersValue: HeaderMap = new Map<string, string[]>();
  private dataToSendValue: ArrayBuffer | null = null;
  private localizationValue: Localization | null = null;
  private automaticLocalizationHeaderValue: boolean = true;

  httpMethod(httpMethodToSet: string): RequestBuilder {
    this.httpMethodValue = httpMethodToSet;
    return this;
  }

  url(urlToSet: string): RequestBuilder {
    this.urlValue = urlToSet;
    return this;
  }

  headers(headersToSet: HeaderMap | null): RequestBuilder {
    this.headersValue.clear();
    if (headersToSet !== null) {
      headersToSet.forEach((value: string[], key: string): void => {
        this.headersValue.set(key, value);
      });
    }
    return this;
  }

  dataToSend(dataToSendToSet: ArrayBuffer | null): RequestBuilder {
    this.dataToSendValue = dataToSendToSet;
    return this;
  }

  localization(localizationToSet: Localization | null): RequestBuilder {
    this.localizationValue = localizationToSet;
    return this;
  }

  automaticLocalizationHeader(automaticLocalizationHeaderToSet: boolean): RequestBuilder {
    this.automaticLocalizationHeaderValue = automaticLocalizationHeaderToSet;
    return this;
  }

  get(urlToSet: string): RequestBuilder {
    this.httpMethodValue = 'GET';
    this.urlValue = urlToSet;
    return this;
  }

  head(urlToSet: string): RequestBuilder {
    this.httpMethodValue = 'HEAD';
    this.urlValue = urlToSet;
    return this;
  }

  post(urlToSet: string, dataToSendToSet: ArrayBuffer | null): RequestBuilder {
    this.httpMethodValue = 'POST';
    this.urlValue = urlToSet;
    this.dataToSendValue = dataToSendToSet;
    return this;
  }

  setHeaders(headerName: string, headerValueList: string[]): RequestBuilder {
    this.headersValue.delete(headerName);
    this.headersValue.set(headerName, headerValueList);
    return this;
  }

  addHeaders(headerName: string, headerValueList: string[]): RequestBuilder {
    let current: string[] | undefined = this.headersValue.get(headerName);
    if (current === undefined) {
      current = [];
    }
    const merged: string[] = current.concat(headerValueList);
    this.headersValue.set(headerName, merged);
    return this;
  }

  setHeader(headerName: string, headerValue: string): RequestBuilder {
    return this.setHeaders(headerName, [headerValue]);
  }

  addHeader(headerName: string, headerValue: string): RequestBuilder {
    return this.addHeaders(headerName, [headerValue]);
  }

  build(): Request {
    return new Request(this.httpMethodValue, this.urlValue, this.headersValue,
      this.dataToSendValue, this.localizationValue, this.automaticLocalizationHeaderValue);
  }
}

/** Port of Response: the data class holding the result of one Downloader request. */
export class Response {
  private readonly responseCodeValue: number;
  private readonly responseMessageValue: string;
  private readonly responseHeadersValue: HeaderMap;
  private readonly responseBodyValue: string;
  private readonly latestUrlValue: string;

  constructor(responseCode: number, responseMessage: string, responseHeaders: HeaderMap | null,
    responseBody: string | null, latestUrl: string | null) {
    this.responseCodeValue = responseCode;
    this.responseMessageValue = responseMessage;
    this.responseHeadersValue = responseHeaders === null ? new Map<string, string[]>() : responseHeaders;
    this.responseBodyValue = responseBody === null ? '' : responseBody;
    this.latestUrlValue = latestUrl === null ? '' : latestUrl;
  }

  responseCode(): number {
    return this.responseCodeValue;
  }

  responseMessage(): string {
    return this.responseMessageValue;
  }

  responseHeaders(): HeaderMap {
    return this.responseHeadersValue;
  }

  responseBody(): string {
    return this.responseBodyValue;
  }

  /** The URL known right before this response was created - used to detect a redirect. */
  latestUrl(): string {
    return this.latestUrlValue;
  }

  /** First value of a header, case-insensitively, or null. Port of Response.getHeader(). */
  getHeader(name: string): string | null {
    const lowered: string = name.toLowerCase();
    for (const key of this.responseHeadersValue.keys()) {
      if (key.toLowerCase() === lowered) {
        const values: string[] | undefined = this.responseHeadersValue.get(key);
        if (values !== undefined && values.length > 0) {
          return values[0];
        }
      }
    }
    return null;
  }
}

/**
 * Port of the abstract Downloader. Every convenience method funnels into execute(), which the
 * concrete DownloaderImpl (common/net/Downloader.ts) implements over @ohos.net.http.
 *
 * The source reads the default localization from NewPipe.getPreferredLocalization(); until the
 * NewPipe facade is ported, that value lives here and the settings layer sets it once at startup.
 */
export abstract class Downloader {
  private static preferredLocalization: Localization = Localization.DEFAULT;

  static setPreferredLocalization(localization: Localization): void {
    Downloader.preferredLocalization = localization;
  }

  static getPreferredLocalization(): Localization {
    return Downloader.preferredLocalization;
  }

  /** Do a request using the specified Request object. */
  abstract execute(request: Request): Promise<Response>;

  async get(url: string, headers: HeaderMap | null = null,
    localization: Localization | null = Downloader.getPreferredLocalization()):
    Promise<Response> {
    return this.execute(Request.newBuilder()
      .get(url)
      .headers(headers)
      .localization(localization)
      .build());
  }

  async head(url: string, headers: HeaderMap | null = null): Promise<Response> {
    return this.execute(Request.newBuilder()
      .head(url)
      .headers(headers)
      .build());
  }

  async post(url: string, headers: HeaderMap | null, dataToSend: ArrayBuffer | null,
    localization: Localization | null = Downloader.getPreferredLocalization()):
    Promise<Response> {
    return this.execute(Request.newBuilder()
      .post(url, dataToSend)
      .headers(headers)
      .localization(localization)
      .build());
  }

  /** post() with an explicit Content-Type header. */
  async postWithContentType(url: string, headers: HeaderMap | null,
    dataToSend: ArrayBuffer | null, contentType: string,
    localization: Localization | null = Downloader.getPreferredLocalization()):
    Promise<Response> {
    const actualHeaders: HeaderMap = new Map<string, string[]>();
    if (headers !== null) {
      headers.forEach((value: string[], key: string): void => {
        actualHeaders.set(key, value);
      });
    }
    actualHeaders.set('Content-Type', [contentType]);
    return this.post(url, actualHeaders, dataToSend, localization);
  }

  /** post() with Content-Type: application/json - the InnerTube / SoundCloud POST shape. */
  async postWithContentTypeJson(url: string, headers: HeaderMap | null,
    dataToSend: ArrayBuffer | null,
    localization: Localization | null = Downloader.getPreferredLocalization()):
    Promise<Response> {
    return this.postWithContentType(url, headers, dataToSend, 'application/json', localization);
  }
}
