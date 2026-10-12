/*
 * Port of app/src/main/java/org/schabi/newpipe/local/feed/service/FeedUpdateInfo.kt - one
 * subscription's fetched feed, carried between the feed loader and the new-stream notifications.
 *
 * As in the source, this deliberately stores as little as possible: no whole ChannelInfo, only
 * the fields below, because instances stay in memory while the whole feed is fetched.
 */

import { StreamInfoItem } from '../extractor/StreamInfoItem';
import { SubscriptionEntity } from '../db/entity/SubscriptionEntity';
import { NotificationMode } from '../enums/NotificationMode';
import { ChannelInfo } from '../extractor/ChannelInfo';
import { imageListToDbUrl } from '../../common/image/ImageLoader';

/** Port of Java's String.hashCode(), which `pseudoId` is defined in terms of. */
export function javaStringHashCode(value: string): number {
  let hash: number = 0;
  for (let i: number = 0; i < value.length; i++) {
    hash = (Math.imul(31, hash) + value.charCodeAt(i)) | 0;
  }
  return hash;
}

/**
 * The half of the extractor's `Info` base class this file reads. Declared locally rather than
 * imported so the feed loader can hand in any Info subclass (ChannelInfo from the full fetch,
 * a feed Info from the fast feed) without this module depending on the base class's location.
 */
export interface FeedSourceInfo {
  getName(): string;

  getUrl(): string;

  getServiceId(): number;
}

export class FeedUpdateInfo {
  uid: number = 0;
  notificationMode: NotificationMode = NotificationMode.DISABLED;
  name: string = '';
  avatarUrl: string | null = null;
  url: string = '';
  serviceId: number = 0;
  /** null when the constructor info came from the fast feed method. */
  description: string | null = null;
  /** null when the constructor info came from the fast feed method. */
  subscriberCount: number | null = null;
  streams: StreamInfoItem[] = [];
  errors: Error[] = [];

  /** `lateinit var newStreams` in the source: filled by the feed loader after the DB diff. */
  newStreams: StreamInfoItem[] = [];

  /** Integer id, used as the notification id. */
  get pseudoId(): number {
    return javaStringHashCode(this.url);
  }

  /**
   * Port of `FeedUpdateInfo(subscription, info, streams, errors)`. Fills every field the Kotlin
   * secondary constructor fills, from the same source values.
   */
  static fromSubscription(subscription: SubscriptionEntity, info: FeedSourceInfo,
    streams: StreamInfoItem[], errors: Error[]): FeedUpdateInfo {
    const channel: ChannelInfo | null = info instanceof ChannelInfo ? info : null;

    const out: FeedUpdateInfo = new FeedUpdateInfo();
    out.uid = subscription.uid;
    out.notificationMode = subscription.notificationMode;
    out.name = info.getName();
    // if the newly fetched info is not from the fast feed, it carries updated avatars
    out.avatarUrl = channel === null ? subscription.avatarUrl : imageListToDbUrl(channel.getAvatars());
    if (out.avatarUrl === null) {
      out.avatarUrl = subscription.avatarUrl;
    }
    out.url = info.getUrl();
    out.serviceId = info.getServiceId();
    // there is no description and subscriberCount in the fast feed
    out.description = channel === null ? null : channel.getDescription();
    out.subscriberCount = channel === null ? null : channel.getSubscriberCount();
    out.streams = streams;
    out.errors = errors;
    out.newStreams = [];
    return out;
  }
}
