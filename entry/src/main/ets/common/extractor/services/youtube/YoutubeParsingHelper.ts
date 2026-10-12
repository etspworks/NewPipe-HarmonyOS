/*
 * Port of org.schabi.newpipe.extractor.services.youtube.YoutubeParsingHelper
 * (NewPipeExtractor v0.26.5).
 *
 * The shared surface of the whole YouTube service: the InnerTube endpoints, the request bodies,
 * the headers, and the JSON-shape readers every extractor calls.
 *
 * Deviations, all forced by the platform and each marked at its site:
 *  - everything that does I/O is a Promise (phase2-logic-contract.md §1);
 *  - java.util.Base64 + protobuf become ./Protobuf.ts (the two schemas written out by hand);
 *  - `Response.latestUrl()` cannot report the post-redirect URL at API 12 (§8), so
 *    getValidJsonResponseBody's redirect check runs only when a latest url is actually known;
 *  - `Random` becomes Math.random, injected through the ported
 *    generateRandomStringFromAlphabet(); setNumberGenerator() keeps the seam the source has.
 * The JS-cipher path (YoutubeSignatureUtils / YoutubeJavaScriptPlayerManager) is deliberately NOT
 * ported — see phase2-logic-contract.md §2.3.
 */

import { JsonArray, JsonBuilder, JsonObject, JsonParser, JsonWriter } from '../../json/NanoJson';
import { Entities } from '../../html/Jsoup';
import { Downloader, HeaderMap, Request, Response } from '../../downloader/Downloader';
import { Localization } from '../../downloader/Localization';
import { ContentCountry } from '../../localization/ContentCountry';
import { NewPipe } from '../../core/NewPipe';
import { JsonUtils } from '../../core/JsonUtils';
import { Parser } from '../../core/Parser';
import { generateRandomStringFromAlphabet } from '../../core/RandomStringFromAlphabetGenerator';
import {
  HTTP,
  HTTPS,
  decodeUrlUtf8,
  getQueryValue,
  getStringResultFromRegexArray,
  isNullOrEmpty,
  removeNonDigitCharacters,
  replaceHttpWithHttps,
  stringToURL
} from '../../core/Utils';
import {
  AccountTerminatedException,
  AccountTerminatedReason,
  ContentNotAvailableException,
  ExtractionException,
  ParsingException
} from '../../exceptions/Exceptions';
import { Image } from '../../../../model/extractor/Image';
import { resolutionLevelFromHeight } from '../../../../model/enums/ImageResolutionLevel';
import { PlaylistType } from '../../../../model/extractor/PlaylistType';
import { AudioTrackType } from '../../../../model/extractor/AudioTrackType';
import { url as ohosUrl } from '@kit.ArkTS';
import {
  ANDROID_CLIENT_VERSION,
  DESKTOP_CLIENT_PLATFORM,
  IOS_CLIENT_VERSION,
  IOS_DEVICE_MODEL,
  IOS_USER_AGENT_VERSION,
  VISIONOS_CLIENT_VERSION,
  VISIONOS_DEVICE_MODEL,
  VISIONOS_USER_AGENT_VERSION,
  WEB_CLIENT_ID,
  WEB_CLIENT_NAME,
  WEB_HARDCODED_CLIENT_VERSION,
  WEB_REMIX_CLIENT_ID,
  WEB_REMIX_CLIENT_NAME,
  WEB_REMIX_HARDCODED_CLIENT_VERSION
} from './ClientsConstants';
import { InnertubeClientRequestInfo } from './InnertubeClientRequestInfo';
import { XTags, base64UrlDecode } from './Protobuf';

/* //////////////////////////////////////////////////////////////////////////
// Endpoints and request constants
////////////////////////////////////////////////////////////////////////// */

/** The base URL of InnerTube requests made by the WEB clients. */
export const YOUTUBEI_V1_URL: string = 'https://www.youtube.com/youtubei/v1/';

/** The base URL of InnerTube requests made by non-web clients. */
export const YOUTUBEI_V1_GAPIS_URL: string = 'https://youtubei.googleapis.com/youtubei/v1/';

/** The base URL of YouTube Music. */
export const YOUTUBE_MUSIC_URL: string = 'https://music.youtube.com';

/** InnerTube base of the YouTube Music (WEB_REMIX) client. */
export const YOUTUBE_MUSIC_INNERTUBE_URL: string = 'https://music.youtube.com/youtubei/v1/';

/** Disables the pretty-printed InnerTube response, cutting response size. */
export const DISABLE_PRETTY_PRINT_PARAMETER: string = 'prettyPrint=false';

/** `contentPlaybackNonce`, 16 random characters, sent on playback and player requests. */
export const CPN: string = 'cpn';
export const VIDEO_ID: string = 'videoId';

/** Allows streaming data on videos carrying a sensitive-content warning. */
export const CONTENT_CHECK_OK: string = 'contentCheckOk';

/** Linked to sensitive content such as age-restricted videos. */
export const RACY_CHECK_OK: string = 'racyCheckOk';

const FEED_BASE_CHANNEL_ID: string = 'https://www.youtube.com/feeds/videos.xml?channel_id=';
const FEED_BASE_USER: string = 'https://www.youtube.com/feeds/videos.xml?user=';

/**
 * The temporary-playlist share url. Ported from the app's ExportPlaylist.kt (it builds a YouTube
 * URL, so it belongs to the YouTube service); the export action that calls it is a later pass.
 */
const TEMP_PLAYLIST_SHARE_BASE_URL: string = 'https://www.youtube.com/watch_videos?video_ids=';

const INNERTUBE_CONTEXT_CLIENT_VERSION_REGEXES: RegExp[] = [
  new RegExp('INNERTUBE_CONTEXT_CLIENT_VERSION":"([0-9\\.]+?)"'),
  new RegExp('innertube_context_client_version":"([0-9\\.]+?)"'),
  new RegExp('client\\.version=([0-9\\.]+)')
];
const INITIAL_DATA_REGEXES: RegExp[] = [
  new RegExp('window\\["ytInitialData"\\]\\s*=\\s*(\\{.*?\\});'),
  new RegExp('var\\s*ytInitialData\\s*=\\s*(\\{.*?\\});')
];

const CONTENT_PLAYBACK_NONCE_ALPHABET: string =
  'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

