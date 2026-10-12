/*
 * svc_database — port of org.schabi.newpipe.database.AppDatabase + NewPipeDatabase (NewPipe app).
 *
 * Room is mapped to @kit.ArkData relationalStore (dependency-decisions.json: androidx.room:* ->
 * native). The DDL below is the schema Room generates at version 9 (Migrations.DB_VER_9), taken
 * verbatim from Migrations.kt's hardcoded statements plus the ALTER COLUMN migrations 3->9 already
 * folded in, so a fresh store is created directly at v9.
 *
 * The Room @TypeConverters (Converters.kt) become plain column types here:
 *   OffsetDateTime <-> INTEGER  epoch milliseconds, UTC   (offsetDateTime{From,To}Timestamp)
 *   StreamType     <-> TEXT     the enum member name      (streamTypeOf / stringOf)
 *   FeedGroupIcon  <-> INTEGER  the icon id               (integerOf / feedGroupIconOf)
 *
 * Rule 8: every ResultSet opened here is closed in a finally block.
 */

import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

/** The v9 schema. Order matters: a table is created after the tables its foreign keys reference. */
const SCHEMA_V9: string[] = [
  'CREATE TABLE IF NOT EXISTS `subscriptions` ' +
    '(`uid` INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, `service_id` INTEGER NOT NULL, ' +
    '`url` TEXT, `name` TEXT, `avatar_url` TEXT, `subscriber_count` INTEGER, ' +
    '`description` TEXT, `notification_mode` INTEGER NOT NULL DEFAULT 0)',
  'CREATE UNIQUE INDEX IF NOT EXISTS `index_subscriptions_service_id_url` ' +
    'ON `subscriptions` (`service_id`, `url`)',

  'CREATE TABLE IF NOT EXISTS `search_history` ' +
    '(`id` INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, `creation_date` INTEGER, ' +
    '`service_id` INTEGER NOT NULL, `search` TEXT)',
  'CREATE INDEX IF NOT EXISTS `index_search_history_search` ON `search_history` (`search`)',

  'CREATE TABLE IF NOT EXISTS `streams` ' +
    '(`uid` INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, `service_id` INTEGER NOT NULL, ' +
    '`url` TEXT NOT NULL, `title` TEXT NOT NULL, `stream_type` TEXT NOT NULL, ' +
    '`duration` INTEGER NOT NULL, `uploader` TEXT NOT NULL, `uploader_url` TEXT, ' +
    '`thumbnail_url` TEXT, `view_count` INTEGER, `textual_upload_date` TEXT, ' +
    '`upload_date` INTEGER, `is_upload_date_approximation` INTEGER)',
  'CREATE UNIQUE INDEX IF NOT EXISTS `index_streams_service_id_url` ' +
    'ON `streams` (`service_id`, `url`)',

  'CREATE TABLE IF NOT EXISTS `stream_history` ' +
    '(`stream_id` INTEGER NOT NULL, `access_date` INTEGER NOT NULL, ' +
    '`repeat_count` INTEGER NOT NULL, PRIMARY KEY(`stream_id`, `access_date`), ' +
    'FOREIGN KEY(`stream_id`) REFERENCES `streams`(`uid`) ' +
    'ON UPDATE CASCADE ON DELETE CASCADE )',
  'CREATE INDEX IF NOT EXISTS `index_stream_history_stream_id` ' +
    'ON `stream_history` (`stream_id`)',

  'CREATE TABLE IF NOT EXISTS `stream_state` ' +
    '(`stream_id` INTEGER NOT NULL, `progress_time` INTEGER NOT NULL, ' +
    'PRIMARY KEY(`stream_id`), FOREIGN KEY(`stream_id`) REFERENCES `streams`(`uid`) ' +
    'ON UPDATE CASCADE ON DELETE CASCADE )',

  'CREATE TABLE IF NOT EXISTS `playlists` ' +
    '(`uid` INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, `name` TEXT, ' +
    '`is_thumbnail_permanent` INTEGER NOT NULL, `thumbnail_stream_id` INTEGER NOT NULL, ' +
    '`display_index` INTEGER NOT NULL)',

  'CREATE TABLE IF NOT EXISTS `playlist_stream_join` ' +
    '(`playlist_id` INTEGER NOT NULL, `stream_id` INTEGER NOT NULL, ' +
    '`join_index` INTEGER NOT NULL, PRIMARY KEY(`playlist_id`, `join_index`), ' +
    'FOREIGN KEY(`playlist_id`) REFERENCES `playlists`(`uid`) ' +
    'ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, ' +
    'FOREIGN KEY(`stream_id`) REFERENCES `streams`(`uid`) ' +
    'ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED)',
  'CREATE UNIQUE INDEX IF NOT EXISTS ' +
    '`index_playlist_stream_join_playlist_id_join_index` ' +
    'ON `playlist_stream_join` (`playlist_id`, `join_index`)',
  'CREATE INDEX IF NOT EXISTS `index_playlist_stream_join_stream_id` ' +
    'ON `playlist_stream_join` (`stream_id`)',

  'CREATE TABLE IF NOT EXISTS `remote_playlists` ' +
    '(`uid` INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, `service_id` INTEGER NOT NULL, ' +
    '`name` TEXT, `url` TEXT, `thumbnail_url` TEXT, `uploader` TEXT, ' +
    '`display_index` INTEGER NOT NULL, `stream_count` INTEGER)',
  'CREATE UNIQUE INDEX IF NOT EXISTS `index_remote_playlists_service_id_url` ' +
    'ON `remote_playlists` (`service_id`, `url`)',

  'CREATE TABLE IF NOT EXISTS `feed` ' +
    '(`stream_id` INTEGER NOT NULL, `subscription_id` INTEGER NOT NULL, ' +
    'PRIMARY KEY(`stream_id`, `subscription_id`), ' +
    'FOREIGN KEY(`stream_id`) REFERENCES `streams`(`uid`) ' +
    'ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, ' +
    'FOREIGN KEY(`subscription_id`) REFERENCES `subscriptions`(`uid`) ' +
    'ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED)',
  'CREATE INDEX IF NOT EXISTS `index_feed_subscription_id` ON `feed` (`subscription_id`)',

  'CREATE TABLE IF NOT EXISTS `feed_group` ' +
    '(`uid` INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, `name` TEXT NOT NULL, ' +
    '`icon_id` INTEGER NOT NULL, `sort_order` INTEGER NOT NULL)',
  'CREATE INDEX IF NOT EXISTS `index_feed_group_sort_order` ON `feed_group` (`sort_order`)',

  'CREATE TABLE IF NOT EXISTS `feed_group_subscription_join` ' +
    '(`group_id` INTEGER NOT NULL, `subscription_id` INTEGER NOT NULL, ' +
    'PRIMARY KEY(`group_id`, `subscription_id`), ' +
    'FOREIGN KEY(`group_id`) REFERENCES `feed_group`(`uid`) ' +
    'ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED, ' +
    'FOREIGN KEY(`subscription_id`) REFERENCES `subscriptions`(`uid`) ' +
    'ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED)',
  'CREATE INDEX IF NOT EXISTS `index_feed_group_subscription_join_subscription_id` ' +
    'ON `feed_group_subscription_join` (`subscription_id`)',

  'CREATE TABLE IF NOT EXISTS `feed_last_updated` ' +
    '(`subscription_id` INTEGER NOT NULL, `last_updated` INTEGER, ' +
    'PRIMARY KEY(`subscription_id`), FOREIGN KEY(`subscription_id`) ' +
    'REFERENCES `subscriptions`(`uid`) ' +
    'ON UPDATE CASCADE ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED)'
];

