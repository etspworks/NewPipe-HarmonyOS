/*
 * S3 — port of org.schabi.newpipe.local.HeaderFooterHolder: LocalItemListAdapter's HEADER_TYPE /
 * FOOTER_TYPE row, which wraps whatever view the fragment supplies.
 *
 * BaseLocalListFragment.getListHeaderSupplier() returns null by default and BookmarkFragment does
 * not override it, so on that screen `hasHeader()` is false and this slot renders nothing.
 * LocalPlaylistFragment DOES supply one (the playlist header + play controls).
 */
@Component
export struct HeaderFooterHolder {
  @BuilderParam content: () => void = this.emptyContent;

  @Builder
  emptyContent() {
    Row()
  }

  build() {
    Column() {
      this.content()
    }
    .width('100%')
  }
}
