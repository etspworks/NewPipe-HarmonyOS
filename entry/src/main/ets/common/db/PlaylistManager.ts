/*
 * svc_playlist_manager — port of org.schabi.newpipe.local.playlist.LocalPlaylistManager and
 * RemotePlaylistManager, together with the PlaylistDAO / PlaylistStreamDAO / PlaylistRemoteDAO
 * queries they drive.
 *
 * Concurrency (phase2-logic-contract §1): all of these are one-shot reads/writes, so
 * Single/Maybe/Completable become Promises; Schedulers.io() is identity.
 * Rule 8: every ResultSet is closed by AppDatabase.query/queryFirst/queryNumber in a finally.
 */

import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { AppDatabase } from './AppDatabase';
import { StreamDao } from './HistoryRecordManager';
import { StreamEntity } from '../../model/db/entity/StreamEntity';
import { PlaylistEntity } from '../../model/db/entity/PlaylistEntity';
import { PlaylistRemoteEntity } from '../../model/db/entity/PlaylistRemoteEntity';
import { PlaylistStreamEntity } from '../../model/db/entity/PlaylistStreamEntity';
import { PlaylistDuplicatesEntry } from '../../model/db/view/PlaylistDuplicatesEntry';
import { PlaylistMetadataEntry } from '../../model/db/view/PlaylistMetadataEntry';
import { PlaylistStreamEntry } from '../../model/db/view/PlaylistStreamEntry';
import { PlaylistInfo } from '../../model/extractor/PlaylistInfo';
import { Localization } from '../i18n/Localization';

/** LocalPlaylistManager.THUMBNAIL_ID_LEAVE_UNCHANGED */
const THUMBNAIL_ID_LEAVE_UNCHANGED: number = -2;

/**
 * Port of LocalPlaylistManager: the user's own playlists and the streams joined onto them.
 */
export class LocalPlaylistManager {
  private readonly database: AppDatabase;

  constructor(database: AppDatabase) {
    this.database = database;
  }

  static async of(context: common.Context): Promise<LocalPlaylistManager> {
    return new LocalPlaylistManager(await AppDatabase.getInstance(context));
  }

  /**
   * Port of createPlaylist(): empty playlists cannot be created, and the new playlist gets
   * display_index -1 so it sits on top of the bookmark list until BookmarkFragment renumbers.
   *
   * @returns the ids of the inserted join rows, or null when `streams` is empty
   */
  async createPlaylist(name: string, streams: StreamEntity[]): Promise<number[] | null> {
    if (streams.length === 0) {
      return null;
    }

    return this.database.runInTransaction<number[]>(async (): Promise<number[]> => {
      const streamIds: number[] = await StreamDao.upsertAll(this.database, streams);
      const newPlaylist: PlaylistEntity = new PlaylistEntity(name, false, streamIds[0], -1);
      const playlistId: number = await this.database.insert(PlaylistEntity.TABLE,
        newPlaylist.toValuesBucket(), relationalStore.ConflictResolution.ON_CONFLICT_NONE);
      return this.insertJoinEntities(playlistId, streamIds, 0);
    });
  }

  /**
   * Port of appendToPlaylist(): the new streams go after the current last join index. Then, as
   * PlaylistAppendDialog.onPlaylistSelected() does, a playlist still on the DEFAULT thumbnail takes
   * the first appended stream as its (non-permanent) thumbnail.
   */
  async appendToPlaylist(playlistId: number, streams: StreamEntity[]): Promise<number[]> {
    const maxJoinIndex: number = await this.getMaximumIndexOf(playlistId);
    let firstStreamId: number = -1;
    const joined: number[] = await this.database.runInTransaction<number[]>(
      async (): Promise<number[]> => {
        const streamIds: number[] = await StreamDao.upsertAll(this.database, streams);
        firstStreamId = streamIds.length > 0 ? streamIds[0] : -1;
        return this.insertJoinEntities(playlistId, streamIds, maxJoinIndex + 1);
      });
    if (firstStreamId >= 0
      && await this.getPlaylistThumbnailStreamId(playlistId) === PlaylistEntity.DEFAULT_THUMBNAIL_ID) {
      await this.changePlaylistThumbnail(playlistId, firstStreamId, false);
    }
    return joined;
  }

  /** Port of insertJoinEntities(). */
  private async insertJoinEntities(playlistId: number, streamIds: number[],
    indexOffset: number): Promise<number[]> {
    const insertedIds: number[] = [];
    for (let index = 0; index < streamIds.length; index++) {
      const join: PlaylistStreamEntity =
        new PlaylistStreamEntity(playlistId, streamIds[index], index + indexOffset);
      insertedIds.push(await this.database.insert(PlaylistStreamEntity.TABLE,
        join.toValuesBucket(), relationalStore.ConflictResolution.ON_CONFLICT_NONE));
    }
    return insertedIds;
  }

