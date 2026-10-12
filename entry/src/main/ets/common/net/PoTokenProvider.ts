/*
 * Port of org.schabi.newpipe.util.potoken.{PoTokenProviderImpl, PoTokenWebView, JavaScriptUtil}
 * (the plan's svc_potoken) — everything except the WebView itself.
 *
 * A poToken can only be minted by running Google's BotGuard JavaScript, which needs a real DOM.
 * The source therefore splits the job in two, and so does this port:
 *   - the NETWORK + ENCODING half (this module): the two BotGuard calls
 *     `https://www.youtube.com/api/jnn/v1/Create` and `.../GenerateIT` (endpoints
 *     potoken_botguard_create / potoken_botguard_generate_it, whose literals live in
 *     services/youtube/PoToken.ts), the challenge/integrity-token parsing, and the u8/base64
 *     conversions;
 *   - the JS half: a `Web` component that evaluates runBotGuard()/obtainPoToken(). That is a
 *     Phase-3 page; it implements PoTokenWebViewDriver and calls setDriver().
 *
 * SUBSTITUTION, phase2-logic-contract.md §2.3: this whole path is best-effort. The extractor's
 * PoTokenProvider interface is SYNCHRONOUS, so the getters answer from a cache that prepare()
 * fills in the background; before that — and after ANY failure, including no driver at all — they
 * return null and YoutubeStreamHelper takes the nsig-free client (ANDROID / IOS / TVHTML5), which
 * needs no poToken. Nothing here throws at a caller and nothing here crashes the load.
 */

import { util } from '@kit.ArkTS';
import { JsonArray, JsonParser } from '../extractor/json/NanoJson';
import { ExtractorLogger } from '../extractor/core/ExtractorLogger';
import { DownloaderImpl } from './Downloader';
import { HeaderMap, Response } from '../extractor/downloader/Downloader';
import {
  PoTokenProvider,
  PoTokenResult,
  PO_TOKEN_CREATE_URL,
  PO_TOKEN_GENERATE_IT_URL
} from '../extractor/services/youtube/PoToken';
import { setPoTokenProvider }
  from '../extractor/services/youtube/extractors/YoutubeStreamExtractor';

const TAG: string = 'PoTokenProvider';

/** Public API key used by BotGuard, obtained by looking at BotGuard requests. */
const GOOGLE_API_KEY: string = 'AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw';
const REQUEST_KEY: string = 'O43z0dpjhgX20SCx4KAo';
/** PoTokenWebView replaces the Downloader's user agent with this one. */
const PO_TOKEN_USER_AGENT: string = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
  + 'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.3';
/** The source leaves 10 minutes of margin on the integrity token's lifetime. */
const EXPIRATION_MARGIN_SECONDS: number = 600;

/** Port of PoTokenException. */
export class PoTokenException extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'PoTokenException';
  }
}

/**
 * What the Phase-3 WebView page must provide. Each method is the ArkTS side of one
 * `evaluateJavascript` block in PoTokenWebView.
 */
export interface PoTokenWebViewDriver {
  /** `runBotGuard(<challengeData>)` -> the botguardResponse it resolves with. */
  runBotGuard(challengeData: string): Promise<string>;

  /** `this.integrityToken = <integrityTokenU8>`. */
  setIntegrityToken(integrityTokenU8: string): Promise<void>;

  /** `obtainPoToken(webPoSignalOutput, integrityToken, <u8Identifier>)`, as "97,98,99". */
  obtainPoToken(identifier: string, u8Identifier: string): Promise<string>;

  /** Releases the WebView. */
  close(): void;
}

/* //////////////////////////////////////////////////////////////////////////
// JavaScriptUtil
////////////////////////////////////////////////////////////////////////// */

/** The JS object literal parseChallengeData() builds, embedded verbatim in a JS snippet. */
interface InterpreterJavascript {
  privateDoNotAccessOrElseSafeScriptWrappedValue: string | null;
  privateDoNotAccessOrElseTrustedResourceUrlWrappedValue: string | null;
}

