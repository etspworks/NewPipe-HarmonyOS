/*
 * Port of org.schabi.newpipe.database.LocalItem.LocalItemType (NewPipe app).
 */
export enum LocalItemType {
  PLAYLIST_LOCAL_ITEM,
  PLAYLIST_REMOTE_ITEM,
  PLAYLIST_STREAM_ITEM,
  STATISTIC_STREAM_ITEM
}

/** Port of the LocalItem interface itself: every local list row carries its type. */
export interface LocalItem {
  readonly localItemType: LocalItemType;
}
