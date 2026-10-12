/*
 * svc_history_record_manager — port of org.schabi.newpipe.local.history.HistoryRecordManager.
 *
 * Also carries StreamDao and StreamStateDao, the ports of StreamDAO / StreamStateDAO: the source
 * hands both to HistoryRecordManager, and the playlist, subscription and feed managers use the
 * same upsert path, so they live here rather than being duplicated per manager.
 *
 * Concurrency (phase2-logic-contract §1): every DAO read/write is one-shot, so Single/Maybe/
 * Completable all become Promises. Schedulers.io() is identity — relationalStore is already async.
 * Rule 8: every ResultSet is closed by AppDatabase.query/queryFirst/queryNumber in a finally.
 */

import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { AppDatabase, colNumber, colNumberOrNull, colStringOrNull } from './AppDatabase';
import { StreamEntity, isLiveStreamType, streamTypeFromDb } from '../../model/db/entity/StreamEntity';
import { StreamHistoryEntity } from '../../model/db/entity/StreamHistoryEntity';
import { StreamStateEntity } from '../../model/db/entity/StreamStateEntity';
import { SearchHistoryEntry } from '../../model/db/entity/SearchHistoryEntry';
import { PlaylistStreamEntry } from '../../model/db/view/PlaylistStreamEntry';
import { StreamHistoryEntry } from '../../model/db/view/StreamHistoryEntry';
import { StreamStatisticsEntry } from '../../model/db/view/StreamStatisticsEntry';
import { PlaylistStreamEntity } from '../../model/db/entity/PlaylistStreamEntity';
import { StreamType } from '../../model/enums/StreamType';
import { LocalItem } from '../../model/enums/LocalItemLocalItemType';
import { StreamInfo } from '../../model/extractor/StreamInfo';
import { StreamInfoItem } from '../../model/extractor/StreamInfoItem';
import { PlayQueueItem } from '../../model/app/PlayQueueItem';
import { ExtractorHelper } from '../extractor/ExtractorHelper';
import { Preferences } from '../prefs/Preferences';
import { enable_search_history_key, enable_watch_history_key } from '../prefs/SettingsKeys';

/** The subset of a `streams` row StreamDAO.getMinimalStreamForCompare() selects. */
class StreamCompareFeed {
  uid: number;
  streamType: StreamType;
  textualUploadDate: string | null;
  uploadDate: number | null;
  isUploadDateApproximation: boolean | null;
  duration: number;

  constructor(uid: number, streamType: StreamType, textualUploadDate: string | null,
    uploadDate: number | null, isUploadDateApproximation: boolean | null, duration: number) {
    this.uid = uid;
    this.streamType = streamType;
    this.textualUploadDate = textualUploadDate;
    this.uploadDate = uploadDate;
    this.isUploadDateApproximation = isUploadDateApproximation;
    this.duration = duration;
  }
}

/** Port of org.schabi.newpipe.database.stream.dao.StreamDAO. */
export class StreamDao {

  /** Port of StreamDAO.upsert(): insert, or reconcile with the existing row and update it. */
  static async upsert(db: AppDatabase, newerStream: StreamEntity): Promise<number> {
    const uid: number = await db.insert(StreamEntity.TABLE, newerStream.toValuesBucket(),
      relationalStore.ConflictResolution.ON_CONFLICT_IGNORE);
    if (uid !== -1) {
      newerStream.uid = uid;
      return uid;
    }

    await StreamDao.compareAndUpdateStream(db, newerStream);
    await StreamDao.update(db, newerStream);
    return newerStream.uid;
  }

  /** Port of StreamDAO.upsertAll(). */
  static async upsertAll(db: AppDatabase, streams: StreamEntity[]): Promise<number[]> {
    const streamIds: number[] = [];
    for (const stream of streams) {
      streamIds.push(await StreamDao.upsert(db, stream));
    }
    return streamIds;
  }