const C_WEB_PATTERN: RegExp = new RegExp('&c=WEB');
const C_WEB_EMBEDDED_PLAYER_PATTERN: RegExp = new RegExp('&c=WEB_EMBEDDED_PLAYER');
const C_ANDROID_PATTERN: RegExp = new RegExp('&c=ANDROID');
const C_IOS_PATTERN: RegExp = new RegExp('&c=IOS');
const C_VISIONOS_PATTERN: RegExp = new RegExp('&c=VISIONOS');

const GOOGLE_URLS: string[] = ['google.', 'm.google.', 'www.google.'];
const INVIDIOUS_URLS: string[] = ['invidio.us', 'dev.invidio.us', 'www.invidio.us',
  'redirect.invidious.io', 'invidious.snopyta.org', 'yewtu.be', 'tube.connect.cafe',
  'tubus.eduvid.org', 'invidious.kavin.rocks', 'invidious.site', 'invidious-us.kavin.rocks',
  'piped.kavin.rocks', 'vid.mint.lgbt', 'invidiou.site', 'invidious.fdn.fr',
  'invidious.048596.xyz', 'invidious.zee.li', 'vid.puffyan.us', 'ytprivate.com',
  'invidious.namazso.eu', 'invidious.silkky.cloud', 'ytb.trom.tf', 'invidious.exonip.de',
  'inv.riverside.rocks', 'invidious.blamefran.net', 'y.com.cm', 'invidious.moomoo.me',
  'yt.cyberhost.uk'];
const YOUTUBE_URLS: string[] = ['youtube.com', 'www.youtube.com', 'm.youtube.com',
  'music.youtube.com'];

/* //////////////////////////////////////////////////////////////////////////
// Mutable module state (the source's private statics)
////////////////////////////////////////////////////////////////////////// */

let clientVersion: string | null = null;
let youtubeMusicClientVersion: string | null = null;
let clientVersionExtracted: boolean = false;
let hardcodedClientVersionValid: boolean | null = null;
let consentAccepted: boolean = false;
/** The seam the source's setNumberGenerator(Random) is; Math.random by default. */
let numberGenerator: () => number = Math.random;

function getDownloader(): Downloader {
  const downloader: Downloader | null = NewPipe.getDownloader();
  if (downloader === null) {
    throw new ExtractionException('Downloader is not initialised');
  }
  return downloader;
}

/* //////////////////////////////////////////////////////////////////////////
// URL predicates
////////////////////////////////////////////////////////////////////////// */

export function isGoogleURL(url: string): boolean {
  const cachedUrl: string | null = extractCachedUrlIfNeeded(url);
  if (cachedUrl === null) {
    return false;
  }
  try {
    const parsed: ohosUrl.URL = stringToURL(cachedUrl);
    const host: string = parsed.host;
    for (const item of GOOGLE_URLS) {
      if (host.startsWith(item)) {
        return true;
      }
    }
    return false;
  } catch (e) {
    return false;
  }
}

export function isYoutubeURL(url: ohosUrl.URL): boolean {
  return YOUTUBE_URLS.includes(url.host.toLowerCase());
}

export function isYoutubeServiceURL(url: ohosUrl.URL): boolean {
  const host: string = url.host.toLowerCase();
  return host === 'www.youtube-nocookie.com' || host === 'youtu.be';
}

export function isHooktubeURL(url: ohosUrl.URL): boolean {
  return url.host.toLowerCase() === 'hooktube.com';
}

export function isInvidiousURL(url: ohosUrl.URL): boolean {
  return INVIDIOUS_URLS.includes(url.host.toLowerCase());
}

export function isY2ubeURL(url: ohosUrl.URL): boolean {
  return url.host.toLowerCase() === 'y2u.be';
}

/* //////////////////////////////////////////////////////////////////////////
// Duration, feed and mix ids
////////////////////////////////////////////////////////////////////////// */

/** Convert a duration string to an int without throwing; 0 when it cannot be converted. */
function convertDurationToInt(input: string | null): number {
  if (input === null || input.length === 0) {
    return 0;
  }
  const cleared: string = removeNonDigitCharacters(input);
  const parsed: number = Number.parseInt(cleared, 10);
  return Number.isNaN(parsed) ? 0 : parsed;
}

/** Parse a `hh:mm:ss` (or `.`-separated) duration string into seconds. */
export function parseDurationString(input: string): number {
  if (!new RegExp('.*\\d.*').test(input) && input.toUpperCase() !== 'SHORTS') {
    throw new ParsingException('Error duration string contains no digits: ' + input);
  }

  // If the time separator ":" is not detected, try "." instead
  const splitInput: string[] = input.includes(':') ? input.split(':') : input.split('.');

  const units: number[] = [24, 60, 60, 1];
  const offset: number = units.length - splitInput.length;
  if (offset < 0) {
    throw new ParsingException('Error duration string with unknown format: ' + input);
  }
  let duration: number = 0;
  for (let i = 0; i < splitInput.length; i++) {
    duration = units[i + offset] * (duration + convertDurationToInt(splitInput[i]));
  }
  return duration;
}

export function getFeedUrlFrom(channelIdOrUser: string): string {
  if (channelIdOrUser.startsWith('user/')) {
    return FEED_BASE_USER + channelIdOrUser.replace('user/', '');
  }
  if (channelIdOrUser.startsWith('channel/')) {
    return FEED_BASE_CHANNEL_ID + channelIdOrUser.replace('channel/', '');
  }
  return FEED_BASE_CHANNEL_ID + channelIdOrUser;
}

/**
 * The share url of a temporary YouTube playlist built from a list of video ids
 * (port of the app's ExportPlaylist.kt). YouTube caps this at 50 ids, as the source does.
 */
export function getTempPlaylistShareUrl(videoIds: string[]): string {
  return TEMP_PLAYLIST_SHARE_BASE_URL + videoIds.slice(0, 50).join(',');
}

/** Mix (auto-generated playlist) ids start with "RD". */
export function isYoutubeMixId(playlistId: string): boolean {
  return playlistId.startsWith('RD');
}

/** My Mix ids start with "RDMM". */
export function isYoutubeMyMixId(playlistId: string): boolean {
  return playlistId.startsWith('RDMM');
}

