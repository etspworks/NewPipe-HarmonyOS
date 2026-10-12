/*
 * svc_subscription_manager — port of org.schabi.newpipe.local.subscription.SubscriptionManager,
 * the SubscriptionDAO queries behind it, and the two import paths of SubscriptionImportWorker
 * (endpoints subscription_import_channel_url and subscription_import_file) together with
 * ImportExportJsonHelper, which has no module of its own in the plan.
 *
 * Concurrency (phase2-logic-contract §1): DAO reads/writes are one-shot Promises. The one
 * repeating stream is `changes`, a Subject the subscription list subscribes to so it refreshes
 * after an import or a delete — the source gets that for free from Room's Flowable.
 * Rule 8: every ResultSet is closed by AppDatabase.query/queryFirst/queryNumber in a finally.
 */

import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { AppDatabase } from './AppDatabase';
import { StreamDao } from './HistoryRecordManager';
import { FeedDatabase } from '../feed/FeedLoader';
import { Subject } from '../rx/Rx';
import { SubscriptionEntity } from '../../model/db/entity/SubscriptionEntity';
import { FeedGroupEntity } from '../../model/db/entity/FeedGroupEntity';
import { StreamEntity } from '../../model/db/entity/StreamEntity';
import { imageListToDbUrl } from '../image/ImageLoader';
import { NotificationMode } from '../../model/enums/NotificationMode';
import { ChannelInfo } from '../../model/extractor/ChannelInfo';
import { ChannelTabInfo } from '../../model/extractor/ChannelTabInfo';
import { StreamInfoItem } from '../../model/extractor/StreamInfoItem';
import { SubscriptionData, SubscriptionItem } from '../../model/app/SubscriptionData';
import { ExtractorHelper } from '../extractor/ExtractorHelper';

/** A channel and the tab its feed was read from, as SubscriptionManager.upsertAll() takes them. */
export class ChannelWithTab {
  readonly channelInfo: ChannelInfo;
  readonly channelTab: ChannelTabInfo | null;

  constructor(channelInfo: ChannelInfo, channelTab: ChannelTabInfo | null) {
    this.channelInfo = channelInfo;
    this.channelTab = channelTab;
  }
}

/** Port of org.schabi.newpipe.database.subscription.SubscriptionDAO. */
export class SubscriptionDao {

  /** Port of SubscriptionDAO.rowCount(). */
  static async rowCount(db: AppDatabase): Promise<number> {
    return db.queryNumber('SELECT COUNT(*) FROM subscriptions', [], 0);
  }

  /** Port of SubscriptionDAO.getAll(). */
  static async getAll(db: AppDatabase): Promise<SubscriptionEntity[]> {
    return db.query<SubscriptionEntity>(
      'SELECT * FROM subscriptions ORDER BY name COLLATE NOCASE ASC', [],
      SubscriptionEntity.fromRow);
  }

  /** Port of SubscriptionDAO.listByService(). */
  static async listByService(db: AppDatabase, serviceId: number): Promise<SubscriptionEntity[]> {
    return db.query<SubscriptionEntity>('SELECT * FROM subscriptions WHERE service_id = ?',
      [serviceId], SubscriptionEntity.fromRow);
  }

  /** Port of SubscriptionDAO.getSubscriptionsFiltered(). */
  static async getSubscriptionsFiltered(db: AppDatabase,
    filter: string): Promise<SubscriptionEntity[]> {
    return db.query<SubscriptionEntity>(
      "SELECT * FROM subscriptions WHERE name LIKE '%' || ? || '%' " +
      'ORDER BY name COLLATE NOCASE ASC', [filter], SubscriptionEntity.fromRow);
  }

  /** Port of SubscriptionDAO.getSubscriptionsOnlyUngrouped(). */
  static async getSubscriptionsOnlyUngrouped(db: AppDatabase,
    currentGroupId: number): Promise<SubscriptionEntity[]> {
    return db.query<SubscriptionEntity>(
      'SELECT s.* FROM subscriptions s ' +
      'LEFT JOIN feed_group_subscription_join fgs ON s.uid = fgs.subscription_id ' +
      'WHERE (fgs.subscription_id IS NULL OR fgs.group_id = ?) ' +
      'ORDER BY name COLLATE NOCASE ASC', [currentGroupId], SubscriptionEntity.fromRow);
  }