  /**
   * Port of StreamDAO.compareAndUpdateStream(): keep the stored upload date when the newer one is
   * only an approximation, and keep the stored duration when the newer one has none.
   */
  private static async compareAndUpdateStream(db: AppDatabase,
    newerStream: StreamEntity): Promise<void> {
    const existent: StreamCompareFeed | null = await db.queryFirst<StreamCompareFeed>(
      'SELECT uid, stream_type, textual_upload_date, upload_date, ' +
      'is_upload_date_approximation, duration FROM streams WHERE url = ? AND service_id = ?',
      [newerStream.url, newerStream.serviceId],
      (rs: relationalStore.ResultSet): StreamCompareFeed => {
        const approximation: number | null = colNumberOrNull(rs, 'is_upload_date_approximation');
        return new StreamCompareFeed(
          colNumber(rs, 'uid'),
          streamTypeFromDb(rs.getString(rs.getColumnIndex('stream_type'))),
          colStringOrNull(rs, 'textual_upload_date'),
          colNumberOrNull(rs, 'upload_date'),
          approximation === null ? null : approximation !== 0,
          colNumber(rs, 'duration')
        );
      });

    if (existent === null) {
      throw new Error('Stream cannot be null just after insertion.');
    }
    newerStream.uid = existent.uid;

    if (isLiveStreamType(newerStream.streamType)) {
      return;
    }

    const hasBetterPrecision: boolean =
      newerStream.uploadDate !== null && newerStream.isUploadDateApproximation !== true;
    if (existent.uploadDate !== null && !hasBetterPrecision) {
      newerStream.uploadDate = existent.uploadDate;
      newerStream.textualUploadDate = existent.textualUploadDate;
      newerStream.isUploadDateApproximation = existent.isUploadDateApproximation;
    }

    if (existent.duration > 0 && newerStream.duration < 0) {
      newerStream.duration = existent.duration;
    }
  }

  /** Port of the inherited BasicDAO.update(entity). */
  static async update(db: AppDatabase, stream: StreamEntity): Promise<number> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(StreamEntity.TABLE);
    predicates.equalTo('uid', stream.uid);
    return db.update(stream.toValuesBucket(), predicates);
  }

  /** Port of StreamDAO.exists(). */
  static async exists(db: AppDatabase, serviceId: number, url: string): Promise<boolean> {
    const count: number = await db.queryNumber(
      'SELECT COUNT(*) FROM streams WHERE url = ? AND service_id = ?', [url, serviceId], 0);
    return count !== 0;
  }

  /** Port of StreamDAO.getStream(). */
  static async getStream(db: AppDatabase, serviceId: number, url: string): Promise<StreamEntity[]> {
    return db.query<StreamEntity>('SELECT * FROM streams WHERE url = ? AND service_id = ?',
      [url, serviceId], StreamEntity.fromRow);
  }

  /** Port of StreamDAO.setUploaderUrl(). */
  static async setUploaderUrl(db: AppDatabase, serviceId: number, url: string,
    uploaderUrl: string): Promise<void> {
    await db.execute(
      'UPDATE streams SET uploader_url = ? WHERE url = ? AND service_id = ?',
      [uploaderUrl, url, serviceId]);
  }

  /** Port of StreamDAO.deleteOrphans(): streams no history, playlist or feed row references. */
  static async deleteOrphans(db: AppDatabase): Promise<number> {
    return db.executeAndCount(
      'DELETE FROM streams WHERE ' +
      'NOT EXISTS (SELECT 1 FROM stream_history sh WHERE sh.stream_id = streams.uid) ' +
      'AND NOT EXISTS (SELECT 1 FROM playlist_stream_join ps WHERE ps.stream_id = streams.uid) ' +
      'AND NOT EXISTS (SELECT 1 FROM feed f WHERE f.stream_id = streams.uid)', []);
  }
}

/** Port of org.schabi.newpipe.database.stream.dao.StreamStateDAO. */
export class StreamStateDao {

  /** Port of StreamStateDAO.getState(). */
  static async getState(db: AppDatabase, streamId: number): Promise<StreamStateEntity[]> {
    return db.query<StreamStateEntity>('SELECT * FROM stream_state WHERE stream_id = ?',
      [streamId], StreamStateEntity.fromRow);
  }

  /** Port of StreamStateDAO.upsert(): silent insert, then update. */
  static async upsert(db: AppDatabase, state: StreamStateEntity): Promise<number> {
    await db.insert(StreamStateEntity.TABLE, state.toValuesBucket(),
      relationalStore.ConflictResolution.ON_CONFLICT_IGNORE);
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(StreamStateEntity.TABLE);
    predicates.equalTo('stream_id', state.streamUid);
    return db.update(state.toValuesBucket(), predicates);
  }

  /** Port of StreamStateDAO.deleteState(). */
  static async deleteState(db: AppDatabase, streamId: number): Promise<number> {
    return db.executeAndCount('DELETE FROM stream_state WHERE stream_id = ?', [streamId]);
  }

