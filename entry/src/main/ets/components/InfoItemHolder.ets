/*
 * S3 - port of org.schabi.newpipe.info_list.holder.InfoItemHolder, the abstract base every
 * info-list row extends. ArkUI structs cannot be extended, so the base's ONE concrete job -
 * owning `itemView` (the row root every list_*_item.xml calls @+id/itemRoot) and the click /
 * long-click gestures the concrete holders install on it - becomes this wrapper struct, and the
 * concrete holder renders as its body.
 *
 * `itemRoot` is deliberately ONE shared id across all N rows (Rule 12's list-row exception): the
 * replay resolves `tap-card-N` by index, not by a unique id.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';

/** A gesture the owning page has not bound yet - never silently empty. */
function unwiredGesture(which: string): void {
  hilog.debug(0x0000, 'NewPipe', 'InfoItemHolder: %{public}s not bound', which);
}

@Component
export struct InfoItemHolder {
  /** itemView.setOnClickListener - what the concrete holder does when the row is selected. */
  onSelected: () => void = (): void => {
    unwiredGesture('onSelected');
  };
  /** itemView.setOnLongClickListener - held(item): the info-item dialog, or copy-to-clipboard. */
  onHeld: () => void = (): void => {
    unwiredGesture('onHeld');
  };
  @BuilderParam body: () => void = this.emptyBody;

  @Builder
  emptyBody() {
    Row()
  }

  build() {
    Column() {
      this.body()
    }
    .id('itemRoot')
    .width('100%')
    .onClick(() => {
      this.onSelected();
    })
    .gesture(LongPressGesture().onAction(() => {
      this.onHeld();
    }))
  }
}