  /** Port of SubscriptionDAO.getSubscriptionsOnlyUngroupedFiltered(). */
  static async getSubscriptionsOnlyUngroupedFiltered(db: AppDatabase, currentGroupId: number,
    filter: string): Promise<SubscriptionEntity[]> {
    return db.query<SubscriptionEntity>(
      'SELECT s.* FROM subscriptions s ' +
      'LEFT JOIN feed_group_subscription_join fgs ON s.uid = fgs.subscription_id ' +
      'WHERE (fgs.subscription_id IS NULL OR fgs.group_id = ?) ' +
      "AND s.name LIKE '%' || ? || '%' " +
      'ORDER BY name COLLATE NOCASE ASC', [currentGroupId, filter], SubscriptionEntity.fromRow);
  }

  /** Port of SubscriptionDAO.getSubscription(serviceId, url). */
  static async getSubscription(db: AppDatabase, serviceId: number,
    url: string): Promise<SubscriptionEntity | null> {
    return db.queryFirst<SubscriptionEntity>(
      'SELECT * FROM subscriptions WHERE url LIKE ? AND service_id = ?', [url, serviceId],
      SubscriptionEntity.fromRow);
  }

  /** Port of SubscriptionDAO.getSubscription(subscriptionId). */
  static async getSubscriptionById(db: AppDatabase,
    subscriptionId: number): Promise<SubscriptionEntity | null> {
    return db.queryFirst<SubscriptionEntity>('SELECT * FROM subscriptions WHERE uid = ?',
      [subscriptionId], SubscriptionEntity.fromRow);
  }

  /** Port of SubscriptionDAO.getSubscriptionIdInternal(). */
  static async getSubscriptionId(db: AppDatabase, serviceId: number,
    url: string): Promise<number> {
    return db.queryNumber('SELECT uid FROM subscriptions WHERE url LIKE ? AND service_id = ?',
      [url, serviceId], -1);
  }

  /** Port of the inherited BasicDAO.insert(entity). */
  static async insert(db: AppDatabase, entity: SubscriptionEntity): Promise<number> {
    const uid: number = await db.insert(SubscriptionEntity.TABLE, entity.toValuesBucket(),
      relationalStore.ConflictResolution.ON_CONFLICT_NONE);
    entity.uid = uid;
    return uid;
  }

  /** Port of the inherited BasicDAO.update(entity). */
  static async update(db: AppDatabase, entity: SubscriptionEntity): Promise<number> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(SubscriptionEntity.TABLE);
    predicates.equalTo('uid', entity.uid);
    return db.update(entity.toValuesBucket(), predicates);
  }

  /**
   * Port of SubscriptionDAO.upsertAll(): silent-insert every entity, then fill in the uid of the
   * ones that already existed and update them. The entities are mutated in place, exactly as in
   * the source, because the caller needs their uids.
   */
  static async upsertAll(db: AppDatabase,
    entities: SubscriptionEntity[]): Promise<SubscriptionEntity[]> {
    for (const entity of entities) {
      const uidFromInsert: number = await db.insert(SubscriptionEntity.TABLE,
        entity.toValuesBucket(), relationalStore.ConflictResolution.ON_CONFLICT_IGNORE);

      if (uidFromInsert !== -1) {
        entity.uid = uidFromInsert;
      } else {
        const existingId: number =
          await SubscriptionDao.getSubscriptionId(db, entity.serviceId, entity.url as string);
        if (existingId === -1) {
          throw new Error('Subscription cannot be null just after insertion.');
        }
        entity.uid = existingId;
        await SubscriptionDao.update(db, entity);
      }
    }
    return entities;
  }

  /** Port of SubscriptionDAO.deleteSubscription(serviceId, url). */
  static async deleteSubscription(db: AppDatabase, serviceId: number,
    url: string): Promise<number> {
    return db.executeAndCount(
      'DELETE FROM subscriptions WHERE url LIKE ? AND service_id = ?', [url, serviceId]);
  }

  /** Port of SubscriptionDAO.deleteAll(). */
  static async deleteAll(db: AppDatabase): Promise<number> {
    return db.executeAndCount('DELETE FROM subscriptions', []);
  }
}