  /** Port of StreamStateDAO.deleteAll(). */
  static async deleteAll(db: AppDatabase): Promise<number> {
    return db.executeAndCount('DELETE FROM stream_state', []);
  }
}

/**
 * Port of HistoryRecordManager: watch history, search history and playback positions.
 */
export class HistoryRecordManager {
  private readonly database: AppDatabase;

  constructor(database: AppDatabase) {
    this.database = database;
  }

  static async of(context: common.Context): Promise<HistoryRecordManager> {
    return new HistoryRecordManager(await AppDatabase.getInstance(context));
  }

  // ///////////////////////////////////////////////////////////////////////////
  // Watch history
  // ///////////////////////////////////////////////////////////////////////////

  /**
   * Port of markAsWatched(StreamInfoItem): hides the item from the feed when played items are
   * hidden, by adding a history entry and setting the progress to 100%.
   *
   * @returns the id of the inserted history row, or null when watch history is disabled
   */
  async markAsWatched(info: StreamInfoItem): Promise<number | null> {
    if (!await this.isStreamHistoryEnabled()) {
      return null;
    }

    const currentTime: number = Date.now();
    return this.database.runInTransaction<number>(async (): Promise<number> => {
      let streamId: number;
      let duration: number;
      // The duration is missing when the item was loaded in fast mode, so fetch it.
      if (info.duration < 0) {
        const completeInfo: StreamInfo =
          await ExtractorHelper.getStreamInfo(info.serviceId, info.url, false);
        duration = completeInfo.duration;
        streamId = await StreamDao.upsert(this.database, StreamEntity.fromStreamInfo(completeInfo));
      } else {
        duration = info.duration;
        streamId = await StreamDao.upsert(this.database, StreamEntity.fromInfoItem(info));
      }

      await StreamStateDao.upsert(this.database,
        new StreamStateEntity(streamId, duration * 1000));

      const latestEntry: StreamHistoryEntity | null =
        await this.getLatestHistoryEntry(streamId);
      if (latestEntry === null) {
        // never actually viewed: add a history entry, but with 0 views
        return this.insertHistoryEntry(new StreamHistoryEntity(streamId, currentTime, 0));
      }
      return 0;
    });
  }

  /** Port of onViewed(StreamInfo): bumps the repeat count, or records the first view. */
  async onViewed(info: StreamInfo): Promise<number | null> {
    if (!await this.isStreamHistoryEnabled()) {
      return null;
    }

    const currentTime: number = Date.now();
    return this.database.runInTransaction<number>(async (): Promise<number> => {
      const streamId: number =
        await StreamDao.upsert(this.database, StreamEntity.fromStreamInfo(info));
      const latestEntry: StreamHistoryEntity | null = await this.getLatestHistoryEntry(streamId);

      if (latestEntry !== null) {
        await this.deleteHistoryEntry(latestEntry);
        latestEntry.accessDate = currentTime;
        latestEntry.repeatCount = latestEntry.repeatCount + 1;
        return this.insertHistoryEntry(latestEntry);
      }
      // just viewed for the first time: set 1 view
      return this.insertHistoryEntry(new StreamHistoryEntity(streamId, currentTime, 1));
    });
  }

  /** Port of deleteStreamHistoryAndState(). */
  async deleteStreamHistoryAndState(streamId: number): Promise<void> {
    await StreamStateDao.deleteState(this.database, streamId);
    await this.database.execute('DELETE FROM stream_history WHERE stream_id = ?', [streamId]);
  }

  /** Port of deleteWholeStreamHistory(). */
  async deleteWholeStreamHistory(): Promise<number> {
    return this.database.executeAndCount('DELETE FROM stream_history', []);
  }

  /** Port of deleteCompleteStreamStateHistory(). */
  async deleteCompleteStreamStateHistory(): Promise<number> {
    return StreamStateDao.deleteAll(this.database);
  }

  /** Port of StreamHistoryDAO.getHistory(): newest first. */
  async getStreamHistory(): Promise<StreamHistoryEntry[]> {
    return this.database.query<StreamHistoryEntry>(
      'SELECT * FROM streams INNER JOIN stream_history ON uid = stream_id ' +
      'ORDER BY access_date DESC', [], StreamHistoryEntry.fromRow);
  }

  /** Port of getStreamHistorySortedById(). */
  async getStreamHistorySortedById(): Promise<StreamHistoryEntry[]> {
    return this.database.query<StreamHistoryEntry>(
      'SELECT * FROM streams INNER JOIN stream_history ON uid = stream_id ORDER BY uid ASC',
      [], StreamHistoryEntry.fromRow);
  }