/** The finished-missions schema, from us.shandian.giga.get.sqlite.FinishedMissionStore. */
const DOWNLOADS_SCHEMA_V4: string[] = [
  'CREATE TABLE IF NOT EXISTS `finished_missions` (' +
    '`path` TEXT NOT NULL, `url` TEXT NOT NULL, `bytes_downloaded` INTEGER NOT NULL, ' +
    '`timestamp` INTEGER NOT NULL, `kind` TEXT NOT NULL, ' +
    'UNIQUE(`timestamp`, `path`))'
];

// ---------------------------------------------------------------------------------------------
// ResultSet column readers. Every read goes through these so a NULL column can never silently
// become 0 or "".
// ---------------------------------------------------------------------------------------------

export function colString(rs: relationalStore.ResultSet, name: string): string {
  return rs.getString(rs.getColumnIndex(name));
}

export function colStringOrNull(rs: relationalStore.ResultSet, name: string): string | null {
  const index: number = rs.getColumnIndex(name);
  return rs.isColumnNull(index) ? null : rs.getString(index);
}

export function colNumber(rs: relationalStore.ResultSet, name: string): number {
  return rs.getLong(rs.getColumnIndex(name));
}

export function colNumberOrNull(rs: relationalStore.ResultSet, name: string): number | null {
  const index: number = rs.getColumnIndex(name);
  return rs.isColumnNull(index) ? null : rs.getLong(index);
}

export function colBoolean(rs: relationalStore.ResultSet, name: string): boolean {
  return rs.getLong(rs.getColumnIndex(name)) !== 0;
}

