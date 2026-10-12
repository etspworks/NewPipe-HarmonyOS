/*
 * svc_feed_loader — port of org.schabi.newpipe.local.feed.service.FeedLoadManager, together with
 * FeedDatabaseManager, FeedDAO and FeedGroupDAO (FeedDatabase below), which the plan gives no
 * module of their own.
 *
 * The two endpoints this service owns:
 *   youtube_feed_rss       — the dedicated feed extractor path (`getFeedExtractor(url)`), which
 *                            for YouTube fetches the channel RSS feed. The URL literal itself
 *                            belongs to YoutubeParsingHelper in the ported extractor, exactly as
 *                            in the source, so it is not repeated here.
 *   feed_channel_fallback  — the channel-tabs path, used when the service has no dedicated feed
 *                            extractor or the user turned the fast method off.
 *
 * Concurrency (phase2-logic-contract §1): the DB work and each extraction are one-shot Promises;
 * `progress`, which emits repeatedly while a load runs, is a Subject. RxJava's parallel(3) is a
 * pool of three async workers here. Rule 8: every ResultSet is closed inside AppDatabase.
 */

import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { AppDatabase } from '../db/AppDatabase';
import { StreamDao } from '../db/HistoryRecordManager';
import { FeedEntity } from '../../model/db/entity/FeedEntity';
import { FeedGroupEntity } from '../../model/db/entity/FeedGroupEntity';
import { FeedGroupSubscriptionEntity } from '../../model/db/entity/FeedGroupSubscriptionEntity';
import { FeedLastUpdatedEntity } from '../../model/db/entity/FeedLastUpdatedEntity';
import { StreamEntity } from '../../model/db/entity/StreamEntity';
import { StreamStateEntity } from '../../model/db/entity/StreamStateEntity';
import { SubscriptionEntity } from '../../model/db/entity/SubscriptionEntity';
import { StreamWithState } from '../../model/db/view/StreamWithState';
import { FeedGroupIcon } from '../../model/enums/FeedGroupIcon';
import { NotificationMode } from '../../model/enums/NotificationMode';
import { StreamType } from '../../model/enums/StreamType';
import { ChannelInfo } from '../../model/extractor/ChannelInfo';
import { ChannelTabInfo } from '../../model/extractor/ChannelTabInfo';
import { FeedInfo } from '../extractor/info/FeedInfo';
import { StreamInfoItem } from '../../model/extractor/StreamInfoItem';
import { InfoItem } from '../extractor/core/InfoItem';
import { InfoItemsPage } from '../../model/extractor/ListExtractorInfoItemsPage';
import { FeedSourceInfo, FeedUpdateInfo } from '../../model/app/FeedUpdateInfo';
import { ExtractorHelper } from '../extractor/ExtractorHelper';
import { Subject } from '../rx/Rx';
import { Preferences } from '../prefs/Preferences';
import {
  feed_update_threshold_default_value, feed_update_threshold_key,
  feed_use_dedicated_fetch_method_key, feed_fetch_channel_tabs_key
} from '../prefs/SettingsKeys';

/** ServiceList.YouTube.serviceId — YouTube is the first service the extractor registers. */
const YOUTUBE_SERVICE_ID: number = 0;

/**
 * FeedDatabaseManager.FEED_OLDEST_ALLOWED_DATE: only items newer than 13 weeks are stored.
 *
 * The source computes this once when the class loads; it is computed per call here so a
 * long-running process does not keep using the date the app started on.
 */
export function feedOldestAllowedDate(): number {
  const now: Date = new Date();
  const startOfToday: number = Date.UTC(now.getFullYear(), now.getMonth(), now.getDate());
  return startOfToday - 13 * 7 * 24 * 60 * 60 * 1000;
}

/**
 * The channel tabs a feed update reads, from ChannelTabHelper.getFetchFeedTabKey(). Tabs outside
 * this set (playlists, channels, albums, ...) never carry feed streams.
 */
const FEED_FETCHABLE_TABS: string[] =
  ['videos', 'tracks', 'shorts', 'livestreams', 'likes'];

/** What a running feed load reports: the source's notificationUpdater plus its ProgressEvent. */
export class FeedLoadProgress {
  readonly description: string;
  readonly currentProgress: number;
  readonly maxProgress: number;

