/*
 * S3 — port of org.schabi.newpipe.local.subscription.item.FeedGroupCardItem
 * (feed_group_card_item.xml), and its FeedGroupCardGridItem variant.
 *
 *   tap        -> NavigationHelper.openFeedFragment(fm, groupId, name)
 *   long-press -> FeedGroupDialog.newInstance(groupId) — EXCEPT for the built-in All group
 *                 (GROUP_ALL_ID), whose long-press listener returns false.
 *
 * `feed_group_itemroot` is ONE shared id across all N cards (Rule 12's list-row exception).
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { FeedGroupIcon, feedGroupIconDrawable } from '../model/enums/FeedGroupIcon';
import { FeedGroupEntity } from '../model/db/entity/FeedGroupEntity';

/**
 * FeedGroupIcon.getDrawableRes() gives a drawable NAME, not a fixed resource, so the icon has to
 * be resolved at runtime — the $r sugar only takes a literal. This is exactly what that sugar
 * compiles to (type 20000 = media, resolved by the name in `params`).
 *
 * ponytail: a by-name lookup rather than a 39-branch switch of $r literals. Upgrade path: if a
 * name ever has to be checked at build time, replace it with the switch.
 */
function mediaByName(name: string): Resource {
  const resource: Resource = {
    bundleName: '',
    moduleName: '',
    id: -1,
    params: [`app.media.${name}`],
    type: 20000
  };
  return resource;
}

@Component
export struct FeedGroupCardItem {
  groupId: number = 0;
  name: string = '';
  icon: FeedGroupIcon = FeedGroupIcon.ALL;
  /** viewModel.getListViewMode(): the card variant vs the grid one. */
  @Prop gridMode: boolean = false;
  onSelected: () => void = (): void => {
    hilog.debug(0x0000, 'NewPipe', 'FeedGroupCardItem: onSelected not bound');
  };
  onHeld: () => void = (): void => {
    hilog.debug(0x0000, 'NewPipe', 'FeedGroupCardItem: onHeld not bound');
  };

  build() {
    Flex({
      direction: this.gridMode ? FlexDirection.Column : FlexDirection.Row,
      // Row direction: Stretch is what gives the title layout_height="match_parent" (its two-tone
      // band fills the card) without a height:'100%' that resolves against an unbounded parent.
      alignItems: this.gridMode ? ItemAlign.Center : ItemAlign.Stretch
    }) {
      // 48dp box, 8dp padding, centerInside (36dp wide with 4dp padding in the grid variant).
      Image(mediaByName(feedGroupIconDrawable(this.icon)))
        .id('icon')
        .width(this.gridMode ? 36 : 48)
        .height(this.gridMode ? 36 : 48)
        .padding(this.gridMode ? 4 : 8)
        .objectFit(ImageFit.Contain)

      // The title fills the rest of the card on ?attr/card_item_contrast_color - the two-tone
      // card the capture shows - 14sp bold on ?attr/colorAccent, 10dp padding.
      Text(this.name)
        .id('title')
        .maxLines(this.gridMode ? 2 : 1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.accent'))
        .backgroundColor($r('app.color.surface_variant'))
        .padding(this.gridMode ? 2 : 10)
        .textAlign(this.gridMode ? TextAlign.Center : TextAlign.Start)
        // Same as the add-new row: weight belongs to the ROW variant only (layout_width=0dp/
        // weight=1). The grid variant is layout_width=match_parent, layout_height=wrap_content —
        // the height is the container's job now, so no Length here at all.
        .width('100%')
        .layoutWeight(this.gridMode ? 0 : 1)
    }
    .id('feed_group_itemroot')
    // One cell of the carousel: full width in list mode, a third of it in grid mode, each minus
    // the 4vp margin below so three cells fit a row exactly.
    .width(this.gridMode ? 'calc(33.33% - 8vp)' : 'calc(100% - 8vp)')
    .margin(4)
    .backgroundColor($r('app.color.surface'))
    .onClick(() => {
      this.onSelected();
    })
    .gesture(LongPressGesture().onAction(() => {
      // setOnLongClickListener returns FALSE for the built-in All group: it can be neither
      // edited nor deleted, so the press does nothing at all here.
      if (this.groupId === FeedGroupEntity.GROUP_ALL_ID) {
        return;
      }
      this.onHeld();
    }))
  }
}