  /** Port of updateJoin(): replaces the playlist's contents with `streamIds`, in that order. */
  async updateJoin(playlistId: number, streamIds: number[]): Promise<void> {
    await this.database.runInTransaction<void>(async (): Promise<void> => {
      await this.database.execute('DELETE FROM playlist_stream_join WHERE playlist_id = ?',
        [playlistId]);
      await this.insertJoinEntities(playlistId, streamIds, 0);
    });
  }

  /** Port of updatePlaylists(): applies the bookmark list's renames, reorders and deletions. */
  async updatePlaylists(updateItems: PlaylistMetadataEntry[],
    deletedItems: number[]): Promise<void> {
    const items: PlaylistEntity[] = updateItems.map((item: PlaylistMetadataEntry): PlaylistEntity =>
      PlaylistEntity.fromMetadata(item));

    await this.database.runInTransaction<void>(async (): Promise<void> => {
      for (const uid of deletedItems) {
        await this.deletePlaylist(uid);
      }
      for (const item of items) {
        await this.upsertPlaylist(item);
      }
    });
  }

  /** Port of PlaylistDAO.upsertPlaylist(). */
  private async upsertPlaylist(playlist: PlaylistEntity): Promise<number> {
    if (playlist.uid === -1) {
      // This situation is probably impossible, but the source handles it.
      return this.database.insert(PlaylistEntity.TABLE, playlist.toValuesBucket(),
        relationalStore.ConflictResolution.ON_CONFLICT_NONE);
    }
    await this.updatePlaylistRow(playlist);
    return playlist.uid;
  }