/**
 * The change bus, shared by every SubscriptionManager instance in the process.
 *
 * Room hands the source ONE Flowable per query, and every observer of the subscription table sees
 * the same emissions however many DAO handles exist. Here the writers notify explicitly, so the
 * Subject has to be the shared thing - and it was an instance field, while the manager is built
 * in four places: SubscriptionManager.of() (a fresh instance per call, not a singleton) plus
 * `new SubscriptionManager(db)` directly in ChannelFragmentPage, FeedFragmentPage and
 * SelectChannelFragmentPage.
 *
 * So a subscribe on the channel screen notified the channel page's OWN Subject while the
 * subscription list sat listening to a different one, and the list only caught up when the app
 * restarted and re-read the table. That is TC-FEED-416.
 *
 * The database underneath is already a singleton (AppDatabase.getInstance), so sharing this
 * changes nothing about what any instance reads or writes - only that they all announce on the
 * same channel.
 */
const subscriptionChanges: Subject<number> = new Subject<number>();
let subscriptionRevision: number = 0;

/**
 * Port of SubscriptionManager.
 */
export class SubscriptionManager {
  private readonly database: AppDatabase;
  private readonly feedDatabase: FeedDatabase;

  /**
   * Emits a new revision number whenever the subscription table changed, so the subscription
   * list can reload. Room hands the source a Flowable that re-emits by itself; here the writers
   * notify explicitly (contract §1: a stream that emits repeatedly is a Subject).
   */
  readonly changes: Subject<number> = subscriptionChanges;

  constructor(database: AppDatabase) {
    this.database = database;
    this.feedDatabase = new FeedDatabase(database);
  }

  static async of(context: common.Context): Promise<SubscriptionManager> {
    return new SubscriptionManager(await AppDatabase.getInstance(context));
  }

  private notifyChanged(): void {
    subscriptionRevision++;
    subscriptionChanges.onNext(subscriptionRevision);
  }

  /** Port of subscriptions(). */
  async subscriptions(): Promise<SubscriptionEntity[]> {
    return SubscriptionDao.getAll(this.database);
  }

  /** Port of SubscriptionManager.getSubscriptions(). */
  async getSubscriptions(currentGroupId: number = FeedGroupEntity.GROUP_ALL_ID,
    filterQuery: string = '', showOnlyUngrouped: boolean = false): Promise<SubscriptionEntity[]> {
    if (filterQuery.length !== 0) {
      if (showOnlyUngrouped) {
        return SubscriptionDao.getSubscriptionsOnlyUngroupedFiltered(this.database, currentGroupId,
          filterQuery);
      }
      return SubscriptionDao.getSubscriptionsFiltered(this.database, filterQuery);
    }
    if (showOnlyUngrouped) {
      return SubscriptionDao.getSubscriptionsOnlyUngrouped(this.database, currentGroupId);
    }
    return SubscriptionDao.getAll(this.database);
  }

  /**
   * Port of upsertAll(): stores the channels as subscriptions and seeds each one's feed from the
   * tab that was fetched with it, so the feed is not empty right after an import.
   */
  async upsertAll(infoList: ChannelWithTab[]): Promise<void> {
    const listEntities: SubscriptionEntity[] = infoList.map(
      (info: ChannelWithTab): SubscriptionEntity =>
        SubscriptionEntity.fromChannelInfo(info.channelInfo));
    await SubscriptionDao.upsertAll(this.database, listEntities);

    await this.database.runInTransaction<void>(async (): Promise<void> => {
      for (let index = 0; index < infoList.length; index++) {
        const tab: ChannelTabInfo | null = infoList[index].channelTab;
        if (tab === null) {
          // There may be no tabs on the channel to refresh the feed from.
          continue;
        }
        const streams: StreamInfoItem[] = SubscriptionManager.onlyStreams(tab);
        await this.feedDatabase.upsertAll(listEntities[index].uid, streams);
      }
    });
    this.notifyChanged();
  }

