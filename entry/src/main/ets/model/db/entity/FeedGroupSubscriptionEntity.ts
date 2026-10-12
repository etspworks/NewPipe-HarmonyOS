/*
 * Port of org.schabi.newpipe.database.feed.model.FeedGroupSubscriptionEntity
 * (Room entity `feed_group_subscription_join`).
 */

import { relationalStore } from '@kit.ArkData';
import { colNumber } from '../../../common/db/AppDatabase';

export class FeedGroupSubscriptionEntity {
  static readonly TABLE: string = 'feed_group_subscription_join';

  /** `group_id` — foreign key onto feed_group(uid); part of the primary key. */
  feedGroupId: number;
  /** `subscription_id` — foreign key onto subscriptions(uid); part of the primary key. */
  subscriptionId: number;

  constructor(feedGroupId: number, subscriptionId: number) {
    this.feedGroupId = feedGroupId;
    this.subscriptionId = subscriptionId;
  }

  static fromRow(rs: relationalStore.ResultSet): FeedGroupSubscriptionEntity {
    return new FeedGroupSubscriptionEntity(
      colNumber(rs, 'group_id'),
      colNumber(rs, 'subscription_id')
    );
  }

  toValuesBucket(): relationalStore.ValuesBucket {
    const values: relationalStore.ValuesBucket = {
      'group_id': this.feedGroupId,
      'subscription_id': this.subscriptionId
    };
    return values;
  }
}
