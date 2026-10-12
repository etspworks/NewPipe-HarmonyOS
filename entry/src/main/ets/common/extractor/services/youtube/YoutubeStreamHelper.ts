/*
 * Port of org.schabi.newpipe.extractor.services.youtube.YoutubeStreamHelper
 * (NewPipeExtractor v0.26.5).
 *
 * One player request per InnerTube client. Every method does I/O, so every method is a Promise
 * (phase2-logic-contract.md §1).
 *
 * THE NSIG-FREE ORDER LIVES HERE (§2.3). ArkTS has no in-process JS engine, so a ciphered or
 * `n`-throttled URL can never be deobfuscated. The clients whose player response hands out
 * ready-to-play URLs are the mobile/TV ones, so YoutubeStreamExtractor walks
 * NSIG_FREE_CLIENT_ORDER — IOS, then VISIONOS (the TVHTML5-class client this extractor version
 * ships), then ANDROID (only with a poToken, which is what the source requires) — and only falls
 * back to the WEB clients when a poToken provider exists. A client that yields nothing usable is
 * skipped, never faked.
 */

import { JsonBuilder, JsonObject, JsonWriter } from '../../json/NanoJson';
import { Downloader, HeaderMap, Request } from '../../downloader/Downloader';
import { Localization } from '../../downloader/Localization';
import { ContentCountry } from '../../localization/ContentCountry';
import { NewPipe } from '../../core/NewPipe';
import { JsonUtils } from '../../core/JsonUtils';
import { ExtractionException } from '../../exceptions/Exceptions';
import { WEB_EMBEDDED_CLIENT_ID, WEB_EMBEDDED_CLIENT_VERSION } from './ClientsConstants';
import { InnertubeClientRequestInfo } from './InnertubeClientRequestInfo';
import { PoTokenResult } from './PoToken';
import {
  CONTENT_CHECK_OK,
  CPN,
  DISABLE_PRETTY_PRINT_PARAMETER,
  RACY_CHECK_OK,
  VIDEO_ID,
  YOUTUBEI_V1_GAPIS_URL,
  YOUTUBEI_V1_URL,
  generateTParameter,
  getAndroidUserAgent,
  getClientHeaders,
  getClientVersion,
  getIosUserAgent,
  getOriginReferrerHeaders,
  getValidJsonResponseBody,
  getVisionOsUserAgent,
  getVisitorDataFromInnertube,
  getYouTubeHeaders,
  prepareJsonBuilder
} from './YoutubeParsingHelper';

const PLAYER: string = 'player';
const SERVICE_INTEGRITY_DIMENSIONS: string = 'serviceIntegrityDimensions';
const PO_TOKEN: string = 'poToken';
const BASE_YT_DESKTOP_WATCH_URL: string = 'https://www.youtube.com/watch?v=';

/** Which InnerTube client a player response came from. */
export enum InnertubeClient {
  WEB,
  WEB_EMBEDDED_PLAYER,
  ANDROID,
  IOS,
  VISIONOS
}

/**
 * The nsig-free client order (phase2-logic-contract.md §2.3): the clients whose streaming URLs
 * need neither signature deciphering nor `n`-parameter deobfuscation, most reliable first.
 *
 * IOS first — it returns muxed progressive formats AND an HLS manifest, which is exactly what
 * AVPlayer wants (§2.5). VISIONOS second — same family, different quality ladder, and the one
 * TV-class client this extractor version still ships. ANDROID last, because the source only
 * sends an ANDROID player request when a poToken is available, and a poToken needs the app-side
 * BotGuard WebView that is a later pass; it is in the order so that it starts working the moment
 * the provider is registered, rather than needing an edit here.
 */
export const NSIG_FREE_CLIENT_ORDER: InnertubeClient[] =
  [InnertubeClient.IOS, InnertubeClient.VISIONOS, InnertubeClient.ANDROID];

function getDownloader(): Downloader {
  const downloader: Downloader | null = NewPipe.getDownloader();
  if (downloader === null) {
    throw new ExtractionException('Downloader is not initialised');
  }
  return downloader;
}

function addVideoIdCpnAndOkChecks(builder: JsonBuilder, videoId: string,
  cpn: string | null): void {
  builder.value(VIDEO_ID, videoId);
  if (cpn !== null) {
    builder.value(CPN, cpn);
  }
  builder.value(CONTENT_CHECK_OK, true)
    .value(RACY_CHECK_OK, true);
}

function addPlaybackContext(builder: JsonBuilder, referer: string,
  signatureTimestamp: number): void {
  builder.object('playbackContext')
    .object('contentPlaybackContext')
    .value('signatureTimestamp', signatureTimestamp)
    .value('referer', referer)
    .end()
    .end();
}

function addPoToken(builder: JsonBuilder, poToken: string): void {
  builder.object(SERVICE_INTEGRITY_DIMENSIONS)
    .value(PO_TOKEN, poToken)
    .end();
}

