/*
 * Port of org.schabi.newpipe.extractor.services.youtube.{PoTokenProvider, PoTokenResult}
 * (NewPipeExtractor v0.26.5), plus the two BotGuard endpoints the APP-side provider drives
 * (org.schabi.newpipe.util.potoken.PoTokenWebView).
 *
 * Both classes live in one module: PoTokenProvider's every method returns a PoTokenResult, so
 * splitting them would only add an import.
 *
 * SUBSTITUTION NOTE (phase2-logic-contract.md §2.3): a poToken can only be minted by running
 * Google's BotGuard JavaScript, so the provider is driven by a WebView on the app side — a LATER
 * PASS owns that driver. Until it exists, no provider is registered, `getPoTokenProvider()`
 * returns null, and YoutubeStreamHelper takes the nsig-free client path (ANDROID / IOS /
 * TVHTML5-equivalent VISIONOS), which needs no poToken. That is a graceful degrade, never a crash.
 */

/** The result of a successful poToken extraction by a PoTokenProvider. */
export class PoTokenResult {
  /** The visitor data associated with the poToken. */
  readonly visitorData: string;
  /** The poToken of a player request: a protobuf object encoded as base 64. */
  readonly playerRequestPoToken: string;
  /**
   * The poToken appended to streaming URLs (`pot` parameter). Required on HTML5 clients and may
   * differ from the player-request poToken; null when the provider has none.
   */
  readonly streamingDataPoToken: string | null;

  constructor(visitorData: string, playerRequestPoToken: string,
    streamingDataPoToken: string | null) {
    this.visitorData = visitorData;
    this.playerRequestPoToken = playerRequestPoToken;
    this.streamingDataPoToken = streamingDataPoToken;
  }
}

/**
 * Provides poTokens ("proof of origin tokens") to YouTube player requests.
 *
 * An implementation that does not want to return a poToken for a client MUST return null for it —
 * the caller then falls back to a client that needs none.
 */
export interface PoTokenProvider {
  /** WEB (desktop website). Needs Google's BotGuard machine and a real DOM. */
  getWebClientPoToken(videoId: string): PoTokenResult | null;

  /** WEB_EMBEDDED_PLAYER (web embeds). One token, used in both player requests and URLs. */
  getWebEmbedClientPoToken(videoId: string): PoTokenResult | null;

  /** ANDROID app. Minted by DroidGuard; only needed for the player request. */
  getAndroidClientPoToken(videoId: string): PoTokenResult | null;

  /** IOS app. Minted by iosGuard; only needed for the player request. */
  getIosClientPoToken(videoId: string): PoTokenResult | null;
}

/**
 * The two BotGuard endpoints the app-side WebView provider posts to, ported verbatim from
 * PoTokenWebView.kt. Declared here so the poToken surface is one module; the driver that calls
 * them is a later pass.
 */
export const PO_TOKEN_CREATE_URL: string = 'https://www.youtube.com/api/jnn/v1/Create';
export const PO_TOKEN_GENERATE_IT_URL: string = 'https://www.youtube.com/api/jnn/v1/GenerateIT';
