/*
 * S3 — port of org.schabi.newpipe.local.subscription.item.FeedGroupCarouselItem
 * (feed_item_carousel.xml#recycler_view): the HORIZONTALLY scrolling nested GroupAdapter that
 * carries the feed-group cards, whose scroll position the fragment saves and restores
 * (feedGroupsCarouselState).
 *
 * The cards themselves are supplied by the owning page — it is the page that knows the list/grid
 * view mode and owns every card's click. The carousel is a SCROLL container and nothing else: it
 * carries no click of its own (the source RecyclerView dumps clickable="false"; its rows carry
 * the clicks).
 */
@Component
export struct FeedGroupCarouselItem {
  @BuilderParam content: () => void = this.emptyContent;

  @Builder
  emptyContent() {
    Row()
  }

  build() {
    // S5 - layout, from the source AND the capture, which agree against the S3 horizontal row:
    // updateViewMode() gives the carousel a plain LinearLayoutManager in list view mode, and
    // feed_item_carousel is layout_height="wrap_content" inside the vertical items_list, so the
    // cards STACK and the RecyclerView does not scroll on its own. The capture shows exactly
    // that - feed_group_add_new above feed_group_itemroot, each the full width.
    // Grid view mode swaps that LinearLayoutManager for a GridLayoutManager of
    // getGridSpanCount(context, 112dp) columns = 3 on every phone width the app supports
    // (1080/336). ONE wrapping Flex serves both: the cards carry their own width, so a card at
    // calc(100% - 8vp) takes a line to itself (list mode) and three at calc(33.33% - 8vp) sit
    // side by side (grid mode) — exactly the two capture layouts.
    Flex({ wrap: FlexWrap.Wrap }) {
      this.content()
    }
    .id('recycler_view')
    .width('100%')
    .margin(4)
  }
}