function getMobileClientHeaders(userAgent: string): HeaderMap {
  const headers: HeaderMap = new Map<string, string[]>();
  headers.set('User-Agent', [userAgent]);
  headers.set('X-Goog-Api-Format-Version', ['2']);
  return headers;
}

/** The WEB metadata-only player response: microformat + thumbnails + videoId. */
export async function getWebMetadataPlayerResponse(localization: Localization,
  contentCountry: ContentCountry, videoId: string): Promise<JsonObject> {
  const innertubeClientRequestInfo: InnertubeClientRequestInfo =
    InnertubeClientRequestInfo.ofWebClient();
  innertubeClientRequestInfo.clientInfo.clientVersion = await getClientVersion();

  const headers: HeaderMap = await getYouTubeHeaders();

  // A valid visitorData must always be passed to get valid player responses, and it has to come
  // from YouTube itself
  innertubeClientRequestInfo.clientInfo.visitorData = await getVisitorDataFromInnertube(
    innertubeClientRequestInfo, localization, contentCountry, headers, YOUTUBEI_V1_URL, null,
    false);

  const builder: JsonBuilder = prepareJsonBuilder(localization, contentCountry,
    innertubeClientRequestInfo, null);

  addVideoIdCpnAndOkChecks(builder, videoId, null);

  const body: ArrayBuffer = Request.utf8Body(JsonWriter.stringValue(builder.done()));

  const url: string = YOUTUBEI_V1_URL + PLAYER + '?' + DISABLE_PRETTY_PRINT_PARAMETER
    + '&$fields=microformat,videoDetails.thumbnail.thumbnails,videoDetails.videoId';

  return JsonUtils.toJsonObject(getValidJsonResponseBody(
    await getDownloader().postWithContentTypeJson(url, headers, body, localization)));
}

export async function getWebEmbeddedPlayerResponse(localization: Localization,
  contentCountry: ContentCountry, videoId: string, cpn: string,
  webEmbeddedPoTokenResult: PoTokenResult | null,
  signatureTimestamp: number): Promise<JsonObject> {
  const innertubeClientRequestInfo: InnertubeClientRequestInfo =
    InnertubeClientRequestInfo.ofWebEmbeddedPlayerClient();

  const headers: HeaderMap = getClientHeaders(WEB_EMBEDDED_CLIENT_ID,
    WEB_EMBEDDED_CLIENT_VERSION);
  getOriginReferrerHeaders('https://www.youtube.com')
    .forEach((value: string[], key: string): void => {
      headers.set(key, value);
    });

  const embedUrl: string = BASE_YT_DESKTOP_WATCH_URL + videoId;

  innertubeClientRequestInfo.clientInfo.visitorData = webEmbeddedPoTokenResult === null
    ? await getVisitorDataFromInnertube(innertubeClientRequestInfo, localization, contentCountry,
      headers, YOUTUBEI_V1_URL, embedUrl, false)
    : webEmbeddedPoTokenResult.visitorData;

  const builder: JsonBuilder = prepareJsonBuilder(localization, contentCountry,
    innertubeClientRequestInfo, embedUrl);

  addVideoIdCpnAndOkChecks(builder, videoId, cpn);
  addPlaybackContext(builder, embedUrl, signatureTimestamp);

  if (webEmbeddedPoTokenResult !== null) {
    addPoToken(builder, webEmbeddedPoTokenResult.playerRequestPoToken);
  }

  const body: ArrayBuffer = Request.utf8Body(JsonWriter.stringValue(builder.done()));
  const url: string = YOUTUBEI_V1_URL + PLAYER + '?' + DISABLE_PRETTY_PRINT_PARAMETER;

  return JsonUtils.toJsonObject(getValidJsonResponseBody(
    await getDownloader().postWithContentTypeJson(url, headers, body, localization)));
}

/** The ANDROID player response. As in the source, it requires a poToken. */
export async function getAndroidPlayerResponse(contentCountry: ContentCountry,
  localization: Localization, videoId: string, cpn: string,
  androidPoTokenResult: PoTokenResult): Promise<JsonObject> {
  const innertubeClientRequestInfo: InnertubeClientRequestInfo =
    InnertubeClientRequestInfo.ofAndroidClient();
  innertubeClientRequestInfo.clientInfo.visitorData = androidPoTokenResult.visitorData;

  const headers: HeaderMap = getMobileClientHeaders(getAndroidUserAgent(localization));

  const builder: JsonBuilder = prepareJsonBuilder(localization, contentCountry,
    innertubeClientRequestInfo, null);

  addVideoIdCpnAndOkChecks(builder, videoId, cpn);
  addPoToken(builder, androidPoTokenResult.playerRequestPoToken);

  const body: ArrayBuffer = Request.utf8Body(JsonWriter.stringValue(builder.done()));

  const url: string = YOUTUBEI_V1_GAPIS_URL + PLAYER + '?' + DISABLE_PRETTY_PRINT_PARAMETER
    + '&t=' + generateTParameter() + '&id=' + videoId;

  return JsonUtils.toJsonObject(getValidJsonResponseBody(
    await getDownloader().postWithContentTypeJson(url, headers, body, localization)));
}

