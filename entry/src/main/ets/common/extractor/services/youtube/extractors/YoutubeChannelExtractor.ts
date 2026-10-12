/*
 * Port of org.schabi.newpipe.extractor.services.youtube.extractors.YoutubeChannelExtractor
 * (NewPipeExtractor v0.26.5).
 *
 * The Optional chains become explicit branches; the two lambda "tab builders" become the small
 * ChannelTabExtractorBuilder implementations at the bottom, since ArkTS has no method references.
 */

import { JsonArray, JsonObject } from '../../../json/NanoJson';
import { Downloader } from '../../../downloader/Downloader';
import { StreamingService } from '../../../core/StreamingService';
import { ChannelExtractor, UNKNOWN_SUBSCRIBER_COUNT } from '../../../info/ChannelExtractor';
import { ChannelTabExtractor, ChannelTabs } from '../../../info/ChannelTabExtractor';
import { ListLinkHandler } from '../../../linkhandler/LinkHandler';
import {
  ChannelTabExtractorBuilder,
  ReadyChannelTabListLinkHandler
} from '../../../linkhandler/ReadyChannelTabListLinkHandler';
import { ParsingException } from '../../../exceptions/Exceptions';
import { mixedNumberWordToLong } from '../../../core/Utils';
import { Image } from '../../../../../model/extractor/Image';
import {
  ChannelHeader,
  ChannelResponseData,
  HeaderType,
  getChannelAgeGateRenderer,
  getChannelHeader,
  getChannelId,
  getChannelName,
  getChannelResponse,
  isChannelVerified,
  resolveChannelId
} from '../YoutubeChannelHelper';
import { getFeedUrlFrom, getImagesFromThumbnailsArray, getTextFromObject } from '../YoutubeParsingHelper';
import {
  YoutubeChannelLinkHandlerFactory,
  YoutubeChannelTabLinkHandlerFactory
} from '../linkHandler/YoutubeChannelLinkHandlerFactory';
import { VideosTabExtractor } from './YoutubeChannelTabExtractor';
import { YoutubeChannelTabPlaylistExtractor } from './YoutubeChannelTabPlaylistExtractor';

// Keys used more than once in a channel response
const IMAGE: string = 'image';
const CONTENTS: string = 'contents';
const CONTENT_PREVIEW_IMAGE_VIEW_MODEL: string = 'contentPreviewImageViewModel';
const PAGE_HEADER_VIEW_MODEL: string = 'pageHeaderViewModel';
const TAB_RENDERER: string = 'tabRenderer';
const CONTENT: string = 'content';
const METADATA: string = 'metadata';
const AVATAR: string = 'avatar';
const THUMBNAILS: string = 'thumbnails';
const SOURCES: string = 'sources';
const BANNER: string = 'banner';

/** Builds the already-fetched Videos tab from the tabRenderer the channel page carries. */
class VideosTabBuilder implements ChannelTabExtractorBuilder {
  private readonly tabRenderer: JsonObject;
  private readonly channelHeader: ChannelHeader | null;
  private readonly channelName: string;
  private readonly channelId: string;
  private readonly channelUrl: string;

  constructor(tabRenderer: JsonObject, channelHeader: ChannelHeader | null, channelName: string,
    channelId: string, channelUrl: string) {
    this.tabRenderer = tabRenderer;
    this.channelHeader = channelHeader;
    this.channelName = channelName;
    this.channelId = channelId;
    this.channelUrl = channelUrl;
  }

  build(service: StreamingService, linkHandler: ListLinkHandler): ChannelTabExtractor {
    return new VideosTabExtractor(service, linkHandler, this.tabRenderer, this.channelHeader,
      this.channelName, this.channelId, this.channelUrl);
  }
}

/** Builds an age-restricted channel's tab out of its uploads system playlist. */
class SystemPlaylistTabBuilder implements ChannelTabExtractorBuilder {
  build(service: StreamingService, linkHandler: ListLinkHandler): ChannelTabExtractor {
    return new YoutubeChannelTabPlaylistExtractor(service, linkHandler);
  }
}

export class YoutubeChannelExtractor extends ChannelExtractor {
  private jsonResponse: JsonObject = new JsonObject();
  private channelHeader: ChannelHeader | null = null;
  private channelId: string = '';
  /** Non-null only when the channel is age-restricted. */
  private channelAgeGateRenderer: JsonObject | null = null;

