/*
 * Port of org.schabi.newpipe.extractor.playlist.{PlaylistExtractor, PlaylistInfoItemExtractor,
 * PlaylistInfoItemsCollector} (NewPipeExtractor v0.26.5).
 */

import { InfoItemExtractor, InfoItemsCollector } from '../core/Collector';
import { toError } from '../core/Errors';
import { ListExtractor } from '../core/ListExtractor';
import { StreamingService } from '../core/StreamingService';
import { ListLinkHandler } from '../linkhandler/LinkHandler';
import { Description } from '../../../model/extractor/Description';
import { Image } from '../../../model/extractor/Image';
import { PlaylistInfoItem } from '../../../model/extractor/PlaylistInfoItem';
import { PlaylistType } from '../../../model/extractor/PlaylistType';
import { StreamInfoItem } from '../../../model/extractor/StreamInfoItem';

export abstract class PlaylistExtractor extends ListExtractor<StreamInfoItem> {
  constructor(service: StreamingService, linkHandler: ListLinkHandler) {
    super(service, linkHandler);
  }

  abstract getUploaderUrl(): string;

  abstract getUploaderName(): string;

  abstract getUploaderAvatars(): Image[];

  abstract isUploaderVerified(): boolean;

  abstract getStreamCount(): number;

  abstract getDescription(): Description;

  getThumbnails(): Image[] {
    return [];
  }

  getBanners(): Image[] {
    return [];
  }

  getSubChannelName(): string {
    return '';
  }

  getSubChannelUrl(): string {
    return '';
  }

  getSubChannelAvatars(): Image[] {
    return [];
  }

  getPlaylistType(): PlaylistType {
    return PlaylistType.NORMAL;
  }
}

export abstract class PlaylistInfoItemExtractor extends InfoItemExtractor {
  abstract getUploaderName(): string;

  abstract getUploaderUrl(): string;

  abstract isUploaderVerified(): boolean;

  abstract getStreamCount(): number;

  getDescription(): Description {
    return Description.EMPTY_DESCRIPTION;
  }

  getPlaylistType(): PlaylistType {
    return PlaylistType.NORMAL;
  }
}

export class PlaylistInfoItemsCollector
  extends InfoItemsCollector<PlaylistInfoItem, PlaylistInfoItemExtractor> {
  constructor(serviceId: number) {
    super(serviceId);
  }

  extract(extractor: PlaylistInfoItemExtractor): PlaylistInfoItem {
    const resultItem: PlaylistInfoItem =
      new PlaylistInfoItem(this.getServiceId(), extractor.getUrl(), extractor.getName());

    try {
      resultItem.uploaderName = extractor.getUploaderName();
    } catch (e) {
      this.addError(toError(e));
    }
    try {
      resultItem.uploaderUrl = extractor.getUploaderUrl();
    } catch (e) {
      this.addError(toError(e));
    }
    try {
      resultItem.uploaderVerified = extractor.isUploaderVerified();
    } catch (e) {
      this.addError(toError(e));
    }
    try {
      resultItem.thumbnails = extractor.getThumbnails();
    } catch (e) {
      this.addError(toError(e));
    }
    try {
      resultItem.streamCount = extractor.getStreamCount();
    } catch (e) {
      this.addError(toError(e));
    }
    try {
      resultItem.description = extractor.getDescription();
    } catch (e) {
      this.addError(toError(e));
    }
    try {
      resultItem.playlistType = extractor.getPlaylistType();
    } catch (e) {
      this.addError(toError(e));
    }

    return resultItem;
  }
}
