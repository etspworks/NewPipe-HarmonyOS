/*
 * S3 — port of org.schabi.newpipe.local.holder.LocalItemHolder plus the gesture wiring that
 * PlaylistItemHolder.updateFromItem() installs on `itemView`: this is the ROW ROOT every local
 * list row is built inside.
 *
 * `R.id.itemRoot` is deliberately ONE shared id across all N rows (Rule 12's list-row
 * exception) — the replay resolves `tap-card-N` by index, not by a unique id.
 *
 * Source: itemView.setOnClickListener -> OnClickGesture.selected(item)
 *         itemView.setOnLongClickListener -> OnClickGesture.held(item)
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PlaylistLocalItem } from '../model/db/view/PlaylistLocalItem';

/** Default for a gesture the parent has not bound yet — never silently empty. */
function unwiredGesture(item: PlaylistLocalItem): void {
  hilog.debug(0x0000, 'NewPipe', 'LocalItemHolder: gesture not bound for uid %{public}d', item.uid);
}

/*
 * S5 — style only. itemRoot carries android:padding="@dimen/video_item_search_padding" (12dp) and
 * android:background="?attr/selectableItemBackground", i.e. transparent over the window
 * background with a ripple on press. Capture S0043: the row is [0,240][1080,462] = 74vp tall,
 * which is exactly 12 + the 50vp thumbnail + 12.
 */

/** ?attr/selectableItemBackground at rest — the #EEEEEE window shows through. */
@Styles
function localItemRowNormal() {
  .backgroundColor(Color.Transparent)
}

/** @color/light_ripple_color — the pressed state of the same selectable background. */
@Styles
function localItemRowPressed() {
  .backgroundColor($r('app.color.ripple'))
}

@Component
export struct LocalItemHolder {
  item: PlaylistLocalItem | null = null;
  onSelected: (item: PlaylistLocalItem) => void = unwiredGesture;
  onHeld: (item: PlaylistLocalItem) => void = unwiredGesture;
  @BuilderParam body: (item: PlaylistLocalItem) => void = this.defaultBody;

  @Builder
  defaultBody(item: PlaylistLocalItem) {
    Text(item.orderingName === null ? '' : item.orderingName)
  }

  build() {
    Row() {
      if (this.item !== null) {
        this.body(this.item)
      }
    }
    .id('itemRoot')
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding($r('app.float.video_item_search_padding'))
    .stateStyles({ normal: localItemRowNormal, pressed: localItemRowPressed })
    .onClick(() => {
      if (this.item !== null) {
        this.onSelected(this.item);
      }
    })
    .gesture(
      LongPressGesture()
        .onAction(() => {
          if (this.item !== null) {
            this.onHeld(this.item);
          }
        })
    )
  }
}