  constructor(service: StreamingService, linkHandler: ListLinkHandler) {
    super(service, linkHandler);
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
    const channelPath: string = super.getId();
    const id: string = await resolveChannelId(channelPath);

    // Fetch the Videos tab
    const data: ChannelResponseData = await getChannelResponse(id, 'EgZ2aWRlb3PyBgQKAjoA',
      this.getExtractorLocalization(), this.getExtractorContentCountry());

    this.jsonResponse = data.jsonResponse;
    this.channelHeader = getChannelHeader(this.jsonResponse);
    this.channelId = data.channelId;
    this.channelAgeGateRenderer = getChannelAgeGateRenderer(this.jsonResponse);
  }

  getUrl(): string {
    try {
      return YoutubeChannelLinkHandlerFactory.getInstance().getUrl('channel/' + this.getId());
    } catch (e) {
      return super.getUrl();
    }
  }

  getId(): string {
    this.assertPageFetched();
    return getChannelId(this.channelHeader, this.jsonResponse, this.channelId);
  }

  getName(): string {
    this.assertPageFetched();
    return getChannelName(this.channelHeader, this.channelAgeGateRenderer, this.jsonResponse);
  }

  getAvatars(): Image[] {
    this.assertPageFetched();

    const ageGate: JsonObject | null = this.channelAgeGateRenderer;
    if (ageGate !== null) {
      return getImagesFromThumbnailsArray(ageGate.getObject(AVATAR).getArray(THUMBNAILS));
    }

    const header: ChannelHeader | null = this.channelHeader;
    if (header === null) {
      throw new ParsingException('Could not get avatars');
    }

    let sources: JsonArray;
    if (header.headerType === HeaderType.PAGE) {
      const imageObj: JsonObject = header.json.getObject(CONTENT)
        .getObject(PAGE_HEADER_VIEW_MODEL)
        .getObject(IMAGE);
      if (imageObj.has(CONTENT_PREVIEW_IMAGE_VIEW_MODEL)) {
        sources = imageObj.getObject(CONTENT_PREVIEW_IMAGE_VIEW_MODEL)
          .getObject(IMAGE)
          .getArray(SOURCES);
      } else if (imageObj.has('decoratedAvatarViewModel')) {
        sources = imageObj.getObject('decoratedAvatarViewModel')
          .getObject(AVATAR)
          .getObject('avatarViewModel')
          .getObject(IMAGE)
          .getArray(SOURCES);
      } else {
        // Fall back to an empty avatar array
        sources = new JsonArray();
      }
    } else if (header.headerType === HeaderType.INTERACTIVE_TABBED) {
      sources = header.json.getObject('boxArt').getArray(THUMBNAILS);
    } else {
      sources = header.json.getObject(AVATAR).getArray(THUMBNAILS);
    }

    return getImagesFromThumbnailsArray(sources);
  }

  getBanners(): Image[] {
    this.assertPageFetched();
    if (this.channelAgeGateRenderer !== null) {
      return [];
    }

    const header: ChannelHeader | null = this.channelHeader;
    if (header === null) {
      return [];
    }

    if (header.headerType === HeaderType.PAGE) {
      const pageHeaderViewModel: JsonObject = header.json.getObject(CONTENT)
        .getObject(PAGE_HEADER_VIEW_MODEL);
      if (pageHeaderViewModel.has(BANNER)) {
        return getImagesFromThumbnailsArray(pageHeaderViewModel.getObject(BANNER)
          .getObject('imageBannerViewModel')
          .getObject(IMAGE)
          .getArray(SOURCES));
      }
      // No banner available (the case on pageHeaderRenderers of system channels)
      return [];
    }

    return getImagesFromThumbnailsArray(header.json.getObject(BANNER).getArray(THUMBNAILS));
  }

  getFeedUrl(): string | null {
    // RSS feeds are reachable for age-restricted channels too, so no age-gate check is needed
    try {
      return getFeedUrlFrom(this.getId());
    } catch (e) {
      throw new ParsingException('Could not get feed URL', e instanceof Error ? e as Error : null);
    }
  }

