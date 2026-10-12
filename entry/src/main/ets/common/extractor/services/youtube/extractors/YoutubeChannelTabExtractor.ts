/*
 * Port of org.schabi.newpipe.extractor.services.youtube.extractors.YoutubeChannelTabExtractor
 * (NewPipeExtractor v0.26.5), including its nested VideosTabExtractor and the per-item
 * anonymous subclasses.
 *
 * ArkTS has no anonymous classes, so each of the source's `new Xxx(...) { ... }` overrides
 * becomes a named subclass below. Their bodies are the source's, including the one place where
 * the source's getUploaderUrl() falls back to `super.getUploaderName()` — kept verbatim rather
 * than "fixed", so behaviour matches upstream.
 *
 * `Optional<JsonObject>` becomes `JsonObject | null`, and the reduce that keeps the FIRST present
 * continuation becomes an explicit first-non-null loop.
 */

import { JsonArray, JsonObject, JsonWriter } from '../../../json/NanoJson';
import { Downloader, Request } from '../../../downloader/Downloader';
import { StreamingService } from '../../../core/StreamingService';
import { InfoItem } from '../../../core/InfoItem';
import { ChannelTabExtractor, ChannelTabs } from '../../../info/ChannelTabExtractor';
import { ListLinkHandler } from '../../../linkhandler/LinkHandler';
import { TimeAgoParser } from '../../../localization/TimeAgoParser';
import { ParsingException } from '../../../exceptions/Exceptions';
import { isNullOrEmpty } from '../../../core/Utils';
import { Image } from '../../../../../model/extractor/Image';
import { InfoItemsPage } from '../../../../../model/extractor/ListExtractorInfoItemsPage';
import { Page } from '../../../../../model/extractor/Page';
import { MultiInfoItemsCollector } from '../../../core/MultiInfoItemsCollector';
import {
  DISABLE_PRETTY_PRINT_PARAMETER,
  YOUTUBEI_V1_URL,
  getJsonPostResponse,
  prepareDesktopJsonBuilder
} from '../YoutubeParsingHelper';
import {
  ChannelHeader,
  ChannelResponseData,
  getChannelAgeGateRenderer,
  getChannelHeader,
  getChannelId,
  getChannelName,
  getChannelResponse,
  isChannelVerified,
  resolveChannelId
} from '../YoutubeChannelHelper';
import {
  YoutubeChannelTabLinkHandlerFactory,
  getChannelTabUrlSuffix
} from '../linkHandler/YoutubeChannelLinkHandlerFactory';
import { YoutubeStreamInfoItemExtractor } from './YoutubeStreamInfoItemExtractor';
import { YoutubeReelInfoItemExtractor } from './YoutubeReelInfoItemExtractor';
import { YoutubePlaylistInfoItemExtractor } from './YoutubePlaylistInfoItemExtractor';
import { YoutubeStreamInfoItemLockupExtractor } from './YoutubeStreamInfoItemLockupExtractor';
import {
  YoutubeBaseShowInfoItemExtractor,
  YoutubeMixOrPlaylistLockupInfoItemExtractor,
  YoutubeShortsLockupInfoItemExtractor
} from './YoutubeLockupInfoItemExtractors';

/**
 * Whether the channel the tab belongs to is verified. Its name round-trips through Page.getIds(),
 * so the name/parse helpers below stand in for Java's Enum.toString()/valueOf().
 */
export enum VerifiedStatus {
  VERIFIED,
  UNVERIFIED,
  UNKNOWN
}

function verifiedStatusName(status: VerifiedStatus): string {
  if (status === VerifiedStatus.VERIFIED) {
    return 'VERIFIED';
  }
  if (status === VerifiedStatus.UNVERIFIED) {
    return 'UNVERIFIED';
  }
  return 'UNKNOWN';
}

function verifiedStatusOf(name: string): VerifiedStatus {
  if (name === 'VERIFIED') {
    return VerifiedStatus.VERIFIED;
  }
  if (name === 'UNVERIFIED') {
    return VerifiedStatus.UNVERIFIED;
  }
  // Java throws IllegalArgumentException and the source maps that to UNKNOWN
  return VerifiedStatus.UNKNOWN;
}

/** The three-way verified override the source's anonymous classes all share. */
function overrideVerified(status: VerifiedStatus, fallback: () => boolean): boolean {
  if (status === VerifiedStatus.VERIFIED) {
    return true;
  }
  if (status === VerifiedStatus.UNVERIFIED) {
    return false;
  }
  return fallback();
}