  /** Port of getStreamStatistics(): the "most played" / "last played" list. */
  async getStreamStatistics(): Promise<StreamStatisticsEntry[]> {
    return this.database.query<StreamStatisticsEntry>(
      'SELECT * FROM streams ' +
      'INNER JOIN (' +
      '  SELECT stream_id, MAX(access_date) AS latestAccess, SUM(repeat_count) AS watchCount ' +
      '  FROM stream_history GROUP BY stream_id' +
      ') ON uid = stream_id ' +
      'LEFT JOIN (SELECT stream_id AS stream_id_alias, progress_time FROM stream_state) ' +
      'ON uid = stream_id_alias', [], StreamStatisticsEntry.fromRow);
  }

  /** Port of StreamHistoryDAO.getLatestEntry(). */
  private async getLatestHistoryEntry(streamId: number): Promise<StreamHistoryEntity | null> {
    return this.database.queryFirst<StreamHistoryEntity>(
      'SELECT * FROM stream_history WHERE stream_id = ? ORDER BY access_date DESC LIMIT 1',
      [streamId], StreamHistoryEntity.fromRow);
  }

  private async insertHistoryEntry(entity: StreamHistoryEntity): Promise<number> {
    return this.database.insert(StreamHistoryEntity.TABLE, entity.toValuesBucket(),
      relationalStore.ConflictResolution.ON_CONFLICT_NONE);
  }

  /** Port of the inherited BasicDAO.delete(entity) — the primary key is (stream_id, access_date). */
  private async deleteHistoryEntry(entity: StreamHistoryEntity): Promise<void> {
    await this.database.execute(
      'DELETE FROM stream_history WHERE stream_id = ? AND access_date = ?',
      [entity.streamUid, entity.accessDate]);
  }

  private async isStreamHistoryEnabled(): Promise<boolean> {
    // NewPipeSettings.initSettings() runs PreferenceManager.setDefaultValues(context,
    // R.xml.history_settings, true) on first launch, and history_settings.xml declares
    // android:defaultValue="true" for this key — so the Java literal `false` in
    // HistoryRecordManager is only ever read when the seeded value is missing, which on
    // Android it never is. Porting the literal without the XML seeding switched history
    // recording OFF for the whole app.
    return Preferences.getBoolean(enable_watch_history_key, true);
  }

  // ///////////////////////////////////////////////////////////////////////////
  // Search history
  // ///////////////////////////////////////////////////////////////////////////

  /** Port of onSearched(): refreshes the latest entry when it is the same search, else inserts. */
  async onSearched(serviceId: number, search: string): Promise<number | null> {
    if (!await this.isSearchHistoryEnabled()) {
      return null;
    }

    const currentTime: number = Date.now();
    const newEntry: SearchHistoryEntry = new SearchHistoryEntry(currentTime, serviceId, search);

    return this.database.runInTransaction<number>(async (): Promise<number> => {
      const latestEntry: SearchHistoryEntry | null =
        await this.database.queryFirst<SearchHistoryEntry>(
          'SELECT * FROM search_history WHERE id = (SELECT MAX(id) FROM search_history)',
          [], SearchHistoryEntry.fromRow);

      if (latestEntry !== null && latestEntry.hasEqualValues(newEntry)) {
        latestEntry.creationDate = currentTime;
        return this.database.executeAndCount(
          'UPDATE search_history SET creation_date = ? WHERE id = ?',
          [currentTime, latestEntry.id]);
      }
      return this.database.insert(SearchHistoryEntry.TABLE, newEntry.toValuesBucket(),
        relationalStore.ConflictResolution.ON_CONFLICT_NONE);
    });
  }

  /** Port of deleteSearchHistory(String). */
  async deleteSearchHistory(search: string): Promise<number> {
    return this.database.executeAndCount('DELETE FROM search_history WHERE search = ?', [search]);
  }

  /** Port of deleteCompleteSearchHistory(). */
  async deleteCompleteSearchHistory(): Promise<number> {
    return this.database.executeAndCount('DELETE FROM search_history', []);
  }

