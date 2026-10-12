/*
 * Port of org.schabi.newpipe.extractor.services.youtube.YoutubeMetaInfoHelper
 * (NewPipeExtractor v0.26.5).
 *
 * The "this topic is covered by ..." panels YouTube puts above a video or a search result.
 * MetaInfo.urls is a string[] in this port (phase2-logic-contract.md §9), so `new URL(x)` is
 * simply the validated string — the URL construction the source did purely to validate is kept as
 * a stringToURL() call whose failure raises the same ParsingException.
 */

import { JsonArray, JsonObject, JsonValue } from '../../json/NanoJson';
import { ParsingException } from '../../exceptions/Exceptions';
import { isNullOrEmpty, replaceHttpWithHttps, stringToURL } from '../../core/Utils';
import {
  Description,
  DESCRIPTION_HTML,
  DESCRIPTION_PLAIN_TEXT
} from '../../../../model/extractor/Description';
import { MetaInfo } from '../../../../model/extractor/MetaInfo';
import {
  extractCachedUrlIfNeeded,
  getTextFromObject,
  getTextFromObjectOrThrow,
  getUrlFromNavigationEndpoint,
  isGoogleURL
} from './YoutubeParsingHelper';

/** Validate a url the way the source's `new URL(...)` did, and return it unchanged. */
function requireValidUrl(url: string | null, error: string): string {
  if (url === null) {
    throw new ParsingException(error);
  }
  try {
    stringToURL(url);
  } catch (e) {
    throw new ParsingException(error, e instanceof Error ? e as Error : null);
  }
  return url;
}

export function getMetaInfo(contents: JsonArray): MetaInfo[] {
  const metaInfo: MetaInfo[] = [];
  for (const resultObject of contents.streamAsJsonObjects()) {
    if (!resultObject.has('itemSectionRenderer')) {
      continue;
    }
    for (const sectionContent of resultObject.getObject('itemSectionRenderer')
      .getArray('contents').streamAsJsonObjects()) {
      if (sectionContent.has('infoPanelContentRenderer')) {
        metaInfo.push(getInfoPanelContent(sectionContent.getObject('infoPanelContentRenderer')));
      }
      if (sectionContent.has('clarificationRenderer')) {
        metaInfo.push(getClarificationRenderer(sectionContent.getObject('clarificationRenderer')));
      }
      if (sectionContent.has('emergencyOneboxRenderer')) {
        collectEmergencyOneboxRenderer(sectionContent.getObject('emergencyOneboxRenderer'),
          metaInfo);
      }
    }
  }
  return metaInfo;
}

function getInfoPanelContent(infoPanelContentRenderer: JsonObject): MetaInfo {
  const metaInfo: MetaInfo = new MetaInfo();
  let sb: string = '';
  for (const paragraph of infoPanelContentRenderer.getArray('paragraphs').streamAsJsonObjects()) {
    if (sb.length !== 0) {
      sb += '<br>';
    }
    sb += getTextFromObject(paragraph);
  }
  metaInfo.setContent(new Description(sb, DESCRIPTION_HTML));

  if (infoPanelContentRenderer.has('sourceEndpoint')) {
    const metaInfoLinkUrl: string | null = getUrlFromNavigationEndpoint(
      infoPanelContentRenderer.getObject('sourceEndpoint'));
    metaInfo.addUrl(requireValidUrl(extractCachedUrlIfNeeded(metaInfoLinkUrl),
      'Could not get metadata info URL'));

    const metaInfoLinkText: string | null = infoPanelContentRenderer.has('inlineSource')
      ? getTextFromObject(infoPanelContentRenderer.getObject('inlineSource'))
      : getTextFromObject(infoPanelContentRenderer.getObject('disclaimer'));
    if (isNullOrEmpty(metaInfoLinkText)) {
      throw new ParsingException('Could not get metadata info link text.');
    }
    metaInfo.addUrlText(metaInfoLinkText as string);
  }

  return metaInfo;
}