class ChannelVideoInfoItemExtractor extends YoutubeStreamInfoItemExtractor {
  private readonly channelVerifiedStatus: VerifiedStatus;
  private readonly channelName: string | null;
  private readonly channelUrl: string | null;

  constructor(jsonObject: JsonObject, timeAgoParser: TimeAgoParser | null,
    channelVerifiedStatus: VerifiedStatus, channelName: string | null,
    channelUrl: string | null) {
    super(jsonObject, timeAgoParser);
    this.channelVerifiedStatus = channelVerifiedStatus;
    this.channelName = channelName;
    this.channelUrl = channelUrl;
  }

  getUploaderName(): string {
    return isNullOrEmpty(this.channelName) ? super.getUploaderName() : this.channelName as string;
  }

  getUploaderUrl(): string {
    // Verbatim from the source, which falls back to getUploaderName() here
    return isNullOrEmpty(this.channelUrl) ? super.getUploaderName() : this.channelUrl as string;
  }

  isUploaderVerified(): boolean {
    return overrideVerified(this.channelVerifiedStatus, (): boolean => super.isUploaderVerified());
  }
}

class ChannelReelInfoItemExtractor extends YoutubeReelInfoItemExtractor {
  private readonly channelVerifiedStatus: VerifiedStatus;
  private readonly channelName: string | null;
  private readonly channelUrl: string | null;

  constructor(reelItemRenderer: JsonObject, channelVerifiedStatus: VerifiedStatus,
    channelName: string | null, channelUrl: string | null) {
    super(reelItemRenderer);
    this.channelVerifiedStatus = channelVerifiedStatus;
    this.channelName = channelName;
    this.channelUrl = channelUrl;
  }

  getUploaderName(): string {
    return isNullOrEmpty(this.channelName) ? super.getUploaderName() : this.channelName as string;
  }

  getUploaderUrl(): string {
    return isNullOrEmpty(this.channelUrl) ? super.getUploaderName() : this.channelUrl as string;
  }

  isUploaderVerified(): boolean {
    return this.channelVerifiedStatus === VerifiedStatus.VERIFIED;
  }
}

class ChannelShortsLockupInfoItemExtractor extends YoutubeShortsLockupInfoItemExtractor {
  private readonly channelVerifiedStatus: VerifiedStatus;
  private readonly channelName: string | null;
  private readonly channelUrl: string | null;

  constructor(shortsLockupViewModel: JsonObject, channelVerifiedStatus: VerifiedStatus,
    channelName: string | null, channelUrl: string | null) {
    super(shortsLockupViewModel);
    this.channelVerifiedStatus = channelVerifiedStatus;
    this.channelName = channelName;
    this.channelUrl = channelUrl;
  }

  getUploaderName(): string {
    return isNullOrEmpty(this.channelName) ? super.getUploaderName() : this.channelName as string;
  }

  getUploaderUrl(): string {
    return isNullOrEmpty(this.channelUrl) ? super.getUploaderName() : this.channelUrl as string;
  }

  isUploaderVerified(): boolean {
    return this.channelVerifiedStatus === VerifiedStatus.VERIFIED;
  }
}

class ChannelVideoLockupExtractor extends YoutubeStreamInfoItemLockupExtractor {
  private readonly channelVerifiedStatus: VerifiedStatus;
  private readonly channelName: string | null;
  private readonly channelUrl: string | null;

  constructor(lockupViewModel: JsonObject, timeAgoParser: TimeAgoParser | null,
    channelVerifiedStatus: VerifiedStatus, channelName: string | null,
    channelUrl: string | null) {
    super(lockupViewModel, timeAgoParser);
    this.channelVerifiedStatus = channelVerifiedStatus;
    this.channelName = channelName;
    this.channelUrl = channelUrl;
  }

  protected isChannelOrCoursePlaylistLockupItem(): boolean {
    return true;
  }

  getUploaderAvatars(): Image[] {
    // Uploader avatars are not available in a channel's video items
    return [];
  }

  getUploaderName(): string {
    return isNullOrEmpty(this.channelName) ? super.getUploaderName() : this.channelName as string;
  }

  getUploaderUrl(): string {
    return isNullOrEmpty(this.channelUrl) ? super.getUploaderName() : this.channelUrl as string;
  }

