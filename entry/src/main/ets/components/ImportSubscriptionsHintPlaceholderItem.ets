/*
 * S3 — port of
 * org.schabi.newpipe.local.subscription.item.ImportSubscriptionsHintPlaceholderItem
 * (list_empty_view_subscriptions.xml): the shrug kaomoji plus @string/import_subscriptions_hint,
 * used as the subscriptionsSection PLACEHOLDER while there are no subscriptions.
 *
 * It is a placeholder, so it is EXCLUSIVE with the channel rows — never rendered beside them.
 */
/* S5 - style only: ?android:attr/textAppearanceLarge for the kaomoji, the hint 6dp below it
 * with 16dp of horizontal padding, the whole block centred in a 128dp minimum height. */
const COLOR_ON_SURFACE: Resource = $r('app.color.on_surface');

@Component
export struct ImportSubscriptionsHintPlaceholderItem {
  build() {
    Column() {
      Text('¯\\_(ツ)_/¯')
        .id('import_subscriptions_hint_kaomoji')
        .fontSize(22)
        .fontColor(COLOR_ON_SURFACE)

      Text($r('app.string.import_subscriptions_hint'))
        .id('import_subscriptions_hint_text')
        .textAlign(TextAlign.Center)
        .fontSize(14)
        .fontColor(COLOR_ON_SURFACE)
        .margin({ top: 6 })
        .padding({ left: 16, right: 16 })
    }
    .id('list_empty_view_subscriptions')
    .width('100%')
    .constraintSize({ minHeight: 128 })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}
