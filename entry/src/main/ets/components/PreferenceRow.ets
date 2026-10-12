/**
 * S3 — port of net.newpipe.app.composable.PreferenceRow (shared/composable/PreferenceRow.kt).
 *
 * "A row that mirrors the standard AndroidX preference item": a Material3 ListItem whose
 * headlineContent is the title, whose supportingContent is the optional summary line, and whose
 * leadingContent is an optional icon — `icon: Painter? = null` HIDES the leading slot when null,
 * which is why the icon is a slot here rather than a value.
 *
 * `Modifier.testTag("preference_itemroot")` is the source's own row id, so it is the `.id()` here:
 * one SHARED slug across every row (Rule 12's list-row exception), resolved by index at replay.
 *
 * S5: Material3 ListItem metrics — a 56dp one-line row (72dp with a supporting line),
 * 16dp horizontal inset and a 16dp gap between the leading icon and the text block.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';

@Component
export struct PreferenceRow {
  /** headlineContent = { Text(text = title) }. */
  title: ResourceStr = '';
  /** supportingContent = summary?.let { ... } — the line is absent, not blank, when null. */
  summary: ResourceStr | null = null;
  /** leadingContent = icon?.let { Icon(...) } — the host supplies the literal media resource. */
  @BuilderParam leading: () => void = this.noIcon;
  /** Whether the caller supplied a leading icon at all (`icon != null`). */
  hasIcon: boolean = false;
  /** Modifier.clickable(onClick = onClick). SettingsHomeScreen passes a TODO no-op. */
  onRowClick: () => void = (): void => {
    // The source's `onClick: () -> Unit = {}` default: a row nobody wired does nothing.
    hilog.debug(0x0000, 'NewPipe', 'PreferenceRow: onClick left at the source default (no destination yet)');
  };

  @Builder
  noIcon() {
    Row()
  }

  build() {
    Row() {
      if (this.hasIcon) {
        this.leading()
      }

      Column() {
        // headlineContent: bodyLarge on onSurface.
        Text(this.title)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontSize(16)
          .fontColor($r('app.color.on_surface'))

        if (this.summary !== null) {
          // supportingContent: bodyMedium on onSurfaceVariant.
          Text(this.summary)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontSize(14)
            .fontColor($r('app.color.on_surface_variant'))
            .margin({ top: 2 })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      // leadingContent gap; without an icon the text keeps the list's own 16dp inset.
      .margin({ left: this.hasIcon ? 16 : 0 })
    }
    .id('preference_itemroot')
    .width('100%')
    .constraintSize({ minHeight: 56 })
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.onRowClick();
    })
  }
}