/** Music Mix ids start with "RDAMVM" or "RDCLAK". */
export function isYoutubeMusicMixId(playlistId: string): boolean {
  return playlistId.startsWith('RDAMVM') || playlistId.startsWith('RDCLAK');
}

/** Genre Mix ids start with "RDGMEM". */
export function isYoutubeGenreMixId(playlistId: string): boolean {
  return playlistId.startsWith('RDGMEM');
}

export function extractVideoIdFromMixId(playlistId: string): string {
  if (isNullOrEmpty(playlistId)) {
    throw new ParsingException('Video id could not be determined from empty playlist id');
  }
  if (isYoutubeMyMixId(playlistId)) {
    return playlistId.substring(4);
  }
  if (isYoutubeMusicMixId(playlistId)) {
    return playlistId.substring(6);
  }
  if (isYoutubeGenreMixId(playlistId)) {
    // Genre mixes are of the form RDGMEM{garbage}, so videoId can't be determined
    throw new ParsingException('Video id could not be determined from genre mix id: '
      + playlistId);
  }
  if (isYoutubeMixId(playlistId)) {
    if (playlistId.length !== 13) {
      // Stream YouTube mixes are of the form RD{videoId}; a videoId is exactly 11 characters
      throw new ParsingException('Video id could not be determined from mix id: ' + playlistId);
    }
    return playlistId.substring(2);
  }
  throw new ParsingException('Video id could not be determined from playlist id: ' + playlistId);
}

export function extractPlaylistTypeFromPlaylistId(playlistId: string | null): PlaylistType {
  if (isNullOrEmpty(playlistId)) {
    throw new ParsingException('Could not extract playlist type from empty playlist id');
  }
  const id: string = playlistId as string;
  if (isYoutubeMusicMixId(id)) {
    return PlaylistType.MIX_MUSIC;
  }
  if (isYoutubeGenreMixId(id)) {
    return PlaylistType.MIX_GENRE;
  }
  if (isYoutubeMixId(id)) {
    // Either a normal mix based on a stream, or a "my mix" (still based on a stream)
    return PlaylistType.MIX_STREAM;
  }
  return PlaylistType.NORMAL;
}

export function extractPlaylistTypeFromPlaylistUrl(playlistUrl: string): PlaylistType {
  try {
    return extractPlaylistTypeFromPlaylistId(
      getQueryValue(stringToURL(playlistUrl), 'list'));
  } catch (e) {
    if (e instanceof ParsingException) {
      throw e;
    }
    throw new ParsingException('Could not extract playlist type from malformed url',
      e instanceof Error ? e as Error : null);
  }
}

/* //////////////////////////////////////////////////////////////////////////
// Client version extraction
////////////////////////////////////////////////////////////////////////// */

function getInitialData(html: string): JsonObject {
  try {
    return JsonParser.object().from(
      getStringResultFromRegexArray(html, INITIAL_DATA_REGEXES, 1));
  } catch (e) {
    throw new ParsingException('Could not get ytInitialData',
      e instanceof Error ? e as Error : null);
  }
}

export async function isHardcodedClientVersionValid(): Promise<boolean> {
  if (hardcodedClientVersionValid !== null) {
    return hardcodedClientVersionValid;
  }
  const body: ArrayBuffer = Request.utf8Body(JsonWriter.string()
    .object()
    .object('context')
    .object('client')
    .value('hl', 'en-GB')
    .value('gl', 'GB')
    .value('clientName', WEB_CLIENT_NAME)
    .value('clientVersion', WEB_HARDCODED_CLIENT_VERSION)
    .value('platform', DESKTOP_CLIENT_PLATFORM)
    .value('utcOffsetMinutes', 0)
    .end()
    .object('request')
    .array('internalExperimentFlags')
    .end()
    .value('useSsl', true)
    .end()
    .object('user')
    // TODO (as in the source): expose restricted mode with .value('enableSafetyMode', boolean)
    .value('lockedSafetyMode', false)
    .end()
    .end()
    .value('fetchLiveState', true)
    .end().done());

  const headers: HeaderMap = getClientHeaders(WEB_CLIENT_ID, WEB_HARDCODED_CLIENT_VERSION);

  // The endpoint the YouTube website uses for its main menu: lightweight, around 30 kB
  const response: Response = await getDownloader().postWithContentTypeJson(
    YOUTUBEI_V1_URL + 'guide?' + DISABLE_PRETTY_PRINT_PARAMETER, headers, body);

  hardcodedClientVersionValid =
    response.responseBody().length > 5000 && response.responseCode() === 200;
  return hardcodedClientVersionValid;
}

async function extractClientVersionFromSwJs(): Promise<void> {
  if (clientVersionExtracted) {
    return;
  }
  const url: string = 'https://www.youtube.com/sw.js';
  const headers: HeaderMap = getOriginReferrerHeaders('https://www.youtube.com');
  const response: string = (await getDownloader().get(url, headers)).responseBody();
  try {
    clientVersion = getStringResultFromRegexArray(response,
      INNERTUBE_CONTEXT_CLIENT_VERSION_REGEXES, 1);
  } catch (e) {
    throw new ParsingException(
      'Could not extract YouTube WEB InnerTube client version from sw.js',
      e instanceof Error ? e as Error : null);
  }
  clientVersionExtracted = true;
}

async function extractClientVersionFromHtmlSearchResultsPage(): Promise<void> {
  if (clientVersionExtracted) {
    return;
  }
  // No search term, to keep the response small
  const url: string = 'https://www.youtube.com/results?search_query=&ucbcb=1';
  const html: string = (await getDownloader().get(url, getCookieHeader())).responseBody();
  const initialData: JsonObject = getInitialData(html);
  const serviceTrackingParams: JsonArray = initialData.getObject('responseContext')
    .getArray('serviceTrackingParams');

  // Try to get the version from the initial data first
  clientVersion = getClientVersionFromServiceTrackingParam(serviceTrackingParams, 'CSI', 'cver');

  if (clientVersion === null) {
    try {
      clientVersion = getStringResultFromRegexArray(html,
        INNERTUBE_CONTEXT_CLIENT_VERSION_REGEXES, 1);
    } catch (ignored) {
      // fall through to the shortened version below
    }
  }

  // Fall back to a shortened client version which does not carry the last two digits
  if (isNullOrEmpty(clientVersion)) {
    clientVersion = getClientVersionFromServiceTrackingParam(serviceTrackingParams, 'ECATCHER',
      'client.version');
  }

  if (clientVersion === null) {
    throw new ParsingException('Could not extract YouTube WEB InnerTube client version from '
      + 'HTML search results page');
  }

  clientVersionExtracted = true;
}

