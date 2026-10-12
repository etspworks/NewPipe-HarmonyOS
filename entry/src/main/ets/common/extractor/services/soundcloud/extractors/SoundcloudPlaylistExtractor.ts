/*
 * Port of org.schabi.newpipe.extractor.services.soundcloud.extractors.SoundcloudPlaylistExtractor
 * (NewPipeExtractor v0.26.5).
 *
 * getThumbnails() is synchronous in the ported core while getInitialPage() is a Promise, so the
 * source's "no artwork -> look at the first page's items" fallback goes through the shared
 * synchronous collectInitialItems() instead of re-entering getInitialPage(). No I/O is lost:
 * the source's getInitialPage() reads the already-fetched playlist object too.
 */

import { Description, DESCRIPTION_PLAIN_TEXT } from '../../../../../model/extractor/Description';
import { Image } from '../../../../../model/extractor/Image';
import { InfoItemsPage } from '../../../../../model/extractor/ListExtractorInfoItemsPage';
import { Page } from '../../../../../model/extractor/Page';
import { StreamInfoItem } from '../../../../../model/extractor/StreamInfoItem';
import { PlaylistExtractor } from '../../../info/PlaylistExtractor';
import { StreamInfoItemsCollector } from '../../../info/StreamInfoItemsCollector';
import { NewPipe } from '../../../core/NewPipe';
import { StreamingService } from '../../../core/StreamingService';
import { isNullOrEmpty } from '../../../core/Utils';
import { Downloader } from '../../../downloader/Downloader';
import { ExtractionException, ParsingException } from '../../../exceptions/Exceptions';
import { ListLinkHandler } from '../../../linkhandler/LinkHandler';
import { JsonArray, JsonObject, JsonParser } from '../../../json/NanoJson';
import { SOUNDCLOUD_API_V2_URL, SoundcloudParsingHelper } from '../SoundcloudParsingHelper';
import { SoundcloudStreamInfoItemExtractor } from './SoundcloudStreamInfoItemExtractor';

const STREAMS_PER_REQUESTED_PAGE: number = 15;

export class SoundcloudPlaylistExtractor extends PlaylistExtractor {
  private playlistId: string = '';
  private playlist: JsonObject | null = null;

  constructor(service: StreamingService, linkHandler: ListLinkHandler) {
    super(service, linkHandler);
  }

  private requirePlaylist(): JsonObject {
    if (this.playlist === null) {
      throw new ParsingException('Page is not fetched. Make sure you call fetchPage()');
    }
    return this.playlist;
  }

  async onFetchPage(downloader: Downloader): Promise<void> {
    this.playlistId = this.getLinkHandler().getId();
    const apiUrl: string = SOUNDCLOUD_API_V2_URL + 'playlists/' + this.playlistId
      + '?client_id=' + await SoundcloudParsingHelper.clientId() + '&representation=compact';

    const response: string = (await downloader.get(apiUrl, null,
      this.getExtractorLocalization())).responseBody();
    try {
      this.playlist = JsonParser.object().from(response);
    } catch (e) {
      throw new ParsingException('Could not parse json response',
        e instanceof Error ? e as Error : null);
    }
  }

  getId(): string {
    return this.playlistId;
  }

  getName(): string {
    const name: string | null = this.requirePlaylist().getString('title');
    return name === null ? '' : name;
  }

  getThumbnails(): Image[] {
    const artworkUrl: string | null = this.requirePlaylist().getString('artwork_url');

    if (!isNullOrEmpty(artworkUrl)) {
      return SoundcloudParsingHelper.getAllImagesFromArtworkOrAvatarUrl(artworkUrl);
    }

    // If the thumbnail is null or empty, traverse the items list and get a valid one.
    // If it also fails, return an empty list.
    try {
      for (const item of this.collectInitialItems().getItems()) {
        const thumbnails: Image[] = item.getThumbnails();
        if (thumbnails.length > 0) {
          return thumbnails;
        }
      }
    } catch (e) {
      // ignored, fall through to the empty list
    }

    return [];
  }

  getUploaderUrl(): string {
    return SoundcloudParsingHelper.getUploaderUrl(this.requirePlaylist());
  }