export function colBooleanOrNull(rs: relationalStore.ResultSet, name: string): boolean | null {
  const index: number = rs.getColumnIndex(name);
  return rs.isColumnNull(index) ? null : rs.getLong(index) !== 0;
}

/** Maps one already-positioned row. */
export type RowMapper<T> = (rs: relationalStore.ResultSet) => T;

/**
 * The NewPipe database. One instance per process, exactly like NewPipeDatabase.getInstance().
 */
export class AppDatabase {
  static readonly DATABASE_NAME: string = 'newpipe.db';
  static readonly DB_VERSION: number = 9;

  private static instance: AppDatabase | null = null;
  private static opening: Promise<AppDatabase> | null = null;

  private readonly store: relationalStore.RdbStore;

  /**
   * The transaction opened by runInTransaction(), or null outside one.
   *
   * Room runs an @Transaction body on ONE connection, so a statement reads back what the same
   * transaction just wrote. relationalStore does NOT: the store keeps one write connection and a
   * pool of read connections, and in WAL mode a read connection only ever sees the last COMMITTED
   * snapshot. Routing every statement of a transaction through this object is what restores
   * Room's read-your-own-writes; see runInTransaction().
   */
  private tx: relationalStore.Transaction | null = null;

  private constructor(store: relationalStore.RdbStore) {
    this.store = store;
  }

  static async getInstance(context: common.Context): Promise<AppDatabase> {
    if (AppDatabase.instance !== null) {
      return AppDatabase.instance;
    }
    if (AppDatabase.opening === null) {
      AppDatabase.opening = AppDatabase.open(context);
    }
    return AppDatabase.opening;
  }

  private static async open(context: common.Context): Promise<AppDatabase> {
    const config: relationalStore.StoreConfig = {
      name: AppDatabase.DATABASE_NAME,
      securityLevel: relationalStore.SecurityLevel.S1
    };
    const store: relationalStore.RdbStore = await relationalStore.getRdbStore(context, config);
    // SQLite disables foreign keys per connection; Room enables them, and the ON DELETE CASCADE
    // rules of playlist_stream_join / feed / stream_history depend on it.
    await store.executeSql('PRAGMA foreign_keys = ON');

    if (store.version !== AppDatabase.DB_VERSION) {
      for (const statement of SCHEMA_V9) {
        await store.executeSql(statement);
      }
      // No historical HarmonyOS version has ever shipped, so there is nothing to migrate from:
      // versions 1..8 only ever existed on Android. A future schema change adds its upgrade
      // steps here, keyed on the store.version it is upgrading from.
      store.version = AppDatabase.DB_VERSION;
    }

    const database: AppDatabase = new AppDatabase(store);
    AppDatabase.instance = database;
    return database;
  }

  /** UPDATE by predicates, for the rare call that cannot express itself as SQL. */
  async update(values: relationalStore.ValuesBucket, predicates: relationalStore.RdbPredicates,
    conflict?: relationalStore.ConflictResolution): Promise<number> {
    const transaction: relationalStore.Transaction | null = this.tx;
    if (transaction !== null) {
      return transaction.update(values, predicates, conflict);
    }
    return this.store.update(values, predicates, conflict);
  }

  /** Every SELECT goes through here so an open transaction reads its own uncommitted writes. */
  private async querySql(sql: string, args: relationalStore.ValueType[]):
    Promise<relationalStore.ResultSet> {
    const transaction: relationalStore.Transaction | null = this.tx;
    if (transaction !== null) {
      return transaction.querySql(sql, args);
    }
    return this.store.querySql(sql, args);
  }

  /** Runs a SELECT and maps every row. The ResultSet is always closed (Rule 8). */
  async query<T>(sql: string, args: relationalStore.ValueType[], mapper: RowMapper<T>):
    Promise<T[]> {
    const rows: T[] = [];
    const rs: relationalStore.ResultSet = await this.querySql(sql, args);
    try {
      while (rs.goToNextRow()) {
        rows.push(mapper(rs));
      }
    } finally {
      rs.close();
    }
    return rows;
  }

  /** Runs a SELECT and maps the first row, or null when there is none. */
  async queryFirst<T>(sql: string, args: relationalStore.ValueType[], mapper: RowMapper<T>):
    Promise<T | null> {
    const rs: relationalStore.ResultSet = await this.querySql(sql, args);
    try {
      return rs.goToNextRow() ? mapper(rs) : null;
    } finally {
      rs.close();
    }
  }

