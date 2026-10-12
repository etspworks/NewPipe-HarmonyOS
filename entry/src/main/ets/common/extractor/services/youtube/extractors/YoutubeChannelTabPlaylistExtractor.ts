/*
 * Port of org.schabi.newpipe.extractor.services.youtube.extractors
 * .YoutubeChannelTabPlaylistExtractor (NewPipeExtractor v0.26.5).
 *
 * The fallback used for age-restricted channels, where the tab list is not reachable: YouTube's
 * uploads system playlists (UULF / UUSH / UULV + the channel id without its UC prefix) carry the
 * same items and need no login.
 */

import { Downloader } from '../../../downloader/Downloader';
import { StreamingService } from '../../../core/StreamingService';
import { InfoItem } from '../../../core/InfoItem';
import { ChannelTabExtractor, ChannelTabs } from '../../../info/ChannelTabExtractor';
import { PlaylistExtractor } from '../../../info/PlaylistExtractor';
import { ListLinkHandler } from '../../../linkhandler/LinkHandler';
import {
  ContentNotAvailableException,
  ParsingException
} from '../../../exceptions/Exceptions';
import { isNullOrEmpty } from '../../../core/Utils';
import { InfoItemsPage } from '../../../../../model/extractor/ListExtractorInfoItemsPage';
import { Page } from '../../../../../model/extractor/Page';
import { StreamInfoItem } from '../../../../../model/extractor/StreamInfoItem';
import { YoutubePlaylistLinkHandlerFactory } from '../linkHandler/YoutubePlaylistLinkHandlerFactory';
import { YoutubePlaylistExtractor } from './YoutubePlaylistExtractor';

/** Thrown when a valid playlist ID somehow could not be turned into a playlist URL. */
export class SystemPlaylistUrlCreationException extends Error {
  private readonly causeError: Error | null;

  constructor(message: string, cause: Error | null) {
    super(message);
    this.name = 'SystemPlaylistUrlCreationException';
    this.causeError = cause;
  }

  getCause(): Error | null {
    return this.causeError;
  }
}

/** The uploads system playlist that stands in for a channel tab. */
function getPlaylistLinkHandler(originalLinkHandler: ListLinkHandler): ListLinkHandler {
  const contentFilters: string[] = originalLinkHandler.getContentFilters();
  if (contentFilters.length === 0) {
    throw new ParsingException('A content filter is required');
  }

  const channelId: string = originalLinkHandler.getId();
  if (isNullOrEmpty(channelId) || !channelId.startsWith('UC')) {
    throw new ParsingException('Invalid channel ID');
  }
  const channelIdWithoutUc: string = channelId.substring(2);

  let playlistId: string;
  if (contentFilters[0] === ChannelTabs.VIDEOS) {
    playlistId = 'UULF' + channelIdWithoutUc;
  } else if (contentFilters[0] === ChannelTabs.SHORTS) {
    playlistId = 'UUSH' + channelIdWithoutUc;
  } else if (contentFilters[0] === ChannelTabs.LIVESTREAMS) {
    playlistId = 'UULV' + channelIdWithoutUc;
  } else {
    throw new ParsingException(
      'Only Videos, Shorts and Livestreams tabs can extracted as playlists');
  }

  try {
    const newUrl: string = YoutubePlaylistLinkHandlerFactory.getInstance().getUrl(playlistId);
    return new ListLinkHandler(newUrl, newUrl, playlistId, [], '');
  } catch (e) {
    // Unreachable: the playlist ID is valid and the factory throws nothing for it
    throw new SystemPlaylistUrlCreationException(
      'Could not create a YouTube playlist from a valid playlist ID',
      e instanceof Error ? e as Error : null);
  }
}

export class YoutubeChannelTabPlaylistExtractor extends ChannelTabExtractor {
  private readonly playlistExtractorInstance: PlaylistExtractor;
  private playlistExisting: boolean = false;

  constructor(service: StreamingService, linkHandler: ListLinkHandler) {
    super(service, linkHandler);
    this.playlistExtractorInstance =
      new YoutubePlaylistExtractor(service, getPlaylistLinkHandler(linkHandler));
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
    try {
      await this.playlistExtractorInstance.onFetchPage(downloader);
      this.playlistExisting = true;
    } catch (e) {
      if (e instanceof ContentNotAvailableException) {
        // A channel with no content of the requested type has no such system playlist, so a
        // ContentNotAvailableException is expected here and ignored
        return;
      }
      throw e;
    }
  }

  async getInitialPage(): Promise<InfoItemsPage<InfoItem>> {
    if (!this.playlistExisting) {
      return InfoItemsPage.emptyPage<InfoItem>();
    }
    const page: InfoItemsPage<StreamInfoItem> =
      await this.playlistExtractorInstance.getInitialPage();
    return new InfoItemsPage<InfoItem>(page.getItems(), page.getNextPage(), page.getErrors());
  }

  async getPage(page: Page): Promise<InfoItemsPage<InfoItem>> {
    if (!this.playlistExisting) {
      return InfoItemsPage.emptyPage<InfoItem>();
    }
    const result: InfoItemsPage<StreamInfoItem> =
      await this.playlistExtractorInstance.getPage(page);
    return new InfoItemsPage<InfoItem>(result.getItems(), result.getNextPage(),
      result.getErrors());
  }
}
