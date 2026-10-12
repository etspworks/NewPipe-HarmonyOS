/*
 * S3 — port of org.schabi.newpipe.local.holder.FallbackViewHolder: LocalItemListAdapter's
 * `default:` branch, reached only when an item's LocalItemType matches no holder. It renders
 * nothing unless something is handed to it.
 */
@Component
export struct FallbackViewHolder {
  message: string = '';

  build() {
    Row() {
      Text(this.message)
    }
    .width('100%')
    .visibility(this.message.length === 0 ? Visibility.None : Visibility.Visible)
  }
}