  /** Runs a SELECT whose first column of its first row is a number (COUNT/MIN/MAX/...). */
  async queryNumber(sql: string, args: relationalStore.ValueType[], fallback: number):
    Promise<number> {
    const rs: relationalStore.ResultSet = await this.querySql(sql, args);
    try {
      if (!rs.goToNextRow() || rs.isColumnNull(0)) {
        return fallback;
      }
      return rs.getLong(0);
    } finally {
      rs.close();
    }
  }

  /** Runs a SELECT of a single nullable number column over many rows. */
  async queryNumbers(sql: string, args: relationalStore.ValueType[]): Promise<Array<number | null>> {
    return this.query<number | null>(sql, args, (rs: relationalStore.ResultSet): number | null => {
      return rs.isColumnNull(0) ? null : rs.getLong(0);
    });
  }

  /** Runs a SELECT of a single string column. */
  async queryStrings(sql: string, args: relationalStore.ValueType[]): Promise<string[]> {
    return this.query<string>(sql, args, (rs: relationalStore.ResultSet): string => rs.getString(0));
  }

  async execute(sql: string, args: relationalStore.ValueType[]): Promise<void> {
    const transaction: relationalStore.Transaction | null = this.tx;
    if (transaction !== null) {
      await transaction.execute(sql, args);
      return;
    }
    await this.store.executeSql(sql, args);
  }

  /**
   * Runs a DELETE/UPDATE and returns the number of rows it changed, which is what the source's
   * DAO methods return (the UI shows it as "N items deleted"). SQLite's changes() reports the
   * rows changed by the most recent statement on the same connection.
   */
  async executeAndCount(sql: string, args: relationalStore.ValueType[]): Promise<number> {
    await this.execute(sql, args);
    return this.queryNumber('SELECT changes()', [], 0);
  }

  /** INSERT one row; returns the new rowId, or -1 when an IGNORE conflict dropped it. */
  async insert(table: string, values: relationalStore.ValuesBucket,
    conflict: relationalStore.ConflictResolution): Promise<number> {
    const transaction: relationalStore.Transaction | null = this.tx;
    if (transaction !== null) {
      return transaction.insert(table, values, conflict);
    }
    return this.store.insert(table, values, conflict);
  }

  async batchInsert(table: string, values: relationalStore.ValuesBucket[]): Promise<number> {
    if (values.length === 0) {
      return 0;
    }
    const transaction: relationalStore.Transaction | null = this.tx;
    if (transaction !== null) {
      return transaction.batchInsert(table, values);
    }
    return this.store.batchInsert(table, values);
  }

  /**
   * Port of AppDatabase.runInTransaction(). The work is committed on success and rolled back on
   * any error, which is then rethrown to the caller.
   *
   * createTransaction(), not beginTransaction(): the transaction object owns ONE connection, so
   * the statements this.tx routes through it read back their own uncommitted writes — the Room
   * behaviour StreamDAO.upsert() depends on (silent-insert, then re-read the conflicting row).
   * beginTransaction() writes on the store's single write connection while every SELECT is served
   * from the read pool, which in WAL mode only sees the last COMMITTED snapshot: each read-back
   * inside a transaction came up empty, so upsert() raised "Stream cannot be null after insertion"
   * and the whole feed write rolled back. IMMEDIATE matches Room's beginTransactionNonExclusive().
   *
   * An already-open transaction is JOINED rather than nested (relationalStore forbids nesting, and
   * only four transaction objects may exist at once), which is also what Room does for a nested
   * runInTransaction: only the outermost commits.
   * ponytail: one transaction per store, so a concurrent unrelated caller joins it too and loses
   * its writes if this one rolls back — per-caller isolation needs an owner token, add it if two
   * independent writers ever overlap.
   */
  async runInTransaction<T>(work: () => Promise<T>): Promise<T> {
    if (this.tx !== null) {
      return work();
    }
    const options: relationalStore.TransactionOptions = {
      transactionType: relationalStore.TransactionType.IMMEDIATE
    };
    const transaction: relationalStore.Transaction = await this.store.createTransaction(options);
    this.tx = transaction;
    try {
      const result: T = await work();
      this.tx = null;
      await transaction.commit();
      return result;
    } catch (error) {
      this.tx = null;
      await transaction.rollback();
      throw error as Error;
    }
  }
}

/** One row of `finished_missions`; mapped to/from FinishedMission by the download manager. */
export class FinishedMissionRow {
  /** The `path` column: the file URI the mission was saved to. */
  path: string;
  /** The `url` column: Mission.source. */
  source: string;
  /** The `bytes_downloaded` column: Mission.length. */
  length: number;
  /** The `timestamp` column. */
  timestamp: number;
  /** The `kind` column: a single character ('v', 'a', 's', ... ), '?' when unknown. */
  kind: string;

