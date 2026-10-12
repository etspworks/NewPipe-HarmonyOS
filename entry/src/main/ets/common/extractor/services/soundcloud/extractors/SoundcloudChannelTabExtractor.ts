/*
 * Port of org.schabi.newpipe.extractor.services.soundcloud.extractors
 * .SoundcloudChannelTabExtractor (NewPipeExtractor v0.26.5).
 */

import { InfoItemsPage } from '../../../../../model/extractor/ListExtractorInfoItemsPage';
import { Page } from '../../../../../model/extractor/Page';
import { InfoItem } from '../../../core/InfoItem';
import { StreamingService } from '../../../core/StreamingService';
import { isNullOrEmpty } from '../../../core/Utils';
import { ChannelTabExtractor, ChannelTabs } from '../../../info/ChannelTabExtractor';
import { Downloader } from '../../../downloader/Downloader';
import { ParsingException } from '../../../exceptions/Exceptions';
import { ListLinkHandler } from '../../../linkhandler/LinkHandler';
import { MultiInfoItemsCollector } from '../../../core/MultiInfoItemsCollector';
import { SOUNDCLOUD_API_V2_URL, SoundcloudParsingHelper } from '../SoundcloudParsingHelper';

const USERS_ENDPOINT: string = SOUNDCLOUD_API_V2_URL + 'users/';

/** Empty page cap against infinite pagination loops. */
const MAX_EMPTY_PAGES: number = 3;

export class SoundcloudChannelTabExtractor extends ChannelTabExtractor {
  private readonly userId: string;

  constructor(service: StreamingService, linkHandler: ListLinkHandler) {
    super(service, linkHandler);
    this.userId = this.getLinkHandler().getId();
  }

  private getEndpoint(): string {
    const name: string = this.getName();
    if (name === ChannelTabs.TRACKS) {
      return '/tracks';
    }
    if (name === ChannelTabs.PLAYLISTS) {
      return '/playlists_without_albums';
    }
    if (name === ChannelTabs.ALBUMS) {
      return '/albums';
    }
    if (name === ChannelTabs.LIKES) {
      return '/likes';
    }
    throw new ParsingException('Unsupported tab: ' + name);
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
  }

  getId(): string {
    return this.userId;
  }

  async getInitialPage(): Promise<InfoItemsPage<InfoItem>> {
    return this.getPage(new Page(USERS_ENDPOINT + this.userId + this.getEndpoint()
      + '?client_id=' + await SoundcloudParsingHelper.clientId()
      + '&limit=20' + '&linked_partitioning=1'));
  }

  async getPage(page: Page): Promise<InfoItemsPage<InfoItem>> {
    if (page === null || isNullOrEmpty(page.getUrl())) {
      throw new Error('Page doesn\'t contain an URL');
    }

    const collector: MultiInfoItemsCollector =
      new MultiInfoItemsCollector(this.getServiceId());
    const visitedPages: Set<string> = new Set<string>();

    let currentPageUrl: string = page.getUrl() as string;
    let nextPageUrl: string = '';
    let emptyPageCount: number = 0;

    while (currentPageUrl.length > 0) {
      if (visitedPages.has(currentPageUrl)) {
        // Prevent infinite loops when the API points back to an already visited page.
        nextPageUrl = '';
        break;
      }
      visitedPages.add(currentPageUrl);

      const itemsBefore: number = collector.getItems().length;
      const candidateNextPage: string =
        await SoundcloudParsingHelper.getInfoItemsFromApi(collector, currentPageUrl);
      const hasNewItems: boolean = collector.getItems().length > itemsBefore;

      if (hasNewItems) {
        nextPageUrl = candidateNextPage;
        break;
      }

      emptyPageCount++;
      if (emptyPageCount >= MAX_EMPTY_PAGES || isNullOrEmpty(candidateNextPage)) {
        // Give up after too many empty responses or when SoundCloud stops providing tokens.
        nextPageUrl = '';
        break;
      }

      currentPageUrl = candidateNextPage;
    }

    const nextPage: Page | null = isNullOrEmpty(nextPageUrl) ? null : new Page(nextPageUrl);
    return InfoItemsPage.fromCollector(collector, nextPage);
  }
}