interface ChallengeData {
  messageId: string | null;
  interpreterJavascript: InterpreterJavascript;
  interpreterHash: string | null;
  program: string | null;
  globalName: string | null;
  clientExperimentsStateBlob: string | null;
}

/** Decodes YouTube's base64 dialect (`-` `_` `.` for `+` `/` `=`). */
function base64ToBytes(base64: string): Uint8Array {
  const normalized: string = base64.replace(new RegExp('-', 'g'), '+')
    .replace(new RegExp('_', 'g'), '/')
    .replace(new RegExp('\\.', 'g'), '=');
  try {
    return new util.Base64Helper().decodeSync(normalized);
  } catch (e) {
    throw new PoTokenException('Cannot base64 decode');
  }
}

/** `new Uint8Array([1,2,3])`, embeddable directly in JavaScript. */
function newUint8Array(contents: Uint8Array): string {
  const parts: string[] = [];
  for (const byte of contents) {
    parts.push(`${byte}`);
  }
  return 'new Uint8Array([' + parts.join(',') + '])';
}

/** Port of stringToU8(). */
export function stringToU8(identifier: string): string {
  return newUint8Array(new util.TextEncoder().encodeInto(identifier));
}

/** Port of u8ToBase64(): "97,98,99" -> the poToken base64 dialect. */
export function u8ToBase64(poToken: string): string {
  const parts: string[] = poToken.split(',');
  const bytes: Uint8Array = new Uint8Array(parts.length);
  for (let i = 0; i < parts.length; i++) {
    bytes[i] = parseInt(parts[i], 10) & 0xFF;
  }
  return new util.Base64Helper().encodeToStringSync(bytes)
    .replace(new RegExp('\\+', 'g'), '-')
    .replace(new RegExp('/', 'g'), '_');
}

/** Port of descramble(): base64-decode the scrambled challenge, then add 97 to each byte. */
function descramble(scrambledChallenge: string): string {
  const bytes: Uint8Array = base64ToBytes(scrambledChallenge);
  const shifted: Uint8Array = new Uint8Array(bytes.length);
  for (let i = 0; i < bytes.length; i++) {
    shifted[i] = (bytes[i] + 97) & 0xFF;
  }
  return util.TextDecoder.create('utf-8').decodeToString(shifted);
}

/** The first string in a nested array, or null — Java's `getArray(i, null)?.find { it is String }`. */
function firstStringIn(array: JsonArray | null): string | null {
  if (array === null) {
    return null;
  }
  for (let i = 0; i < array.size(); i++) {
    if (array.isString(i)) {
      return array.getString(i, null);
    }
  }
  return null;
}

/** Port of parseChallengeData(). */
export function parseChallengeData(rawChallengeData: string): string {
  const scrambled: JsonArray = JsonParser.array().from(rawChallengeData);

  let challengeData: JsonArray;
  if (scrambled.size() > 1 && scrambled.isString(1)) {
    challengeData = JsonParser.array().from(descramble(scrambled.getString(1, '') as string));
  } else {
    challengeData = scrambled.getArray(0);
  }

  const interpreter: InterpreterJavascript = {
    privateDoNotAccessOrElseSafeScriptWrappedValue: firstStringIn(challengeData.getArray(1, null)),
    privateDoNotAccessOrElseTrustedResourceUrlWrappedValue:
      firstStringIn(challengeData.getArray(2, null))
  };
  const data: ChallengeData = {
    messageId: challengeData.getString(0, null),
    interpreterJavascript: interpreter,
    interpreterHash: challengeData.getString(3, null),
    program: challengeData.getString(4, null),
    globalName: challengeData.getString(5, null),
    clientExperimentsStateBlob: challengeData.getString(7, null)
  };
  return JSON.stringify(data);
}

/** The integrity token as an embeddable `Uint8Array`, plus its lifetime in seconds. */
export class IntegrityTokenData {
  readonly integrityTokenU8: string;
  readonly expirationSeconds: number;

