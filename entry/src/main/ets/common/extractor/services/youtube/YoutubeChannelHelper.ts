/*
 * Port of org.schabi.newpipe.extractor.services.youtube.YoutubeChannelHelper
 * (NewPipeExtractor v0.26.5).
 *
 * Resolving a channel handle/custom name to a `UC...` id, fetching the browse response behind it,
 * and reading the four header shapes YouTube ships. The Optional/Stream chains become plain
 * loops; the two resolving methods do I/O, so they are Promises (§1).
 */

import { JsonArray, JsonObject, JsonWriter } from '../../json/NanoJson';
import { Request } from '../../downloader/Downloader';
import { Localization } from '../../downloader/Localization';
import { ContentCountry } from '../../localization/ContentCountry';
import {
  ContentNotAvailableException,
  ExtractionException,
  ParsingException
} from '../../exceptions/Exceptions';
import { isNullOrEmpty } from '../../core/Utils';
import {
  defaultAlertsCheck,
  getJsonPostResponse,
  getTextFromObject,
  hasArtistOrVerifiedIconBadgeAttachment,
  isVerified,
  prepareDesktopJsonBuilder
} from './YoutubeParsingHelper';

const BROWSE_ENDPOINT: string = 'browseEndpoint';
const BROWSE_ID: string = 'browseId';
const CAROUSEL_HEADER_RENDERER: string = 'carouselHeaderRenderer';
const C4_TABBED_HEADER_RENDERER: string = 'c4TabbedHeaderRenderer';
const CONTENT: string = 'content';
const CONTENTS: string = 'contents';
const HEADER: string = 'header';
const PAGE_HEADER_VIEW_MODEL: string = 'pageHeaderViewModel';
const TAB_RENDERER: string = 'tabRenderer';
const TITLE: string = 'title';
const TOPIC_CHANNEL_DETAILS_RENDERER: string = 'topicChannelDetailsRenderer';

/** Which of the four header shapes a channel response carries. */
export enum HeaderType {
  C4_TABBED,
  INTERACTIVE_TABBED,
  CAROUSEL,
  PAGE
}

export class ChannelHeader {
  readonly json: JsonObject;
  readonly headerType: HeaderType;

  constructor(json: JsonObject, headerType: HeaderType) {
    this.json = json;
    this.headerType = headerType;
  }
}

/** The browse response plus the channel id it actually resolved to. */
export class ChannelResponseData {
  readonly jsonResponse: JsonObject;
  readonly channelId: string;

  constructor(jsonResponse: JsonObject, channelId: string) {
    this.jsonResponse = jsonResponse;
    this.channelId = channelId;
  }
}

function checkIfChannelResponseIsValid(jsonResponse: JsonObject): void {
  const errorJsonObject: JsonObject = jsonResponse.getObject('error');
  if (errorJsonObject.size() === 0) {
    return;
  }
  const errorCode: number = errorJsonObject.getInt('code');
  if (errorCode === 404) {
    throw new ContentNotAvailableException('This channel doesn\'t exist.');
  }
  throw new ContentNotAvailableException('Got error:\"' + errorJsonObject.getString('status', '')
    + '\": ' + errorJsonObject.getString('message', ''));
}

/**
 * Resolve a channel id from a handle (`@name`), a custom name, a `user/...` or a `channel/...`
 * path, following at most three redirects exactly as the source does.
 */
export async function resolveChannelId(idOrPath: string): Promise<string> {
  const channelId: string[] = idOrPath.split('/');

  if (channelId[0].startsWith('UC')) {
    return channelId[0];
  }

  if (channelId[0] !== 'channel') {
    let urlToResolve: string | null = 'https://www.youtube.com/' + idOrPath;
    let endpoint: JsonObject = new JsonObject();
    let webPageType: string = '';

    for (let tries = 0; urlToResolve !== null && tries < 3; tries++) {
      const body: ArrayBuffer = Request.utf8Body(JsonWriter.stringValue(
        (await prepareDesktopJsonBuilder(Localization.DEFAULT, ContentCountry.DEFAULT))
          .value('url', urlToResolve)
          .done()));
      const jsonResponse: JsonObject = await getJsonPostResponse('navigation/resolve_url', body,
        Localization.DEFAULT);
      checkIfChannelResponseIsValid(jsonResponse);

      endpoint = jsonResponse.getObject('endpoint');
      webPageType = endpoint.getObject('commandMetadata')
        .getObject('webCommandMetadata')
        .getString('webPageType', '') as string;
      urlToResolve = webPageType === 'WEB_PAGE_TYPE_UNKNOWN'
        ? endpoint.getObject('urlEndpoint').getString('url')
        : null;
    }

    const browseId: string = endpoint.getObject(BROWSE_ENDPOINT).getString(BROWSE_ID, '') as string;
    const upperWebPageType: string = webPageType.toUpperCase();
    if ((upperWebPageType === 'WEB_PAGE_TYPE_BROWSE' || upperWebPageType === 'WEB_PAGE_TYPE_CHANNEL')
      && browseId.length > 0) {
      if (!browseId.startsWith('UC')) {
        throw new ExtractionException('Redirected id is not pointing to a channel');
      }
      return browseId;
    }

    if (channelId.length < 2) {
      throw new ExtractionException('Failed to resolve channelId for ' + idOrPath);
    }
  }

  return channelId[1];
}