function getClientVersionFromServiceTrackingParam(serviceTrackingParams: JsonArray,
  serviceName: string, clientVersionKey: string): string | null {
  for (const serviceTrackingParam of serviceTrackingParams.streamAsJsonObjects()) {
    if (serviceTrackingParam.getString('service', '') !== serviceName) {
      continue;
    }
    for (const param of serviceTrackingParam.getArray('params').streamAsJsonObjects()) {
      if (param.getString('key', '') !== clientVersionKey) {
        continue;
      }
      const paramValue: string | null = param.getString('value');
      if (!isNullOrEmpty(paramValue)) {
        return paramValue;
      }
    }
  }
  return null;
}

/** The client version the YouTube website uses on InnerTube requests. */
export async function getClientVersion(): Promise<string> {
  if (!isNullOrEmpty(clientVersion)) {
    return clientVersion as string;
  }

  // Always extract the latest client version — first from the JavaScript service worker, then
  // from the HTML search results page — to prevent fingerprinting on the client version used
  try {
    await extractClientVersionFromSwJs();
  } catch (e) {
    await extractClientVersionFromHtmlSearchResultsPage();
  }

  if (clientVersionExtracted && clientVersion !== null) {
    return clientVersion;
  }

  // Fall back to the hardcoded one if it is valid
  if (await isHardcodedClientVersionValid()) {
    clientVersion = WEB_HARDCODED_CLIENT_VERSION;
    return clientVersion;
  }

  throw new ExtractionException('Could not get YouTube WEB client version');
}

/** Resets the cached client version; the source uses it between test classes. */
export function resetClientVersion(): void {
  clientVersion = null;
  clientVersionExtracted = false;
}

/** The seam the source's setNumberGenerator(Random) is. */
export function setNumberGenerator(random: () => number): void {
  numberGenerator = random;
}

export async function isHardcodedYoutubeMusicClientVersionValid(): Promise<boolean> {
  const url: string = YOUTUBE_MUSIC_INNERTUBE_URL + 'music/get_search_suggestions?'
    + DISABLE_PRETTY_PRINT_PARAMETER;

  const json: ArrayBuffer = Request.utf8Body(JsonWriter.string()
    .object()
    .object('context')
    .object('client')
    .value('clientName', WEB_REMIX_CLIENT_NAME)
    .value('clientVersion', WEB_REMIX_HARDCODED_CLIENT_VERSION)
    .value('hl', 'en-GB')
    .value('gl', 'GB')
    .value('platform', DESKTOP_CLIENT_PLATFORM)
    .value('utcOffsetMinutes', 0)
    .end()
    .object('request')
    .array('internalExperimentFlags')
    .end()
    .value('useSsl', true)
    .end()
    .object('user')
    .value('lockedSafetyMode', false)
    .end()
    .end()
    .value('input', '')
    .end().done());

  const headers: HeaderMap = getOriginReferrerHeaders(YOUTUBE_MUSIC_URL);
  getClientHeaders(WEB_REMIX_CLIENT_ID, WEB_HARDCODED_CLIENT_VERSION)
    .forEach((value: string[], key: string): void => {
      headers.set(key, value);
    });

  const response: Response = await getDownloader().postWithContentTypeJson(url, headers, json);
  return response.responseBody().length > 500 && response.responseCode() === 200;
}

export async function getYoutubeMusicClientVersion(): Promise<string> {
  if (!isNullOrEmpty(youtubeMusicClientVersion)) {
    return youtubeMusicClientVersion as string;
  }
  if (await isHardcodedYoutubeMusicClientVersionValid()) {
    youtubeMusicClientVersion = WEB_REMIX_HARDCODED_CLIENT_VERSION;
    return youtubeMusicClientVersion;
  }

  try {
    const url: string = 'https://music.youtube.com/sw.js';
    const headers: HeaderMap = getOriginReferrerHeaders(YOUTUBE_MUSIC_URL);
    const response: string = (await getDownloader().get(url, headers)).responseBody();
    youtubeMusicClientVersion = getStringResultFromRegexArray(response,
      INNERTUBE_CONTEXT_CLIENT_VERSION_REGEXES, 1);
  } catch (e) {
    const url: string = 'https://music.youtube.com/?ucbcb=1';
    const html: string = (await getDownloader().get(url, getCookieHeader())).responseBody();
    youtubeMusicClientVersion = getStringResultFromRegexArray(html,
      INNERTUBE_CONTEXT_CLIENT_VERSION_REGEXES, 1);
  }

  return youtubeMusicClientVersion as string;
}

/* //////////////////////////////////////////////////////////////////////////
// JSON shape readers
////////////////////////////////////////////////////////////////////////// */

