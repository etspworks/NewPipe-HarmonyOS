/*
 * S3 — port of org.schabi.newpipe.local.playlist.PlaylistAppendDialog: pick one of the user's
 * local playlists to append the selected streams to, or create a new one.
 *
 * The rows come from LocalPlaylistManager.getPlaylistDuplicates(), so a playlist that already
 * holds the stream is greyed out. BookmarkFragment owns the file in the build order; the screens
 * that open it are the append flows listed in the plan's usedBy.
 *
 * S5 — the AlertDialog surface this dialog is shown in. Theme.AppCompat.Dialog's window
 * background is a square nine-patch, so the card has no corner rounding, and the rows are
 * item_playlist_mini: a 48dp thumbnail, the name on one line, the stream count under it.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PlaylistMetadataEntry } from '../model/db/view/PlaylistMetadataEntry';
import { PlaylistDuplicatesEntry } from '../model/db/view/PlaylistDuplicatesEntry';
import { Localization } from '../common/i18n/Localization';

/** Theme.AppCompat.Dialog: a square window background, a white surface, 280dp wide. */
const DIALOG_WIDTH: number = 280;
const DIALOG_CORNER_RADIUS: number = 0;
const COLOR_DIALOG_SURFACE: Resource = $r('app.color.dialog_surface');
/** ?android:textColorPrimary / ?android:textColorSecondary over that surface. */
const COLOR_ON_SURFACE: Resource = $r('app.color.on_surface');
const COLOR_SECONDARY_TEXT: Resource = $r('app.color.on_surface_variant');
/** ?attr/disabledAlpha - what greys a row whose playlist already holds the stream. */
const DISABLED_ALPHA: number = 0.5;
/** item_playlist_mini metrics. */
const ROW_HEIGHT: number = 56;
const THUMB_SIZE: number = 48;
/**
 * The playlist row's thumbnail, and the count band down its right half with the glyph inside it.
 * 90x50 with a 45 band is list_playlist_mini_item.xml - what the reference draws here and what
 * SelectPlaylistAdapter already uses. This dialog had a 48x48 square, which is why the row still
 * did not match after the band was added.
 */
const PLAYLIST_ROW_HEIGHT: number = 74;
const THUMB_WIDTH: number = 90;
const THUMB_HEIGHT: number = 50;
const COUNT_BAND_WIDTH: number = 45;
const COUNT_GLYPH_SIZE: number = 24;
/** The list is bounded so a long playlist collection cannot push the dialog off-screen. */
const LIST_MAX_HEIGHT: number = 360;

@CustomDialog
export struct PlaylistAppendDialog {
  controller?: CustomDialogController;
  /**
   * getPlaylistDuplicates() rows where the caller has them. PlaylistDuplicatesEntry extends
   * PlaylistMetadataEntry, so a caller that still passes plain metadata keeps working and simply
   * gets no greying - which is why this type did not have to change across seven screens.
   *
   * @Link, not a plain member and not @Prop: every host builds its CustomDialogController in a
   * FIELD INITIALISER, which runs before the playlists have been queried. A by-value binding
   * freezes that empty array forever, so `this.playlists.length > 0` below can never become
   * true and the dialog shows nothing but the "New playlist" row. Same reasoning, and the same
   * call shape (`playlists: this.<@State member>`, no `$`), as InfoItemDialog's @Link pair.
   */
  @Link playlists: PlaylistMetadataEntry[];
  onSelected: (playlist: PlaylistMetadataEntry) => void =
    (playlist: PlaylistMetadataEntry): void => {
      hilog.debug(0x0000, 'NewPipe', 'PlaylistAppendDialog: append to uid %{public}d not bound',
        playlist.uid);
    };
  onNewPlaylist: () => void = (): void => {
    hilog.debug(0x0000, 'NewPipe', 'PlaylistAppendDialog: new playlist not bound');
  };

  /**
   * LocalPlaylistItemHolder: a playlist that already contains the stream is drawn at
   * GRAYED_OUT_ALPHA - and stays tappable. onPlaylistSelected() appends it again and says so
   * ("Duplicate added N time(s)"); the grey only warns.
   */
  private alreadyContains(playlist: PlaylistMetadataEntry): boolean {
    return playlist instanceof PlaylistDuplicatesEntry
      && (playlist as PlaylistDuplicatesEntry).timesStreamIsContained > 0;
  }

  /** anyPlaylistContainsDuplicates(): the indicator line is GONE otherwise. */
  private anyContains(): boolean {
    return this.playlists.some((playlist: PlaylistMetadataEntry): boolean =>
      this.alreadyContains(playlist));
  }

