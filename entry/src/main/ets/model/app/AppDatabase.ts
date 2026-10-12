/*
 * Port of app/src/main/java/org/schabi/newpipe/database/AppDatabase.kt.
 *
 * Room's `@Database(version, entities)` has no ArkTS analogue: `@kit.ArkData`
 * relationalStore is opened with a StoreConfig carrying the name, and the schema is created by
 * the DAO layer. What survives the annotation is exactly what the annotation declared - the
 * database file name, the schema version and the set of entities - so that is what this module
 * carries. The store handle, the DAOs and the migrations live in the persistence wave under
 * `common/db/`; this module deliberately imports nothing from there so both can be generated
 * independently.
 */

/** `AppDatabase.Companion.DATABASE_NAME`, verbatim. */
export const DATABASE_NAME: string = 'newpipe.db';

/** `Migrations.DB_VER_9` - the `version` of the `@Database` annotation. */
export const DATABASE_VERSION: number = 9;

/**
 * The `entities = [...]` list of the `@Database` annotation, in source order. Each name is the
 * ArkTS model class of the corresponding Room entity; the persistence wave owns their tables.
 */
export const DATABASE_ENTITIES: string[] = [
  'SubscriptionEntity',
  'SearchHistoryEntry',
  'StreamEntity',
  'StreamHistoryEntity',
  'StreamStateEntity',
  'PlaylistEntity',
  'PlaylistStreamEntity',
  'PlaylistRemoteEntity',
  'FeedEntity',
  'FeedGroupEntity',
  'FeedGroupSubscriptionEntity',
  'FeedLastUpdatedEntity'
];

/**
 * The DAO accessors declared on `abstract class AppDatabase`. Recorded so a reader of the
 * migrated app can see the same surface the Room class exposed; the implementations are the
 * DAO modules of the persistence wave.
 */
export const DATABASE_DAOS: string[] = [
  'feedDAO',
  'feedGroupDAO',
  'playlistDAO',
  'playlistRemoteDAO',
  'playlistStreamDAO',
  'searchHistoryDAO',
  'streamDAO',
  'streamHistoryDAO',
  'streamStateDAO',
  'subscriptionDAO'
];
