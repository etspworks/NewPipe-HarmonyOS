/*
 * S3 — port of org.schabi.newpipe.local.subscription.item.PickerIconItem (picker_icon_item.xml).
 *
 * The whole item IS the ImageView: a single `icon_view` ImageView, match_parent wide,
 * wrap_content tall, minWidth/minHeight 24dp, 8dp padding, scaleType centerInside, focusable and
 * backed by ?attr/selectableItemBackground. One cell of the 7-column icon_selector grid.
 *
 * The tap is the adapter's OnItemClickListener in FeedGroupDialog.setupIconPicker():
 *   selectedIcon = item.icon; iconPreview.setImageResource(item.iconRes); showScreen(InitialScreen)
 * — the owning page runs that, so the effect arrives as `onSelected`.
 *
 * Rule 12: the row is repeated, so every cell carries the SAME id — `icon_view`, the layout's own
 * pre-existing slug, which is what the capture recorded.
 *
 * S5 owns the visual finish (selectable-item background, exact glyph tint).
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FeedGroupIcon, feedGroupIconDrawable } from '../model/enums/FeedGroupIcon';
import { mediaByName } from './SelectedTabsAdapter';

@Component
export struct PickerIconItem {
  /** PickerIconItem(icon): the enum entry this cell stands for. */
  icon: FeedGroupIcon = FeedGroupIcon.ALL;
  onSelected: () => void = (): void => {
    hilog.debug(0x0000, 'NewPipe', 'PickerIconItem: onSelected not bound');
  };

  build() {
    // getDrawableRes() gives a drawable NAME, so it is resolved at runtime, not with $r sugar.
    Image(mediaByName(feedGroupIconDrawable(this.icon)))
      .id('icon_view')
      .width('100%')
      .height(40)
      .constraintSize({ minWidth: 24, minHeight: 24 })
      .padding(8)
      .borderRadius(2)
      .objectFit(ImageFit.Contain)
      .onClick(() => {
        this.onSelected();
      })
  }
}
