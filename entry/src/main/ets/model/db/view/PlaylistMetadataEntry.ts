/*
 * Port of org.schabi.newpipe.database.playlist.PlaylistMetadataEntry — one row of
 * PlaylistStreamDAO.getPlaylistMetadata(): a local playlist plus its stream count and the
 * thumbnail URL resolved from thumbnail_stream_id.
 */

import { relationalStore } from '@kit.ArkData';
import { colBooleanOrNull, colNumber, colNumberOrNull, colStringOrNull }
  from '../../../common/db/AppDatabase';
import { LocalItemType } from '../../enums/LocalItemLocalItemType';
import { PlaylistLocalItem } from './PlaylistLocalItem';

export class PlaylistMetadataEntry implements PlaylistLocalItem {
  /** The alias the metadata query gives COUNT(playlist_id). */
  static readonly PLAYLIST_STREAM_COUNT: string = 'streamCount';

  /** `uid` */
  readonly uid: number;
  /** `name` */
  readonly orderingName: string | null;
  /** `thumbnail_url`, from the stream thumbnail_stream_id points at. */
  readonly thumbnailUrl: string | null;
  /** `display_index` */
  displayIndex: number | null;
  /** `is_thumbnail_permanent` */
  readonly isThumbnailPermanent: boolean | null;
  /** `thumbnail_stream_id` */
  readonly thumbnailStreamId: number | null;
  /** `streamCount` */
  readonly streamCount: number;

  constructor(uid: number, orderingName: string | null, thumbnailUrl: string | null,
    displayIndex: number | null, isThumbnailPermanent: boolean | null,
    thumbnailStreamId: number | null, streamCount: number) {
    this.uid = uid;
    this.orderingName = orderingName;
    this.thumbnailUrl = thumbnailUrl;
    this.displayIndex = displayIndex;
    this.isThumbnailPermanent = isThumbnailPermanent;
    this.thumbnailStreamId = thumbnailStreamId;
    this.streamCount = streamCount;
  }

  get localItemType(): LocalItemType {
    return LocalItemType.PLAYLIST_LOCAL_ITEM;
  }

  static fromRow(rs: relationalStore.ResultSet): PlaylistMetadataEntry {
    return new PlaylistMetadataEntry(
      colNumber(rs, 'uid'),
      colStringOrNull(rs, 'name'),
      colStringOrNull(rs, 'thumbnail_url'),
      colNumberOrNull(rs, 'display_index'),
      colBooleanOrNull(rs, 'is_thumbnail_permanent'),
      colNumberOrNull(rs, 'thumbnail_stream_id'),
      colNumber(rs, 'streamCount')
    );
  }
}