export function getUrlFromNavigationEndpoint(navigationEndpoint: JsonObject): string | null {
  if (navigationEndpoint.has('urlEndpoint')) {
    const urlEndpoint: JsonObject = navigationEndpoint.getObject('urlEndpoint');
    let internUrl: string = urlEndpoint.getString('url', '') as string;
    if (internUrl.startsWith('https://www.youtube.com/redirect?')) {
      // remove the https://www.youtube.com part to fall in the next if block
      internUrl = internUrl.substring(23);
    }

    if (internUrl.startsWith('/redirect?')) {
      // the q parameter can be the first parameter
      internUrl = internUrl.substring(10);
      for (const param of internUrl.split('&')) {
        const parts: string[] = param.split('=');
        if (parts[0] === 'q' && parts.length > 1) {
          return decodeUrlUtf8(parts[1]);
        }
      }
    } else if (internUrl.startsWith('http')) {
      return internUrl;
    } else if (internUrl.startsWith('/channel') || internUrl.startsWith('/user')
      || internUrl.startsWith('/watch')) {
      return 'https://www.youtube.com' + internUrl;
    }
  }

  if (navigationEndpoint.has('browseEndpoint')) {
    const browseEndpoint: JsonObject = navigationEndpoint.getObject('browseEndpoint');
    const canonicalBaseUrl: string | null = browseEndpoint.getString('canonicalBaseUrl');
    const browseId: string | null = browseEndpoint.getString('browseId');

    if (browseId !== null) {
      if (browseId.startsWith('UC')) {
        // All channel IDs are prefixed with UC
        return 'https://www.youtube.com/channel/' + browseId;
      }
      if (browseId.startsWith('VL')) {
        // All playlist IDs are prefixed with VL, which is removed from the playlist ID
        return 'https://www.youtube.com/playlist?list=' + browseId.substring(2);
      }
    }

    if (!isNullOrEmpty(canonicalBaseUrl)) {
      return 'https://www.youtube.com' + canonicalBaseUrl;
    }
  }

  if (navigationEndpoint.has('watchEndpoint')) {
    const watchEndpoint: JsonObject = navigationEndpoint.getObject('watchEndpoint');
    let url: string = 'https://www.youtube.com/watch?v=' + watchEndpoint.getString(VIDEO_ID, '');
    if (watchEndpoint.has('playlistId')) {
      url += '&list=' + watchEndpoint.getString('playlistId', '');
    }
    if (watchEndpoint.has('startTimeSeconds')) {
      url += '&t=' + watchEndpoint.getInt('startTimeSeconds');
    }
    return url;
  }

  if (navigationEndpoint.has('watchPlaylistEndpoint')) {
    return 'https://www.youtube.com/playlist?list='
      + navigationEndpoint.getObject('watchPlaylistEndpoint').getString('playlistId', '');
  }

  if (navigationEndpoint.has('showDialogCommand')) {
    try {
      const listItems: JsonArray = JsonUtils.getArray(navigationEndpoint,
        'showDialogCommand.panelLoadingStrategy.inlineContent.dialogViewModel.customContent'
        + '.listViewModel.listItems');
      // the first item is always the channel that actually uploaded the video, i.e. the one it
      // appears in the video feed of
      const command: JsonObject = JsonUtils.getObject(listItems.getObject(0),
        'listItemViewModel.rendererContext.commandContext.onTap.innertubeCommand');
      return getUrlFromNavigationEndpoint(command);
    } catch (p) {
      // the dialog does not carry a navigation command; fall through
    }
  }

  if (navigationEndpoint.has('commandMetadata')) {
    const metadata: JsonObject = navigationEndpoint.getObject('commandMetadata')
      .getObject('webCommandMetadata');
    if (metadata.has('url')) {
      return 'https://www.youtube.com' + metadata.getString('url', '');
    }
  }

  return null;
}

/**
 * The text of a JSON object carrying either `simpleText` or a `runs` array.
 * `html` renders the runs' navigationEndpoints as anchors and their bold/italic/strikethrough.
 */
export function getTextFromObjectHtml(textObject: JsonObject | null, html: boolean):
  string | null {
  if (textObject === null || textObject.size() === 0) {
    return null;
  }

  if (textObject.has('simpleText')) {
    return textObject.getString('simpleText');
  }

  const runs: JsonArray = textObject.getArray('runs');
  if (runs.size() === 0) {
    return null;
  }

  let textBuilder: string = '';
  for (const run of runs.streamAsJsonObjects()) {
    let text: string = run.getString('text', '') as string;

    if (html) {
      if (run.has('navigationEndpoint')) {
        const url: string | null =
          getUrlFromNavigationEndpoint(run.getObject('navigationEndpoint'));
        if (!isNullOrEmpty(url)) {
          text = '<a href="' + Entities.escape(url as string) + '">' + Entities.escape(text)
            + '</a>';
        }
      }

      const bold: boolean = run.has('bold') && run.getBoolean('bold');
      const italic: boolean = run.has('italics') && run.getBoolean('italics');
      const strikethrough: boolean = run.has('strikethrough') && run.getBoolean('strikethrough');

      if (bold) {
        textBuilder += '<b>';
      }
      if (italic) {
        textBuilder += '<i>';
      }
      if (strikethrough) {
        textBuilder += '<s>';
      }

      textBuilder += text;

      if (strikethrough) {
        textBuilder += '</s>';
      }
      if (italic) {
        textBuilder += '</i>';
      }
      if (bold) {
        textBuilder += '</b>';
      }
    } else {
      textBuilder += text;
    }
  }

  let text: string = textBuilder;
  if (html) {
    text = text.replace(new RegExp('\\n', 'g'), '<br>');
    text = text.replace(new RegExp(' {2}', 'g'), ' &nbsp;');
  }
  return text;
}

/** The no-html overload of getTextFromObject(). */
export function getTextFromObject(textObject: JsonObject | null): string | null {
  return getTextFromObjectHtml(textObject, false);
}

export function getTextFromObjectOrThrow(textObject: JsonObject | null, error: string): string {
  const result: string | null = getTextFromObject(textObject);
  if (result === null) {
    throw new ParsingException('Could not extract text: ' + error);
  }
  return result;
}

export function getUrlFromObject(textObject: JsonObject | null): string | null {
  if (textObject === null || textObject.size() === 0) {
    return null;
  }
  const runs: JsonArray = textObject.getArray('runs');
  if (runs.size() === 0) {
    return null;
  }
  for (const textPart of runs.streamAsJsonObjects()) {
    const url: string | null =
      getUrlFromNavigationEndpoint(textPart.getObject('navigationEndpoint'));
    if (!isNullOrEmpty(url)) {
      return url;
    }
  }
  return null;
}

export function getTextAtKey(jsonObject: JsonObject, theKey: string): string | null {
  if (jsonObject.isString(theKey)) {
    return jsonObject.getString(theKey);
  }
  return getTextFromObject(jsonObject.getObject(theKey));
}

export function fixThumbnailUrl(thumbnailUrl: string): string {
  let result: string = thumbnailUrl;
  if (result.startsWith('//')) {
    result = result.substring(2);
  }
  if (result.startsWith(HTTP)) {
    result = replaceHttpWithHttps(result) as string;
  } else if (!result.startsWith(HTTPS)) {
    result = 'https://' + result;
  }
  return result;
}

/** Thumbnails of a YouTube InfoItem, from its `thumbnail.thumbnails` array. */
export function getThumbnailsFromInfoItem(infoItem: JsonObject): Image[] {
  try {
    return getImagesFromThumbnailsArray(infoItem.getObject('thumbnail')
      .getArray('thumbnails'));
  } catch (e) {
    throw new ParsingException('Could not get thumbnails from InfoItem',
      e instanceof Error ? e as Error : null);
  }
}

