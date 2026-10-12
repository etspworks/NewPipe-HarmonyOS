/*
 * Port of org.schabi.newpipe.database.history.model.StreamHistoryEntity
 * (Room entity `stream_history`).
 */

import { relationalStore } from '@kit.ArkData';
import { colNumber } from '../../../common/db/AppDatabase';

export class StreamHistoryEntity {
  static readonly TABLE: string = 'stream_history';

  /** `stream_id` — the stream this history item refers to; part of the primary key. */
  streamUid: number;
  /** `access_date` — the last time the stream was accessed, epoch milliseconds UTC. */
  accessDate: number;
  /** `repeat_count` — the total number of views this stream received. */
  repeatCount: number;

  constructor(streamUid: number, accessDate: number, repeatCount: number) {
    this.streamUid = streamUid;
    this.accessDate = accessDate;
    this.repeatCount = repeatCount;
  }

  static fromRow(rs: relationalStore.ResultSet): StreamHistoryEntity {
    return new StreamHistoryEntity(
      colNumber(rs, 'stream_id'),
      colNumber(rs, 'access_date'),
      colNumber(rs, 'repeat_count')
    );
  }

  toValuesBucket(): relationalStore.ValuesBucket {
    const values: relationalStore.ValuesBucket = {
      'stream_id': this.streamUid,
      'access_date': this.accessDate,
      'repeat_count': this.repeatCount
    };
    return values;
  }
}
