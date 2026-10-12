/*
 * Port of org.schabi.newpipe.extractor.services.youtube.linkHandler
 * .YoutubeStreamLinkHandlerFactory (NewPipeExtractor v0.26.5).
 *
 * The Java switch over an uppercased host becomes an if/else chain: ArkTS forbids `switch` in a
 * build() and the source's fall-through cases are cleaner as membership tests here. The
 * `vnd.youtube:` scheme is parsed by hand — java.net.URI accepts an opaque scheme, ohos url.URL
 * does not.
 *
 * The singleton is lazy: the source's static INSTANCE would be constructed at import time, and
 * this module and YoutubePlaylistLinkHandlerFactory reference each other.
 */

import { LinkHandlerFactory } from '../../../linkhandler/LinkHandlerFactory';
import { FoundAdException, ParsingException } from '../../../exceptions/Exceptions';
import { getQueryValue, isHTTP, stringToURL } from '../../../core/Utils';
import {
  isHooktubeURL,
  isInvidiousURL,
  isY2ubeURL,
  isYoutubeServiceURL,
  isYoutubeURL
} from '../YoutubeParsingHelper';
import { YoutubePlaylistLinkHandlerFactory } from './YoutubePlaylistLinkHandlerFactory';
import { url as ohosUrl } from '@kit.ArkTS';

const YOUTUBE_VIDEO_ID_REGEX_PATTERN: RegExp = new RegExp('^([a-zA-Z0-9_-]{11})');
const SUBPATHS: string[] = ['embed/', 'live/', 'shorts/', 'watch/', 'v/', 'w/'];

/** The hosts the source's third case block covers: hooktube plus every Invidious instance. */
const HOOKTUBE_AND_INVIDIOUS_HOSTS: string[] = ['hooktube.com', 'invidio.us', 'dev.invidio.us',
  'www.invidio.us', 'redirect.invidious.io', 'invidious.snopyta.org', 'yewtu.be',
  'tube.connect.cafe', 'tubus.eduvid.org', 'invidious.kavin.rocks', 'invidious-us.kavin.rocks',
  'piped.kavin.rocks', 'invidious.site', 'vid.mint.lgbt', 'invidiou.site', 'invidious.fdn.fr',
  'invidious.048596.xyz', 'invidious.zee.li', 'vid.puffyan.us', 'ytprivate.com',
  'invidious.namazso.eu', 'invidious.silkky.cloud', 'invidious.exonip.de', 'inv.riverside.rocks',
  'invidious.blamefran.net', 'invidious.moomoo.me', 'ytb.trom.tf', 'yt.cyberhost.uk', 'y.com.cm'];

const YOUTUBE_HOSTS: string[] = ['youtube.com', 'www.youtube.com', 'm.youtube.com',
  'music.youtube.com'];

function extractId(id: string | null): string | null {
  if (id === null) {
    return null;
  }
  YOUTUBE_VIDEO_ID_REGEX_PATTERN.lastIndex = 0;
  const match: RegExpExecArray | null = YOUTUBE_VIDEO_ID_REGEX_PATTERN.exec(id);
  return match === null ? null : match[1];
}

function assertIsId(id: string | null): string {
  const extractedId: string | null = extractId(id);
  if (extractedId !== null) {
    return extractedId;
  }
  throw new ParsingException('The given string is not a YouTube video ID');
}

export class YoutubeStreamLinkHandlerFactory extends LinkHandlerFactory {
  private static instance: YoutubeStreamLinkHandlerFactory | null = null;

  static getInstance(): YoutubeStreamLinkHandlerFactory {
    let current: YoutubeStreamLinkHandlerFactory | null =
      YoutubeStreamLinkHandlerFactory.instance;
    if (current === null) {
      current = new YoutubeStreamLinkHandlerFactory();
      YoutubeStreamLinkHandlerFactory.instance = current;
    }
    return current;
  }

  getUrl(id: string, baseUrl: string | null = null): string {
    return 'https://www.youtube.com/watch?v=' + id;
  }

