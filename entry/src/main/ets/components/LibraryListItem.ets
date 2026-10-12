/*
 * S3 - port of shared/.../composable/about/LibraryListItem.kt.
 *
 *   val description = when {
 *       library.developers.isNotEmpty() && library.licenses.isNotEmpty() ->
 *           stringResource(Res.string.license, developers.first().name, licenses.first())
 *       else -> stringResource(Res.string.not_available)
 *   }
 *   ListItem(modifier.testTag("license_library_itemroot"), onClick = onClick,
 *            enabled = library.licenses.isNotEmpty()) { Column { Text(name); Text(description) } }
 *
 * `enabled` is the source's OWN guard, not an invented one: a library that declares no licence
 * has nothing to open, so its row is rendered disabled AND its description falls back to
 * @string/not_available. Both halves of that conditionalVariant live here.
 */

/*
 * S5 - no captured sid for this screen, so the style is the shared Compose module's own
 * Material3 scheme (theme/Color.kt) plus ListItemDefaults: a headline in onSurfaceLight and a
 * supporting line in onSurfaceVariantLight, inside the M3 list-item box (16dp horizontal,
 * 8dp vertical). No app-wide XML theme value applies to this screen.
 */
import { Library } from '../model/app/Library';
import { Localization } from '../common/i18n/Localization';

/**
 * LibraryListItem.kt:35-46 - the `when` block. Exported because the page's own description
 * binding reads the same rule.
 */
const COLOR_ON_SURFACE: string = '#231918';
const COLOR_ON_SURFACE_VARIANT: string = '#534342';
/** ListItemDefaults: 16dp start/end, 8dp top/bottom around a two-line item. */
const LIST_ITEM_PADDING_HORIZONTAL: number = 16;
const LIST_ITEM_PADDING_VERTICAL: number = 8;

export function libraryDescription(library: Library): string {
  if (library.developers.length > 0 && library.licenses.length > 0) {
    return Localization.getStringArgs('license',
      [library.developers[0].name, library.licenses[0]]);
  }
  return Localization.getString('not_available');
}

@Component
export struct LibraryListItem {
  /** One entry of the parsed AboutLibraries BOM. */
  library: Library = new Library();
  /** the row's tap (named onSelected: a member called `onClick` collides with
   *  CustomComponent's own onClick attribute) -> licenseToShow = License(name, website, licenses.first()); show the dialog. */
  onSelected: () => void = (): void => {
    console.info('LibraryListItem: onSelected not bound');
  };

  build() {
    Column() {
      Text(this.library.name)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .lineHeight(24)
        .fontColor(COLOR_ON_SURFACE)
        .width('100%')
      Text(libraryDescription(this.library))
        .fontSize(14)
        .lineHeight(20)
        .fontColor(COLOR_ON_SURFACE_VARIANT)
        .width('100%')
    }
    .id('license_library_itemroot')
    .width('100%')
    .padding({
      left: LIST_ITEM_PADDING_HORIZONTAL,
      right: LIST_ITEM_PADDING_HORIZONTAL,
      top: LIST_ITEM_PADDING_VERTICAL,
      bottom: LIST_ITEM_PADDING_VERTICAL
    })
    .alignItems(HorizontalAlign.Start)
    // enabled = library.licenses.isNotEmpty(): no licence, nothing to open, row not tappable.
    .enabled(this.library.licenses.length > 0)
    .onClick((): void => {
      this.onSelected();
    })
  }
}
