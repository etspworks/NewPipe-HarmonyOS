/*
 * Port of org.schabi.newpipe.extractor.playlist.PlaylistInfo (NewPipeExtractor v0.26.5).
 *
 * The playlist mapper. The uploader fields are collected into their own error bucket exactly as
 * in the source: a playlist with no uploader at all is normal, so those errors are only reported
 * when something else already failed or fewer than three of them failed.
 */

import { ExtractorHelper } from '../../common/extractor/core/ExtractorHelper';
import { ListInfo } from '../../common/extractor/core/ListInfo';
import { toError } from '../../common/extractor/core/Errors';
import { NewPipe } from '../../common/extractor/core/NewPipe';
import { StreamingService } from '../../common/extractor/core/StreamingService';
import { PlaylistExtractor } from '../../common/extractor/info/PlaylistExtractor';
import { ListLinkHandler } from '../../common/extractor/linkhandler/LinkHandler';
import { Description } from './Description';
import { Image } from './Image';
import { InfoItemsPage } from './ListExtractorInfoItemsPage';
import { Page } from './Page';
import { PlaylistType } from './PlaylistType';
import { StreamInfoItem } from './StreamInfoItem';

export class PlaylistInfo extends ListInfo<StreamInfoItem> {
  uploaderUrl: string = '';
  uploaderName: string = '';
  subChannelUrl: string = '';
  subChannelName: string = '';
  description: Description = Description.EMPTY_DESCRIPTION;
  banners: Image[] = [];
  subChannelAvatars: Image[] = [];
  thumbnails: Image[] = [];
  uploaderAvatars: Image[] = [];
  streamCount: number = 0;
  playlistType: PlaylistType = PlaylistType.NORMAL;

  constructor(serviceId: number, id: string, url: string, originalUrl: string, name: string,
    contentFilter: string[], sortFilter: string) {
    super(serviceId, id, url, originalUrl, name, contentFilter, sortFilter);
  }

  static async getInfoFromUrl(url: string): Promise<PlaylistInfo> {
    return PlaylistInfo.getInfoFromService(NewPipe.getServiceByUrl(url), url);
  }

  static async getInfoFromService(service: StreamingService, url: string): Promise<PlaylistInfo> {
    const extractor: PlaylistExtractor = service.getPlaylistExtractorFromUrl(url);
    await extractor.fetchPage();
    return PlaylistInfo.getInfo(extractor);
  }

  static async getMoreItems(service: StreamingService, url: string,
    page: Page): Promise<InfoItemsPage<StreamInfoItem>> {
    return service.getPlaylistExtractorFromUrl(url).getPage(page);
  }

  static async getInfo(extractor: PlaylistExtractor): Promise<PlaylistInfo> {
    const linkHandler: ListLinkHandler = extractor.getLinkHandler();
    const info: PlaylistInfo = new PlaylistInfo(extractor.getServiceId(), linkHandler.getId(),
      linkHandler.getUrl(), linkHandler.getOriginalUrl(), extractor.getName(),
      linkHandler.getContentFilters(), linkHandler.getSortFilter());

    // collect uploader errors separately: see the class comment
    const uploaderParsingErrors: Error[] = [];

    try {
      info.setOriginalUrl(extractor.getOriginalUrl());
    } catch (e) {
      info.addError(toError(e));
    }
    try {
      info.streamCount = extractor.getStreamCount();
    } catch (e) {
      info.addError(toError(e));
    }
    try {
      info.description = extractor.getDescription();
    } catch (e) {
      info.addError(toError(e));
    }
    try {
      info.thumbnails = extractor.getThumbnails();
    } catch (e) {
      info.addError(toError(e));
    }
    try {
      info.uploaderUrl = extractor.getUploaderUrl();
    } catch (e) {
      uploaderParsingErrors.push(toError(e));
    }
    try {
      info.uploaderName = extractor.getUploaderName();
    } catch (e) {
      uploaderParsingErrors.push(toError(e));
    }
    try {
      info.uploaderAvatars = extractor.getUploaderAvatars();
    } catch (e) {
      uploaderParsingErrors.push(toError(e));
    }
    try {
      info.subChannelUrl = extractor.getSubChannelUrl();
    } catch (e) {
      uploaderParsingErrors.push(toError(e));
    }
    try {
      info.subChannelName = extractor.getSubChannelName();
    } catch (e) {
      uploaderParsingErrors.push(toError(e));
    }
    try {
      info.subChannelAvatars = extractor.getSubChannelAvatars();
    } catch (e) {
      uploaderParsingErrors.push(toError(e));
    }
    try {
      info.banners = extractor.getBanners();
    } catch (e) {
      info.addError(toError(e));
    }
    try {
      info.playlistType = extractor.getPlaylistType();
    } catch (e) {
      info.addError(toError(e));
    }

    // Report the uploader errors only if something else also failed, or if fewer than three of
    // them failed — a playlist with no uploader information at all is a normal playlist.
    if (uploaderParsingErrors.length > 0
      && (info.getErrors().length > 0 || uploaderParsingErrors.length < 3)) {
      info.addAllErrors(uploaderParsingErrors);
    }

    const itemsPage: InfoItemsPage<StreamInfoItem> =
      await ExtractorHelper.getItemsPageOrLogError(info, extractor);
    info.setRelatedItems(itemsPage.getItems());
    info.setNextPage(itemsPage.getNextPage());

    return info;
  }

  getThumbnails(): Image[] {
    return this.thumbnails;
  }

  getBanners(): Image[] {
    return this.banners;
  }

  getUploaderUrl(): string {
    return this.uploaderUrl;
  }

  getUploaderName(): string {
    return this.uploaderName;
  }

  getUploaderAvatars(): Image[] {
    return this.uploaderAvatars;
  }

  getSubChannelUrl(): string {
    return this.subChannelUrl;
  }

  getSubChannelName(): string {
    return this.subChannelName;
  }

  getSubChannelAvatars(): Image[] {
    return this.subChannelAvatars;
  }

  getStreamCount(): number {
    return this.streamCount;
  }

  getDescription(): Description {
    return this.description;
  }

  getPlaylistType(): PlaylistType {
    return this.playlistType;
  }
}