/** The `browse` response for a channel id, following at most three channel redirects. */
export async function getChannelResponse(channelId: string, parameters: string,
  localization: Localization, country: ContentCountry): Promise<ChannelResponseData> {
  let id: string = channelId;
  let ajaxJson: JsonObject | null = null;
  let level: number = 0;

  while (level < 3) {
    const body: ArrayBuffer = Request.utf8Body(JsonWriter.stringValue(
      (await prepareDesktopJsonBuilder(localization, country))
        .value(BROWSE_ID, id)
        .value('params', parameters)
        .done()));
    const jsonResponse: JsonObject = await getJsonPostResponse('browse', body, localization);
    checkIfChannelResponseIsValid(jsonResponse);

    const endpoint: JsonObject = jsonResponse.getArray('onResponseReceivedActions')
      .getObject(0)
      .getObject('navigateAction')
      .getObject('endpoint');
    const webPageType: string = endpoint.getObject('commandMetadata')
      .getObject('webCommandMetadata')
      .getString('webPageType', '') as string;
    const browseId: string = endpoint.getObject(BROWSE_ENDPOINT).getString(BROWSE_ID, '') as string;

    const upperWebPageType: string = webPageType.toUpperCase();
    if ((upperWebPageType === 'WEB_PAGE_TYPE_BROWSE' || upperWebPageType === 'WEB_PAGE_TYPE_CHANNEL')
      && browseId.length > 0) {
      if (!browseId.startsWith('UC')) {
        throw new ExtractionException('Redirected id is not pointing to a channel');
      }
      id = browseId;
      level++;
    } else {
      ajaxJson = jsonResponse;
      break;
    }
  }

  if (ajaxJson === null) {
    throw new ExtractionException('Got no channel response after 3 redirects');
  }

  defaultAlertsCheck(ajaxJson);
  return new ChannelResponseData(ajaxJson, id);
}

/** The channel header, whichever of the four shapes the response uses, or null. */
export function getChannelHeader(channelResponse: JsonObject): ChannelHeader | null {
  const header: JsonObject = channelResponse.getObject(HEADER);

  if (header.has(C4_TABBED_HEADER_RENDERER)) {
    return new ChannelHeader(header.getObject(C4_TABBED_HEADER_RENDERER), HeaderType.C4_TABBED);
  }
  if (header.has(CAROUSEL_HEADER_RENDERER)) {
    for (const item of header.getObject(CAROUSEL_HEADER_RENDERER).getArray(CONTENTS)
      .streamAsJsonObjects()) {
      if (item.has(TOPIC_CHANNEL_DETAILS_RENDERER)) {
        return new ChannelHeader(item.getObject(TOPIC_CHANNEL_DETAILS_RENDERER),
          HeaderType.CAROUSEL);
      }
    }
    return null;
  }
  if (header.has('pageHeaderRenderer')) {
    return new ChannelHeader(header.getObject('pageHeaderRenderer'), HeaderType.PAGE);
  }
  if (header.has('interactiveTabbedHeaderRenderer')) {
    return new ChannelHeader(header.getObject('interactiveTabbedHeaderRenderer'),
      HeaderType.INTERACTIVE_TABBED);
  }
  return null;
}

export function isChannelVerified(channelHeader: ChannelHeader): boolean {
  if (channelHeader.headerType === HeaderType.CAROUSEL) {
    // A carousel header is only shown on topic channels, which are always verified
    return true;
  }
  if (channelHeader.headerType === HeaderType.PAGE) {
    const pageHeaderViewModel: JsonObject = channelHeader.json.getObject(CONTENT)
      .getObject(PAGE_HEADER_VIEW_MODEL);
    const hasCircleOrMusicIcon: boolean = hasArtistOrVerifiedIconBadgeAttachment(
      pageHeaderViewModel.getObject(TITLE)
        .getObject('dynamicTextViewModel')
        .getObject('text')
        .getArray('attachmentRuns'));
    if (!hasCircleOrMusicIcon
      && pageHeaderViewModel.getObject('image').has('contentPreviewImageViewModel')) {
      return true;
    }
    return hasCircleOrMusicIcon;
  }
  if (channelHeader.headerType === HeaderType.INTERACTIVE_TABBED) {
    return channelHeader.json.has('autoGenerated');
  }
  return isVerified(channelHeader.json.getArray('badges'));
}

