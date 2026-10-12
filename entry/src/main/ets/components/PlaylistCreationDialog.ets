/*
 * S3 — port of org.schabi.newpipe.local.playlist.PlaylistCreationDialog: name a new local
 * playlist (dialog_edit_text.xml) and create it with the streams the caller passed.
 *
 * BookmarkFragment owns this file in the build order; it is opened from the add-to-playlist
 * flows (RouterActivity, the video-detail append path) through PlaylistDialog.
 */
import { Localization } from '../common/i18n/Localization';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * Every host opens this through a `customStyle: true` CustomDialogController, which hands the
 * WHOLE surface to the builder: no card, no background, no width and no padding are drawn for
 * it. The structure-only version set none of them, so the name field and the two buttons were
 * laid straight onto the screen edge with nothing behind them. These are the AlertDialog metrics
 * ConfirmDeleteDialog and BookmarkFragmentPage's RenameDialog already draw.
 */
const DIALOG_WIDTH: number = 294;
/** Theme.AppCompat.Dialog's window background is a square nine-patch: no corner rounding. */
const DIALOG_CORNER_RADIUS: number = 0;
const COLOR_DIALOG_SURFACE: Resource = $r('app.color.dialog_surface');
/** ?android:textColorPrimary over that surface. */
const COLOR_ON_SURFACE: Resource = $r('app.color.on_surface');
/** ?attr/colorAccent — the AlertDialog button colour the captures sample. */
const COLOR_ACCENT: Resource = $r('app.color.settings_accent');
const DIALOG_GUTTER: number = 24;
const DIALOG_TITLE_SIZE: number = 20;
const DIALOG_BODY_SIZE: number = 16;
const BUTTON_TEXT_SIZE: number = 14;

@CustomDialog
export struct PlaylistCreationDialog {
  controller?: CustomDialogController;
  name: string = '';
  onCreate: (name: string) => void = (playlistName: string): void => {
    hilog.debug(0x0000, 'NewPipe', 'PlaylistCreationDialog: create %{public}s not bound',
      playlistName);
  };

  build() {
    Column() {
      // setTitle(R.string.create_playlist) — the AlertDialog's own title row.
      Text($r('app.string.create_playlist'))
        .id('playlist_creation_title')
        .width('100%')
        .fontSize(DIALOG_TITLE_SIZE)
        .fontColor(COLOR_ON_SURFACE)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 12 })

      TextInput({ text: this.name, placeholder: $r('app.string.name') })
        .id('dialog_edit_text')
        .fontSize(DIALOG_BODY_SIZE)
        .fontColor(COLOR_ON_SURFACE)
        .margin({ top: 12 })
        .onChange((value: string) => {
          this.name = value;
        })

      Row() {
        // android:textAllCaps, which Widget.AppCompat.Button carries: the reference's dialog reads
        // CANCEL / CREATE. Localization.buttonLabel() is this port's locale-aware equivalent and
        // is what ConfirmDeleteDialog already uses; this dialog passed the raw resource.
        Button(Localization.buttonLabel('cancel'))
          .id('Cancel')
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .fontSize(BUTTON_TEXT_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_ACCENT)
          .onClick(() => {
            this.controller?.close();
          })
        // setPositiveButton(R.string.create, ...) — the label is the verb, not the screen name.
        Button(Localization.buttonLabel('create'))
          .id('create_playlist')
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .fontSize(BUTTON_TEXT_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_ACCENT)
          .onClick(() => {
            this.controller?.close();
            this.onCreate(this.name);
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .margin({ top: 12 })
    }
    .width(DIALOG_WIDTH)
    .padding({ left: DIALOG_GUTTER, right: DIALOG_GUTTER, top: 8, bottom: 8 })
    .backgroundColor(COLOR_DIALOG_SURFACE)
    .borderRadius(DIALOG_CORNER_RADIUS)
    .alignItems(HorizontalAlign.Start)
  }
}
