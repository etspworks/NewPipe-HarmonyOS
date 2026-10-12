/*
 * Port of org.schabi.newpipe.extractor.services.bandcamp.extractors.BandcampCommentsExtractor
 * (NewPipeExtractor v0.26.5).
 *
 * Bandcamp "comments" are the reviews the collectors endpoint serves.
 */

import { CommentsInfoItem } from '../../../../../model/extractor/CommentsInfoItem';
import { InfoItemsPage } from '../../../../../model/extractor/ListExtractorInfoItemsPage';
import { Page } from '../../../../../model/extractor/Page';
import { CommentsExtractor, CommentsInfoItemsCollector } from '../../../info/CommentsExtractor';
import { JsonUtils } from '../../../core/JsonUtils';
import { StreamingService } from '../../../core/StreamingService';
import { Downloader, Request } from '../../../downloader/Downloader';
import { ParsingException } from '../../../exceptions/Exceptions';
import { Document, Element, Jsoup } from '../../../html/Jsoup';
import { JsonArray, JsonObject, JsonWriter } from '../../../json/NanoJson';
import { ListLinkHandler } from '../../../linkhandler/LinkHandler';
import { BASE_API_URL, BandcampExtractorHelper } from './BandcampExtractorHelper';
import { BandcampCommentsInfoItemExtractor } from './BandcampCommentsInfoItemExtractor';

const REVIEWS_API_URL: string = BASE_API_URL + '/tralbumcollectors/2/reviews';

export class BandcampCommentsExtractor extends CommentsExtractor {
  private document: Document | null = null;

  constructor(service: StreamingService, linkHandler: ListLinkHandler) {
    super(service, linkHandler);
  }

  private requireDocument(): Document {
    if (this.document === null) {
      throw new ParsingException('Page is not fetched. Make sure you call fetchPage()');
    }
    return this.document;
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
    this.document =
      Jsoup.parse((await downloader.get(this.getLinkHandler().getUrl())).responseBody());
  }

  async getInitialPage(): Promise<InfoItemsPage<CommentsInfoItem>> {
    const collector: CommentsInfoItemsCollector =
      new CommentsInfoItemsCollector(this.getServiceId());

    const collectorsElement: Element | null =
      this.requireDocument().getElementById('collectors-data');
    if (collectorsElement === null) {
      throw new ParsingException('Could not find collectors-data in document');
    }
    const collectorsData: JsonObject =
      JsonUtils.toJsonObject(collectorsElement.attr('data-blob'));
    const reviews: JsonArray = collectorsData.getArray('reviews');

    for (const review of reviews.streamAsJsonObjects()) {
      collector.commit(new BandcampCommentsInfoItemExtractor(review, this.getUrl()));
    }

    if (!collectorsData.getBoolean('more_reviews_available')) {
      return InfoItemsPage.fromCollector(collector, null);
    }

    const trackId: string = this.getTrackId();
    const token: string = BandcampCommentsExtractor.getNextPageToken(reviews);
    return InfoItemsPage.fromCollector(collector, Page.ofIds([trackId, token]));
  }

  async getPage(page: Page): Promise<InfoItemsPage<CommentsInfoItem>> {
    const collector: CommentsInfoItemsCollector =
      new CommentsInfoItemsCollector(this.getServiceId());

    const pageIds: string[] | null = page.getIds();
    if (pageIds === null || pageIds.length < 2) {
      throw new ParsingException('Page doesn\'t contain the track id and the token');
    }
    const trackId: string = pageIds[0];
    const token: string = pageIds[1];
    const reviewsData: JsonObject = await this.fetchReviewsData(trackId, token);
    const reviews: JsonArray = reviewsData.getArray('results');

    for (const review of reviews.streamAsJsonObjects()) {
      collector.commit(new BandcampCommentsInfoItemExtractor(review, this.getUrl()));
    }

    if (!reviewsData.getBoolean('more_available')) {
      return InfoItemsPage.fromCollector(collector, null);
    }

    return InfoItemsPage.fromCollector(collector,
      Page.ofIds([trackId, BandcampCommentsExtractor.getNextPageToken(reviews)]));
  }

  private async fetchReviewsData(trackId: string, token: string): Promise<JsonObject> {
    try {
      const body: ArrayBuffer = Request.utf8Body(JsonWriter.string().object()
        .value('tralbum_type', 't')
        .value('tralbum_id', trackId)
        .value('token', token)
        .value('count', 7)
        .array('exclude_fan_ids').end()
        .end().done());
      return JsonUtils.toJsonObject((await this.getDownloader().postWithContentTypeJson(
        REVIEWS_API_URL, new Map<string, string[]>(), body)).responseBody());
    } catch (e) {
      throw new ParsingException('Could not fetch reviews',
        e instanceof Error ? e as Error : null);
    }
  }

  private static getNextPageToken(reviews: JsonArray): string {
    let token: string | null = null;
    for (const review of reviews.streamAsJsonObjects()) {
      // keep only the last element
      token = review.getString('token');
    }
    if (token === null) {
      throw new ParsingException('Could not get token');
    }
    return token;
  }

  private getTrackId(): string {
    const meta: Element | null =
      this.requireDocument().selectFirst('meta[name=bc-page-properties]');
    if (meta === null) {
      throw new ParsingException('Could not find bc-page-properties in document');
    }
    const pageProperties: JsonObject = JsonUtils.toJsonObject(meta.attr('content'));
    return `${pageProperties.getLong('item_id')}`;
  }

  isCommentsDisabled(): boolean {
    return BandcampExtractorHelper.isRadioUrl(this.getUrl());
  }
}
