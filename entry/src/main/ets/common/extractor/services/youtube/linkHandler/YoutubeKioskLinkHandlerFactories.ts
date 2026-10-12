/*
 * Port of the six YouTube kiosk link-handler factories (NewPipeExtractor v0.26.5):
 *   YoutubeLiveLinkHandlerFactory, YoutubeTrendingLinkHandlerFactory,
 *   YoutubeTrendingMusicLinkHandlerFactory, YoutubeTrendingGamingVideosLinkHandlerFactory,
 *   YoutubeTrendingPodcastsEpisodesLinkHandlerFactory,
 *   YoutubeTrendingMoviesAndShowsTrailersLinkHandlerFactory.
 *
 * All six are the same 25-line shape — a fixed url, a fixed id, one path test — so they share a
 * module rather than six files of imports. Every url, path and KIOSK_ID is the source's.
 */

import { ListLinkHandlerFactory } from '../../../linkhandler/LinkHandlerFactory';
import { isHTTP, stringToURL } from '../../../core/Utils';
import { isInvidiousURL, isYoutubeURL } from '../YoutubeParsingHelper';
import { url as ohosUrl } from '@kit.ArkTS';

/** Parse without throwing; every one of these factories treats a bad url as "not mine". */
function parseOrNull(url: string): ohosUrl.URL | null {
  try {
    return stringToURL(url);
  } catch (e) {
    return null;
  }
}

const LIVE_CHANNEL_PATH: string = '/channel/UC4R8DWoMoI7CAwX8_LjQHig/livetab';
const LIVE_CHANNEL_TAB_PARAMS: string = 'ss=CKEK';

export class YoutubeLiveLinkHandlerFactory extends ListLinkHandlerFactory {
  static readonly KIOSK_ID: string = 'live';
  private static instance: YoutubeLiveLinkHandlerFactory | null = null;

  static getInstance(): YoutubeLiveLinkHandlerFactory {
    let current: YoutubeLiveLinkHandlerFactory | null = YoutubeLiveLinkHandlerFactory.instance;
    if (current === null) {
      current = new YoutubeLiveLinkHandlerFactory();
      YoutubeLiveLinkHandlerFactory.instance = current;
    }
    return current;
  }

  getUrlWithFilters(id: string, contentFilters: string[], sortFilter: string,
    baseUrl: string | null): string {
    return 'https://www.youtube.com' + LIVE_CHANNEL_PATH + '?' + LIVE_CHANNEL_TAB_PARAMS;
  }

  getId(url: string): string {
    return YoutubeLiveLinkHandlerFactory.KIOSK_ID;
  }

  onAcceptUrl(url: string): boolean {
    const urlObj: ohosUrl.URL | null = parseOrNull(url);
    if (urlObj === null) {
      return false;
    }
    // `search` carries the leading "?"; java.net.URL.getQuery() does not
    const query: string = urlObj.search.startsWith('?') ? urlObj.search.substring(1)
      : urlObj.search;
    return isHTTP(urlObj) && (isYoutubeURL(urlObj) || isInvidiousURL(urlObj))
      && LIVE_CHANNEL_PATH === urlObj.pathname && LIVE_CHANNEL_TAB_PARAMS === query;
  }
}

export class YoutubeTrendingLinkHandlerFactory extends ListLinkHandlerFactory {
  /** Deprecated by YouTube on July 21, 2025, but still reachable; kept as in the source. */
  static readonly KIOSK_ID: string = 'Trending';
  private static instance: YoutubeTrendingLinkHandlerFactory | null = null;

  static getInstance(): YoutubeTrendingLinkHandlerFactory {
    let current: YoutubeTrendingLinkHandlerFactory | null =
      YoutubeTrendingLinkHandlerFactory.instance;
    if (current === null) {
      current = new YoutubeTrendingLinkHandlerFactory();
      YoutubeTrendingLinkHandlerFactory.instance = current;
    }
    return current;
  }

  getUrlWithFilters(id: string, contentFilters: string[], sortFilter: string,
    baseUrl: string | null): string {
    return 'https://www.youtube.com/feed/trending';
  }

  getId(url: string): string {
    return 'Trending';
  }

  onAcceptUrl(url: string): boolean {
    const urlObj: ohosUrl.URL | null = parseOrNull(url);
    if (urlObj === null) {
      return false;
    }
    return isHTTP(urlObj) && (isYoutubeURL(urlObj) || isInvidiousURL(urlObj))
      && urlObj.pathname === '/feed/trending';
  }
}

const TRENDING_MUSIC_PATH: string = '/charts/TrendingVideos';

export class YoutubeTrendingMusicLinkHandlerFactory extends ListLinkHandlerFactory {
  static readonly KIOSK_ID: string = 'trending_music';
  private static instance: YoutubeTrendingMusicLinkHandlerFactory | null = null;

  static getInstance(): YoutubeTrendingMusicLinkHandlerFactory {
    let current: YoutubeTrendingMusicLinkHandlerFactory | null =
      YoutubeTrendingMusicLinkHandlerFactory.instance;
    if (current === null) {
      current = new YoutubeTrendingMusicLinkHandlerFactory();
      YoutubeTrendingMusicLinkHandlerFactory.instance = current;
    }
    return current;
  }