  getUploaderName(): string {
    return SoundcloudParsingHelper.getUploaderName(this.requirePlaylist());
  }

  getUploaderAvatars(): Image[] {
    return SoundcloudParsingHelper.getAllImagesFromArtworkOrAvatarUrl(
      SoundcloudParsingHelper.getAvatarUrl(this.requirePlaylist()));
  }

  isUploaderVerified(): boolean {
    return this.requirePlaylist().getObject('user').getBoolean('verified');
  }

  getStreamCount(): number {
    return this.requirePlaylist().getLong('track_count');
  }

  getDescription(): Description {
    const description: string | null = this.requirePlaylist().getString('description');
    if (isNullOrEmpty(description)) {
      return Description.EMPTY_DESCRIPTION;
    }
    return new Description(description, DESCRIPTION_PLAIN_TEXT);
  }

  /** The source's getInitialPage() body: no I/O, it reads the fetched playlist object. */
  private collectInitialItems(): InfoItemsPage<StreamInfoItem> {
    const streamInfoItemsCollector: StreamInfoItemsCollector =
      new StreamInfoItemsCollector(this.getServiceId());
    const ids: string[] = [];

    for (const track of this.requirePlaylist().getArray('tracks').streamAsJsonObjects()) {
      // i.e. if full info is available
      if (track.has('title')) {
        streamInfoItemsCollector.commit(new SoundcloudStreamInfoItemExtractor(track));
      } else {
        ids.push(`${track.getLong('id')}`);
      }
    }

    return InfoItemsPage.fromCollector(streamInfoItemsCollector, Page.ofIds(ids));
  }

  async getInitialPage(): Promise<InfoItemsPage<StreamInfoItem>> {
    return this.collectInitialItems();
  }

  async getPage(page: Page): Promise<InfoItemsPage<StreamInfoItem>> {
    const pageIds: string[] | null = page === null ? null : page.getIds();
    if (pageIds === null || pageIds.length === 0) {
      throw new Error('Page doesn\'t contain IDs');
    }

    let currentIds: string[];
    let nextIds: string[] | null;
    if (pageIds.length <= STREAMS_PER_REQUESTED_PAGE) {
      // Fetch every remaining stream, there are less than the max
      currentIds = pageIds;
      nextIds = null;
    } else {
      currentIds = pageIds.slice(0, STREAMS_PER_REQUESTED_PAGE);
      nextIds = pageIds.slice(STREAMS_PER_REQUESTED_PAGE, pageIds.length);
    }

    const currentPageUrl: string = SOUNDCLOUD_API_V2_URL + 'tracks?client_id='
      + await SoundcloudParsingHelper.clientId() + '&ids=' + currentIds.join(',');

    const collector: StreamInfoItemsCollector =
      new StreamInfoItemsCollector(this.getServiceId());
    const downloader: Downloader | null = NewPipe.getDownloader();
    if (downloader === null) {
      throw new ExtractionException('NewPipe was not initialised with a Downloader');
    }
    const response: string = (await downloader.get(currentPageUrl, null,
      this.getExtractorLocalization())).responseBody();

    try {
      const tracks: JsonArray = JsonParser.array().from(response);
      // Response may not contain tracks in the same order as currentIds.
      // The streams are displayed in the order which is used in currentIds on SoundCloud.
      const idToTrack: Map<string, JsonObject> = new Map<string, JsonObject>();
      for (const o of tracks.streamAsJsonObjects()) {
        idToTrack.set(`${o.getLong('id')}`, o);
      }
      for (const strId of currentIds) {
        const track: JsonObject | undefined = idToTrack.get(strId);
        if (track === undefined) {
          throw new ParsingException('Could not parse json response: no track with id ' + strId
            + ' in response');
        }
        collector.commit(new SoundcloudStreamInfoItemExtractor(track));
      }
    } catch (e) {
      if (e instanceof ParsingException) {
        throw e;
      }
      throw new ParsingException('Could not parse json response',
        e instanceof Error ? e as Error : null);
    }

    return InfoItemsPage.fromCollector(collector,
      nextIds === null ? null : Page.ofIds(nextIds));
  }
}