  constructor(description: string, currentProgress: number, maxProgress: number) {
    this.description = description;
    this.currentProgress = currentProgress;
    this.maxProgress = maxProgress;
  }
}

/**
 * Port of FeedDatabaseManager + FeedDAO + FeedGroupDAO.
 */
export class FeedDatabase {
  private readonly database: AppDatabase;

  constructor(database: AppDatabase) {
    this.database = database;
  }

  static async of(context: common.Context): Promise<FeedDatabase> {
    return new FeedDatabase(await AppDatabase.getInstance(context));
  }

  /** The store, for callers that need to wrap several feed writes in one transaction. */
  db(): AppDatabase {
    return this.database;
  }

  // ///////////////////////////////////////////////////////////////////////////
  // Feed streams
  // ///////////////////////////////////////////////////////////////////////////

  /**
   * Port of FeedDAO.getStreams(): the feed of one group, filtered by what the user chose to see.
   *
   * @param groupId FeedGroupEntity.GROUP_ALL_ID for every subscription
   * @param includeFutureStreams when false, streams whose upload date is in the future are hidden
   */
  async getStreams(groupId: number, includePlayed: boolean, includePartiallyPlayed: boolean,
    includeFutureStreams: boolean): Promise<StreamWithState[]> {
    const uploadDateBefore: number | null = includeFutureStreams ? null : Date.now();
    return this.database.query<StreamWithState>(
      'SELECT s.*, sst.progress_time FROM streams s ' +
      'LEFT JOIN stream_state sst ON s.uid = sst.stream_id ' +
      'LEFT JOIN stream_history sh ON s.uid = sh.stream_id ' +
      'INNER JOIN feed f ON s.uid = f.stream_id ' +
      'LEFT JOIN feed_group_subscription_join fgs ' +
      '  ON (? <> ' + FeedGroupEntity.GROUP_ALL_ID + ' AND fgs.subscription_id = f.subscription_id) ' +
      'WHERE (? = ' + FeedGroupEntity.GROUP_ALL_ID + ' OR fgs.group_id = ?) ' +
      'AND (? OR sh.stream_id IS NULL OR sst.stream_id IS NULL ' +
      '  OR sst.progress_time < s.duration * 1000 - ' +
      StreamStateEntity.PLAYBACK_FINISHED_END_MILLISECONDS + ' ' +
      '  OR sst.progress_time < s.duration * 1000 * 3 / 4 ' +
      "  OR s.stream_type = 'LIVE_STREAM' OR s.stream_type = 'AUDIO_LIVE_STREAM') " +
      'AND (? OR sh.stream_id IS NULL OR sst.stream_id IS NULL ' +
      '  OR (sst.progress_time <= ' + StreamStateEntity.PLAYBACK_SAVE_THRESHOLD_START_MILLISECONDS +
      '    AND sst.progress_time <= s.duration * 1000 / 4) ' +
      '  OR (sst.progress_time >= s.duration * 1000 - ' +
      StreamStateEntity.PLAYBACK_FINISHED_END_MILLISECONDS +
      '    AND sst.progress_time >= s.duration * 1000 * 3 / 4)) ' +
      'AND (? IS NULL OR s.upload_date IS NULL OR s.upload_date < ?) ' +
      'ORDER BY s.upload_date IS NULL DESC, s.upload_date DESC, s.uploader ASC LIMIT 500',
      [groupId, groupId, groupId, includePlayed ? 1 : 0, includePartiallyPlayed ? 1 : 0,
        uploadDateBefore, uploadDateBefore],
      StreamWithState.fromRow);
  }

  /** Port of FeedDatabaseManager.doesStreamExist(). */
  async doesStreamExist(stream: StreamInfoItem): Promise<boolean> {
    return StreamDao.exists(this.database, stream.serviceId, stream.url);
  }

