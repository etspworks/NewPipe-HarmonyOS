/*
 * Port of org.schabi.newpipe.database.history.model.StreamHistoryEntry — one row of
 * StreamHistoryDAO.getHistory(): a stream joined with its history entry.
 */

import { relationalStore } from '@kit.ArkData';
import { colNumber } from '../../../common/db/AppDatabase';
import { StreamEntity } from '../entity/StreamEntity';
import { dbUrlToImageList } from '../../../common/image/ImageLoader';
import { StreamHistoryEntity } from '../entity/StreamHistoryEntity';
import { StreamInfoItem } from '../../extractor/StreamInfoItem';

export class StreamHistoryEntry {
  /** The embedded `streams` row. */
  readonly streamEntity: StreamEntity;
  /** `stream_id`, from stream_history. */
  readonly streamId: number;
  /** `access_date`, epoch milliseconds UTC. */
  readonly accessDate: number;
  /** `repeat_count` */
  readonly repeatCount: number;

  constructor(streamEntity: StreamEntity, streamId: number, accessDate: number,
    repeatCount: number) {
    this.streamEntity = streamEntity;
    this.streamId = streamId;
    this.accessDate = accessDate;
    this.repeatCount = repeatCount;
  }

  static fromRow(rs: relationalStore.ResultSet): StreamHistoryEntry {
    return new StreamHistoryEntry(
      StreamEntity.fromRow(rs),
      colNumber(rs, 'stream_id'),
      colNumber(rs, 'access_date'),
      colNumber(rs, 'repeat_count')
    );
  }

  /** Port of toStreamHistoryEntity(). */
  toStreamHistoryEntity(): StreamHistoryEntity {
    return new StreamHistoryEntity(this.streamId, this.accessDate, this.repeatCount);
  }

  /** Port of hasEqualValues(): the repeat count is deliberately not compared. */
  hasEqualValues(other: StreamHistoryEntry): boolean {
    return this.streamEntity.uid === other.streamEntity.uid && this.streamId === other.streamId &&
      this.accessDate === other.accessDate;
  }

  /** Port of StreamHistoryEntry.toStreamInfoItem(). */
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