  getSubscriberCount(): number {
    this.assertPageFetched();
    if (this.channelAgeGateRenderer !== null) {
      return UNKNOWN_SUBSCRIBER_COUNT;
    }

    const header: ChannelHeader | null = this.channelHeader;
    if (header !== null) {
      if (header.headerType === HeaderType.INTERACTIVE_TABBED) {
        // An interactiveTabbedHeaderRenderer carries no subscriber count
        return UNKNOWN_SUBSCRIBER_COUNT;
      }

      const headerJson: JsonObject = header.json;
      if (header.headerType === HeaderType.PAGE) {
        return YoutubeChannelExtractor.getSubscriberCountFromPageChannelHeader(headerJson);
      }

      let textObject: JsonObject | null = null;
      if (headerJson.has('subscriberCountText')) {
        textObject = headerJson.getObject('subscriberCountText');
      } else if (headerJson.has('subtitle')) {
        textObject = headerJson.getObject('subtitle');
      }

      if (textObject !== null) {
        try {
          return mixedNumberWordToLong(getTextFromObject(textObject) as string);
        } catch (e) {
          throw new ParsingException('Could not get subscriber count',
            e instanceof Error ? e as Error : null);
        }
      }
    }

    return UNKNOWN_SUBSCRIBER_COUNT;
  }

  private static getSubscriberCountFromPageChannelHeader(headerJson: JsonObject): number {
    const metadataObject: JsonObject = headerJson.getObject(CONTENT)
      .getObject(PAGE_HEADER_VIEW_MODEL)
      .getObject(METADATA);

    if (!metadataObject.has('contentMetadataViewModel')) {
      // System channels using this header carry no contentMetadataViewModel
      return UNKNOWN_SUBSCRIBER_COUNT;
    }

    const metadataRows: JsonArray = metadataObject.getObject('contentMetadataViewModel')
      .getArray('metadataRows');
    // The last metadata row generally holds two elements: the subscriber and the video counts
    const lastMetadataRowParts: JsonArray = metadataRows
      .getObject(Math.max(0, metadataRows.size() - 1))
      .getArray('metadataParts');

    if (lastMetadataRowParts.size() < 2) {
      // Auto-generated channels (artist ones) do not report a subscriber count, so their
      // metadata part is shorter
      return UNKNOWN_SUBSCRIBER_COUNT;
    }

    try {
      // The subscriber count sits at the same position in every language as of 07/07/2025
      return mixedNumberWordToLong(lastMetadataRowParts.getObject(0)
        .getObject('text')
        .getString(CONTENT, '') as string);
    } catch (e) {
      throw new ParsingException('Could not get subscriber count',
        e instanceof Error ? e as Error : null);
    }
  }

  getDescription(): string {
    this.assertPageFetched();
    if (this.channelAgeGateRenderer !== null) {
      return '';
    }

    try {
      const header: ChannelHeader | null = this.channelHeader;
      if (header !== null && header.headerType === HeaderType.INTERACTIVE_TABBED) {
        // In an interactiveTabbedHeaderRenderer the real description lives only in the header.
        // The one in the microformatDataRenderer of non-About tabs can be completely different,
        // and the extracted one is incomplete — the original is only on the About tab.
        const description: string | null = getTextFromObject(header.json.getObject('description'));
        return description === null ? '' : description;
      }
      const description: string | null = this.jsonResponse.getObject(METADATA)
        .getObject('channelMetadataRenderer')
        .getString('description');
      return description === null ? '' : description;
    } catch (e) {
      throw new ParsingException('Could not get channel description',
        e instanceof Error ? e as Error : null);
    }
  }

  getParentChannelName(): string {
    return '';
  }

  getParentChannelUrl(): string {
    return '';
  }

  getParentChannelAvatars(): Image[] {
    return [];
  }

  isVerified(): boolean {
    this.assertPageFetched();
    if (this.channelAgeGateRenderer !== null) {
      // The verified status is unknown behind an age gate
      return false;
    }
    const header: ChannelHeader | null = this.channelHeader;
    if (header === null) {
      throw new ParsingException(
        'Could not get channel verified status, no channel header has been extracted');
    }
    return isChannelVerified(header);
  }

  getTabs(): ListLinkHandler[] {
    this.assertPageFetched();
    if (this.channelAgeGateRenderer === null) {
      return this.getTabsForNonAgeRestrictedChannels();
    }
    return this.getTabsForAgeRestrictedChannels();
  }