/** Images from a YouTube `thumbnails` array, dropping entries with no url. */
export function getImagesFromThumbnailsArray(thumbnails: JsonArray): Image[] {
  const images: Image[] = [];
  for (const thumbnail of thumbnails.streamAsJsonObjects()) {
    const url: string | null = thumbnail.getString('url');
    if (isNullOrEmpty(url)) {
      continue;
    }
    const height: number = thumbnail.getInt('height', Image.HEIGHT_UNKNOWN);
    images.push(new Image(fixThumbnailUrl(url as string), height,
      thumbnail.getInt('width', Image.WIDTH_UNKNOWN), resolutionLevelFromHeight(height)));
  }
  return images;
}

/* //////////////////////////////////////////////////////////////////////////
// Requests
////////////////////////////////////////////////////////////////////////// */

export function getValidJsonResponseBody(response: Response): string {
  if (response.responseCode() === 404) {
    throw new ContentNotAvailableException('Not found (\"' + response.responseCode() + ' '
      + response.responseMessage() + '\")');
  }

  const responseBody: string = response.responseBody();
  if (responseBody.length < 50) {
    throw new ParsingException('JSON response is too short');
  }

  // Check whether the request was redirected to the error page.
  // KNOWN CEILING (phase2-logic-contract.md §8): @ohos.net.http follows redirects internally and
  // exposes no final URL at API 12, so latestUrl() falls back to Content-Location and then the
  // request url. When it is empty there is nothing to check, and skipping is the safe direction:
  // a real /oops page also fails the content-type and length checks below/above.
  const latestUrlString: string = response.latestUrl();
  if (latestUrlString.length > 0) {
    try {
      const latestUrl: ohosUrl.URL = stringToURL(latestUrlString);
      if (latestUrl.host.toLowerCase() === 'www.youtube.com') {
        const path: string = latestUrl.pathname.toLowerCase();
        if (path === '/oops' || path === '/error') {
          throw new ContentNotAvailableException('Content unavailable');
        }
      }
    } catch (e) {
      if (e instanceof ContentNotAvailableException) {
        throw e;
      }
      // a malformed latest url is not itself a content error
    }
  }

  const responseContentType: string | null = response.getHeader('Content-Type');
  if (responseContentType !== null && responseContentType.toLowerCase().includes('text/html')) {
    throw new ParsingException('Got HTML document, expected JSON response (latest url was: \"'
      + response.latestUrl() + '\")');
  }

  return responseBody;
}

export async function getJsonPostResponse(endpoint: string, body: ArrayBuffer,
  localization: Localization): Promise<JsonObject> {
  const headers: HeaderMap = await getYouTubeHeaders();
  return JsonUtils.toJsonObject(getValidJsonResponseBody(
    await getDownloader().postWithContentTypeJson(
      YOUTUBEI_V1_URL + endpoint + '?' + DISABLE_PRETTY_PRINT_PARAMETER, headers, body,
      localization)));
}

/** The overload taking extra query parameters. */
export async function getJsonPostResponseWithQuery(endpoint: string, queryParameters: string[],
  body: ArrayBuffer, localization: Localization): Promise<JsonObject> {
  const headers: HeaderMap = await getYouTubeHeaders();

  const queryParametersString: string = queryParameters.length === 0
    ? '?' + DISABLE_PRETTY_PRINT_PARAMETER
    : '?' + queryParameters.join('&') + '&' + DISABLE_PRETTY_PRINT_PARAMETER;

  return JsonUtils.toJsonObject(getValidJsonResponseBody(
    await getDownloader().postWithContentTypeJson(
      YOUTUBEI_V1_URL + endpoint + queryParametersString, headers, body, localization)));
}

export async function prepareDesktopJsonBuilder(localization: Localization,
  contentCountry: ContentCountry): Promise<JsonBuilder> {
  return JsonObject.builder()
    .object('context')
    .object('client')
    .value('hl', localization.getLocalizationCode())
    .value('gl', contentCountry.getCountryCode())
    .value('clientName', WEB_CLIENT_NAME)
    .value('clientVersion', await getClientVersion())
    .value('originalUrl', 'https://www.youtube.com')
    .value('platform', DESKTOP_CLIENT_PLATFORM)
    .value('utcOffsetMinutes', 0)
    .end()
    .object('request')
    .array('internalExperimentFlags')
    .end()
    .value('useSsl', true)
    .end()
    .object('user')
    // TODO (as in the source): expose restricted mode with .value('enableSafetyMode', boolean)
    .value('lockedSafetyMode', false)
    .end()
    .end();
}

/* //////////////////////////////////////////////////////////////////////////
// User agents and headers
////////////////////////////////////////////////////////////////////////// */

export function getAndroidUserAgent(localization: Localization | null): string {
  return 'com.google.android.youtube/' + ANDROID_CLIENT_VERSION + ' (Linux; U; Android 15; '
    + (localization !== null ? localization : Localization.DEFAULT).getCountryCode() + ') gzip';
}

export function getIosUserAgent(localization: Localization | null): string {
  return 'com.google.ios.youtube/' + IOS_CLIENT_VERSION + '(' + IOS_DEVICE_MODEL
    + '; U; CPU iOS ' + IOS_USER_AGENT_VERSION + ' like Mac OS X; '
    + (localization !== null ? localization : Localization.DEFAULT).getCountryCode() + ')';
}

export function getVisionOsUserAgent(localization: Localization | null): string {
  return 'com.google.visionos.youtube/' + VISIONOS_CLIENT_VERSION + '(' + VISIONOS_DEVICE_MODEL
    + '; U; CPU visionOS ' + VISIONOS_USER_AGENT_VERSION + ' like Mac OS X; '
    + (localization !== null ? localization : Localization.DEFAULT).getCountryCode() + ')';
}

/** The required YouTube Music headers. */
export function getYoutubeMusicHeaders(): HeaderMap {
  const headers: HeaderMap = getOriginReferrerHeaders(YOUTUBE_MUSIC_URL);
  getClientHeaders(WEB_REMIX_CLIENT_ID,
    youtubeMusicClientVersion === null ? WEB_REMIX_HARDCODED_CLIENT_VERSION
      : youtubeMusicClientVersion)
    .forEach((value: string[], key: string): void => {
      headers.set(key, value);
    });
  return headers;
}