function getClarificationRenderer(clarificationRenderer: JsonObject): MetaInfo {
  const metaInfo: MetaInfo = new MetaInfo();
  const title: string | null = getTextFromObject(clarificationRenderer.getObject('contentTitle'));
  const text: string | null = getTextFromObject(clarificationRenderer.getObject('text'));

  if (title === null || text === null) {
    throw new ParsingException('Could not extract clarification renderer content');
  }
  metaInfo.setTitle(title);
  metaInfo.setContent(new Description(text, DESCRIPTION_PLAIN_TEXT));

  if (clarificationRenderer.has('actionButton')) {
    const actionButton: JsonObject = clarificationRenderer.getObject('actionButton')
      .getObject('buttonRenderer');
    const url: string | null = getUrlFromNavigationEndpoint(actionButton.getObject('command'));
    metaInfo.addUrl(requireValidUrl(extractCachedUrlIfNeeded(url),
      'Could not get metadata info URL'));

    const metaInfoLinkText: string | null = getTextFromObject(actionButton.getObject('text'));
    if (isNullOrEmpty(metaInfoLinkText)) {
      throw new ParsingException('Could not get metadata info link text.');
    }
    metaInfo.addUrlText(metaInfoLinkText as string);
  }

  if (clarificationRenderer.has('secondaryEndpoint')
    && clarificationRenderer.has('secondarySource')) {
    const url: string | null =
      getUrlFromNavigationEndpoint(clarificationRenderer.getObject('secondaryEndpoint'));
    // Google URLs are ignored: they point at a Google search about "Covid-19"
    if (url !== null && !isGoogleURL(url)) {
      metaInfo.addUrl(requireValidUrl(url, 'Could not get metadata info secondary URL'));
      const description: string | null =
        getTextFromObject(clarificationRenderer.getObject('secondarySource'));
      metaInfo.addUrlText(description === null ? url : description);
    }
  }

  return metaInfo;
}

function collectEmergencyOneboxRenderer(emergencyOneboxRenderer: JsonObject,
  into: MetaInfo[]): void {
  const supportRenderers: JsonObject[] = [];
  for (const key of emergencyOneboxRenderer.keys()) {
    const value: JsonValue | null = emergencyOneboxRenderer.get(key);
    if (value instanceof JsonObject
      && (value as JsonObject).has('singleActionEmergencySupportRenderer')) {
      supportRenderers.push((value as JsonObject).getObject('singleActionEmergencySupportRenderer'));
    }
  }

  if (supportRenderers.length === 0) {
    throw new ParsingException('Could not extract any meta info from emergency renderer');
  }

  for (const r of supportRenderers) {
    const metaInfo: MetaInfo = new MetaInfo();
    // usually an encouragement like "We are with you"
    const title: string = getTextFromObjectOrThrow(r.getObject('title'), 'title');

    // usually a phone number; this value is expected to start with "\n"
    let action: string = '';
    if (r.has('actionText')) {
      action = '\n' + getTextFromObjectOrThrow(r.getObject('actionText'), 'action');
    } else if (r.has('contacts')) {
      const contacts: JsonArray = r.getArray('contacts');
      for (let i = 0; i < contacts.size(); i++) {
        action += '\n';
        action += getTextFromObjectOrThrow(contacts.getObject(i).getObject('actionText'),
          'contacts.actionText');
      }
    }

    // usually details about the phone number
    const details: string = getTextFromObjectOrThrow(r.getObject('detailsText'), 'details');
    // usually the name of an association
    const urlText: string = getTextFromObjectOrThrow(r.getObject('navigationText'), 'urlText');

    metaInfo.setTitle(title);
    metaInfo.setContent(new Description(details + action, DESCRIPTION_PLAIN_TEXT));
    metaInfo.addUrlText(urlText);

    // usually the webpage of the association
    const url: string | null = getUrlFromNavigationEndpoint(r.getObject('navigationEndpoint'));
    if (url === null) {
      throw new ParsingException('Could not extract emergency renderer url');
    }
    metaInfo.addUrl(requireValidUrl(replaceHttpWithHttps(url),
      'Could not parse emergency renderer url'));

    into.push(metaInfo);
  }
}
