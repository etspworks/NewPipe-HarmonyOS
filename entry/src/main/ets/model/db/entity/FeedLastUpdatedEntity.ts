/*
 * Port of org.schabi.newpipe.database.feed.model.FeedLastUpdatedEntity
 * (Room entity `feed_last_updated`) — when each subscription's feed was last fetched.
 */

import { relationalStore } from '@kit.ArkData';
import { colNumber, colNumberOrNull } from '../../../common/db/AppDatabase';

export class FeedLastUpdatedEntity {
  static readonly TABLE: string = 'feed_last_updated';

  /** `subscription_id` — the primary key and a foreign key onto subscriptions(uid). */
  subscriptionId: number;
  /** `last_updated`, epoch milliseconds UTC; null marks the subscription as never loaded. */
  lastUpdated: number | null;

  constructor(subscriptionId: number, lastUpdated: number | null) {
    this.subscriptionId = subscriptionId;
    this.lastUpdated = lastUpdated;
  }

  static fromRow(rs: relationalStore.ResultSet): FeedLastUpdatedEntity {
    return new FeedLastUpdatedEntity(
      colNumber(rs, 'subscription_id'),
      colNumberOrNull(rs, 'last_updated')
    );
  }

  toValuesBucket(): relationalStore.ValuesBucket {
    const values: relationalStore.ValuesBucket = {
      'subscription_id': this.subscriptionId,
      'last_updated': this.lastUpdated
    };
    return values;
  }
}
