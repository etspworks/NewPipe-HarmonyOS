/*
 * Port of org.schabi.newpipe.extractor.services.soundcloud.linkHandler
 * .SoundcloudStreamLinkHandlerFactory (NewPipeExtractor v0.26.5).
 *
 * DEVIATION, and it is structural: SoundCloud resolves BOTH directions of the url <-> id mapping
 * over the network (the widget API for the id, the embed player for the url), while the ported
 * core LinkHandlerFactory.getId()/getUrl() are synchronous. So each is split in two:
 *   - `resolveId(url)` / `getUrlAsync(id)` do the I/O and memoize the answer in
 *     SoundcloudParsingHelper;
 *   - `getId(url)` / `getUrl(id, baseUrl)` are the synchronous overrides the core calls; they
 *     serve the memoized answer and raise a ParsingException when it has not been resolved yet.
 * Callers therefore use `fromUrlAsync(url)` instead of `fromUrl(url)`.
 */

import { LinkHandlerFactory } from '../../../linkhandler/LinkHandlerFactory';
import { LinkHandler } from '../../../linkhandler/LinkHandler';
import { Parser } from '../../../core/Parser';
import { checkUrl, followGoogleRedirectIfNeeded } from '../../../core/Utils';
import { ParsingException } from '../../../exceptions/Exceptions';
import { SoundcloudParsingHelper } from '../SoundcloudParsingHelper';

const ON_URL_PATTERN: string = '^https?://on\\.soundcloud\\.com/[0-9a-zA-Z]+$';

const URL_PATTERN: RegExp = new RegExp(
  '^https?://(?:www\\.|m\\.)?'
  + 'soundcloud.com/[0-9a-z_-]+'
  + '/(?!(?:tracks|albums|sets|reposts|followers|following)/?$)[0-9a-z_-]+/?(?:[#?].*)?$'
  + '|' + ON_URL_PATTERN);

const API_URL_PATTERN: RegExp = new RegExp(
  '^https?://api-v2\\.soundcloud.com'
  + '/(tracks|albums|sets|reposts|followers|following)/([0-9a-z_-]+)/');

/** The legacy track API the embed player canonicalises a track id through. */
const TRACKS_API: string = 'https://api.soundcloud.com/tracks/';

export class SoundcloudStreamLinkHandlerFactory extends LinkHandlerFactory {
  private static readonly INSTANCE: SoundcloudStreamLinkHandlerFactory =
    new SoundcloudStreamLinkHandlerFactory();

  static getInstance(): SoundcloudStreamLinkHandlerFactory {
    return SoundcloudStreamLinkHandlerFactory.INSTANCE;
  }

  /** Does the embed-player round trip and memoizes the canonical url. */
  static async resolveUrl(id: string): Promise<string> {
    try {
      return await SoundcloudParsingHelper.resolveUrlWithEmbedPlayer(TRACKS_API + id);
    } catch (e) {
      throw new ParsingException(e instanceof Error ? (e as Error).message : `${e}`,
        e instanceof Error ? e as Error : null);
    }
  }

  getUrl(id: string, baseUrl: string | null = null): string {
    const cached: string | null = SoundcloudParsingHelper.cachedUrl(TRACKS_API + id);
    if (cached === null) {
      throw new ParsingException('SoundCloud track url for id ' + id
        + ' is not resolved yet - call SoundcloudStreamLinkHandlerFactory.resolveUrl(id) first');
    }
    return cached;
  }

  /** Does the widget-API round trip and memoizes the id for the synchronous getId(). */
  static async resolveId(url: string): Promise<string> {
    if (Parser.isMatch(API_URL_PATTERN, url)) {
      return Parser.matchGroup1(API_URL_PATTERN, url);
    }
    checkUrl(URL_PATTERN, url);
    try {
      return await SoundcloudParsingHelper.resolveIdWithWidgetApi(url);
    } catch (e) {
      throw new ParsingException(e instanceof Error ? (e as Error).message : `${e}`,
        e instanceof Error ? e as Error : null);
    }
  }

  getId(url: string): string {
    if (Parser.isMatch(API_URL_PATTERN, url)) {
      return Parser.matchGroup1(API_URL_PATTERN, url);
    }
    checkUrl(URL_PATTERN, url);

    const cached: string | null = SoundcloudParsingHelper.cachedId(url);
    if (cached === null) {
      throw new ParsingException('SoundCloud id for ' + url
        + ' is not resolved yet - use fromUrlAsync(url)');
    }
    return cached;
  }

  onAcceptUrl(url: string): boolean {
    return Parser.isMatch(URL_PATTERN, url.toLowerCase());
  }

  /** The async form of fromUrl(): resolves the id first, then builds the handler. */
  async fromUrlAsync(url: string, baseUrl: string | null = null): Promise<LinkHandler> {
    const polishedUrl: string = followGoogleRedirectIfNeeded(url);
    await SoundcloudStreamLinkHandlerFactory.resolveId(polishedUrl);
    await SoundcloudStreamLinkHandlerFactory.resolveUrl(this.getId(polishedUrl));
    return this.fromUrl(polishedUrl, baseUrl);
  }

  /** The async form of fromId(): resolves the canonical url first. */
  async fromIdAsync(id: string, baseUrl: string | null = null): Promise<LinkHandler> {
    await SoundcloudStreamLinkHandlerFactory.resolveUrl(id);
    return this.fromId(id, baseUrl);
  }
}
