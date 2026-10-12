/*
 * Port of org.schabi.newpipe.database.playlist.PlaylistDuplicatesEntry — a PlaylistMetadataEntry
 * plus how many times a given stream is already in that playlist, so the "add to playlist" dialog
 * can grey out the playlists that already contain it.
 */

import { relationalStore } from '@kit.ArkData';
import { colBooleanOrNull, colNumber, colNumberOrNull, colStringOrNull }
  from '../../../common/db/AppDatabase';
import { PlaylistMetadataEntry } from './PlaylistMetadataEntry';

export class PlaylistDuplicatesEntry extends PlaylistMetadataEntry {
  /** The alias the duplicates query gives SUM(url = :streamUrl). */
  static readonly PLAYLIST_TIMES_STREAM_IS_CONTAINED: string = 'timesStreamIsContained';

  /** `timesStreamIsContained` */
  readonly timesStreamIsContained: number;

  constructor(uid: number, orderingName: string | null, thumbnailUrl: string | null,
    displayIndex: number | null, isThumbnailPermanent: boolean | null,
    thumbnailStreamId: number | null, streamCount: number, timesStreamIsContained: number) {
    super(uid, orderingName, thumbnailUrl, displayIndex, isThumbnailPermanent, thumbnailStreamId,
      streamCount);
    this.timesStreamIsContained = timesStreamIsContained;
  }

  static fromDuplicatesRow(rs: relationalStore.ResultSet): PlaylistDuplicatesEntry {
    return new PlaylistDuplicatesEntry(
      colNumber(rs, 'uid'),
      colStringOrNull(rs, 'name'),
      colStringOrNull(rs, 'thumbnail_url'),
      colNumberOrNull(rs, 'display_index'),
      colBooleanOrNull(rs, 'is_thumbnail_permanent'),
      colNumberOrNull(rs, 'thumbnail_stream_id'),
      colNumber(rs, 'streamCount'),
      colNumber(rs, 'timesStreamIsContained')
    );
  }
}