  private getTabsForNonAgeRestrictedChannels(): ListLinkHandler[] {
    const responseTabs: JsonArray = this.jsonResponse.getObject(CONTENTS)
      .getObject('twoColumnBrowseResultsRenderer')
      .getArray('tabs');

    const tabs: ListLinkHandler[] = [];
    const name: string = this.getName();
    const url: string = this.getUrl();
    const id: string = this.getId();
    const channelId: string = this.channelId;

    const addNonVideosTab: (tabName: string) => void = (tabName: string): void => {
      try {
        // The id a channel LinkHandler carries is the channel PATH, prefix included -
        // 'channel/UC...', 'user/...', '@handle' - because getUrlWithFilters() is literally
        // 'https://www.youtube.com/' + id + the tab suffix. `channelId` here is the bare UC id
        // out of the browse response, so handing it over unprefixed built
        // 'https://www.youtube.com/UC.../shorts': not a channel URL, and not parseable back into
        // one by the very factory that produced it.
        tabs.push(YoutubeChannelTabLinkHandlerFactory.getInstance()
          .fromQuery('channel/' + channelId, [tabName], ''));
      } catch (ignored) {
        // Do not add the tab if the LinkHandler could not be created
      }
    };

    for (const tab of responseTabs.streamAsJsonObjects()) {
      if (!tab.has(TAB_RENDERER)) {
        continue;
      }
      const tabRenderer: JsonObject = tab.getObject(TAB_RENDERER);
      const tabUrl: string | null = tabRenderer.getObject('endpoint')
        .getObject('commandMetadata')
        .getObject('webCommandMetadata')
        .getString('url');
      if (tabUrl === null) {
        continue;
      }

      const urlParts: string[] = tabUrl.split('/');

      // Java's String.split DISCARDS trailing empty strings and JS keeps them. A tabUrl ending in
      // '/' put an empty string last, so urlSuffix read '' and the tab was silently dropped; and
      // the length === 0 guard below - which in Java catches tabUrl "/" - could never fire at all,
      // because JS splits that to ['', ''].
      while (urlParts.length > 0 && urlParts[urlParts.length - 1] === '') {
        urlParts.pop();
      }

      if (urlParts.length === 0) {
        continue;
      }
      const urlSuffix: string = urlParts[urlParts.length - 1];

      // A copy of channelHeader, so the ReadyChannelTabListLinkHandler does not keep a reference
      // to this extractor instance
      const header: ChannelHeader | null = this.channelHeader;
      const channelHeaderCopy: ChannelHeader | null =
        header === null ? null : new ChannelHeader(header.json, header.headerType);

      if (urlSuffix === 'videos') {
        // The Videos tab's contents are already fetched, so it goes first
        tabs.unshift(new ReadyChannelTabListLinkHandler(tabUrl, channelId, ChannelTabs.VIDEOS,
          new VideosTabBuilder(tabRenderer, channelHeaderCopy, name, id, url)));
      } else if (urlSuffix === 'shorts') {
        addNonVideosTab(ChannelTabs.SHORTS);
      } else if (urlSuffix === 'streams') {
        addNonVideosTab(ChannelTabs.LIVESTREAMS);
      } else if (urlSuffix === 'releases') {
        addNonVideosTab(ChannelTabs.ALBUMS);
      } else if (urlSuffix === 'playlists') {
        addNonVideosTab(ChannelTabs.PLAYLISTS);
      }
      // Any other tab is unsupported and ignored
    }

    return tabs;
  }

  private getTabsForAgeRestrictedChannels(): ListLinkHandler[] {
    // With no access to the channel tab list, assume the channel has videos, shorts and
    // livestreams — the data reachable without login through the uploads system playlists. The
    // playlists tab is still available on YouTube Music, which the extractor does not implement.
    const tabs: ListLinkHandler[] = [];
    const channelUrl: string = this.getUrl();
    const channelId: string = this.channelId;
    const builder: SystemPlaylistTabBuilder = new SystemPlaylistTabBuilder();

    const addTab: (tabName: string) => void = (tabName: string): void => {
      tabs.push(new ReadyChannelTabListLinkHandler(channelUrl + '/' + tabName, channelId,
        tabName, builder));
    };

    addTab(ChannelTabs.VIDEOS);
    addTab(ChannelTabs.SHORTS);
    addTab(ChannelTabs.LIVESTREAMS);
    return tabs;
  }

  getTags(): string[] {
    this.assertPageFetched();
    if (this.channelAgeGateRenderer !== null) {
      return [];
    }
    return this.jsonResponse.getObject('microformat')
      .getObject('microformatDataRenderer')
      .getArray('tags')
      .streamAsStrings();
  }
}