  /**
   * Port of FeedDatabaseManager.upsertAll(): stores the streams that are recent enough (or live)
   * and links them to the subscription, then stamps the subscription as just updated.
   */
  async upsertAll(subscriptionId: number, items: StreamInfoItem[],
    oldestAllowedDate: number = feedOldestAllowedDate()): Promise<void> {
    const itemsToInsert: StreamInfoItem[] = [];
    for (const stream of items) {
      if (stream.uploadDate === null && stream.streamType === StreamType.LIVE_STREAM) {
        itemsToInsert.push(stream);
      } else if (stream.uploadDate !== null && stream.uploadDate >= oldestAllowedDate) {
        itemsToInsert.push(stream);
      }
    }

    await this.unlinkOldLivestreams(subscriptionId);

    if (itemsToInsert.length !== 0) {
      const streamEntities: StreamEntity[] = itemsToInsert.map(
        (item: StreamInfoItem): StreamEntity => StreamEntity.fromInfoItem(item));
      const streamIds: number[] = await StreamDao.upsertAll(this.database, streamEntities);
      for (const streamId of streamIds) {
        const feedEntity: FeedEntity = new FeedEntity(streamId, subscriptionId);
        await this.database.insert(FeedEntity.TABLE, feedEntity.toValuesBucket(),
          relationalStore.ConflictResolution.ON_CONFLICT_IGNORE);
      }
    }

    await this.setLastUpdatedForSubscription(
      new FeedLastUpdatedEntity(subscriptionId, Date.now()));
  }

  /** Port of FeedDAO.unlinkOldLivestreams(). */
  private async unlinkOldLivestreams(subscriptionId: number): Promise<void> {
    await this.database.execute(
      'DELETE FROM feed WHERE feed.subscription_id = ? AND feed.stream_id IN (' +
      '  SELECT s.uid FROM streams s INNER JOIN feed f ON s.uid = f.stream_id ' +
      "  WHERE s.stream_type = 'LIVE_STREAM' OR s.stream_type = 'AUDIO_LIVE_STREAM')",
      [subscriptionId]);
  }

  /**
   * Port of FeedDatabaseManager.removeOrphansOrOlderStreams(): keeps the feed and stream tables
   * small, but always keeps one stream per uploader as the reference for "is this new?".
   */
  async removeOrphansOrOlderStreams(
    oldestAllowedDate: number = feedOldestAllowedDate()): Promise<void> {
    await this.database.execute(
      'DELETE FROM feed WHERE feed.stream_id IN (SELECT uid FROM (' +
      '  SELECT s.uid, (SELECT MAX(upload_date) FROM streams s1 ' +
      '    INNER JOIN feed f1 ON s1.uid = f1.stream_id ' +
      '    WHERE f1.subscription_id = f.subscription_id) max_upload_date ' +
      '  FROM streams s INNER JOIN feed f ON s.uid = f.stream_id ' +
      '  WHERE s.upload_date < ? AND s.upload_date <> max_upload_date))', [oldestAllowedDate]);
    await StreamDao.deleteOrphans(this.database);
  }

  /** Port of FeedDatabaseManager.clear(). */
  async clear(): Promise<number> {
    await this.database.execute('DELETE FROM feed', []);
    return StreamDao.deleteOrphans(this.database);
  }

  // ///////////////////////////////////////////////////////////////////////////
  // Update bookkeeping
  // ///////////////////////////////////////////////////////////////////////////

  /** Port of FeedDAO.setLastUpdatedForSubscription(): insert, or update when it already exists. */
  async setLastUpdatedForSubscription(entity: FeedLastUpdatedEntity): Promise<void> {
    const id: number = await this.database.insert(FeedLastUpdatedEntity.TABLE,
      entity.toValuesBucket(), relationalStore.ConflictResolution.ON_CONFLICT_IGNORE);
    if (id === -1) {
      await this.database.execute(
        'UPDATE feed_last_updated SET last_updated = ? WHERE subscription_id = ?',
        [entity.lastUpdated, entity.subscriptionId]);
    }
  }

  /** Port of FeedDatabaseManager.markAsOutdated(). */
  async markAsOutdated(subscriptionId: number): Promise<void> {
    await this.setLastUpdatedForSubscription(new FeedLastUpdatedEntity(subscriptionId, null));
  }

  /** Port of FeedDAO.getAllOutdated(). */
  async outdatedSubscriptions(outdatedThreshold: number): Promise<SubscriptionEntity[]> {
    return this.database.query<SubscriptionEntity>(
      'SELECT s.* FROM subscriptions s ' +
      'LEFT JOIN feed_last_updated lu ON s.uid = lu.subscription_id ' +
      'WHERE lu.last_updated IS NULL OR lu.last_updated < ?',
      [outdatedThreshold], SubscriptionEntity.fromRow);
  }