  isUploaderVerified(): boolean {
    return this.channelVerifiedStatus === VerifiedStatus.VERIFIED;
  }
}

class ChannelPlaylistInfoItemExtractor extends YoutubePlaylistInfoItemExtractor {
  private readonly channelVerifiedStatus: VerifiedStatus;
  private readonly channelName: string | null;
  private readonly channelUrl: string | null;

  constructor(jsonObject: JsonObject, channelVerifiedStatus: VerifiedStatus,
    channelName: string | null, channelUrl: string | null) {
    super(jsonObject);
    this.channelVerifiedStatus = channelVerifiedStatus;
    this.channelName = channelName;
    this.channelUrl = channelUrl;
  }

  getUploaderName(): string {
    return isNullOrEmpty(this.channelName) ? super.getUploaderName() : this.channelName as string;
  }

  getUploaderUrl(): string {
    return isNullOrEmpty(this.channelUrl) ? super.getUploaderName() : this.channelUrl as string;
  }

  isUploaderVerified(): boolean {
    return overrideVerified(this.channelVerifiedStatus, (): boolean => super.isUploaderVerified());
  }
}

class ChannelPlaylistLockupInfoItemExtractor extends YoutubeMixOrPlaylistLockupInfoItemExtractor {
  private readonly channelVerifiedStatus: VerifiedStatus;
  private readonly channelName: string | null;
  private readonly channelUrl: string | null;

  constructor(playlistLockupViewModel: JsonObject, channelVerifiedStatus: VerifiedStatus,
    channelName: string | null, channelUrl: string | null) {
    super(playlistLockupViewModel);
    this.channelVerifiedStatus = channelVerifiedStatus;
    this.channelName = channelName;
    this.channelUrl = channelUrl;
  }

  getUploaderName(): string {
    return isNullOrEmpty(this.channelName) ? super.getUploaderName() : this.channelName as string;
  }

  getUploaderUrl(): string {
    return isNullOrEmpty(this.channelUrl) ? super.getUploaderName() : this.channelUrl as string;
  }

  isUploaderVerified(): boolean {
    return overrideVerified(this.channelVerifiedStatus, (): boolean => super.isUploaderVerified());
  }
}

class YoutubeGridShowRendererChannelInfoItemExtractor extends YoutubeBaseShowInfoItemExtractor {
  private readonly verifiedStatus: VerifiedStatus;
  private readonly channelName: string | null;
  private readonly channelUrl: string | null;

  constructor(gridShowRenderer: JsonObject, verifiedStatus: VerifiedStatus,
    channelName: string | null, channelUrl: string | null) {
    super(gridShowRenderer);
    this.verifiedStatus = verifiedStatus;
    this.channelName = channelName;
    this.channelUrl = channelUrl;
  }

  getUploaderName(): string {
    return this.channelName === null ? '' : this.channelName;
  }

  getUploaderUrl(): string {
    return this.channelUrl === null ? '' : this.channelUrl;
  }

  isUploaderVerified(): boolean {
    if (this.verifiedStatus === VerifiedStatus.VERIFIED) {
      return true;
    }
    if (this.verifiedStatus === VerifiedStatus.UNVERIFIED) {
      return false;
    }
    throw new ParsingException('Could not get uploader verification status');
  }
}

export class YoutubeChannelTabExtractor extends ChannelTabExtractor {
  protected channelHeader: ChannelHeader | null = null;
  private jsonResponse: JsonObject = new JsonObject();
  private channelId: string = '';

  constructor(service: StreamingService, linkHandler: ListLinkHandler) {
    super(service, linkHandler);
  }

  /** The opaque `params` protobuf that selects one channel tab; verbatim from the source. */
  private getChannelTabsParameters(): string {
    const name: string = this.getName();
    if (name === ChannelTabs.VIDEOS) {
      return 'EgZ2aWRlb3PyBgQKAjoA';
    }
    if (name === ChannelTabs.SHORTS) {
      return 'EgZzaG9ydHPyBgUKA5oBAA%3D%3D';
    }
    if (name === ChannelTabs.LIVESTREAMS) {
      return 'EgdzdHJlYW1z8gYECgJ6AA%3D%3D';
    }
    if (name === ChannelTabs.ALBUMS) {
      return 'EghyZWxlYXNlc_IGBQoDsgEA';
    }
    if (name === ChannelTabs.PLAYLISTS) {
      return 'EglwbGF5bGlzdHPyBgQKAkIA';
    }
    throw new ParsingException('Unsupported channel tab: ' + name);
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
    const channelIdFromId: string = await resolveChannelId(super.getId());
    const params: string = this.getChannelTabsParameters();
    const data: ChannelResponseData = await getChannelResponse(channelIdFromId, params,
      this.getExtractorLocalization(), this.getExtractorContentCountry());

    this.jsonResponse = data.jsonResponse;
    this.channelHeader = getChannelHeader(this.jsonResponse);
    this.channelId = data.channelId;
  }