export function getChannelId(channelHeader: ChannelHeader | null, jsonResponse: JsonObject,
  fallbackChannelId: string | null): string {
  if (channelHeader !== null) {
    if (channelHeader.headerType === HeaderType.C4_TABBED) {
      const channelId: string = channelHeader.json.getObject(HEADER)
        .getObject(C4_TABBED_HEADER_RENDERER)
        .getString('channelId', '') as string;
      if (channelId.length > 0) {
        return channelId;
      }
      const navigationC4TabChannelId: string | null = channelHeader.json
        .getObject('navigationEndpoint')
        .getObject(BROWSE_ENDPOINT)
        .getString(BROWSE_ID);
      if (!isNullOrEmpty(navigationC4TabChannelId)) {
        return navigationC4TabChannelId as string;
      }
    } else if (channelHeader.headerType === HeaderType.CAROUSEL) {
      let topicRenderer: JsonObject = new JsonObject();
      for (const item of channelHeader.json.getObject(HEADER)
        .getObject(CAROUSEL_HEADER_RENDERER)
        .getArray(CONTENTS)
        .streamAsJsonObjects()) {
        if (item.has(TOPIC_CHANNEL_DETAILS_RENDERER)) {
          topicRenderer = item;
          break;
        }
      }
      const navigationCarouselChannelId: string | null =
        topicRenderer.getObject(TOPIC_CHANNEL_DETAILS_RENDERER)
          .getObject('navigationEndpoint')
          .getObject(BROWSE_ENDPOINT)
          .getString(BROWSE_ID);
      if (!isNullOrEmpty(navigationCarouselChannelId)) {
        return navigationCarouselChannelId as string;
      }
    }
  }

  const externalChannelId: string | null = jsonResponse.getObject('metadata')
    .getObject('channelMetadataRenderer')
    .getString('externalChannelId');
  if (!isNullOrEmpty(externalChannelId)) {
    return externalChannelId as string;
  }

  if (!isNullOrEmpty(fallbackChannelId)) {
    return fallbackChannelId as string;
  }
  throw new ParsingException('Could not get channel ID');
}

export function getChannelName(channelHeader: ChannelHeader | null,
  channelAgeGateRenderer: JsonObject | null, jsonResponse: JsonObject): string {
  if (channelAgeGateRenderer !== null) {
    const title: string | null = channelAgeGateRenderer.getString('channelTitle');
    if (isNullOrEmpty(title)) {
      throw new ParsingException('Could not get channel name');
    }
    return title as string;
  }

  const metadataRendererTitle: string | null = jsonResponse.getObject('metadata')
    .getObject('channelMetadataRenderer')
    .getString(TITLE);
  if (!isNullOrEmpty(metadataRendererTitle)) {
    return metadataRendererTitle as string;
  }

  if (channelHeader !== null) {
    const channelJson: JsonObject = channelHeader.json;
    let name: string | null = null;
    if (channelHeader.headerType === HeaderType.PAGE) {
      name = channelJson.getObject(CONTENT)
        .getObject(PAGE_HEADER_VIEW_MODEL)
        .getObject(TITLE)
        .getObject('dynamicTextViewModel')
        .getObject('text')
        .getString(CONTENT, channelJson.getString('pageTitle'));
    } else if (channelHeader.headerType === HeaderType.CAROUSEL
      || channelHeader.headerType === HeaderType.INTERACTIVE_TABBED) {
      name = getTextFromObject(channelJson.getObject(TITLE));
    } else {
      name = channelJson.getString(TITLE);
    }
    if (name !== null) {
      return name;
    }
  }

  const microformatTitle: string | null = jsonResponse.getObject('microformat')
    .getObject('microformatDataRenderer')
    .getString(TITLE);
  if (microformatTitle !== null) {
    return microformatTitle;
  }
  throw new ParsingException('Could not get channel name');
}

/** The age-gate renderer of a channel response, when the channel is age-restricted. */
export function getChannelAgeGateRenderer(jsonResponse: JsonObject): JsonObject | null {
  const tabs: JsonArray = jsonResponse.getObject(CONTENTS)
    .getObject('twoColumnBrowseResultsRenderer')
    .getArray('tabs');
  for (const tab of tabs.streamAsJsonObjects()) {
    const contents: JsonArray = tab.getObject(TAB_RENDERER)
      .getObject(CONTENT)
      .getObject('sectionListRenderer')
      .getArray(CONTENTS);
    for (const content of contents.streamAsJsonObjects()) {
      if (content.has('channelAgeGateRenderer')) {
        return content.getObject('channelAgeGateRenderer');
      }
    }
  }
  return null;
}