  getId(theUrlString: string): string {
    let urlString: string = theUrlString;

    // Port of the java.net.URI branch: an opaque `vnd.youtube:`/`vnd.youtube.launch:` scheme
    const schemeSeparator: number = urlString.indexOf(':');
    if (schemeSeparator > 0) {
      const scheme: string = urlString.substring(0, schemeSeparator);
      if (scheme === 'vnd.youtube' || scheme === 'vnd.youtube.launch') {
        const schemeSpecificPart: string = urlString.substring(schemeSeparator + 1);
        if (schemeSpecificPart.startsWith('//')) {
          const extractedId: string | null = extractId(schemeSpecificPart.substring(2));
          if (extractedId !== null) {
            return extractedId;
          }
          urlString = 'https:' + schemeSpecificPart;
        } else {
          return assertIsId(schemeSpecificPart);
        }
      }
    }

    let url: ohosUrl.URL;
    try {
      url = stringToURL(urlString);
    } catch (e) {
      throw new ParsingException('The given URL is not valid',
        e instanceof Error ? e as Error : null);
    }

    const host: string = url.host;
    let path: string = url.pathname;
    // remove the leading "/" of the URL path when there is one
    if (path.length > 0) {
      path = path.substring(1);
    }

    if (!isHTTP(url) || !(isYoutubeURL(url) || isYoutubeServiceURL(url) || isHooktubeURL(url)
      || isInvidiousURL(url) || isY2ubeURL(url))) {
      if (host.toLowerCase() === 'googleads.g.doubleclick.net') {
        throw new FoundAdException('Error: found ad: ' + urlString);
      }
      throw new ParsingException('The URL is not a YouTube URL');
    }

    if (YoutubePlaylistLinkHandlerFactory.getInstance().acceptUrl(urlString)) {
      throw new ParsingException('Error: no suitable URL: ' + urlString);
    }

    const lowerHost: string = host.toLowerCase();

    if (lowerHost === 'www.youtube-nocookie.com') {
      if (path.startsWith('embed/')) {
        return assertIsId(path.substring(6));
      }
      throw new ParsingException('Error: no suitable URL: ' + urlString);
    }

    if (YOUTUBE_HOSTS.includes(lowerHost)) {
      if (path === 'attribution_link') {
        const uQueryValue: string | null = getQueryValue(url, 'u');
        let decodedURL: ohosUrl.URL;
        try {
          decodedURL = stringToURL('https://www.youtube.com' + uQueryValue);
        } catch (e) {
          throw new ParsingException('Error: no suitable URL: ' + urlString);
        }
        return assertIsId(getQueryValue(decodedURL, 'v'));
      }

      const maybeId: string | null = YoutubeStreamLinkHandlerFactory.getIdFromSubpathsInPath(path);
      if (maybeId !== null) {
        return maybeId;
      }
      return assertIsId(getQueryValue(url, 'v'));
    }

    if (lowerHost === 'y2u.be' || lowerHost === 'youtu.be') {
      const viewQueryValue: string | null = getQueryValue(url, 'v');
      if (viewQueryValue !== null) {
        return assertIsId(viewQueryValue);
      }
      return assertIsId(path);
    }

    if (HOOKTUBE_AND_INVIDIOUS_HOSTS.includes(lowerHost)) {
      if (path === 'watch') {
        const viewQueryValue: string | null = getQueryValue(url, 'v');
        if (viewQueryValue !== null) {
          return assertIsId(viewQueryValue);
        }
      }
      const maybeId: string | null = YoutubeStreamLinkHandlerFactory.getIdFromSubpathsInPath(path);
      if (maybeId !== null) {
        return maybeId;
      }
      const viewQueryValue: string | null = getQueryValue(url, 'v');
      if (viewQueryValue !== null) {
        return assertIsId(viewQueryValue);
      }
      return assertIsId(path);
    }

    throw new ParsingException('Error: no suitable URL: ' + urlString);
  }

  onAcceptUrl(url: string): boolean {
    try {
      this.getId(url);
      return true;
    } catch (e) {
      if (e instanceof FoundAdException) {
        throw e;
      }
      if (e instanceof ParsingException) {
        return false;
      }
      throw e;
    }
  }

  private static getIdFromSubpathsInPath(path: string): string | null {
    for (const subpath of SUBPATHS) {
      if (path.startsWith(subpath)) {
        return assertIsId(path.substring(subpath.length));
      }
    }
    return null;
  }
}