  getUrl(): string {
    try {
      return YoutubeChannelTabLinkHandlerFactory.getInstance()
        .getUrlWithFilters('channel/' + this.getId(), [this.getName()], '', null);
    } catch (e) {
      return super.getUrl();
    }
  }

  getId(): string {
    return getChannelId(this.channelHeader, this.jsonResponse, this.channelId);
  }

  protected getChannelDisplayName(): string {
    return getChannelName(this.channelHeader, getChannelAgeGateRenderer(this.jsonResponse),
      this.jsonResponse);
  }

  async getInitialPage(): Promise<InfoItemsPage<InfoItem>> {
    const collector: MultiInfoItemsCollector =
      new MultiInfoItemsCollector(this.getServiceId());

    let items: JsonArray = new JsonArray();
    const tab: JsonObject | null = this.getTabData();
    if (tab !== null) {
      const tabContent: JsonObject = tab.getObject('content');
      items = tabContent.getObject('sectionListRenderer')
        .getArray('contents')
        .getObject(0)
        .getObject('itemSectionRenderer')
        .getArray('contents')
        .getObject(0)
        .getObject('gridRenderer')
        .getArray('items');

      if (items.size() === 0) {
        items = tabContent.getObject('richGridRenderer').getArray('contents');
        if (items.size() === 0) {
          items = tabContent.getObject('sectionListRenderer').getArray('contents');
        }
      }
    }

    let verifiedStatus: VerifiedStatus;
    const header: ChannelHeader | null = this.channelHeader;
    if (header === null) {
      verifiedStatus = VerifiedStatus.UNKNOWN;
    } else {
      verifiedStatus = isChannelVerified(header)
        ? VerifiedStatus.VERIFIED : VerifiedStatus.UNVERIFIED;
    }

    // Continuing a channel tab needs the channel ID and name, since channel streams do not carry
    // their channel; the values are handed to the next page through Page.getIds()
    const channelName: string = this.getChannelDisplayName();
    const channelUrl: string = this.getUrl();

    const continuation: JsonObject | null = this.collectItemsFromWithChannel(collector, items,
      verifiedStatus, channelName, channelUrl);
    const nextPage: Page | null = await this.getNextPageFrom(continuation,
      [channelName, channelUrl, verifiedStatusName(verifiedStatus)]);

    return InfoItemsPage.fromCollector(collector, nextPage);
  }

  async getPage(page: Page): Promise<InfoItemsPage<InfoItem>> {
    if (page === null || isNullOrEmpty(page.getUrl())) {
      throw new ParsingException('Page doesn\'t contain an URL');
    }

    const channelIds: string[] = page.getIds() === null ? [] : page.getIds() as string[];
    const collector: MultiInfoItemsCollector =
      new MultiInfoItemsCollector(this.getServiceId());

    const ajaxJson: JsonObject = await getJsonPostResponse('browse',
      page.getBody() as ArrayBuffer, this.getExtractorLocalization());

    let sectionListContinuation: JsonObject = new JsonObject();
    for (const jsonObject of ajaxJson.getArray('onResponseReceivedActions')
      .streamAsJsonObjects()) {
      if (jsonObject.has('appendContinuationItemsAction')) {
        sectionListContinuation = jsonObject.getObject('appendContinuationItemsAction');
        break;
      }
    }

    const continuation: JsonObject | null = this.collectItemsFromWithIds(collector,
      sectionListContinuation.getArray('continuationItems'), channelIds);

    return InfoItemsPage.fromCollector(collector,
      await this.getNextPageFrom(continuation, channelIds));
  }

