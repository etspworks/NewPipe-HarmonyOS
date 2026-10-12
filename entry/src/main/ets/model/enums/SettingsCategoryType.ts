/*
 * Port of net.newpipe.app.screen.settings.model.SettingsCategoryType (NewPipe shared module).
 *
 * The Kotlin enum pairs each category with a StringResource and a DrawableResource. ArkTS enums
 * are uniform-typed, so the enum keeps the identity and SETTINGS_CATEGORY_RESOURCES carries the
 * two resource NAMES, resolved by the UI as $r('app.string.<title>') / $r('app.media.<icon>').
 */
export enum SettingsCategoryType {
  VIDEO_AUDIO,
  DOWNLOADS,
  APPEARANCE,
  HISTORY,
  CONTENT,
  NOTIFICATIONS,
  UPDATES,
  BACKUP_RESTORE,
  DEBUG
}

export class SettingsCategoryResource {
  readonly type: SettingsCategoryType;
  readonly title: string;
  readonly icon: string;

  constructor(type: SettingsCategoryType, title: string, icon: string) {
    this.type = type;
    this.title = title;
    this.icon = icon;
  }
}

/** Declaration order is the order the settings home screen lists the categories in. */
export const SETTINGS_CATEGORY_RESOURCES: SettingsCategoryResource[] = [
  new SettingsCategoryResource(SettingsCategoryType.VIDEO_AUDIO,
    'settings_category_video_audio_title', 'ic_headset'),
  new SettingsCategoryResource(SettingsCategoryType.DOWNLOADS,
    'settings_category_downloads_title', 'ic_file_download'),
  new SettingsCategoryResource(SettingsCategoryType.APPEARANCE,
    'settings_category_appearance_title', 'ic_palette'),
  new SettingsCategoryResource(SettingsCategoryType.HISTORY,
    'settings_category_history_title', 'ic_history'),
  new SettingsCategoryResource(SettingsCategoryType.CONTENT, 'content', 'ic_language'),
  new SettingsCategoryResource(SettingsCategoryType.NOTIFICATIONS,
    'notifications', 'ic_notifications'),
  new SettingsCategoryResource(SettingsCategoryType.UPDATES,
    'settings_category_updates_title', 'ic_cloud_download'),
  new SettingsCategoryResource(SettingsCategoryType.BACKUP_RESTORE,
    'settings_category_backup_restore_title', 'ic_settings_backup_restore'),
  new SettingsCategoryResource(SettingsCategoryType.DEBUG,
    'settings_category_debug_title', 'ic_bug_report')
];

export function settingsCategoryResource(type: SettingsCategoryType): SettingsCategoryResource {
  for (const entry of SETTINGS_CATEGORY_RESOURCES) {
    if (entry.type === type) {
      return entry;
    }
  }
  throw new Error('No resources registered for settings category ' + type);
}