  private async updatePlaylistRow(playlist: PlaylistEntity): Promise<number> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(PlaylistEntity.TABLE);
    predicates.equalTo('uid', playlist.uid);
    return this.database.update(playlist.toValuesBucket(), predicates);
  }

  /** Port of PlaylistDAO.deletePlaylist(). The join rows go with it (ON DELETE CASCADE). */
  async deletePlaylist(playlistId: number): Promise<number> {
    return this.database.executeAndCount('DELETE FROM playlists WHERE uid = ?', [playlistId]);
  }

  /** Port of getPlaylists() / PlaylistStreamDAO.getPlaylistMetadata(). */
  async getPlaylists(): Promise<PlaylistMetadataEntry[]> {
    return this.database.query<PlaylistMetadataEntry>(
      'SELECT uid, name, is_thumbnail_permanent, thumbnail_stream_id, display_index, ' +
      '(SELECT thumbnail_url FROM streams WHERE streams.uid = thumbnail_stream_id) ' +
      'AS thumbnail_url, ' +
      'COALESCE(COUNT(playlist_id), 0) AS streamCount FROM playlists ' +
      'LEFT JOIN playlist_stream_join ON playlists.uid = playlist_id ' +
      'GROUP BY uid ORDER BY display_index', [], PlaylistMetadataEntry.fromRow);
  }

  /** Port of getPlaylistStreams() / PlaylistStreamDAO.getOrderedStreamsOf(). */
  async getPlaylistStreams(playlistId: number): Promise<PlaylistStreamEntry[]> {
    return this.database.query<PlaylistStreamEntry>(
      'SELECT * FROM streams ' +
      'INNER JOIN (SELECT stream_id, join_index FROM playlist_stream_join ' +
      '  WHERE playlist_id = ?) ON uid = stream_id ' +
      'LEFT JOIN (SELECT stream_id AS stream_id_alias, progress_time FROM stream_state) ' +
      'ON uid = stream_id_alias ' +
      'ORDER BY join_index ASC', [playlistId], PlaylistStreamEntry.fromRow);
  }

  /** Port of getDistinctPlaylistStreams() / PlaylistStreamDAO.getStreamsWithoutDuplicates(). */
  async getDistinctPlaylistStreams(playlistId: number): Promise<PlaylistStreamEntry[]> {
    return this.database.query<PlaylistStreamEntry>(
      'SELECT *, MIN(join_index) FROM streams ' +
      'INNER JOIN (SELECT stream_id, join_index FROM playlist_stream_join ' +
      '  WHERE playlist_id = ?) ON uid = stream_id ' +
      'LEFT JOIN (SELECT stream_id AS stream_id_alias, progress_time FROM stream_state) ' +
      'ON uid = stream_id_alias ' +
      'GROUP BY uid ORDER BY MIN(join_index) ASC', [playlistId], PlaylistStreamEntry.fromRow);
  }

  /**
   * Port of getPlaylistDuplicates(): every playlist plus how many times `streamUrl` is already in
   * it, so the append dialog can grey the playlists that already contain the stream.
   */
  async getPlaylistDuplicates(streamUrl: string): Promise<PlaylistDuplicatesEntry[]> {
    return this.database.query<PlaylistDuplicatesEntry>(
      'SELECT playlists.uid, name, is_thumbnail_permanent, thumbnail_stream_id, display_index, ' +
      '(SELECT thumbnail_url FROM streams WHERE streams.uid = thumbnail_stream_id) ' +
      'AS thumbnail_url, ' +
      'COALESCE(COUNT(playlist_id), 0) AS streamCount, ' +
      'COALESCE(SUM(url = ?), 0) AS timesStreamIsContained FROM playlists ' +
      'LEFT JOIN playlist_stream_join ON playlists.uid = playlist_id ' +
      'LEFT JOIN streams ON streams.uid = stream_id ' +
      'GROUP BY playlists.uid ORDER BY display_index, name',
      [streamUrl], PlaylistDuplicatesEntry.fromDuplicatesRow);
  }

  /** Port of PlaylistStreamDAO.getMaximumIndexOf(). */
  async getMaximumIndexOf(playlistId: number): Promise<number> {
    return this.database.queryNumber(
      'SELECT COALESCE(MAX(join_index), -1) FROM playlist_stream_join WHERE playlist_id = ?',
      [playlistId], -1);
  }

  /** Port of renamePlaylist(). */
  async renamePlaylist(playlistId: number, name: string): Promise<number | null> {
    return this.modifyPlaylist(playlistId, name, THUMBNAIL_ID_LEAVE_UNCHANGED, false);
  }

  /** Port of changePlaylistThumbnail(). */
  async changePlaylistThumbnail(playlistId: number, thumbnailStreamId: number,
    isPermanent: boolean): Promise<number | null> {
    return this.modifyPlaylist(playlistId, null, thumbnailStreamId, isPermanent);
  }

  /** Port of modifyPlaylist(): null when the playlist no longer exists. */
  private async modifyPlaylist(playlistId: number, name: string | null, thumbnailStreamId: number,
    isPermanent: boolean): Promise<number | null> {
    const playlist: PlaylistEntity | null = await this.getPlaylist(playlistId);
    if (playlist === null) {
      return null;
    }
    if (name !== null) {
      playlist.name = name;
    }
    if (thumbnailStreamId !== THUMBNAIL_ID_LEAVE_UNCHANGED) {
      playlist.thumbnailStreamId = thumbnailStreamId;
      playlist.isThumbnailPermanent = isPermanent;
    }
    return this.updatePlaylistRow(playlist);
  }

  /** Port of PlaylistDAO.getPlaylist(). */
  async getPlaylist(playlistId: number): Promise<PlaylistEntity | null> {
    return this.database.queryFirst<PlaylistEntity>('SELECT * FROM playlists WHERE uid = ?',
      [playlistId], PlaylistEntity.fromRow);
  }

  /** Port of getPlaylistThumbnailStreamId(). */
  async getPlaylistThumbnailStreamId(playlistId: number): Promise<number> {
    const playlist: PlaylistEntity | null = await this.getPlaylist(playlistId);
    return playlist === null ? PlaylistEntity.DEFAULT_THUMBNAIL_ID : playlist.thumbnailStreamId;
  }

  /** Port of getIsPlaylistThumbnailPermanent(). */
  async getIsPlaylistThumbnailPermanent(playlistId: number): Promise<boolean> {
    const playlist: PlaylistEntity | null = await this.getPlaylist(playlistId);
    return playlist === null ? false : playlist.isThumbnailPermanent;
  }

  /**
   * Port of getAutomaticPlaylistThumbnailStreamId() /
   * PlaylistStreamDAO.getAutomaticThumbnailStreamId(): the first stream of the playlist.
   */
  async getAutomaticPlaylistThumbnailStreamId(playlistId: number): Promise<number> {
    const streamId: number = await this.database.queryNumber(
      'SELECT CASE WHEN COUNT(*) != 0 THEN stream_id ELSE ? END FROM streams ' +
      'LEFT JOIN playlist_stream_join ON uid = stream_id WHERE playlist_id = ? LIMIT 1',
      [PlaylistEntity.DEFAULT_THUMBNAIL_ID, playlistId], PlaylistEntity.DEFAULT_THUMBNAIL_ID);
    return streamId < 0 ? PlaylistEntity.DEFAULT_THUMBNAIL_ID : streamId;
  }

  /** Port of hasPlaylists() / PlaylistDAO.getCount(). */
  async hasPlaylists(): Promise<boolean> {
    const count: number =
      await this.database.queryNumber('SELECT COUNT(*) FROM playlists', [], 0);
    return count > 0;
  }
}

