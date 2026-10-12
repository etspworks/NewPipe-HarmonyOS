/*
 * S3 — port of org.schabi.newpipe.local.subscription.item.FeedGroupAddNewItem
 * (feed_group_add_new_item.xml), and its FeedGroupAddNewGridItem variant.
 *
 * carouselAdapter.setOnItemClickListener -> FeedGroupDialog.newInstance().show(fm, null).
 * It is ALWAYS the first carousel entry.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';

/* S5 - style only. The CardView is ?attr/card_item_background_color with a 4dp margin, and the
 * LinearLayout inside carries ?attr/dashed_border = @drawable/dashed_border_light (a 1dp
 * light_border_color dashed stroke). ArkUI's border has no dash-width control, so the stroke
 * width, color and Dashed style carry over and the 4dp/4dp dash rhythm does not. */

@Component
export struct FeedGroupAddNewItem {
  /** viewModel.getListViewMode(): the card variant vs the grid one. */
  @Prop gridMode: boolean = false;
  onSelected: () => void = (): void => {
    hilog.debug(0x0000, 'NewPipe', 'FeedGroupAddNewItem: onSelected not bound');
  };

  build() {
    Flex({
      direction: this.gridMode ? FlexDirection.Column : FlexDirection.Row,
      alignItems: ItemAlign.Center
    }) {
      // 48dp box, 8dp padding, centerInside (36dp wide with 4dp padding in the grid variant).
      Image($r('app.media.ic_add'))
        .id('icon')
        .width(this.gridMode ? 36 : 48)
        .height(this.gridMode ? 36 : 48)
        .padding(this.gridMode ? 4 : 8)
        .objectFit(ImageFit.Contain)

      // android:textAllCaps="true", 14sp bold on ?attr/colorAccent, 10dp padding.
      Text($r('app.string.feed_create_new_group_button_title'))
        .id('title')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textCase(TextCase.UpperCase)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.accent'))
        .padding(this.gridMode ? 2 : 10)
        .textAlign(this.gridMode ? TextAlign.Center : TextAlign.Start)
        // feed_group_add_new_item.xml is layout_width=0dp/weight=1 in a HORIZONTAL row; the grid
        // variant is layout_width=match_parent with NO weight. Carrying the weight into the column
        // direction made this row claim the carousel's entire remaining height (2169px on device),
        // which pushed every following card out of the layout.
        .width('100%')
        .layoutWeight(this.gridMode ? 0 : 1)
    }
    .id('feed_group_add_new')
    // One cell of the carousel: full width in list mode, a third of it in grid mode, each minus
    // the 4vp margin below so three cells fit a row exactly.
    .width(this.gridMode ? 'calc(33.33% - 8vp)' : 'calc(100% - 8vp)')
    .margin(4)
    .backgroundColor($r('app.color.surface'))
    .border({
      width: 1,
      color: $r('app.color.border'),
      style: BorderStyle.Dashed
    })
    .onClick(() => {
      this.onSelected();
    })
  }
}
