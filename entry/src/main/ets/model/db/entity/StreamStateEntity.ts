/*
 * Port of org.schabi.newpipe.database.stream.model.StreamStateEntity (Room entity `stream_state`).
 */

import { relationalStore } from '@kit.ArkData';
import { colNumber } from '../../../common/db/AppDatabase';

export class StreamStateEntity {
  static readonly TABLE: string = 'stream_state';

  /**
   * Playback state will not be saved if playback time is less than this threshold
   * (5000ms = 5s).
   */
  static readonly PLAYBACK_SAVE_THRESHOLD_START_MILLISECONDS: number = 5000;

  /**
   * A stream is considered finished if the playback time left exceeds this threshold
   * (60000ms = 60s).
   */
  static readonly PLAYBACK_FINISHED_END_MILLISECONDS: number = 60000;

  /** `stream_id`, the primary key and a foreign key onto streams(uid). */
  streamUid: number;
  /** `progress_time`, in milliseconds. */
  progressMillis: number;

  constructor(streamUid: number, progressMillis: number) {
    this.streamUid = streamUid;
    this.progressMillis = progressMillis;
  }

  static fromRow(rs: relationalStore.ResultSet): StreamStateEntity {
    return new StreamStateEntity(colNumber(rs, 'stream_id'), colNumber(rs, 'progress_time'));
  }

  toValuesBucket(): relationalStore.ValuesBucket {
    const values: relationalStore.ValuesBucket = {
      'stream_id': this.streamUid,
      'progress_time': this.progressMillis
    };
    return values;
  }

  /**
   * The state is valid, and thus saved, if the progress is more than
   * PLAYBACK_SAVE_THRESHOLD_START_MILLISECONDS or at least 1/4 of the stream length.
   *
   * @param durationInSeconds the duration of the stream this state belongs to, in seconds
   */
  isValid(durationInSeconds: number): boolean {
    return this.progressMillis > StreamStateEntity.PLAYBACK_SAVE_THRESHOLD_START_MILLISECONDS ||
      this.progressMillis > durationInSeconds * 1000 / 4;
  }

  /**
   * The stream counts as finished if the time left is less than
   * PLAYBACK_FINISHED_END_MILLISECONDS and the progress is at least 3/4 of the stream length.
   * The state is saved anyway so it can be shown under stream info items, but the player does not
   * resume a finished stream, and the feed can filter finished streams out.
   *
   * @param durationInSeconds the duration of the stream this state belongs to, in seconds
   */
  isFinished(durationInSeconds: number): boolean {
    return this.progressMillis >=
      durationInSeconds * 1000 - StreamStateEntity.PLAYBACK_FINISHED_END_MILLISECONDS &&
      this.progressMillis >= durationInSeconds * 1000 * 3 / 4;
  }
}