  /** Port of FeedDAO.getAllOutdatedForGroup(). */
  async outdatedSubscriptionsForGroup(groupId: number,
    outdatedThreshold: number): Promise<SubscriptionEntity[]> {
    return this.database.query<SubscriptionEntity>(
      'SELECT s.* FROM subscriptions s ' +
      'INNER JOIN feed_group_subscription_join fgs ' +
      '  ON s.uid = fgs.subscription_id AND fgs.group_id = ? ' +
      'LEFT JOIN feed_last_updated lu ON s.uid = lu.subscription_id ' +
      'WHERE lu.last_updated IS NULL OR lu.last_updated < ?',
      [groupId, outdatedThreshold], SubscriptionEntity.fromRow);
  }

  /** Port of FeedDAO.getOutdatedWithNotificationMode(). */
  async outdatedSubscriptionsWithNotificationMode(outdatedThreshold: number,
    notificationMode: NotificationMode): Promise<SubscriptionEntity[]> {
    return this.database.query<SubscriptionEntity>(
      'SELECT s.* FROM subscriptions s ' +
      'LEFT JOIN feed_last_updated lu ON s.uid = lu.subscription_id ' +
      'WHERE (lu.last_updated IS NULL OR lu.last_updated < ?) AND s.notification_mode = ?',
      [outdatedThreshold, notificationMode as number], SubscriptionEntity.fromRow);
  }

  /** Port of FeedDatabaseManager.notLoadedCount(). */
  async notLoadedCount(groupId: number = FeedGroupEntity.GROUP_ALL_ID): Promise<number> {
    if (groupId === FeedGroupEntity.GROUP_ALL_ID) {
      return this.database.queryNumber(
        'SELECT COUNT(*) FROM feed_last_updated WHERE last_updated IS NULL', [], 0);
    }
    return this.database.queryNumber(
      'SELECT COUNT(*) FROM subscriptions s ' +
      'INNER JOIN feed_group_subscription_join fgs ' +
      '  ON s.uid = fgs.subscription_id AND fgs.group_id = ? ' +
      'LEFT JOIN feed_last_updated lu ON s.uid = lu.subscription_id ' +
      'WHERE lu.last_updated IS NULL', [groupId], 0);
  }

  /** Port of FeedDatabaseManager.oldestSubscriptionUpdate(): null when nothing was ever loaded. */
  async oldestSubscriptionUpdate(groupId: number): Promise<number | null> {
    const rows: Array<number | null> = groupId === FeedGroupEntity.GROUP_ALL_ID
      ? await this.database.queryNumbers('SELECT MIN(last_updated) FROM feed_last_updated', [])
      : await this.database.queryNumbers(
        'SELECT MIN(lu.last_updated) FROM feed_last_updated lu ' +
        'INNER JOIN feed_group_subscription_join fgs ' +
        '  ON fgs.subscription_id = lu.subscription_id AND fgs.group_id = ?', [groupId]);
    return rows.length === 0 ? null : rows[0];
  }

  // ///////////////////////////////////////////////////////////////////////////
  // Feed groups
  // ///////////////////////////////////////////////////////////////////////////

  /** Port of FeedGroupDAO.getAll(). */
  async groups(): Promise<FeedGroupEntity[]> {
    return this.database.query<FeedGroupEntity>(
      'SELECT * FROM feed_group ORDER BY sort_order ASC', [], FeedGroupEntity.fromRow);
  }

  /** Port of FeedGroupDAO.getGroup(). */
  async getGroup(groupId: number): Promise<FeedGroupEntity | null> {
    return this.database.queryFirst<FeedGroupEntity>('SELECT * FROM feed_group WHERE uid = ?',
      [groupId], FeedGroupEntity.fromRow);
  }

  /** Port of FeedGroupDAO.insert(): the new group goes last in the sort order. */
  async createGroup(name: string, icon: FeedGroupIcon): Promise<number> {
    return this.database.runInTransaction<number>(async (): Promise<number> => {
      const nextSortOrder: number = await this.database.queryNumber(
        'SELECT IFNULL(MAX(sort_order) + 1, 0) FROM feed_group', [], 0);
      const entity: FeedGroupEntity = new FeedGroupEntity(0, name, icon);
      entity.sortOrder = nextSortOrder;
      return this.database.insert(FeedGroupEntity.TABLE, entity.toValuesBucket(),
        relationalStore.ConflictResolution.ON_CONFLICT_ABORT);
    });
  }