  private nameOf(playlist: PlaylistMetadataEntry): string {
    return playlist.orderingName === null ? '' : playlist.orderingName;
  }

  build() {
    Column() {
      // The dialog title, which the structure-only version had no room for.
      Text($r('app.string.add_to_playlist'))
        .width('100%')
        .fontSize(20)
        .fontColor(COLOR_ON_SURFACE)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding({ left: 24, right: 24, top: 18, bottom: 12 })

      // The first row is always "New playlist" - the source puts it above the list so it stays
      // reachable when the collection is long enough to scroll.
      Row() {
        Image($r('app.media.ic_add'))
          .width(THUMB_SIZE)
          .height(THUMB_SIZE)
          .padding(12)
          .objectFit(ImageFit.Contain)
          .fillColor(COLOR_ON_SURFACE)
        Text($r('app.string.create_playlist'))
          .layoutWeight(1)
          .fontSize(16)
          .fontColor(COLOR_ON_SURFACE)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ left: 12 })
      }
      .id('newPlaylist')
      .width('100%')
      .height(ROW_HEIGHT)
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.controller?.close();
        this.onNewPlaylist();
      })

      if (this.playlists.length > 0) {
        // playlist_duplicate: the line that says WHY a row is greyed, drawn between the
        // New-playlist row and the list - and only when some row IS greyed.
        if (this.anyContains()) {
          Text($r('app.string.duplicate_in_playlist'))
            .id('playlist_duplicate')
            .width('100%')
            .fontSize(14)
            .fontColor(COLOR_SECONDARY_TEXT)
            .textAlign(TextAlign.Center)
            .padding({ left: 16, right: 16, top: 8, bottom: 8 })
        }

        Divider()
          .strokeWidth(1)
          .color($r('app.color.separator'))
          .margin({ left: 16, right: 16 })

        List() {
          ForEach(this.playlists, (playlist: PlaylistMetadataEntry) => {
            ListItem() {
              Row() {
                // TC-PLAYER-484: a playlist row is a thumbnail with the COUNT BAND down its right half -
                // the treatment SelectPlaylistAdapter.rowBody() and every other playlist row in this app
                // already use, and the one the reference draws here, with the count inside the band under
                // the glyph. This dialog drew its own row instead: a bare thumbnail with the count as a
                // subtitle under the name. That is the card's "UI is not same".
                Stack({ alignContent: Alignment.End }) {
                  Image(playlist.thumbnailUrl === null ? '' : playlist.thumbnailUrl)
                    .alt($r('app.media.placeholder_thumbnail_playlist'))
                    .width(THUMB_WIDTH)
                    .height(THUMB_HEIGHT)
                    .objectFit(ImageFit.Cover)
                  Column() {
                    Image($r('app.media.ic_playlist_play'))
                      .width(COUNT_GLYPH_SIZE)
                      .height(COUNT_GLYPH_SIZE)
                      .objectFit(ImageFit.Contain)
                      .fillColor($r('app.color.duration_text_color'))
                    Text(Localization.localizeStreamCountMini(playlist.streamCount))
                      .fontSize(12)
                      .fontColor($r('app.color.duration_text_color'))
                      .maxLines(1)
                      .textAlign(TextAlign.Center)
                  }
                  .width(COUNT_BAND_WIDTH)
                  .height(THUMB_HEIGHT)
                  .justifyContent(FlexAlign.Center)
                  .backgroundColor($r('app.color.playlist_stream_count_background_color'))
                }
                .width(THUMB_WIDTH)
                .height(THUMB_HEIGHT)

                Text(this.nameOf(playlist))
                  .fontSize(16)
                  .fontColor(COLOR_ON_SURFACE)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                  .margin({ left: 12 })
              }
              .width('100%')
              .height(PLAYLIST_ROW_HEIGHT)
              .padding({ left: 16, right: 16 })
              .alignItems(VerticalAlign.Center)
              // A playlist that already holds this stream is dimmed, not disabled.
              .opacity(this.alreadyContains(playlist) ? DISABLED_ALPHA : 1)
            }
            .id('itemRoot')
            .onClick(() => {
              this.controller?.close();
              this.onSelected(playlist);
            })
          }, (playlist: PlaylistMetadataEntry) => playlist.uid.toString())
        }
        .id('playlist_list')
        .width('100%')
        .constraintSize({ maxHeight: LIST_MAX_HEIGHT })
      }
    }
    .width(DIALOG_WIDTH)
    .backgroundColor(COLOR_DIALOG_SURFACE)
    .borderRadius(DIALOG_CORNER_RADIUS)
    .padding({ bottom: 8 })
    .alignItems(HorizontalAlign.Start)
  }
}