/**
 * Port of RemotePlaylistManager: the playlists bookmarked from a service.
 */
export class RemotePlaylistManager {
  private readonly database: AppDatabase;

  constructor(database: AppDatabase) {
    this.database = database;
  }

  static async of(context: common.Context): Promise<RemotePlaylistManager> {
    return new RemotePlaylistManager(await AppDatabase.getInstance(context));
  }

  /** Port of RemotePlaylistManager.getPlaylists(). */
  async getPlaylists(): Promise<PlaylistRemoteEntity[]> {
    return this.database.query<PlaylistRemoteEntity>(
      'SELECT * FROM remote_playlists ORDER BY display_index', [], PlaylistRemoteEntity.fromRow);
  }

  /** Port of getPlaylist(long). */
  async getPlaylist(playlistId: number): Promise<PlaylistRemoteEntity | null> {
    return this.database.queryFirst<PlaylistRemoteEntity>(
      'SELECT * FROM remote_playlists WHERE uid = ?', [playlistId], PlaylistRemoteEntity.fromRow);
  }

  /** Port of getPlaylist(PlaylistInfo). */
  async getPlaylistOf(info: PlaylistInfo): Promise<PlaylistRemoteEntity[]> {
    return this.database.query<PlaylistRemoteEntity>(
      'SELECT * FROM remote_playlists WHERE url = ? AND service_id = ?',
      [info.getUrl(), info.getServiceId()], PlaylistRemoteEntity.fromRow);
  }

  /** Port of RemotePlaylistManager.deletePlaylist(). */
  async deletePlaylist(playlistId: number): Promise<number> {
    return this.database.executeAndCount('DELETE FROM remote_playlists WHERE uid = ?',
      [playlistId]);
  }

  /** Port of RemotePlaylistManager.updatePlaylists(). */
  async updatePlaylists(updateItems: PlaylistRemoteEntity[],
    deletedItems: number[]): Promise<void> {
    await this.database.runInTransaction<void>(async (): Promise<void> => {
      for (const uid of deletedItems) {
        await this.deletePlaylist(uid);
      }
      for (const item of updateItems) {
        await this.upsert(item);
      }
    });
  }

  /** Port of onBookmark(). */
  async onBookmark(playlistInfo: PlaylistInfo): Promise<number> {
    return this.upsert(PlaylistRemoteEntity.fromPlaylistInfo(playlistInfo));
  }

  /** Port of onUpdate(). */
  async onUpdate(playlistId: number, playlistInfo: PlaylistInfo): Promise<number> {
    const playlist: PlaylistRemoteEntity = PlaylistRemoteEntity.fromPlaylistInfo(playlistInfo);
    playlist.uid = playlistId;
    return this.updateRow(playlist);
  }

  /** Port of PlaylistRemoteDAO.upsert(). */
  private async upsert(playlist: PlaylistRemoteEntity): Promise<number> {
    const existingId: number = await this.database.queryNumber(
      'SELECT uid FROM remote_playlists WHERE url = ? AND service_id = ?',
      [playlist.url, playlist.serviceId], -1);

    if (existingId === -1) {
      return this.database.insert(PlaylistRemoteEntity.TABLE, playlist.toValuesBucket(),
        relationalStore.ConflictResolution.ON_CONFLICT_NONE);
    }
    playlist.uid = existingId;
    await this.updateRow(playlist);
    return existingId;
  }

  private async updateRow(playlist: PlaylistRemoteEntity): Promise<number> {
    const predicates: relationalStore.RdbPredicates =
      new relationalStore.RdbPredicates(PlaylistRemoteEntity.TABLE);
    predicates.equalTo('uid', playlist.uid);
    return this.database.update(playlist.toValuesBucket(), predicates);
  }
}

/**
 * PlaylistAppendDialog.onPlaylistSelected()'s toast: "Duplicate added N time(s)" when the playlist
 * already held the stream, "Playlisted" otherwise. A row that is not a duplicates entry carries no
 * count, which is the plain message.
 */
export function playlistAppendToast(playlist: object | null): string {
  if (playlist instanceof PlaylistDuplicatesEntry) {
    const times: number = (playlist as PlaylistDuplicatesEntry).timesStreamIsContained;
    if (times > 0) {
      return Localization.getStringArgs('playlist_add_stream_success_duplicate', [times]);
    }
  }
  return Localization.getString('playlist_add_stream_success');
}