  /**
   * Port of getRelatedSearches(): the searches starting with the query, or — for an empty query —
   * the most recent distinct searches.
   */
  async getRelatedSearches(query: string, similarQueryLimit: number,
    uniqueQueryLimit: number): Promise<string[]> {
    if (query.length > 0) {
      return this.database.queryStrings(
        "SELECT search FROM search_history WHERE search LIKE ? || '%' " +
        'GROUP BY search ORDER BY MAX(creation_date) DESC LIMIT ?', [query, similarQueryLimit]);
    }
    return this.database.queryStrings(
      'SELECT search FROM search_history GROUP BY search ORDER BY MAX(creation_date) DESC ' +
      'LIMIT ?', [uniqueQueryLimit]);
  }

  private async isSearchHistoryEnabled(): Promise<boolean> {
    // NewPipeSettings.initSettings() runs PreferenceManager.setDefaultValues(context,
    // R.xml.history_settings, true) on first launch, and history_settings.xml declares
    // android:defaultValue="true" for this key — so the Java literal `false` in
    // HistoryRecordManager is only ever read when the seeded value is missing, which on
    // Android it never is. Porting the literal without the XML seeding switched history
    // recording OFF for the whole app.
    return Preferences.getBoolean(enable_search_history_key, true);
  }

  // ///////////////////////////////////////////////////////////////////////////
  // Playback positions
  // ///////////////////////////////////////////////////////////////////////////

  /** Port of loadStreamState(PlayQueueItem). */
  async loadStreamStateOfQueueItem(queueItem: PlayQueueItem): Promise<StreamStateEntity | null> {
    const info: StreamInfo = await queueItem.getStream();
    const streamId: number =
      await StreamDao.upsert(this.database, StreamEntity.fromStreamInfo(info));
    return this.firstValidState(streamId, queueItem.duration);
  }

  /** Port of loadStreamState(StreamInfo). */
  async loadStreamStateOfInfo(info: StreamInfo): Promise<StreamStateEntity | null> {
    const streamId: number =
      await StreamDao.upsert(this.database, StreamEntity.fromStreamInfo(info));
    return this.firstValidState(streamId, info.duration);
  }

  /**
   * Port of loadStreamState(InfoItem): unlike the two above this never inserts the stream, so an
   * item that was never played simply has no state.
   */
  async loadStreamStateOfInfoItem(info: StreamInfoItem): Promise<StreamStateEntity | null> {
    const entities: StreamEntity[] =
      await StreamDao.getStream(this.database, info.serviceId, info.url);
    if (entities.length === 0) {
      return null;
    }
    const states: StreamStateEntity[] =
      await StreamStateDao.getState(this.database, entities[0].uid);
    return states.length === 0 ? null : states[0];
  }

  /** Port of saveStreamState(): only a state the stream's duration makes valid is stored. */
  async saveStreamState(info: StreamInfo, progressMillis: number): Promise<void> {
    await this.database.runInTransaction<void>(async (): Promise<void> => {
      const streamId: number =
        await StreamDao.upsert(this.database, StreamEntity.fromStreamInfo(info));
      const state: StreamStateEntity = new StreamStateEntity(streamId, progressMillis);
      if (state.isValid(info.duration)) {
        await StreamStateDao.upsert(this.database, state);
      }
    });
  }

  /**
   * Port of loadLocalStreamStateBatch(): one state per item, in the same order, with null where
   * the item has no state or is not a stream row.
   */
  async loadLocalStreamStateBatch(items: LocalItem[]): Promise<Array<StreamStateEntity | null>> {
    const result: Array<StreamStateEntity | null> = [];
    for (const item of items) {
      let streamId: number = -1;
      if (item instanceof StreamStatisticsEntry) {
        streamId = item.streamId;
      } else if (item instanceof PlaylistStreamEntity) {
        streamId = item.streamUid;
      } else if (item instanceof PlaylistStreamEntry) {
        streamId = item.streamId;
      } else {
        result.push(null);
        continue;
      }
      const states: StreamStateEntity[] = await StreamStateDao.getState(this.database, streamId);
      result.push(states.length === 0 ? null : states[0]);
    }
    return result;
  }

  private async firstValidState(streamId: number,
    durationInSeconds: number): Promise<StreamStateEntity | null> {
    const states: StreamStateEntity[] = await StreamStateDao.getState(this.database, streamId);
    if (states.length === 0) {
      return null;
    }
    return states[0].isValid(durationInSeconds) ? states[0] : null;
  }

  // ///////////////////////////////////////////////////////////////////////////
  // Utility
  // ///////////////////////////////////////////////////////////////////////////

  /** Port of removeOrphanedRecords(). */
  async removeOrphanedRecords(): Promise<number> {
    return StreamDao.deleteOrphans(this.database);
  }
}
