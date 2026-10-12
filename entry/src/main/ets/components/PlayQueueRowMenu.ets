/*
 * S3 - menu_play_queue_item.xml, the popup QueueItemMenuUtil.openPopupMenu() raises on a long
 * press of a queue row.
 *
 * It lived as a @Builder MEMBER of PlayQueueActivityPage, so the player's own queue panel - the
 * other surface that shows these very rows - had no way to reach it and long-pressing a row there
 * produced nothing at all. A @Builder member is not mountable from another struct; a struct is,
 * which is the whole reason this is its own file.
 *
 * It is PRESENTATION ONLY: every entry hands its action back to the host, because it is the host
 * that knows which row is held and which queue it belongs to. The ids are the source's own menu
 * slugs and stay unchanged - the replay resolves the entries by them.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'PlayQueueRowMenu';

/** menu_play_queue_item entry height, as every other popup in this screen uses. */
const ENTRY_HEIGHT: number = 48;

@Component
export struct PlayQueueRowMenu {
  /** menu_item_remove -> playQueue.remove(playQueue.indexOf(item)). */
  onRemove: () => void = (): void => {
    hilog.debug(0x0000, TAG, 'menu_item_remove not bound');
  };
  /** menu_item_details -> NavigationHelper.openVideoDetail(...). */
  onDetails: () => void = (): void => {
    hilog.debug(0x0000, TAG, 'menu_item_details not bound');
  };
  /** menu_item_append_playlist -> PlaylistAppendDialog.fromPlayQueueItems(...). */
  onAppendPlaylist: () => void = (): void => {
    hilog.debug(0x0000, TAG, 'menu_item_append_playlist not bound');
  };
  /** menu_item_channel_details -> fetchUploaderUrlIfSparse() -> ChannelFragment. */
  onChannelDetails: () => void = (): void => {
    hilog.debug(0x0000, TAG, 'menu_item_channel_details not bound');
  };
  /** menu_item_share -> ShareUtils.shareText(...). */
  onShare: () => void = (): void => {
    hilog.debug(0x0000, TAG, 'menu_item_share not bound');
  };
  /** menu_item_download -> DownloadDialog, which is hosted by screen_video_detail. */
  onDownload: () => void = (): void => {
    hilog.debug(0x0000, TAG, 'menu_item_download not bound');
  };

  build() {
    Column() {
      Text($r('app.string.play_queue_remove'))
        .id('menu_item_remove')
        .width('100%')
        .height(ENTRY_HEIGHT)
        .padding({ left: 16, right: 16 })
        .fontSize(16)
        .fontColor($r('app.color.on_surface'))
        .textAlign(TextAlign.Start)
        .onClick(() => {
          this.onRemove();
        })

      Text($r('app.string.play_queue_stream_detail'))
        .id('menu_item_details')
        .width('100%')
        .height(ENTRY_HEIGHT)
        .padding({ left: 16, right: 16 })
        .fontSize(16)
        .fontColor($r('app.color.on_surface'))
        .textAlign(TextAlign.Start)
        .onClick(() => {
          this.onDetails();
        })

      Text($r('app.string.add_to_playlist'))
        .id('menu_item_append_playlist')
        .width('100%')
        .height(ENTRY_HEIGHT)
        .padding({ left: 16, right: 16 })
        .fontSize(16)
        .fontColor($r('app.color.on_surface'))
        .textAlign(TextAlign.Start)
        .onClick(() => {
          this.onAppendPlaylist();
        })

      Text($r('app.string.show_channel_details'))
        .id('menu_item_channel_details')
        .width('100%')
        .height(ENTRY_HEIGHT)
        .padding({ left: 16, right: 16 })
        .fontSize(16)
        .fontColor($r('app.color.on_surface'))
        .textAlign(TextAlign.Start)
        .onClick(() => {
          this.onChannelDetails();
        })

      Text($r('app.string.share'))
        .id('menu_item_share')
        .width('100%')
        .height(ENTRY_HEIGHT)
        .padding({ left: 16, right: 16 })
        .fontSize(16)
        .fontColor($r('app.color.on_surface'))
        .textAlign(TextAlign.Start)
        .onClick(() => {
          this.onShare();
        })

      Text($r('app.string.download'))
        .id('menu_item_download')
        .width('100%')
        .height(ENTRY_HEIGHT)
        .padding({ left: 16, right: 16 })
        .fontSize(16)
        .fontColor($r('app.color.on_surface'))
        .textAlign(TextAlign.Start)
        .onClick(() => {
          this.onDownload();
        })
    }
    .id('play_queue_item_menu')
    .backgroundColor($r('app.color.surface'))
    .borderRadius(2)
    .padding({ top: 8, bottom: 8 })
    .constraintSize({ minWidth: 180 })
    .shadow({ radius: 8, color: '#33000000', offsetX: 0, offsetY: 2 })
  }
}