  /** Port of FeedGroupDAO.update(). */
  async updateGroup(entity: FeedGroupEntity): Promise<number> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(FeedGroupEntity.TABLE);
    predicates.equalTo('uid', entity.uid);
    return this.database.update(entity.toValuesBucket(), predicates,
      relationalStore.ConflictResolution.ON_CONFLICT_IGNORE);
  }

  /** Port of FeedGroupDAO.delete(groupId). */
  async deleteGroup(groupId: number): Promise<number> {
    return this.database.executeAndCount('DELETE FROM feed_group WHERE uid = ?', [groupId]);
  }

  /** Port of FeedGroupDAO.getSubscriptionIdsFor(). */
  async subscriptionIdsForGroup(groupId: number): Promise<number[]> {
    const ids: Array<number | null> = await this.database.queryNumbers(
      'SELECT subscription_id FROM feed_group_subscription_join WHERE group_id = ?', [groupId]);
    const result: number[] = [];
    for (const id of ids) {
      if (id !== null) {
        result.push(id);
      }
    }
    return result;
  }

  /** Port of FeedGroupDAO.updateSubscriptionsForGroup(): replaces the group's membership. */
  async updateSubscriptionsForGroup(groupId: number, subscriptionIds: number[]): Promise<void> {
    await this.database.runInTransaction<void>(async (): Promise<void> => {
      await this.database.execute(
        'DELETE FROM feed_group_subscription_join WHERE group_id = ?', [groupId]);
      for (const subscriptionId of subscriptionIds) {
        const join: FeedGroupSubscriptionEntity =
          new FeedGroupSubscriptionEntity(groupId, subscriptionId);
        await this.database.insert(FeedGroupSubscriptionEntity.TABLE, join.toValuesBucket(),
          relationalStore.ConflictResolution.ON_CONFLICT_IGNORE);
      }
    });
  }

  /** Port of FeedDatabaseManager.updateGroupsOrder(). */
  async updateGroupsOrder(groupIdList: number[]): Promise<void> {
    await this.database.runInTransaction<void>(async (): Promise<void> => {
      for (let index = 0; index < groupIdList.length; index++) {
        await this.database.execute('UPDATE feed_group SET sort_order = ? WHERE uid = ?',
          [index, groupIdList[index]]);
      }
    });
  }
}

/**
 * Port of FeedLoadManager: checks the subscriptions of a group for new streams.
 */
export class FeedLoader {
  /** Checks subscriptions with NotificationMode.ENABLED instead of a real group. */
  static readonly GROUP_NOTIFICATION_ENABLED: number = -2;

  /** How many extractions run in parallel. */
  private static readonly PARALLEL_EXTRACTIONS: number = 3;
  /** How many YouTube extractions to do before pausing, to avoid being rate limited. */
  private static readonly BATCH_SIZE: number = 50;
  private static readonly DELAY_BETWEEN_BATCHES_MIN_MILLIS: number = 6000;
  private static readonly DELAY_BETWEEN_BATCHES_MAX_MILLIS: number = 12000;
  /** How many results to buffer before writing them to the database in one transaction. */
  private static readonly BUFFER_COUNT_BEFORE_INSERT: number = 20;

  private readonly database: AppDatabase;
  private readonly feedDatabase: FeedDatabase;

  /** Emits while a load runs — the source's notificationUpdater plus its ProgressEvents. */
  readonly progress: Subject<FeedLoadProgress> = new Subject<FeedLoadProgress>();

  private currentProgress: number = -1;
  private maxProgress: number = -1;
  private cancelSignal: boolean = false;
  private readonly itemsErrors: Error[] = [];

  constructor(database: AppDatabase) {
    this.database = database;
    this.feedDatabase = new FeedDatabase(database);
  }

  static async of(context: common.Context): Promise<FeedLoader> {
    return new FeedLoader(await AppDatabase.getInstance(context));
  }

  /** The errors the last load collected, as FeedResultsHolder holds them. */
  errors(): Error[] {
    return this.itemsErrors;
  }

