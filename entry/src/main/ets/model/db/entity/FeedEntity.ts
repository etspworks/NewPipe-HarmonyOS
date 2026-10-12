/*
 * Port of org.schabi.newpipe.database.feed.model.FeedEntity (Room entity `feed`) — the join that
 * links a stream to the subscription whose feed it came from.
 */

import { relationalStore } from '@kit.ArkData';
import { colNumber } from '../../../common/db/AppDatabase';

export class FeedEntity {
  static readonly TABLE: string = 'feed';

  /** `stream_id` — foreign key onto streams(uid); part of the primary key. */
  streamId: number;
  /** `subscription_id` — foreign key onto subscriptions(uid); part of the primary key. */
  subscriptionId: number;

  constructor(streamId: number, subscriptionId: number) {
    this.streamId = streamId;
    this.subscriptionId = subscriptionId;
  }

  static fromRow(rs: relationalStore.ResultSet): FeedEntity {
    return new FeedEntity(colNumber(rs, 'stream_id'), colNumber(rs, 'subscription_id'));
  }

  toValuesBucket(): relationalStore.ValuesBucket {
    const values: relationalStore.ValuesBucket = {
      'stream_id': this.streamId,
      'subscription_id': this.subscriptionId
    };
    return values;
  }
}