  /** Port of updateChannelInfo(). */
  async updateChannelInfo(info: ChannelInfo): Promise<void> {
    const entity: SubscriptionEntity | null =
      await SubscriptionDao.getSubscription(this.database, info.getServiceId(), info.getUrl());
    if (entity === null) {
      return;
    }
    entity.name = info.getName();
    entity.avatarUrl = imageListToDbUrl(info.avatars);
    entity.description = info.description;
    entity.subscriberCount = info.subscriberCount;
    await SubscriptionDao.update(this.database, entity);
    this.notifyChanged();
  }

  /**
   * Port of updateNotificationMode(): when notifications are being switched ON, every stream the
   * channel currently has is stored first so the user is never notified about them.
   */
  async updateNotificationMode(serviceId: number, url: string,
    mode: NotificationMode): Promise<void> {
    const entity: SubscriptionEntity | null =
      await SubscriptionDao.getSubscription(this.database, serviceId, url);
    if (entity === null) {
      return;
    }
    entity.notificationMode = mode;
    await SubscriptionDao.update(this.database, entity);

    if (mode !== NotificationMode.DISABLED) {
      await this.rememberAllStreams(entity);
    }
    this.notifyChanged();
  }

  /** Port of updateFromInfo(): only the fields a feed update actually carries are overwritten. */
  async updateFromInfo(subscriptionId: number, name: string, avatarUrl: string | null,
    description: string | null, subscriberCount: number | null): Promise<void> {
    const entity: SubscriptionEntity | null =
      await SubscriptionDao.getSubscriptionById(this.database, subscriptionId);
    if (entity === null) {
      return;
    }
    entity.name = name;
    // Some services do not provide an avatar URL.
    if (avatarUrl !== null) {
      entity.avatarUrl = avatarUrl;
    }
    // These two are null when the feed info was fetched with the fast feed method.
    if (description !== null) {
      entity.description = description;
    }
    if (subscriberCount !== null) {
      entity.subscriberCount = subscriberCount;
    }
    await SubscriptionDao.update(this.database, entity);
  }

  /** Port of deleteSubscription(serviceId, url). */
  async deleteSubscription(serviceId: number, url: string): Promise<number> {
    const deleted: number =
      await SubscriptionDao.deleteSubscription(this.database, serviceId, url);
    this.notifyChanged();
    return deleted;
  }

  /** Port of insertSubscription(). */
  async insertSubscription(entity: SubscriptionEntity): Promise<number> {
    const uid: number = await SubscriptionDao.insert(this.database, entity);
    this.notifyChanged();
    return uid;
  }

  /**
   * Port of rememberAllStreams(): fetches the channel's current streams and stores them, so they
   * count as "already seen". Failures are swallowed, exactly as onErrorComplete() does.
   */
  private async rememberAllStreams(subscription: SubscriptionEntity): Promise<void> {
    try {
      const url: string = subscription.url as string;
      const info: ChannelInfo =
        await ExtractorHelper.getChannelInfo(subscription.serviceId, url, false);
      if (info.tabs.length === 0) {
        return;
      }
      const channel: ChannelTabInfo =
        await ExtractorHelper.getChannelTab(subscription.serviceId, info.tabs[0], false);
      const entities: StreamEntity[] = SubscriptionManager.onlyStreams(channel)
        .map((item: StreamInfoItem): StreamEntity => StreamEntity.fromInfoItem(item));
      await StreamDao.upsertAll(this.database, entities);
    } catch (error) {
      // onErrorComplete(): remembering the streams is best-effort.
    }
  }

  /** Port of `relatedItems.filterIsInstance<StreamInfoItem>()` — a tab also lists non-streams. */
  private static onlyStreams(tab: ChannelTabInfo): StreamInfoItem[] {
    const streams: StreamInfoItem[] = [];
    for (const item of tab.relatedItems) {
      if (item instanceof StreamInfoItem) {
        streams.push(item);
      }
    }
    return streams;
  }

  // ///////////////////////////////////////////////////////////////////////////
  // Import — SubscriptionImportWorker's three input modes
  // ///////////////////////////////////////////////////////////////////////////