  /** Port of FeedLoadManager.cancel(). */
  cancel(): void {
    this.cancelSignal = true;
  }

  /**
   * Port of startLoading(): fetches new streams for every outdated subscription of a group.
   *
   * @param groupId FeedGroupEntity.GROUP_ALL_ID for all subscriptions, GROUP_NOTIFICATION_ENABLED
   *                for the ones with notifications on, or a real group id
   * @param ignoreOutdatedThreshold when true, every subscription is checked regardless of when it
   *                                was last updated
   */
  async startLoading(groupId: number = FeedGroupEntity.GROUP_ALL_ID,
    ignoreOutdatedThreshold: boolean = false): Promise<FeedUpdateInfo[]> {
    this.cancelSignal = false;
    this.itemsErrors.length = 0;

    const useFeedExtractor: boolean =
      await Preferences.getBoolean(feed_use_dedicated_fetch_method_key, false);

    let outdatedThreshold: number = Date.now();
    if (!ignoreOutdatedThreshold) {
      const thresholdSeconds: string = await Preferences.getString(feed_update_threshold_key,
        feed_update_threshold_default_value);
      outdatedThreshold = Date.now() - Number.parseInt(thresholdSeconds, 10) * 1000;
    }

    const subscriptions: SubscriptionEntity[] =
      await this.outdatedSubscriptions(groupId, outdatedThreshold);

    this.currentProgress = 0;
    this.maxProgress = subscriptions.length;
    if (subscriptions.length === 0) {
      return [];
    }
    this.emitProgress('');

    // Randomize the subscription ordering to resist fingerprinting, as the source does.
    const shuffled: SubscriptionEntity[] = FeedLoader.shuffle(subscriptions);
    const results: FeedUpdateInfo[] = [];
    const buffer: FeedUpdateInfo[] = [];
    let nextIndex: number = 0;
    let youtubeExtractionCount: number = 0;

    const worker = async (): Promise<void> => {
      while (true) {
        if (this.cancelSignal || nextIndex >= shuffled.length) {
          return;
        }
        const subscription: SubscriptionEntity = shuffled[nextIndex];
        nextIndex++;

        // Throttle YouTube extractions once every BATCH_SIZE to avoid being rate limited.
        if (subscription.serviceId === YOUTUBE_SERVICE_ID) {
          const previousCount: number = youtubeExtractionCount;
          youtubeExtractionCount++;
          if (previousCount !== 0 && previousCount % FeedLoader.BATCH_SIZE === 0) {
            await FeedLoader.delay(FeedLoader.randomBatchDelay());
          }
        }

        const info: FeedUpdateInfo | null = await this.loadStreams(subscription, useFeedExtractor);
        this.currentProgress++;
        this.emitProgress(info === null ? '' : info.name);

        if (info !== null) {
          buffer.push(info);
          results.push(info);
          if (buffer.length >= FeedLoader.BUFFER_COUNT_BEFORE_INSERT) {
            await this.storeBuffer(buffer);
          }
        }
      }
    };

    const workers: Array<Promise<void>> = [];
    for (let i = 0; i < FeedLoader.PARALLEL_EXTRACTIONS; i++) {
      workers.push(worker());
    }
    await Promise.all(workers);
    await this.storeBuffer(buffer);
    await this.postProcessFeed();
    return results;
  }

  private async outdatedSubscriptions(groupId: number,
    outdatedThreshold: number): Promise<SubscriptionEntity[]> {
    if (groupId === FeedGroupEntity.GROUP_ALL_ID) {
      return this.feedDatabase.outdatedSubscriptions(outdatedThreshold);
    }
    if (groupId === FeedLoader.GROUP_NOTIFICATION_ENABLED) {
      return this.feedDatabase.outdatedSubscriptionsWithNotificationMode(outdatedThreshold,
        NotificationMode.ENABLED);
    }
    return this.feedDatabase.outdatedSubscriptionsForGroup(groupId, outdatedThreshold);
  }

