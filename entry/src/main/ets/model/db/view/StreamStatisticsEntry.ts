/*
 * Port of org.schabi.newpipe.database.stream.StreamStatisticsEntry — one row of
 * StreamHistoryDAO.getStatistics(): a stream with its latest access date, total watch count and
 * playback progress.
 */

import { relationalStore } from '@kit.ArkData';
import { colNumber, colNumberOrNull } from '../../../common/db/AppDatabase';
import { LocalItem, LocalItemType } from '../../enums/LocalItemLocalItemType';
import { StreamEntity } from '../entity/StreamEntity';
import { dbUrlToImageList } from '../../../common/image/ImageLoader';
import { StreamInfoItem } from '../../extractor/StreamInfoItem';

export class StreamStatisticsEntry implements LocalItem {
  /** The alias the statistics query gives MAX(access_date). */
  static readonly STREAM_LATEST_DATE: string = 'latestAccess';
  /** The alias the statistics query gives SUM(repeat_count). */
  static readonly STREAM_WATCH_COUNT: string = 'watchCount';

  /** The embedded `streams` row. */
  readonly streamEntity: StreamEntity;
  /** `progress_time`, in milliseconds; 0 when the stream has never been played. */
  readonly progressMillis: number;
  /** `stream_id`, from stream_history. */
  readonly streamId: number;
  /** `latestAccess`, epoch milliseconds UTC. */
  readonly latestAccessDate: number;
  /** `watchCount` */
  readonly watchCount: number;

  constructor(streamEntity: StreamEntity, progressMillis: number, streamId: number,
    latestAccessDate: number, watchCount: number) {
    this.streamEntity = streamEntity;
    this.progressMillis = progressMillis;
    this.streamId = streamId;
    this.latestAccessDate = latestAccessDate;
    this.watchCount = watchCount;
  }

  get localItemType(): LocalItemType {
    return LocalItemType.STATISTIC_STREAM_ITEM;
  }

  static fromRow(rs: relationalStore.ResultSet): StreamStatisticsEntry {
    const progress: number | null = colNumberOrNull(rs, 'progress_time');
    return new StreamStatisticsEntry(
      StreamEntity.fromRow(rs),
      progress === null ? 0 : progress,
      colNumber(rs, 'stream_id'),
      colNumber(rs, StreamStatisticsEntry.STREAM_LATEST_DATE),
      colNumber(rs, StreamStatisticsEntry.STREAM_WATCH_COUNT)
    );
  }

  /** Port of StreamStatisticsEntry.toStreamInfoItem(). */
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
