/*
 * Port of org.schabi.newpipe.extractor.services.soundcloud.linkHandler
 * .SoundcloudChannelLinkHandlerFactory (NewPipeExtractor v0.26.5).
 *
 * Same sync/async split as SoundcloudStreamLinkHandlerFactory - see its header.
 */

import { ListLinkHandlerFactory } from '../../../linkhandler/LinkHandlerFactory';
import { ListLinkHandler } from '../../../linkhandler/LinkHandler';
import { Parser } from '../../../core/Parser';
import { checkUrl, followGoogleRedirectIfNeeded } from '../../../core/Utils';
import { ParsingException } from '../../../exceptions/Exceptions';
import { SoundcloudParsingHelper } from '../SoundcloudParsingHelper';

const URL_PATTERN: RegExp = new RegExp('^https?://(www\\.|m\\.)?soundcloud.com/[0-9a-z_-]+'
  + '(/((tracks|albums|sets|reposts|followers|following)/?)?)?([#?].*)?$');

/** The legacy users API the embed player canonicalises a user id through. */
const USERS_API: string = 'https://api.soundcloud.com/users/';

export class SoundcloudChannelLinkHandlerFactory extends ListLinkHandlerFactory {
  private static readonly INSTANCE: SoundcloudChannelLinkHandlerFactory =
    new SoundcloudChannelLinkHandlerFactory();

  static getInstance(): SoundcloudChannelLinkHandlerFactory {
    return SoundcloudChannelLinkHandlerFactory.INSTANCE;
  }

  static async resolveId(url: string): Promise<string> {
    checkUrl(URL_PATTERN, url);
    try {
      return await SoundcloudParsingHelper.resolveIdWithWidgetApi(url);
    } catch (e) {
      throw new ParsingException(e instanceof Error ? (e as Error).message : `${e}`,
        e instanceof Error ? e as Error : null);
    }
  }

  static async resolveUrl(id: string): Promise<string> {
    try {
      return await SoundcloudParsingHelper.resolveUrlWithEmbedPlayer(USERS_API + id);
    } catch (e) {
      throw new ParsingException(e instanceof Error ? (e as Error).message : `${e}`,
        e instanceof Error ? e as Error : null);
    }
  }

  getId(url: string): string {
    checkUrl(URL_PATTERN, url);
    const cached: string | null = SoundcloudParsingHelper.cachedId(url);
    if (cached === null) {
      throw new ParsingException('Could not get id of url: ' + url
        + ' - it is not resolved yet, use fromUrlAsListAsync(url)');
    }
    return cached;
  }

  getUrlWithFilters(id: string, contentFilter: string[], sortFilter: string,
    baseUrl: string | null = null): string {
    const cached: string | null = SoundcloudParsingHelper.cachedUrl(USERS_API + id);
    if (cached === null) {
      throw new ParsingException('SoundCloud channel url for id ' + id
        + ' is not resolved yet - call SoundcloudChannelLinkHandlerFactory.resolveUrl(id) first');
    }
    return cached;
  }

  onAcceptUrl(url: string): boolean {
    return Parser.isMatch(URL_PATTERN, url.toLowerCase());
  }

  async fromUrlAsListAsync(url: string, baseUrl: string | null = null): Promise<ListLinkHandler> {
    const polishedUrl: string = followGoogleRedirectIfNeeded(url);
    const id: string = await SoundcloudChannelLinkHandlerFactory.resolveId(polishedUrl);
    await SoundcloudChannelLinkHandlerFactory.resolveUrl(id);
    return this.fromUrlAsList(polishedUrl, baseUrl);
  }

  async fromIdAsListAsync(id: string, baseUrl: string | null = null): Promise<ListLinkHandler> {
    await SoundcloudChannelLinkHandlerFactory.resolveUrl(id);
    return this.fromIdAsList(id, baseUrl);
  }
}
