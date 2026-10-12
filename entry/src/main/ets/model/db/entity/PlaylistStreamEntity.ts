/*
 * Port of org.schabi.newpipe.database.playlist.model.PlaylistStreamEntity
 * (Room entity `playlist_stream_join`) — the ordered join between a local playlist and its
 * streams.
 */

import { relationalStore } from '@kit.ArkData';
import { colNumber } from '../../../common/db/AppDatabase';
import { LocalItem, LocalItemType } from '../../enums/LocalItemLocalItemType';

export class PlaylistStreamEntity implements LocalItem {
  static readonly TABLE: string = 'playlist_stream_join';

  /** `playlist_id` — foreign key onto playlists(uid); part of the primary key. */
  playlistUid: number;
  /** `stream_id` — foreign key onto streams(uid). */
  streamUid: number;
  /** `join_index` — the position of the stream in the playlist; part of the primary key. */
  index: number;

  constructor(playlistUid: number, streamUid: number, index: number) {
    this.playlistUid = playlistUid;
    this.streamUid = streamUid;
    this.index = index;
  }

  get localItemType(): LocalItemType {
    return LocalItemType.PLAYLIST_STREAM_ITEM;
  }

  static fromRow(rs: relationalStore.ResultSet): PlaylistStreamEntity {
    return new PlaylistStreamEntity(
      colNumber(rs, 'playlist_id'),
      colNumber(rs, 'stream_id'),
      colNumber(rs, 'join_index')
    );
  }

  toValuesBucket(): relationalStore.ValuesBucket {
    const values: relationalStore.ValuesBucket = {
      'playlist_id': this.playlistUid,
      'stream_id': this.streamUid,
      'join_index': this.index
    };
    return values;
  }
}