  /**
   * Port of loadStreams(): the dedicated feed extractor first (endpoint youtube_feed_rss), then
   * the channel tabs (endpoint feed_channel_fallback). Returns null when the subscription failed,
   * after marking it outdated so the next run retries it.
   */
  private async loadStreams(subscription: SubscriptionEntity,
    useFeedExtractor: boolean): Promise<FeedUpdateInfo | null> {
    const url: string = subscription.url as string;
    const errors: Error[] = [];
    let channelInfo: ChannelInfo | null = null;
    // Whichever of the two fetches produced the feed; FeedUpdateInfo reads name/url/serviceId
    // off it, exactly as the source's FeedUpdateInfo(subscription, info, ...) constructor does.
    let sourceInfo: FeedSourceInfo | null = null;
    let streams: StreamInfoItem[] | null = null;

    try {
      if (useFeedExtractor) {
        // The user wants the fast method: for YouTube this is the channel RSS feed, whose URL
        // the ported YoutubeParsingHelper owns (endpoint youtube_feed_rss).
        const feedInfo: FeedInfo | null =
          await ExtractorHelper.getFeedInfo(subscription.serviceId, url);
        if (feedInfo !== null) {
          errors.push(...feedInfo.getErrors());
          sourceInfo = feedInfo;
          streams = FeedLoader.onlyStreams(feedInfo.relatedItems);
        }
      }

      if (streams === null) {
        // Either the user turned the fast method off, or the service has no feed extractor:
        // read the channel's feed-carrying tabs instead (endpoint feed_channel_fallback).
        channelInfo = await ExtractorHelper.getChannelInfo(subscription.serviceId, url, true);
        errors.push(...channelInfo.getErrors());
        sourceInfo = channelInfo;
        streams = await this.loadStreamsFromTabs(subscription.serviceId, channelInfo, errors);
      }
    } catch (error) {
      // FeedLoadService.RequestException: the subscription is marked outdated so it is retried.
      this.itemsErrors.push(new Error(
        `${subscription.serviceId}:${url}: ${(error as Error).message}`));
      await this.feedDatabase.markAsOutdated(subscription.uid);
      return null;
    }

    if (sourceInfo === null) {
      // Neither fetch produced an info object and neither threw; nothing to report.
      return null;
    }
    // fromSubscription() keeps the stored avatar/description/subscriberCount when the fast feed
    // was used, so the fast/full-fetch split does not have to be re-derived here.
    return FeedUpdateInfo.fromSubscription(subscription, sourceInfo,
      streams === null ? [] : streams, errors);
  }

  /** Port of the tab loop in loadStreams(): the feed-carrying tabs, paged once if empty. */
  private async loadStreamsFromTabs(serviceId: number, channelInfo: ChannelInfo,
    errors: Error[]): Promise<StreamInfoItem[]> {
    const streams: StreamInfoItem[] = [];
    for (const tab of channelInfo.tabs) {
      if (!FeedLoader.fetchFeedChannelTab(tab.getContentFilters())) {
        continue;
      }
      const tabInfo: ChannelTabInfo = await ExtractorHelper.getChannelTab(serviceId, tab, true);
      errors.push(...tabInfo.getErrors());

      if (tabInfo.relatedItems.length === 0 && tabInfo.nextPage !== null) {
        const page: InfoItemsPage<InfoItem> =
          await ExtractorHelper.getMoreChannelTabItems(serviceId, tab, tabInfo.nextPage);
        errors.push(...page.getErrors());
        streams.push(...FeedLoader.onlyStreams(page.getItems()));
      } else {
        streams.push(...FeedLoader.onlyStreams(tabInfo.relatedItems));
      }
    }
    return streams;
  }

  /**
   * Port of ChannelTabHelper.fetchFeedChannelTab(): only the video-like tabs carry feed streams,
   * and they are all enabled unless the user unticked one (feed_fetch_channel_tabs_key).
   */
  private static fetchFeedChannelTab(contentFilters: string[]): boolean {
    if (contentFilters.length === 0) {
      return false; // this should never happen, but check just to be sure
    }
    const tab: string = contentFilters[0];
    if (!FEED_FETCHABLE_TABS.includes(tab)) {
      return false;
    }
    // getFetchFeedTabKey(tab): 'videos' -> fetch_channel_tabs_videos, and so on. A user who never
    // opened the setting has no stored set, which means every tab (the source's default true).
    let enabled: string[] | null = null;
    try {
      const prefs: Preferences = Preferences.instance();
      enabled = prefs.has(feed_fetch_channel_tabs_key)
        ? prefs.getStringSetSync(feed_fetch_channel_tabs_key, []) : null;
    } catch (err) {
      enabled = null;
    }
    return enabled === null || enabled.includes('fetch_channel_tabs_' + tab);
  }

