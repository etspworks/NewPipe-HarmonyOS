/*
 * Port of app/src/main/java/org/schabi/newpipe/settings/preferencesearch/
 * PreferenceSearchItem.kt - one settings entry inside the settings search index.
 *
 * `@XmlRes searchIndexItemResId` pointed at the preference XML the item was built from. The
 * migrated settings screens are ArkUI, not XML, so the field carries the settings-screen route
 * name instead - the same "where does this setting live" role, resolvable by the router.
 */

export class PreferenceSearchItem {
  /** Key of the setting, as in SettingsKeys.ts. */
  key: string = '';
  /** Title of the setting, e.g. 'Default resolution'. */
  title: string = '';
  /** Summary of the setting, e.g. '480p'. */
  summary: string = '';
  /** Possible entries of the setting, e.g. '480p,720p,...'. */
  entries: string = '';
  /** Where the setting lives, e.g. 'Video and Audio > Player'. */
  breadcrumbs: string = '';
  /** The settings screen this item was built from. */
  searchIndexItemResId: string = '';

  constructor(key: string = '', title: string = '', summary: string = '', entries: string = '',
    breadcrumbs: string = '', searchIndexItemResId: string = '') {
    this.key = key;
    this.title = title;
    this.summary = summary;
    this.entries = entries;
    this.breadcrumbs = breadcrumbs;
    this.searchIndexItemResId = searchIndexItemResId;
  }

  get allRelevantSearchFields(): string[] {
    return [this.title, this.summary, this.entries, this.breadcrumbs];
  }

  hasData(): boolean {
    return this.key.length > 0 && this.title.length > 0;
  }

  toString(): string {
    return `PreferenceItem: ${this.title} ${this.summary} ${this.key}`;
  }
}