  /**
   * Endpoint subscription_import_channel_url — port of SubscriptionImportWorker's
   * ChannelUrlMode: the service turns a channel/user URL into the subscription list behind it
   * (a YouTube channel URL, a SoundCloud user page, ...).
   */
  async importFromChannelUrl(serviceId: number, url: string): Promise<SubscriptionItem[]> {
    return ExtractorHelper.getSubscriptionsFromChannelUrl(serviceId, url);
  }

  /**
   * Endpoint subscription_import_file — port of SubscriptionImportWorker's InputStreamMode and
   * PreviousExportMode: either a service's own export file, or a file this app exported before.
   *
   * @param serviceId the service the file belongs to
   * @param fileUri the URI DocumentViewPicker returned (contract §2.4 — there is no raw file path)
   * @param contentType the file's MIME type, or null for a previous NewPipe export
   */
  async importFromFile(serviceId: number, fileUri: string,
    contentType: string | null): Promise<SubscriptionItem[]> {
    if (contentType === null) {
      // A previous NewPipe export is always JSON text.
      const content: string = await SubscriptionManager.readTextFile(fileUri);
      return SubscriptionManager.readPreviousExport(content);
    }
    // A service export may be a ZIP (Google Takeout), which has no text form — hand the URI
    // over so the extractor reads it as bytes and unzips it.
    return ExtractorHelper.getSubscriptionsFromFileUri(serviceId, fileUri, contentType);
  }

  /**
   * Port of SubscriptionImportWorker.doWork(): resolves every item to a channel plus its first
   * tab and stores them. Items that fail are skipped, as in the source.
   *
   * @param onProgress the worker's setForeground(createForegroundInfo(title, name, index)): called
   *                   after each item with how many are done and the channel just resolved
   * @param isCancelled the notification's Cancel: checked before each item; what was resolved
   *                    up to then is still stored
   */
  async importSubscriptions(items: SubscriptionItem[],
    onProgress?: (done: number, channelName: string) => void,
    isCancelled?: () => boolean): Promise<number> {
    const resolved: ChannelWithTab[] = [];
    let done: number = 0;
    for (const item of items) {
      if (isCancelled !== undefined && isCancelled()) {
        break;
      }
      done++;
      try {
        const channelInfo: ChannelInfo =
          await ExtractorHelper.getChannelInfo(item.serviceId, item.url, true);
        let channelTab: ChannelTabInfo | null = null;
        if (channelInfo.tabs.length !== 0) {
          channelTab = await ExtractorHelper.getChannelTab(item.serviceId, channelInfo.tabs[0],
            true);
        }
        resolved.push(new ChannelWithTab(channelInfo, channelTab));
        if (onProgress !== undefined) {
          onProgress(done, channelInfo.getName());
        }
      } catch (error) {
        // "Failed to fetch subscription" — the source logs and moves on.
      }
    }
    await this.upsertAll(resolved);
    return resolved.length;
  }

  /** Port of ImportExportJsonHelper.readFrom(). */
  static readPreviousExport(json: string): SubscriptionItem[] {
    const data: SubscriptionData = JSON.parse(json) as SubscriptionData;
    if (data === null || data.subscriptions === undefined) {
      throw new Error("Couldn't parse json");
    }
    return data.subscriptions;
  }

  /** Port of ImportExportJsonHelper.writeTo(). */
  static writePreviousExport(items: SubscriptionItem[], appVersion: string,
    appVersionInt: number): string {
    const data: SubscriptionData = new SubscriptionData(items, appVersion, appVersionInt);
    return JSON.stringify(data);
  }

  /** Reads the whole picked file; the file handle is always closed (Rule 8). */
  private static async readTextFile(fileUri: string): Promise<string> {
    const file: fileIo.File = await fileIo.open(fileUri, fileIo.OpenMode.READ_ONLY);
    try {
      const stat: fileIo.Stat = await fileIo.stat(file.fd);
      const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
      const read: number = await fileIo.read(file.fd, buffer);
      const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
      return decoder.decodeToString(new Uint8Array(buffer, 0, read));
    } finally {
      await fileIo.close(file);
    }
  }
}