  /**
   * Port of DatabaseConsumer: writes one buffer of results in a single transaction, marking the
   * subscriptions whose fetch reported errors as outdated so they are retried.
   */
  private async storeBuffer(buffer: FeedUpdateInfo[]): Promise<void> {
    if (buffer.length === 0) {
      return;
    }
    const batch: FeedUpdateInfo[] = buffer.slice(0);
    buffer.length = 0;

    await this.database.runInTransaction<void>(async (): Promise<void> => {
      for (const info of batch) {
        info.newStreams = await this.filterNewStreams(info.streams);
        await this.feedDatabase.upsertAll(info.uid, info.streams);
        await this.updateSubscriptionFromInfo(info);

        if (info.errors.length !== 0) {
          for (const error of info.errors) {
            this.itemsErrors.push(new Error(
              `${info.serviceId}:${info.url}: ${error.message}`));
          }
          await this.feedDatabase.markAsOutdated(info.uid);
        }
      }
    });
  }

  /**
   * Port of SubscriptionManager.updateFromInfo(). It is done with SQL here rather than through
   * SubscriptionManager because SubscriptionManager already depends on this module for the feed
   * writes, and importing it back would make the two modules circular.
   */
  private async updateSubscriptionFromInfo(info: FeedUpdateInfo): Promise<void> {
    await this.database.execute(
      'UPDATE subscriptions SET name = ?, ' +
      'avatar_url = COALESCE(?, avatar_url), ' +
      'description = COALESCE(?, description), ' +
      'subscriber_count = COALESCE(?, subscriber_count) WHERE uid = ?',
      [info.name, info.avatarUrl, info.description, info.subscriberCount, info.uid]);
  }

  /**
   * Port of DatabaseConsumer.filterNewStreams(): a stream is new when it is not stored yet and is
   * recent enough that it would not be pruned right away.
   */
  private async filterNewStreams(list: StreamInfoItem[]): Promise<StreamInfoItem[]> {
    const oldestAllowed: number = feedOldestAllowedDate();
    const result: StreamInfoItem[] = [];
    for (const stream of list) {
      if (stream.uploadDate === null || stream.uploadDate <= oldestAllowed) {
        continue;
      }
      if (!await this.feedDatabase.doesStreamExist(stream)) {
        result.push(stream);
      }
    }
    return result;
  }

  /** Port of postProcessFeed(): keeps the feed and stream tables small. */
  private async postProcessFeed(): Promise<void> {
    this.currentProgress = -1;
    this.maxProgress = -1;
    this.emitProgress('processing');
    await this.feedDatabase.removeOrphansOrOlderStreams();
  }

  private emitProgress(description: string): void {
    this.progress.onNext(new FeedLoadProgress(description, this.currentProgress, this.maxProgress));
  }

  /** Port of `relatedItems.filterIsInstance<StreamInfoItem>()`. */
  private static onlyStreams(items: object[]): StreamInfoItem[] {
    const streams: StreamInfoItem[] = [];
    for (const item of items) {
      if (item instanceof StreamInfoItem) {
        streams.push(item);
      }
    }
    return streams;
  }

  /** Port of Kotlin's List.shuffled(). */
  private static shuffle(items: SubscriptionEntity[]): SubscriptionEntity[] {
    const copy: SubscriptionEntity[] = items.slice(0);
    for (let i = copy.length - 1; i > 0; i--) {
      const j: number = Math.floor(Math.random() * (i + 1));
      const swap: SubscriptionEntity = copy[i];
      copy[i] = copy[j];
      copy[j] = swap;
    }
    return copy;
  }

  private static randomBatchDelay(): number {
    const span: number =
      FeedLoader.DELAY_BETWEEN_BATCHES_MAX_MILLIS - FeedLoader.DELAY_BETWEEN_BATCHES_MIN_MILLIS;
    return FeedLoader.DELAY_BETWEEN_BATCHES_MIN_MILLIS + Math.floor(Math.random() * span);
  }

  private static delay(millis: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout(resolve, millis);
    });
  }
}