  /** The tabRenderer of this tab, or null when the tab has no content. */
  protected getTabData(): JsonObject | null {
    const urlSuffix: string = getChannelTabUrlSuffix(this.getName());

    for (const tab of this.jsonResponse.getObject('contents')
      .getObject('twoColumnBrowseResultsRenderer')
      .getArray('tabs')
      .streamAsJsonObjects()) {
      if (!tab.has('tabRenderer')) {
        continue;
      }
      const tabRenderer: JsonObject = tab.getObject('tabRenderer');
      const url: string = tabRenderer.getObject('endpoint')
        .getObject('commandMetadata')
        .getObject('webCommandMetadata')
        .getString('url', '') as string;
      if (!url.endsWith(urlSuffix)) {
        continue;
      }

      // Check whether the tab has no content
      const tabContents: JsonArray = tabRenderer.getObject('content')
        .getObject('sectionListRenderer')
        .getArray('contents')
        .getObject(0)
        .getObject('itemSectionRenderer')
        .getArray('contents');
      if (tabContents.size() === 1 && tabContents.getObject(0).has('messageRenderer')) {
        return null;
      }
      return tabRenderer;
    }
    return null;
  }

  private collectItemsFromWithIds(collector: MultiInfoItemsCollector, items: JsonArray,
    channelIds: string[]): JsonObject | null {
    let channelName: string | null = null;
    let channelUrl: string | null = null;
    let verifiedStatus: VerifiedStatus = VerifiedStatus.UNKNOWN;

    if (channelIds.length >= 3) {
      channelName = channelIds[0];
      channelUrl = channelIds[1];
      verifiedStatus = verifiedStatusOf(channelIds[2]);
    }

    return this.collectItemsFromWithChannel(collector, items, verifiedStatus, channelName,
      channelUrl);
  }

  private collectItemsFromWithChannel(collector: MultiInfoItemsCollector, items: JsonArray,
    verifiedStatus: VerifiedStatus, channelName: string | null,
    channelUrl: string | null): JsonObject | null {
    // The source reduces with `c1.or(() -> c2)`, keeping the FIRST present continuation
    let continuation: JsonObject | null = null;
    for (const item of items.streamAsJsonObjects()) {
      const found: JsonObject | null =
        this.collectItem(collector, item, verifiedStatus, channelName, channelUrl);
      if (continuation === null) {
        continuation = found;
      }
    }
    return continuation;
  }

  private collectItem(collector: MultiInfoItemsCollector, item: JsonObject,
    channelVerifiedStatus: VerifiedStatus, channelName: string | null,
    channelUrl: string | null): JsonObject | null {
    const timeAgoParser: TimeAgoParser = this.getTimeAgoParser();

    if (item.has('richItemRenderer')) {
      const richItem: JsonObject = item.getObject('richItemRenderer').getObject('content');
      if (richItem.has('videoRenderer')) {
        collector.commit(new ChannelVideoInfoItemExtractor(richItem.getObject('videoRenderer'),
          timeAgoParser, channelVerifiedStatus, channelName, channelUrl));
      } else if (richItem.has('reelItemRenderer')) {
        collector.commit(new ChannelReelInfoItemExtractor(richItem.getObject('reelItemRenderer'),
          channelVerifiedStatus, channelName, channelUrl));
      } else if (richItem.has('shortsLockupViewModel')) {
        collector.commit(new ChannelShortsLockupInfoItemExtractor(
          richItem.getObject('shortsLockupViewModel'), channelVerifiedStatus, channelName,
          channelUrl));
      } else if (richItem.has('playlistRenderer')) {
        collector.commit(new ChannelPlaylistInfoItemExtractor(
          richItem.getObject('playlistRenderer'), channelVerifiedStatus, channelName,
          channelUrl));
      } else if (richItem.has('lockupViewModel')) {
        this.commitLockup(collector, channelVerifiedStatus, channelName, channelUrl,
          timeAgoParser, richItem);
      }
    } else if (item.has('gridVideoRenderer')) {
      collector.commit(new ChannelVideoInfoItemExtractor(item.getObject('gridVideoRenderer'),
        timeAgoParser, channelVerifiedStatus, channelName, channelUrl));
    } else if (item.has('gridPlaylistRenderer')) {
      collector.commit(new ChannelPlaylistInfoItemExtractor(
        item.getObject('gridPlaylistRenderer'), channelVerifiedStatus, channelName, channelUrl));
    } else if (item.has('gridShowRenderer')) {
      collector.commit(new YoutubeGridShowRendererChannelInfoItemExtractor(
        item.getObject('gridShowRenderer'), channelVerifiedStatus, channelName, channelUrl));
    } else if (item.has('shelfRenderer')) {
      return this.collectItem(collector, item.getObject('shelfRenderer').getObject('content'),
        channelVerifiedStatus, channelName, channelUrl);
    } else if (item.has('itemSectionRenderer')) {
      return this.collectItemsFromWithChannel(collector,
        item.getObject('itemSectionRenderer').getArray('contents'), channelVerifiedStatus,
        channelName, channelUrl);
    } else if (item.has('horizontalListRenderer')) {
      return this.collectItemsFromWithChannel(collector,
        item.getObject('horizontalListRenderer').getArray('items'), channelVerifiedStatus,
        channelName, channelUrl);
    } else if (item.has('expandedShelfContentsRenderer')) {
      return this.collectItemsFromWithChannel(collector,
        item.getObject('expandedShelfContentsRenderer').getArray('items'),
        channelVerifiedStatus, channelName, channelUrl);
    } else if (item.has('lockupViewModel')) {
      this.commitLockup(collector, channelVerifiedStatus, channelName, channelUrl, timeAgoParser,
        item);
    } else if (item.has('continuationItemRenderer')) {
      return item.getObject('continuationItemRenderer');
    }

    return null;
  }