/**
 * The required YouTube headers, including the CONSENT cookie that prevents a redirect to
 * consent.youtube.com.
 */
export async function getYouTubeHeaders(): Promise<HeaderMap> {
  const headers: HeaderMap = await getClientInfoHeaders();
  headers.set('Cookie', [generateConsentCookie()]);
  return headers;
}

/** X-YouTube-Client-Name, X-YouTube-Client-Version, Origin and Referer. */
export async function getClientInfoHeaders(): Promise<HeaderMap> {
  const headers: HeaderMap = getOriginReferrerHeaders('https://www.youtube.com');
  getClientHeaders(WEB_CLIENT_ID, await getClientVersion())
    .forEach((value: string[], key: string): void => {
      headers.set(key, value);
    });
  return headers;
}

/** Origin and Referer, both set to the given URL. */
export function getOriginReferrerHeaders(url: string): HeaderMap {
  const headers: HeaderMap = new Map<string, string[]>();
  headers.set('Origin', [url]);
  headers.set('Referer', [url]);
  return headers;
}

/** X-YouTube-Client-Name and X-YouTube-Client-Version. */
export function getClientHeaders(name: string, version: string): HeaderMap {
  const headers: HeaderMap = new Map<string, string[]>();
  headers.set('X-YouTube-Client-Name', [name]);
  headers.set('X-YouTube-Client-Version', [version]);
  return headers;
}

/** A map holding only the consent cookie header. */
export function getCookieHeader(): HeaderMap {
  const headers: HeaderMap = new Map<string, string[]>();
  headers.set('Cookie', [generateConsentCookie()]);
  return headers;
}

export function generateConsentCookie(): string {
  // CAISAiAD means the user configured YouTube cookies manually, whatever the consent values.
  // It surprisingly allows extracting mixes and some YouTube Music playlists in the same way as
  // allowing all cookies. CAE= means the user rejected all non-necessary cookies.
  return 'SOCS=' + (isConsentAccepted() ? 'CAISAiAD' : 'CAE=');
}

export function extractCookieValue(cookieName: string, response: Response): string {
  const cookies: string[] | undefined = response.responseHeaders().get('set-cookie');
  if (cookies === undefined) {
    return '';
  }
  let result: string = '';
  for (const cookie of cookies) {
    const startIndex: number = cookie.indexOf(cookieName);
    if (startIndex !== -1) {
      const valueStart: number = startIndex + cookieName.length + '='.length;
      const valueEnd: number = cookie.indexOf(';', startIndex);
      result = valueEnd === -1
        ? cookie.substring(valueStart) : cookie.substring(valueStart, valueEnd);
    }
  }
  return result;
}

/* //////////////////////////////////////////////////////////////////////////
// Misc
////////////////////////////////////////////////////////////////////////// */

/**
 * The shared alert check: several endpoints report an error the same way, as an `alerts` entry
 * of type ERROR.
 */
export function defaultAlertsCheck(initialData: JsonObject): void {
  const alerts: JsonArray = initialData.getArray('alerts');
  if (alerts.size() === 0) {
    return;
  }
  const alertRenderer: JsonObject = alerts.getObject(0).getObject('alertRenderer');
  const alertText: string | null = getTextFromObject(alertRenderer.getObject('text'));
  const alertType: string = alertRenderer.getString('type', '') as string;
  if (alertType.toUpperCase() !== 'ERROR') {
    return;
  }
  if (alertText !== null && (alertText.includes('This account has been terminated')
    || alertText.includes('This channel was removed'))) {
    if (new RegExp('.*violat(ed|ion|ing).*').test(alertText)
      || alertText.includes('infringement')) {
      throw new AccountTerminatedException(alertText, AccountTerminatedReason.VIOLATION);
    }
    throw new AccountTerminatedException(alertText);
  }
  throw new ContentNotAvailableException('Got error: \"' + alertText + '\"');
}

/**
 * YouTube sometimes hands out URLs going through Google's cache
 * (`https://webcache.googleusercontent.com/search?q=cache:CACHED_URL`); this returns the original.
 */
export function extractCachedUrlIfNeeded(url: string | null): string | null {
  if (url === null) {
    return null;
  }
  if (url.includes('webcache.googleusercontent.com')) {
    return url.split('cache:')[1];
  }
  return url;
}

export function isVerified(badges: JsonArray): boolean {
  if (badges.size() === 0) {
    return false;
  }
  for (const badge of badges.streamAsJsonObjects()) {
    const style: string | null = badge.getObject('metadataBadgeRenderer').getString('style');
    if (style !== null
      && (style === 'BADGE_STYLE_TYPE_VERIFIED' || style === 'BADGE_STYLE_TYPE_VERIFIED_ARTIST')) {
      return true;
    }
  }
  return false;
}

export function hasArtistOrVerifiedIconBadgeAttachment(attachmentRuns: JsonArray): boolean {
  for (const attachmentRun of attachmentRuns.streamAsJsonObjects()) {
    const sources: JsonArray = attachmentRun.getObject('element')
      .getObject('type')
      .getObject('imageType')
      .getObject('image')
      .getArray('sources');
    for (const source of sources.streamAsJsonObjects()) {
      const imageName: string | null = source.getObject('clientResource').getString('imageName');
      if (imageName === 'CHECK_CIRCLE_FILLED' || imageName === 'AUDIO_BADGE'
        || imageName === 'MUSIC_FILLED') {
        return true;
      }
    }
  }
  return false;
}

/** A content playback nonce (`cpn`), sent by YouTube clients in playback and player requests. */
export function generateContentPlaybackNonce(): string {
  return generateRandomStringFromAlphabet(CONTENT_PLAYBACK_NONCE_ALPHABET, 16, numberGenerator);
}

/** The `t` parameter mobile clients send as a query of the player request. */
export function generateTParameter(): string {
  return generateRandomStringFromAlphabet(CONTENT_PLAYBACK_NONCE_ALPHABET, 12, numberGenerator);
}

export function isWebStreamingUrl(url: string): boolean {
  return Parser.isMatch(C_WEB_PATTERN, url);
}

export function isWebEmbeddedPlayerStreamingUrl(url: string): boolean {
  return Parser.isMatch(C_WEB_EMBEDDED_PLAYER_PATTERN, url);
}

