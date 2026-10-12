/*
 * Port of org.schabi.newpipe.database.stream.StreamWithState — one row of FeedDAO.getStreams():
 * a stream plus its playback progress, if any.
 */

import { relationalStore } from '@kit.ArkData';
import { colNumberOrNull } from '../../../common/db/AppDatabase';
import { StreamEntity } from '../entity/StreamEntity';

export class StreamWithState {
  /** The embedded `streams` row. */
  readonly stream: StreamEntity;
  /** `progress_time`, in milliseconds; null when the stream has never been played. */
  readonly stateProgressMillis: number | null;

  constructor(stream: StreamEntity, stateProgressMillis: number | null) {
    this.stream = stream;
    this.stateProgressMillis = stateProgressMillis;
  }

  static fromRow(rs: relationalStore.ResultSet): StreamWithState {
    return new StreamWithState(StreamEntity.fromRow(rs), colNumberOrNull(rs, 'progress_time'));
  }
}
