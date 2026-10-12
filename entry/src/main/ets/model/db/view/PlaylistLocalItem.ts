/*
 * Port of org.schabi.newpipe.database.playlist.PlaylistLocalItem — what the bookmark list needs
 * from a playlist, whether it is a local playlist (PlaylistMetadataEntry) or a bookmarked remote
 * one (PlaylistRemoteEntity).
 */

import { LocalItem } from '../../enums/LocalItemLocalItemType';

export interface PlaylistLocalItem extends LocalItem {
  readonly orderingName: string | null;
  readonly displayIndex: number | null;
  readonly uid: number;
  readonly thumbnailUrl: string | null;
}