export function isAndroidStreamingUrl(url: string): boolean {
  return Parser.isMatch(C_ANDROID_PATTERN, url);
}

export function isIosStreamingUrl(url: string): boolean {
  return Parser.isMatch(C_IOS_PATTERN, url);
}

export function isVisionOsStreamingUrl(url: string): boolean {
  return Parser.isMatch(C_VISIONOS_PATTERN, url);
}

/**
 * How the required `SOCS` consent cookie is generated: false (the default) uses `CAE=`, true uses
 * `CAISAiAD`. True is needed to extract mixes and some YouTube Music playlists in some countries.
 */
export function setConsentAccepted(accepted: boolean): void {
  consentAccepted = accepted;
}

export function isConsentAccepted(): boolean {
  return consentAccepted;
}

/**
 * The audio track type carried by a format's XTags (e.g. `acont=original, lang=en`), or null when
 * there is none. The XTags are a base64url-encoded protobuf — see ./Protobuf.ts.
 */
export function extractAudioTrackType(xtags: string | null): AudioTrackType | null {
  if (xtags === null) {
    return null;
  }
  let atype: string | null = null;
  try {
    for (const tag of XTags.parseFrom(base64UrlDecode(xtags)).getXtagsList()) {
      if (tag.getKey() === 'acont') {
        atype = tag.getValue();
        break;
      }
    }
  } catch (ignored) {
    // InvalidProtocolBufferException in the source: an unreadable xtags is simply unknown
    return null;
  }

  if (atype === null) {
    return null;
  }
  if (atype === 'original') {
    return AudioTrackType.ORIGINAL;
  }
  if (atype === 'dubbed' || atype === 'dubbed-auto') {
    return AudioTrackType.DUBBED;
  }
  if (atype === 'descriptive') {
    return AudioTrackType.DESCRIPTIVE;
  }
  if (atype === 'secondary') {
    return AudioTrackType.SECONDARY;
  }
  return null;
}

export async function getVisitorDataFromInnertube(
  innertubeClientRequestInfo: InnertubeClientRequestInfo, localization: Localization,
  contentCountry: ContentCountry, httpHeaders: HeaderMap,
  innertubeDomainAndVersionEndpoint: string, embedUrl: string | null,
  useGuideEndpoint: boolean): Promise<string> {
  const builder: JsonBuilder = prepareJsonBuilder(localization, contentCountry,
    innertubeClientRequestInfo, embedUrl);

  const body: ArrayBuffer = Request.utf8Body(JsonWriter.stringValue(builder.done()));

  const visitorData: string | null = JsonUtils.toJsonObject(getValidJsonResponseBody(
    await getDownloader().postWithContentTypeJson(
      innertubeDomainAndVersionEndpoint + (useGuideEndpoint ? 'guide' : 'visitor_id') + '?'
      + DISABLE_PRETTY_PRINT_PARAMETER, httpHeaders, body)))
    .getObject('responseContext')
    .getString('visitorData');

  if (isNullOrEmpty(visitorData)) {
    throw new ParsingException('Could not get visitorData');
  }
  return visitorData as string;
}

export function prepareJsonBuilder(localization: Localization, contentCountry: ContentCountry,
  innertubeClientRequestInfo: InnertubeClientRequestInfo,
  embedUrl: string | null): JsonBuilder {
  const builder: JsonBuilder = JsonObject.builder()
    .object('context')
    .object('client')
    .value('clientName', innertubeClientRequestInfo.clientInfo.clientName)
    .value('clientVersion', innertubeClientRequestInfo.clientInfo.clientVersion);

  if (innertubeClientRequestInfo.clientInfo.clientScreen !== null) {
    builder.value('clientScreen', innertubeClientRequestInfo.clientInfo.clientScreen);
  }
  if (innertubeClientRequestInfo.deviceInfo.platform !== null) {
    builder.value('platform', innertubeClientRequestInfo.deviceInfo.platform);
  }
  if (innertubeClientRequestInfo.clientInfo.visitorData !== null) {
    builder.value('visitorData', innertubeClientRequestInfo.clientInfo.visitorData);
  }
  if (innertubeClientRequestInfo.deviceInfo.deviceMake !== null) {
    builder.value('deviceMake', innertubeClientRequestInfo.deviceInfo.deviceMake);
  }
  if (innertubeClientRequestInfo.deviceInfo.deviceModel !== null) {
    builder.value('deviceModel', innertubeClientRequestInfo.deviceInfo.deviceModel);
  }
  if (innertubeClientRequestInfo.deviceInfo.osName !== null) {
    builder.value('osName', innertubeClientRequestInfo.deviceInfo.osName);
  }
  if (innertubeClientRequestInfo.deviceInfo.osVersion !== null) {
    builder.value('osVersion', innertubeClientRequestInfo.deviceInfo.osVersion);
  }
  if (innertubeClientRequestInfo.deviceInfo.androidSdkVersion > 0) {
    builder.value('androidSdkVersion', innertubeClientRequestInfo.deviceInfo.androidSdkVersion);
  }

  builder.value('hl', localization.getLocalizationCode())
    .value('gl', contentCountry.getCountryCode())
    .value('utcOffsetMinutes', 0)
    .end();

  if (embedUrl !== null) {
    builder.object('thirdParty')
      .value('embedUrl', embedUrl)
      .end();
  }

  builder.object('request')
    .array('internalExperimentFlags')
    .end()
    .value('useSsl', true)
    .end()
    .object('user')
    // TODO (as in the source): expose restricted mode with .value('enableSafetyMode', boolean)
    .value('lockedSafetyMode', false)
    .end()
    .end();

  return builder;
}

/**
 * The first collaborator: the channel that owns the video, i.e. the one whose channel page shows
 * it. Null when the navigation endpoint carries no collaborator dialog.
 */
export function getFirstCollaborator(navigationEndpoint: JsonObject): JsonObject | null {
  try {
    const listItems: JsonArray = JsonUtils.getArray(navigationEndpoint,
      'showDialogCommand.panelLoadingStrategy.inlineContent.dialogViewModel.customContent'
      + '.listViewModel.listItems');
    return listItems.getObject(0).getObject('listItemViewModel');
  } catch (e) {
    return null;
  }
}
