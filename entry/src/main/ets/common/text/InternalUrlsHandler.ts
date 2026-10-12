/*
 * Port of org.schabi.newpipe.util.text.InternalUrlsHandler, together with what TextLinkifier's
 * LongPressClickableSpans do on a tap and on a long press (UrlLongPressClickableSpan,
 * HashtagLongPressClickableSpan, TimestampLongPressClickableSpan.getTimestampTextToCopy).
 *
 * The description, the meta-info banners and anything else that renders Linkify spans share
 * these, so a link behaves the same wherever it is drawn.
 */

import { router } from '@kit.ArkUI';
import { NewPipe } from '../extractor/core/NewPipe';
import { LinkType, StreamingService } from '../extractor/core/StreamingService';
import { ServiceLocator } from '../di/ServiceLocator';
import { openStreamAtTimestamp } from '../player/TimestampHandler';
import { LinkKind, LinkSpan } from './Linkify';

/** InternalUrlsHandler.AMPERSAND_TIMESTAMP_PATTERN, matched against the WHOLE url. */
const AMPERSAND_TIMESTAMP_PATTERN: RegExp = /^(.*)&t=(\d+)$/;

/** ServiceList ids getTimestampTextToCopy() switches on. */
const YOUTUBE_SERVICE_ID: number = 0;
const SOUNDCLOUD_SERVICE_ID: number = 1;
const MEDIA_CCC_SERVICE_ID: number = 2;
const PEERTUBE_SERVICE_ID: number = 3;

/**
 * handleUrlDescriptionTimestamp(context, url): a `...&t=<seconds>` link to a stream NewPipe can
 * open starts that stream at that second (playOnPopup -> the TimestampChange handler); any other
 * link a service claims goes to RouterActivity. False means "not ours", and the caller opens it.
 */
export function handleUrlDescriptionTimestamp(url: string): boolean {
  const match: RegExpMatchArray | null = url.match(AMPERSAND_TIMESTAMP_PATTERN);
  if (match === null) {
    return false;
  }
  const matchedUrl: string = match[1];
  const seconds: number = Number.parseInt(match[2], 10);
  let service: StreamingService;
  let linkType: LinkType;
  try {
    service = NewPipe.getServiceByUrl(matchedUrl);
    linkType = service.getLinkTypeByUrl(matchedUrl);
  } catch (err) {
    return false;
  }
  if (linkType === LinkType.NONE) {
    return false;
  }
  if (linkType === LinkType.STREAM) {
    // playOnPopup(): the clean stream url, so it matches the stream that may already be playing.
    let cleanUrl: string;
    try {
      cleanUrl = service.getStreamLHFactory().fromUrl(matchedUrl).getUrl();
    } catch (err) {
      return false;
    }
    openStreamAtTimestamp(service.getServiceId(), cleanUrl, seconds);
    return true;
  }
  // NavigationHelper.openRouterActivity(context, matchedUrl).
  const params: Record<string, Object> = { 'uri': matchedUrl };
  router.pushUrl({ url: 'pages/RouterActivityPage', params: params });
  return true;
}

/** UrlLongPressClickableSpan.onClick(). */
export function openUrlLink(url: string): void {
  if (!handleUrlDescriptionTimestamp(url)) {
    ServiceLocator.get().share.openUrlInBrowser(url);
  }
}

/**
 * The text a LongPressClickableSpan's onLongClick() copies: the url (UrlLongPressClickableSpan),
 * the hashtag itself, or - getTimestampTextToCopy() - a link to that second of the stream, in the
 * form the stream's service understands, falling back to the timestamp text.
 */
export function linkTextToCopy(span: LinkSpan, serviceId: number, streamUrl: string): string {
  const seconds: number | null = span.seconds;
  if (span.kind === LinkKind.TIMESTAMP && seconds !== null && streamUrl.length > 0) {
    if (serviceId === YOUTUBE_SERVICE_ID) {
      return `${streamUrl}&t=${seconds}`;
    }
    if (serviceId === SOUNDCLOUD_SERVICE_ID || serviceId === MEDIA_CCC_SERVICE_ID) {
      return `${streamUrl}#t=${seconds}`;
    }
    if (serviceId === PEERTUBE_SERVICE_ID) {
      return `${streamUrl}?start=${seconds}`;
    }
    return span.text;
  }
  const url: string | null = span.url;
  return url !== null ? url : span.text;
}