  private commitLockup(collector: MultiInfoItemsCollector, channelVerifiedStatus: VerifiedStatus,
    channelName: string | null, channelUrl: string | null, timeAgoParser: TimeAgoParser,
    richItem: JsonObject): void {
    const lockupViewModel: JsonObject = richItem.getObject('lockupViewModel');
    const contentType: string | null = lockupViewModel.getString('contentType');

    if (contentType === 'LOCKUP_CONTENT_TYPE_PLAYLIST'
      || contentType === 'LOCKUP_CONTENT_TYPE_PODCAST') {
      collector.commit(new ChannelPlaylistLockupInfoItemExtractor(lockupViewModel,
        channelVerifiedStatus, channelName, channelUrl));
    } else if (contentType === 'LOCKUP_CONTENT_TYPE_VIDEO') {
      collector.commit(new ChannelVideoLockupExtractor(lockupViewModel, timeAgoParser,
        channelVerifiedStatus, channelName, channelUrl));
    }
  }

  private async getNextPageFrom(continuations: JsonObject | null,
    channelIds: string[]): Promise<Page | null> {
    if (continuations === null || continuations.size() === 0) {
      return null;
    }

    const continuation: string | null = continuations.getObject('continuationEndpoint')
      .getObject('continuationCommand')
      .getString('token');

    const body: ArrayBuffer = Request.utf8Body(JsonWriter.stringValue(
      (await prepareDesktopJsonBuilder(this.getExtractorLocalization(),
        this.getExtractorContentCountry()))
        .value('continuation', continuation)
        .done()));

    return new Page(YOUTUBEI_V1_URL + 'browse?' + DISABLE_PRETTY_PRINT_PARAMETER, null,
      channelIds, null, body);
  }
}

/**
 * Port of the nested VideosTabExtractor: the channel page has already fetched the Videos tab, so
 * this serves it from the tabRenderer it was handed instead of fetching again.
 */
export class VideosTabExtractor extends YoutubeChannelTabExtractor {
  private readonly tabRenderer: JsonObject;
  private readonly videosChannelId: string;
  private readonly videosChannelName: string;
  private readonly videosChannelUrl: string;

  constructor(service: StreamingService, linkHandler: ListLinkHandler, tabRenderer: JsonObject,
    channelHeader: ChannelHeader | null, channelName: string, channelId: string,
    channelUrl: string) {
    super(service, linkHandler);
    this.channelHeader = channelHeader;
    this.tabRenderer = tabRenderer;
    this.videosChannelId = channelId;
    this.videosChannelName = channelName;
    this.videosChannelUrl = channelUrl;
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
    // Nothing to do: the initial data was already fetched and is stored in the link handler
  }

  getId(): string {
    return this.videosChannelId;
  }

  getUrl(): string {
    return this.videosChannelUrl;
  }

  protected getChannelDisplayName(): string {
    return this.videosChannelName;
  }

  protected getTabData(): JsonObject | null {
    return this.tabRenderer;
  }
}