  constructor(integrityTokenU8: string, expirationSeconds: number) {
    this.integrityTokenU8 = integrityTokenU8;
    this.expirationSeconds = expirationSeconds;
  }
}

/** Port of parseIntegrityTokenData(). */
export function parseIntegrityTokenData(rawIntegrityTokenData: string): IntegrityTokenData {
  const data: JsonArray = JsonParser.array().from(rawIntegrityTokenData);
  return new IntegrityTokenData(newUint8Array(base64ToBytes(data.getString(0, '') as string)),
    data.getLong(1, 0));
}

/* //////////////////////////////////////////////////////////////////////////
// The provider
////////////////////////////////////////////////////////////////////////// */

export class PoTokenProviderImpl implements PoTokenProvider {
  private static readonly INSTANCE: PoTokenProviderImpl = new PoTokenProviderImpl();

  private driver: PoTokenWebViewDriver | null = null;
  private visitorData: string | null = null;
  private streamingPot: string | null = null;
  private expirationEpochMillis: number = 0;
  /** videoId -> player poToken, filled by prepare(). */
  private readonly playerPoTokens: Map<string, string> = new Map<string, string>();
  /** One in-flight preparation at a time; the source synchronizes on WebPoTokenGenLock. */
  private preparing: Promise<void> | null = null;

  private constructor() {
    // no instance
  }

  static getInstance(): PoTokenProviderImpl {
    return PoTokenProviderImpl.INSTANCE;
  }

  /**
   * Called by the Phase-3 WebView page once it is ready. Registering the provider only here is
   * what keeps the nsig-free path in charge until BotGuard can actually run (§2.3).
   */
  setDriver(driver: PoTokenWebViewDriver | null): void {
    this.driver = driver;
    this.reset();
    setPoTokenProvider(driver === null ? null : this);
  }

  /** Port of PoTokenGenerator.isExpired(). */
  isExpired(): boolean {
    return Date.now() > this.expirationEpochMillis;
  }

  private reset(): void {
    this.visitorData = null;
    this.streamingPot = null;
    this.expirationEpochMillis = 0;
    this.playerPoTokens.clear();
  }

  /* ---- PoTokenProvider: synchronous, cache-only, never throws ---- */

  getWebClientPoToken(videoId: string): PoTokenResult | null {
    const visitorData: string | null = this.visitorData;
    const playerPot: string | undefined = this.playerPoTokens.get(videoId);
    if (visitorData === null || playerPot === undefined || this.isExpired()) {
      return null;
    }
    return new PoTokenResult(visitorData, playerPot, this.streamingPot);
  }

  getWebEmbedClientPoToken(videoId: string): PoTokenResult | null {
    return null;
  }

  getAndroidClientPoToken(videoId: string): PoTokenResult | null {
    return null;
  }

  getIosClientPoToken(videoId: string): PoTokenResult | null {
    return null;
  }

  /* ---- The asynchronous half ---- */

  /**
   * Port of PoTokenProviderImpl.getWebClientPoToken(videoId, forceRecreate): mint the tokens for
   * one video so the synchronous getter can answer. Resolves to false on ANY failure (no driver,
   * a broken WebView, a non-200 from BotGuard) — the caller then simply loads without a poToken.
   *
   * Call it before loading a stream; awaiting it is optional, since a miss only costs the WEB
   * client path.
   */
  async prepare(videoId: string, forceRecreate: boolean = false): Promise<boolean> {
    const driver: PoTokenWebViewDriver | null = this.driver;
    if (driver === null) {
      return false;
    }
    try {
      await this.initialize(driver, forceRecreate);
      const playerPot: string = u8ToBase64(
        await driver.obtainPoToken(videoId, stringToU8(videoId)));
      this.playerPoTokens.set(videoId, playerPot);
      return true;
    } catch (e) {
      ExtractorLogger.e(TAG, 'Could not obtain poToken, falling back to the nsig-free client',
        [], e instanceof Error ? e as Error : null);
      if (!forceRecreate) {
        // The source retries once, recreating the generator from scratch.
        this.reset();
        return this.prepare(videoId, true);
      }
      return false;
    }
  }

