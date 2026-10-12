/*
 * Port of org.schabi.newpipe.extractor.playlist.PlaylistInfo.PlaylistType
 * (NewPipeExtractor v0.26.5).
 *
 * Its own module rather than a member of PlaylistInfo: PlaylistInfoItem and the playlist
 * extractors need it, and importing PlaylistInfo for it would make an ES-module cycle that is
 * resolved at init time.
 */
export enum PlaylistType {
  NORMAL,
  MIX_STREAM,
  MIX_MUSIC,
  /** Deprecated in the source. */
  MIX_CHANNEL,
  MIX_GENRE
}