  constructor(path: string, source: string, length: number, timestamp: number, kind: string) {
    this.path = path;
    this.source = source;
    this.length = length;
    this.timestamp = timestamp;
    this.kind = kind;
  }
}

/**
 * Port of us.shandian.giga.get.sqlite.FinishedMissionStore — a SEPARATE store from newpipe.db,
 * exactly as in the source (its own file, its own version).
 */
export class DownloadsDatabase {
  static readonly DATABASE_NAME: string = 'downloads.db';
  static readonly DB_VERSION: number = 4;
  private static readonly TABLE: string = 'finished_missions';

  private static instance: DownloadsDatabase | null = null;
  private static opening: Promise<DownloadsDatabase> | null = null;

  private readonly store: relationalStore.RdbStore;

  private constructor(store: relationalStore.RdbStore) {
    this.store = store;
  }

  static async getInstance(context: common.Context): Promise<DownloadsDatabase> {
    if (DownloadsDatabase.instance !== null) {
      return DownloadsDatabase.instance;
    }
    if (DownloadsDatabase.opening === null) {
      DownloadsDatabase.opening = DownloadsDatabase.open(context);
    }
    return DownloadsDatabase.opening;
  }

  private static async open(context: common.Context): Promise<DownloadsDatabase> {
    const config: relationalStore.StoreConfig = {
      name: DownloadsDatabase.DATABASE_NAME,
      securityLevel: relationalStore.SecurityLevel.S1
    };
    const store: relationalStore.RdbStore = await relationalStore.getRdbStore(context, config);
    if (store.version !== DownloadsDatabase.DB_VERSION) {
      for (const statement of DOWNLOADS_SCHEMA_V4) {
        await store.executeSql(statement);
      }
      // The v2 `download_missions` table and its 2->3->4 upgrades only ever existed on Android.
      store.version = DownloadsDatabase.DB_VERSION;
    }
    const database: DownloadsDatabase = new DownloadsDatabase(store);
    DownloadsDatabase.instance = database;
    return database;
  }

  /** Port of loadFinishedMissions(): newest first. */
  async loadFinishedMissions(): Promise<FinishedMissionRow[]> {
    const rows: FinishedMissionRow[] = [];
    const rs: relationalStore.ResultSet = await this.store.querySql(
      'SELECT path, url, bytes_downloaded, timestamp, kind FROM finished_missions ' +
      'ORDER BY timestamp DESC', []);
    try {
      while (rs.goToNextRow()) {
        const kind: string | null = colStringOrNull(rs, 'kind');
        rows.push(new FinishedMissionRow(
          colString(rs, 'path'),
          colString(rs, 'url'),
          colNumber(rs, 'bytes_downloaded'),
          colNumber(rs, 'timestamp'),
          kind === null || kind.length === 0 ? '?' : kind.charAt(0)
        ));
      }
    } finally {
      rs.close();
    }
    return rows;
  }

  /** Port of addFinishedMission(). */
  async addFinishedMission(row: FinishedMissionRow): Promise<number> {
    return this.store.insert(DownloadsDatabase.TABLE, DownloadsDatabase.valuesOf(row),
      relationalStore.ConflictResolution.ON_CONFLICT_NONE);
  }

  /**
   * Port of deleteMission(). When the mission's storage is invalid the source deletes by
   * timestamp alone, otherwise by timestamp AND path.
   */
  async deleteMission(timestamp: number, path: string | null): Promise<void> {
    if (path === null) {
      await this.store.executeSql('DELETE FROM finished_missions WHERE timestamp = ?', [timestamp]);
    } else {
      await this.store.executeSql(
        'DELETE FROM finished_missions WHERE timestamp = ? AND path = ?', [timestamp, path]);
    }
  }

  /**
   * Port of updateMission(). With an invalid storage the source matches on timestamp, otherwise
   * on the path.
   */
  async updateMission(row: FinishedMissionRow, storageIsInvalid: boolean): Promise<number> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(DownloadsDatabase.TABLE);
    if (storageIsInvalid) {
      predicates.equalTo('timestamp', row.timestamp);
    } else {
      predicates.equalTo('path', row.path);
    }
    return this.store.update(DownloadsDatabase.valuesOf(row), predicates);
  }

  /** Port of getValuesOfMission(). */
  private static valuesOf(row: FinishedMissionRow): relationalStore.ValuesBucket {
    const values: relationalStore.ValuesBucket = {
      'url': row.source,
      'path': row.path,
      'bytes_downloaded': row.length,
      'timestamp': row.timestamp,
      'kind': row.kind
    };
    return values;
  }
}
