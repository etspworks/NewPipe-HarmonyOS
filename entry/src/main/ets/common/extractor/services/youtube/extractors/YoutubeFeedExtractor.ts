/*
 * Port of org.schabi.newpipe.extractor.services.youtube.extractors
 * .{YoutubeFeedExtractor, YoutubeFeedInfoItemExtractor} (NewPipeExtractor v0.26.5).
 *
 * The lightweight channel RSS feed. Both classes share a module: the info-item extractor is only
 * ever constructed by the feed extractor, from an Element of the same document.
 */

import { Document, Element, Elements, Jsoup } from '../../../html/Jsoup';
import { Downloader, Response } from '../../../downloader/Downloader';
import { StreamingService } from '../../../core/StreamingService';
import { ListLinkHandler } from '../../../linkhandler/LinkHandler';
import { FeedExtractor } from '../../../info/FeedExtractor';
import { StreamInfoItemExtractor } from '../../../info/StreamInfoItemExtractor';
import { StreamInfoItemsCollector } from '../../../info/StreamInfoItemsCollector';
import { ContentNotAvailableException } from '../../../exceptions/Exceptions';
import { DateWrapper } from '../../../localization/DateWrapper';
import { InfoItemsPage } from '../../../../../model/extractor/ListExtractorInfoItemsPage';
import { Page } from '../../../../../model/extractor/Page';
import { StreamInfoItem } from '../../../../../model/extractor/StreamInfoItem';
import { Image } from '../../../../../model/extractor/Image';
import { resolutionLevelFromHeight } from '../../../../../model/enums/ImageResolutionLevel';
import { StreamType } from '../../../../../model/enums/StreamType';
import { getFeedUrlFrom } from '../YoutubeParsingHelper';

const WEBSITE_CHANNEL_BASE_URL: string = 'https://www.youtube.com/channel/';

export class YoutubeFeedInfoItemExtractor extends StreamInfoItemExtractor {
  private readonly entryElement: Element;

  constructor(entryElement: Element) {
    super();
    this.entryElement = entryElement;
  }

  getStreamType(): StreamType {
    // The feed endpoint cannot tell the stream type, so everything is a video stream
    return StreamType.VIDEO_STREAM;
  }

  isAd(): boolean {
    return false;
  }

  getDuration(): number {
    // Not available when fetching through the feed endpoint
    return -1;
  }

  getViewCount(): number {
    const statistics: Element | null =
      this.entryElement.getElementsByTag('media:statistics').first();
    if (statistics === null) {
      return -1;
    }
    return Number.parseInt(statistics.attr('views'), 10);
  }

  getUploaderName(): string {
    const name: Element | null = this.entryElement.select('author > name').first();
    return name === null ? '' : name.text();
  }

  getUploaderUrl(): string {
    const uri: Element | null = this.entryElement.select('author > uri').first();
    return uri === null ? '' : uri.text();
  }

  isUploaderVerified(): boolean {
    return false;
  }

  getTextualUploadDate(): string | null {
    const published: Element | null = this.entryElement.getElementsByTag('published').first();
    return published === null ? null : published.text();
  }

  getUploadDate(): DateWrapper | null {
    return DateWrapper.fromOffsetDateTime(this.getTextualUploadDate());
  }

  getName(): string {
    const title: Element | null = this.entryElement.getElementsByTag('title').first();
    return title === null ? '' : title.text();
  }

  getUrl(): string {
    const link: Element | null = this.entryElement.getElementsByTag('link').first();
    return link === null ? '' : link.attr('href');
  }

  getThumbnails(): Image[] {
    const thumbnailElement: Element | null =
      this.entryElement.getElementsByTag('media:thumbnail').first();
    if (thumbnailElement === null) {
      return [];
    }

    const feedThumbnailUrl: string = thumbnailElement.attr('url');
    // An empty URL means no thumbnail is available
    if (feedThumbnailUrl.length === 0) {
      return [];
    }

    // The hqdefault thumbnail has black bars at the top and bottom while the mqdefault does not,
    // so the mqdefault is returned; it always exists.
    const newFeedThumbnailUrl: string = feedThumbnailUrl.replace('hqdefault', 'mqdefault');

    let height: number;
    let width: number;
    if (newFeedThumbnailUrl === feedThumbnailUrl) {
      // The feed uses a different image resolution, so use the height and width it provides
      const parsedHeight: number = Number.parseInt(thumbnailElement.attr('height'), 10);
      height = Number.isNaN(parsedHeight) ? Image.HEIGHT_UNKNOWN : parsedHeight;
      const parsedWidth: number = Number.parseInt(thumbnailElement.attr('width'), 10);
      width = Number.isNaN(parsedWidth) ? Image.WIDTH_UNKNOWN : parsedWidth;
    } else {
      height = 320;
      width = 180;
    }

    return [new Image(newFeedThumbnailUrl, height, width, resolutionLevelFromHeight(height))];
  }
}

export class YoutubeFeedExtractor extends FeedExtractor {
  private document: Document | null = null;

  constructor(service: StreamingService, linkHandler: ListLinkHandler) {
    super(service, linkHandler);
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
    const channelIdOrUser: string = this.getLinkHandler().getId();
    const feedUrl: string = getFeedUrlFrom(channelIdOrUser);

    const response: Response = await downloader.get(feedUrl);
    if (response.responseCode() === 404) {
      throw new ContentNotAvailableException('Could not get feed: 404 - not found');
    }
    this.document = Jsoup.parse(response.responseBody());
  }

  private requireDocument(): Document {
    this.assertPageFetched();
    const document: Document | null = this.document;
    if (document === null) {
      throw new ContentNotAvailableException('Feed document was not fetched');
    }
    return document;
  }

  async getInitialPage(): Promise<InfoItemsPage<StreamInfoItem>> {
    const entries: Elements = this.requireDocument().select('feed > entry');
    const collector: StreamInfoItemsCollector =
      new StreamInfoItemsCollector(this.getServiceId());
    for (const entryElement of entries.toArray()) {
      collector.commit(new YoutubeFeedInfoItemExtractor(entryElement));
    }
    return InfoItemsPage.fromCollector(collector, null);
  }

  getId(): string {
    return this.getUrl().replace(WEBSITE_CHANNEL_BASE_URL, '');
  }

  getUrl(): string {
    const document: Document = this.requireDocument();
    const authorUriElement: Element | null = document.select('feed > author > uri').first();
    if (authorUriElement !== null) {
      const authorUriElementText: string = authorUriElement.text();
      if (authorUriElementText !== '') {
        return authorUriElementText;
      }
    }

    const linkElement: Element | null = document.select('feed > link[rel*=alternate]').first();
    if (linkElement !== null) {
      return linkElement.attr('href');
    }
    return '';
  }

  getName(): string {
    const nameElement: Element | null =
      this.requireDocument().select('feed > author > name').first();
    return nameElement === null ? '' : nameElement.text();
  }

  async getPage(page: Page): Promise<InfoItemsPage<StreamInfoItem>> {
    return InfoItemsPage.emptyPage<StreamInfoItem>();
  }
}