/** The ANDROID reel player response, used for Shorts; needs no poToken. */
export async function getAndroidReelPlayerResponse(contentCountry: ContentCountry,
  localization: Localization, videoId: string, cpn: string): Promise<JsonObject> {
  const innertubeClientRequestInfo: InnertubeClientRequestInfo =
    InnertubeClientRequestInfo.ofAndroidClient();

  const headers: HeaderMap = getMobileClientHeaders(getAndroidUserAgent(localization));

  innertubeClientRequestInfo.clientInfo.visitorData = await getVisitorDataFromInnertube(
    innertubeClientRequestInfo, localization, contentCountry, headers, YOUTUBEI_V1_GAPIS_URL,
    null, false);

  const builder: JsonBuilder = prepareJsonBuilder(localization, contentCountry,
    innertubeClientRequestInfo, null);

  builder.object('playerRequest');
  addVideoIdCpnAndOkChecks(builder, videoId, cpn);
  builder.end()
    .value('disablePlayerResponse', false);

  const body: ArrayBuffer = Request.utf8Body(JsonWriter.stringValue(builder.done()));

  const url: string = YOUTUBEI_V1_GAPIS_URL + 'reel/reel_item_watch' + '?'
    + DISABLE_PRETTY_PRINT_PARAMETER + '&t=' + generateTParameter() + '&id=' + videoId
    + '&$fields=playerResponse';

  return JsonUtils.toJsonObject(getValidJsonResponseBody(
    await getDownloader().postWithContentTypeJson(url, headers, body, localization)))
    .getObject('playerResponse');
}

/** The IOS player response — first choice of the nsig-free order. */
export async function getIosPlayerResponse(contentCountry: ContentCountry,
  localization: Localization, videoId: string, cpn: string,
  iosPoTokenResult: PoTokenResult | null): Promise<JsonObject> {
  const innertubeClientRequestInfo: InnertubeClientRequestInfo =
    InnertubeClientRequestInfo.ofIosClient();

  const headers: HeaderMap = getMobileClientHeaders(getIosUserAgent(localization));

  innertubeClientRequestInfo.clientInfo.visitorData = iosPoTokenResult === null
    ? await getVisitorDataFromInnertube(innertubeClientRequestInfo, localization, contentCountry,
      headers, YOUTUBEI_V1_URL, null, false)
    : iosPoTokenResult.visitorData;

  const builder: JsonBuilder = prepareJsonBuilder(localization, contentCountry,
    innertubeClientRequestInfo, null);

  addVideoIdCpnAndOkChecks(builder, videoId, cpn);

  if (iosPoTokenResult !== null) {
    addPoToken(builder, iosPoTokenResult.playerRequestPoToken);
  }

  const body: ArrayBuffer = Request.utf8Body(JsonWriter.stringValue(builder.done()));

  const url: string = YOUTUBEI_V1_GAPIS_URL + PLAYER + '?' + DISABLE_PRETTY_PRINT_PARAMETER
    + '&t=' + generateTParameter() + '&id=' + videoId;

  return JsonUtils.toJsonObject(getValidJsonResponseBody(
    await getDownloader().postWithContentTypeJson(url, headers, body, localization)));
}

/** The VISIONOS player response — second choice of the nsig-free order. */
export async function getVisionOsPlayerResponse(contentCountry: ContentCountry,
  localization: Localization, videoId: string, cpn: string): Promise<JsonObject> {
  const innertubeClientRequestInfo: InnertubeClientRequestInfo =
    InnertubeClientRequestInfo.ofVisionOsClient();

  const headers: HeaderMap = getMobileClientHeaders(getVisionOsUserAgent(localization));

  innertubeClientRequestInfo.clientInfo.visitorData = await getVisitorDataFromInnertube(
    innertubeClientRequestInfo, localization, contentCountry, headers, YOUTUBEI_V1_URL, null,
    false);

  const builder: JsonBuilder = prepareJsonBuilder(localization, contentCountry,
    innertubeClientRequestInfo, null);

  addVideoIdCpnAndOkChecks(builder, videoId, cpn);

  const body: ArrayBuffer = Request.utf8Body(JsonWriter.stringValue(builder.done()));

  const url: string = YOUTUBEI_V1_GAPIS_URL + PLAYER + '?' + DISABLE_PRETTY_PRINT_PARAMETER
    + '&t=' + generateTParameter() + '&id=' + videoId;

  return JsonUtils.toJsonObject(getValidJsonResponseBody(
    await getDownloader().postWithContentTypeJson(url, headers, body, localization)));
}