  getUrlWithFilters(id: string, contentFilter: string[], sortFilter: string,
    baseUrl: string | null): string {
    return 'https://charts.youtube.com' + TRENDING_MUSIC_PATH + '/RightNow';
  }

  getId(url: string): string {
    return YoutubeTrendingMusicLinkHandlerFactory.KIOSK_ID;
  }

  onAcceptUrl(url: string): boolean {
    const urlObj: ohosUrl.URL | null = parseOrNull(url);
    if (urlObj === null) {
      return false;
    }
    // URLs without the /RightNow part are accepted too, as in the source
    return isHTTP(urlObj) && urlObj.host.toLowerCase() === 'charts.youtube.com'
      && urlObj.pathname.startsWith(TRENDING_MUSIC_PATH);
  }
}

export class YoutubeTrendingGamingVideosLinkHandlerFactory extends ListLinkHandlerFactory {
  static readonly KIOSK_ID: string = 'trending_gaming';
  private static instance: YoutubeTrendingGamingVideosLinkHandlerFactory | null = null;

  static getInstance(): YoutubeTrendingGamingVideosLinkHandlerFactory {
    let current: YoutubeTrendingGamingVideosLinkHandlerFactory | null =
      YoutubeTrendingGamingVideosLinkHandlerFactory.instance;
    if (current === null) {
      current = new YoutubeTrendingGamingVideosLinkHandlerFactory();
      YoutubeTrendingGamingVideosLinkHandlerFactory.instance = current;
    }
    return current;
  }

  getUrlWithFilters(id: string, contentFilters: string[], sortFilter: string,
    baseUrl: string | null): string {
    return 'https://www.youtube.com/gaming/trending';
  }

  getId(url: string): string {
    return YoutubeTrendingGamingVideosLinkHandlerFactory.KIOSK_ID;
  }

  onAcceptUrl(url: string): boolean {
    const urlObj: ohosUrl.URL | null = parseOrNull(url);
    if (urlObj === null) {
      return false;
    }
    return isHTTP(urlObj) && (isYoutubeURL(urlObj) || isInvidiousURL(urlObj))
      && urlObj.pathname === '/gaming/trending';
  }
}

const TRENDING_PODCASTS_PATH: string = '/podcasts/popularepisodes';

export class YoutubeTrendingPodcastsEpisodesLinkHandlerFactory extends ListLinkHandlerFactory {
  static readonly KIOSK_ID: string = 'trending_podcasts_episodes';
  private static instance: YoutubeTrendingPodcastsEpisodesLinkHandlerFactory | null = null;

  static getInstance(): YoutubeTrendingPodcastsEpisodesLinkHandlerFactory {
    let current: YoutubeTrendingPodcastsEpisodesLinkHandlerFactory | null =
      YoutubeTrendingPodcastsEpisodesLinkHandlerFactory.instance;
    if (current === null) {
      current = new YoutubeTrendingPodcastsEpisodesLinkHandlerFactory();
      YoutubeTrendingPodcastsEpisodesLinkHandlerFactory.instance = current;
    }
    return current;
  }

  getUrlWithFilters(id: string, contentFilters: string[], sortFilter: string,
    baseUrl: string | null): string {
    return 'https://www.youtube.com' + TRENDING_PODCASTS_PATH;
  }

  getId(url: string): string {
    return YoutubeTrendingPodcastsEpisodesLinkHandlerFactory.KIOSK_ID;
  }

  onAcceptUrl(url: string): boolean {
    const urlObj: ohosUrl.URL | null = parseOrNull(url);
    if (urlObj === null) {
      return false;
    }
    return isHTTP(urlObj) && (isYoutubeURL(urlObj) || isInvidiousURL(urlObj))
      && TRENDING_PODCASTS_PATH === urlObj.pathname;
  }
}

const TRENDING_TRAILERS_PATH: string = '/charts/TrendingTrailers';

export class YoutubeTrendingMoviesAndShowsTrailersLinkHandlerFactory
  extends ListLinkHandlerFactory {
  static readonly KIOSK_ID: string = 'trending_movies_and_shows';
  private static instance: YoutubeTrendingMoviesAndShowsTrailersLinkHandlerFactory | null = null;

  static getInstance(): YoutubeTrendingMoviesAndShowsTrailersLinkHandlerFactory {
    let current: YoutubeTrendingMoviesAndShowsTrailersLinkHandlerFactory | null =
      YoutubeTrendingMoviesAndShowsTrailersLinkHandlerFactory.instance;
    if (current === null) {
      current = new YoutubeTrendingMoviesAndShowsTrailersLinkHandlerFactory();
      YoutubeTrendingMoviesAndShowsTrailersLinkHandlerFactory.instance = current;
    }
    return current;
  }

  getUrlWithFilters(id: string, contentFilter: string[], sortFilter: string,
    baseUrl: string | null): string {
    return 'https://charts.youtube.com' + TRENDING_TRAILERS_PATH;
  }

  getId(url: string): string {
    return YoutubeTrendingMoviesAndShowsTrailersLinkHandlerFactory.KIOSK_ID;
  }

  onAcceptUrl(url: string): boolean {
    const urlObj: ohosUrl.URL | null = parseOrNull(url);
    if (urlObj === null) {
      return false;
    }
    return isHTTP(urlObj) && urlObj.host.toLowerCase() === 'charts.youtube.com'
      && TRENDING_TRAILERS_PATH === urlObj.pathname;
  }
}
