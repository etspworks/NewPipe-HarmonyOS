/*
 * Port of shared/src/commonMain/kotlin/net/newpipe/app/screen/settings/model/
 * SettingsCategory.kt - one row of the settings home screen.
 *
 * Compose Multiplatform's `StringResource` / `DrawableResource` are compile-time resource
 * handles. ArkUI resolves resources by name at runtime, so the two fields carry the migrated
 * resource NAMES: `title` is a `<string name=...>` in string.json, `icon` a file base name in
 * resources/base/media. The screen turns them into `$r('app.string.<title>')` and
 * `$r('app.media.<icon>')`.
 */

export class SettingsCategory {
  /** Name of the migrated string resource for the row title. */
  title: string = '';
  /** Base name of the migrated media resource for the row icon. */
  icon: string = '';
  /**
   * The source's `onClick: () -> Unit = {}` with the TODO "Replace with a Destination once
   * sub-screens are migrated". Here it is the settings sub-screen this row opens, by route name;
   * '' means the row is not navigable yet, exactly as the empty lambda meant.
   */
  destination: string = '';

  constructor(title: string = '', icon: string = '', destination: string = '') {
    this.title = title;
    this.icon = icon;
    this.destination = destination;
  }
}