  /**
   * The initialization the source does inside `synchronized(WebPoTokenGenLock)`: run BotGuard,
   * install the integrity token, and mint the ONE streaming poToken that must exist before any
   * player token. Concurrent callers await the same run rather than starting a second one.
   */
  private async initialize(driver: PoTokenWebViewDriver, forceRecreate: boolean): Promise<void> {
    if (!forceRecreate && this.visitorData !== null && !this.isExpired()) {
      return;
    }
    const inFlight: Promise<void> | null = this.preparing;
    if (inFlight !== null) {
      return inFlight;
    }
    const run: Promise<void> = this.runInitialization(driver);
    this.preparing = run;
    try {
      await run;
    } finally {
      this.preparing = null;
    }
  }

  private async runInitialization(driver: PoTokenWebViewDriver): Promise<void> {
    // downloadAndRunBotguard()
    const challenge: string = parseChallengeData(await PoTokenProviderImpl.botguardRequest(
      PO_TOKEN_CREATE_URL, `[ "${REQUEST_KEY}" ]`));
    const botguardResponse: string = await driver.runBotGuard(challenge);

    // onRunBotguardResult()
    const integrity: IntegrityTokenData = parseIntegrityTokenData(
      await PoTokenProviderImpl.botguardRequest(PO_TOKEN_GENERATE_IT_URL,
        `[ "${REQUEST_KEY}", "${botguardResponse}" ]`));
    this.expirationEpochMillis =
      Date.now() + (integrity.expirationSeconds - EXPIRATION_MARGIN_SECONDS) * 1000;
    await driver.setIntegrityToken(integrity.integrityTokenU8);

    // The visitor data the WEB client sends with the token. The source reads it from Innertube;
    // the WebView is the same origin, so the page's own visitor data is what BotGuard signed.
    this.visitorData = YoutubeVisitorData.get();
    // The streaming poToken must be generated exactly once, before any player token.
    this.streamingPot = u8ToBase64(await driver.obtainPoToken(this.visitorData as string,
      stringToU8(this.visitorData as string)));
  }

  /**
   * Port of makeBotguardServiceRequest(): POST with BotGuard's own headers, the Downloader's user
   * agent replaced. A non-200 is an error, as there.
   */
  private static async botguardRequest(url: string, data: string): Promise<string> {
    const headers: HeaderMap = new Map<string, string[]>();
    headers.set('User-Agent', [PO_TOKEN_USER_AGENT]);
    headers.set('Accept', ['application/json']);
    headers.set('Content-Type', ['application/json+protobuf']);
    headers.set('x-goog-api-key', [GOOGLE_API_KEY]);
    headers.set('x-user-agent', ['grpc-web-javascript/0.1']);

    const body: Uint8Array = new util.TextEncoder().encodeInto(data);
    const response: Response = await DownloaderImpl.getInstance().post(url, headers, body.buffer);
    if (response.responseCode() !== 200) {
      throw new PoTokenException('Invalid response code: ' + response.responseCode());
    }
    return response.responseBody();
  }
}

/**
 * The visitor-data holder. The extractor sets it while bootstrapping Innertube; until it does,
 * the WEB poToken path stays unavailable and the nsig-free client serves — never a crash (§2.3).
 * ponytail: a one-value holder rather than a second Innertube bootstrap here; the extractor
 * already performs that request and duplicating it would double the traffic.
 */
export class YoutubeVisitorData {
  private static value: string | null = null;

  static set(visitorData: string): void {
    YoutubeVisitorData.value = visitorData;
  }

  static get(): string {
    const current: string | null = YoutubeVisitorData.value;
    if (current === null) {
      throw new PoTokenException('visitor data is not available yet');
    }
    return current;
  }
}
