/*
 * S3 - port of shared/.../composable/about/LinkListItem.kt.
 *
 *   Column(Modifier.fillMaxWidth().padding(spaceMedium)) {
 *     Text(link.title,       titleMedium)
 *     Text(link.description, bodyMedium)
 *     TextButton(Modifier.fillMaxWidth().wrapContentWidth(Alignment.End)
 *                        .testTag("about_link_action_itemroot"), onClick = onAction) {
 *       Text(link.action)
 *     }
 *   }
 *
 * The action button is instantiated FIVE times (one per Link) and every instance carries the
 * SAME testTag, so the shared row slug is the source's own, not an invention (Rule 12's
 * list-row exception).
 */

import { Link } from '../model/app/Link';

/** Dimens.kt spaceMedium. */
const SPACE_MEDIUM: number = 10;
/** ButtonDefaults.MinHeight / TextButtonContentPadding - the M3 TextButton box. */
const BUTTON_HEIGHT: number = 40;
const BUTTON_PADDING: number = 12;
/** theme/Color.kt: onSurfaceLight is the list text, primaryLight the TextButton label. */
const COLOR_ON_SURFACE: string = '#231918';

@Component
export struct LinkListItem {
  /** One Link out of defaultLinks(); the five are static chrome and never change at runtime. */
  link: Link = new Link();
  /** TextButton(onClick = onAction) -> onOpenUrl(link.url) -> shareHandler.openUrlInBrowser. */
  onAction: () => void = (): void => {
    console.info('LinkListItem: onAction not bound');
  };

  build() {
    Column() {
      // The title/description block; the plan's slug for it is about_link_text.
      Column() {
        Text(this.link.title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .lineHeight(24)
          .fontColor(COLOR_ON_SURFACE)
          .width('100%')
        Text(this.link.description)
          .fontSize(14)
          .lineHeight(20)
          .fontColor(COLOR_ON_SURFACE)
          .width('100%')
      }
      .id('about_link_text')
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      // fillMaxWidth().wrapContentWidth(Alignment.End): content-sized, aligned to the end.
      Text(this.link.action)
        .id('about_link_action_itemroot')
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .lineHeight(20)
        // TextButton's label is MaterialTheme.colorScheme.primary (primaryLight #904A45).
        .fontColor($r('app.color.about_link_color'))
        .textAlign(TextAlign.Center)
        .height(BUTTON_HEIGHT)
        .padding({ left: BUTTON_PADDING, right: BUTTON_PADDING })
        .onClick((): void => {
          this.onAction();
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.End)
    .padding(SPACE_MEDIUM)
  }
}
