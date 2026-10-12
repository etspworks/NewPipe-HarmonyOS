/*
 * S3 — port of org.schabi.newpipe.local.playlist.PlaylistDialog: the entry point that decides
 * WHICH playlist dialog to show. createCorrespondingDialog() asks
 * LocalPlaylistManager.hasPlaylists(): with playlists it shows PlaylistAppendDialog, without any
 * it jumps straight to PlaylistCreationDialog.
 *
 * That branch is the real source condition, so it is an ArkUI `if` on `hasPlaylists`.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';

@CustomDialog
export struct PlaylistDialog {
  controller?: CustomDialogController;
  /** LocalPlaylistManager.hasPlaylists() — decides append vs create. */
  hasPlaylists: boolean = false;
  onAppend: () => void = (): void => {
    hilog.debug(0x0000, 'NewPipe', 'PlaylistDialog: append branch not bound');
  };
  onCreate: () => void = (): void => {
    hilog.debug(0x0000, 'NewPipe', 'PlaylistDialog: create branch not bound');
  };

  build() {
    Column() {
      if (this.hasPlaylists) {
        Text($r('app.string.add_to_playlist'))
          .id('add_to_playlist')
          .width('100%')
          .onClick(() => {
            this.controller?.close();
            this.onAppend();
          })
      } else {
        Text($r('app.string.create_playlist'))
          .id('create_playlist')
          .width('100%')
          .onClick(() => {
            this.controller?.close();
            this.onCreate();
          })
      }
    }
    .width('100%')
  }
}
