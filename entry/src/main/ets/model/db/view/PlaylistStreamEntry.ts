/*
 * Port of org.schabi.newpipe.database.playlist.PlaylistStreamEntry — one row of
 * PlaylistStreamDAO.getOrderedStreamsOf(): a stream, its playback progress and its position in
 * the playlist.
 */

import { relationalStore } from '@kit.ArkData';
import { colNumber, colNumberOrNull } from '../../../common/db/AppDatabase';
import { LocalItem, LocalItemType } from '../../enums/LocalItemLocalItemType';
import { StreamEntity } from '../entity/StreamEntity';
import { dbUrlToImageList } from '../../../common/image/ImageLoader';
import { StreamInfoItem } from '../../extractor/StreamInfoItem';

export class PlaylistStreamEntry implements LocalItem {
  /** The embedded `streams` row. */
  readonly streamEntity: StreamEntity;
  /** `progress_time`, in milliseconds; 0 when the stream has never been played. */
  readonly progressMillis: number;
  /** `stream_id`, from the join table. */
  readonly streamId: number;
  /** `join_index` — the position of this stream in the playlist. */
  readonly joinIndex: number;

  constructor(streamEntity: StreamEntity, progressMillis: number, streamId: number,
    joinIndex: number) {
    this.streamEntity = streamEntity;
    this.progressMillis = progressMillis;
    this.streamId = streamId;
    this.joinIndex = joinIndex;
  }

  get localItemType(): LocalItemType {
    return LocalItemType.PLAYLIST_STREAM_ITEM;
  }

  static fromRow(rs: relationalStore.ResultSet): PlaylistStreamEntry {
    const progress: number | null = colNumberOrNull(rs, 'progress_time');
    return new PlaylistStreamEntry(
      StreamEntity.fromRow(rs),
      progress === null ? 0 : progress,
      colNumber(rs, 'stream_id'),
      colNumber(rs, 'join_index')
    );
  }

  /** Port of PlaylistStreamEntry.toStreamInfoItem(). */
  toStreamInfoItem(): StreamInfoItem {
    const item: StreamInfoItem = new StreamInfoItem(this.streamEntity.serviceId,
      this.streamEntity.url, this.streamEntity.title, this.streamEntity.streamType);
    item.duration = this.streamEntity.duration;
    item.uploaderName = this.streamEntity.uploader;
    item.uploaderUrl = this.streamEntity.uploaderUrl;
    item.thumbnails = dbUrlToImageList(this.streamEntity.thumbnailUrl);
    return item;
  }
}
