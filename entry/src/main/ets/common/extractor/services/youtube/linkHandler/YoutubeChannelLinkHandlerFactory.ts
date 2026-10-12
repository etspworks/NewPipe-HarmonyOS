/*
 * Port of org.schabi.newpipe.extractor.services.youtube.linkHandler
 * .{YoutubeChannelLinkHandlerFactory, YoutubeChannelTabLinkHandlerFactory}
 * (NewPipeExtractor v0.26.5).
 *
 * Both classes live in one module because the tab factory's getId() is literally the channel
 * factory's getId(); splitting them would only add an import.
 */

import { ListLinkHandlerFactory } from '../../../linkhandler/LinkHandlerFactory';
import { ParsingException, UnsupportedTabException } from '../../../exceptions/Exceptions';
import { isBlank, isHTTP, stringToURL } from '../../../core/Utils';
import { ChannelTabs } from '../../../info/ChannelTabExtractor';
import { isHooktubeURL, isInvidiousURL, isYoutubeURL } from '../YoutubeParsingHelper';
import { url as ohosUrl } from '@kit.ArkTS';

const EXCLUDED_SEGMENTS: RegExp = new RegExp(
  '^(playlist|watch|attribution_link|watch_popup|embed|feed|select_site|account|reporthistory'
  + '|redirect)$');

export class YoutubeChannelLinkHandlerFactory extends ListLinkHandlerFactory {
  private static instance: YoutubeChannelLinkHandlerFactory | null = null;

  static getInstance(): YoutubeChannelLinkHandlerFactory {
    let current: YoutubeChannelLinkHandlerFactory | null =
      YoutubeChannelLinkHandlerFactory.instance;
    if (current === null) {
      current = new YoutubeChannelLinkHandlerFactory();
      YoutubeChannelLinkHandlerFactory.instance = current;
    }
    return current;
  }

  /** `id` already carries its prefix, e.g. `channel/UC...`, `user/...` or `@handle`. */
  getUrlWithFilters(id: string, contentFilters: string[], sortFilter: string,
    baseUrl: string | null): string {
    return 'https://www.youtube.com/' + id;
  }

  /** A custom short channel url such as `youtube.com/yourcustomname`. */
  private isCustomShortChannelUrl(splitPath: string[]): boolean {
    return splitPath.length === 1 && splitPath[0].length > 0
      && !EXCLUDED_SEGMENTS.test(splitPath[0]);
  }

  /** A handle url such as `youtube.com/@yourhandle`. */
  private isHandle(splitPath: string[]): boolean {
    return splitPath.length > 0 && splitPath[0].startsWith('@');
  }

  getId(url: string): string {
    try {
      const urlObj: ohosUrl.URL = stringToURL(url);
      let path: string = urlObj.pathname;

      if (!isHTTP(urlObj) || !(isYoutubeURL(urlObj) || isInvidiousURL(urlObj)
        || isHooktubeURL(urlObj))) {
        throw new ParsingException('The URL given is not a YouTube URL');
      }

      // Remove the leading "/"
      path = path.substring(1);

      const splitPath: string[] = path.split('/');

      // Java's String.split DISCARDS trailing empty strings and JS keeps them. A custom short
      // channel url with a trailing slash - youtube.com/SomeCustomName/ - splits to
      // ['SomeCustomName', ''] here where Java gives one element, so isCustomShortChannelUrl's
      // length === 1 failed and the url fell through to the user/ channel/ c/ check and was
      // rejected as "not a channel, a user or a handle URL". channel/UC.../ and @handle/ survived
      // only because they read splitPath[1] and splitPath[0].
      while (splitPath.length > 0 && splitPath[splitPath.length - 1] === '') {
        splitPath.pop();
      }

      if (this.isHandle(splitPath) || this.isCustomShortChannelUrl(splitPath)) {
        return splitPath[0];
      }

      if (!path.startsWith('user/') && !path.startsWith('channel/') && !path.startsWith('c/')) {
        throw new ParsingException('The given URL is not a channel, a user or a handle URL');
      }

      const id: string = splitPath[1];
      if (isBlank(id)) {
        throw new ParsingException('The given ID is not a YouTube channel or user ID');
      }
      return splitPath[0] + '/' + id;
    } catch (e) {
      const message: string = e instanceof Error ? (e as Error).message : `${e}`;
      throw new ParsingException('Could not parse URL :' + message,
        e instanceof Error ? e as Error : null);
    }
  }

  onAcceptUrl(url: string): boolean {
    try {
      this.getId(url);
    } catch (e) {
      return false;
    }
    return true;
  }
}

/** The channel-tab url suffix for a ChannelTabs id; throws for a tab YouTube has no page for. */
export function getChannelTabUrlSuffix(tab: string): string {
  if (tab === ChannelTabs.VIDEOS) {
    return '/videos';
  }
  if (tab === ChannelTabs.SHORTS) {
    return '/shorts';
  }
  if (tab === ChannelTabs.LIVESTREAMS) {
    return '/streams';
  }
  if (tab === ChannelTabs.ALBUMS) {
    return '/releases';
  }
  if (tab === ChannelTabs.PLAYLISTS) {
    return '/playlists';
  }
  throw new UnsupportedTabException(tab);
}

export class YoutubeChannelTabLinkHandlerFactory extends ListLinkHandlerFactory {
  private static instance: YoutubeChannelTabLinkHandlerFactory | null = null;

  static getInstance(): YoutubeChannelTabLinkHandlerFactory {
    let current: YoutubeChannelTabLinkHandlerFactory | null =
      YoutubeChannelTabLinkHandlerFactory.instance;
    if (current === null) {
      current = new YoutubeChannelTabLinkHandlerFactory();
      YoutubeChannelTabLinkHandlerFactory.instance = current;
    }
    return current;
  }

  getUrlWithFilters(id: string, contentFilter: string[], sortFilter: string,
    baseUrl: string | null): string {
    return 'https://www.youtube.com/' + id + getChannelTabUrlSuffix(contentFilter[0]);
  }

  getId(url: string): string {
    return YoutubeChannelLinkHandlerFactory.getInstance().getId(url);
  }

  onAcceptUrl(url: string): boolean {
    try {
      this.getId(url);
    } catch (e) {
      return false;
    }
    return true;
  }

  getAvailableContentFilter(): string[] {
    return [ChannelTabs.VIDEOS, ChannelTabs.SHORTS, ChannelTabs.LIVESTREAMS, ChannelTabs.ALBUMS,
      ChannelTabs.PLAYLISTS];
  }
}
