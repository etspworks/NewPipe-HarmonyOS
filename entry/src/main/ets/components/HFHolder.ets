/*
 * S3 - port of InfoListAdapter.HFHolder (InfoListAdapter.java:353): the HEADER_TYPE / FOOTER_TYPE
 * row, a ViewHolder wrapping whatever view the fragment supplied.
 *
 * The header view comes from BaseListInfoFragment.getListHeaderSupplier() - on
 * CommentRepliesFragment that is comment_replies_header, the parent comment in full. The footer
 * is pignate_footer, the load-more progress row.
 */
@Component
export struct HFHolder {
  @BuilderParam view: () => void = this.emptyView;

  @Builder
  emptyView() {
    Row()
  }

  build() {
    Column() {
      this.view()
    }
    .width('100%')
  }
}
