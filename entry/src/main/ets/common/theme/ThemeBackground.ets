/*
 * ThemeHelper's black theme: BlackTheme only replaces the dark theme's window background with
 * @color/black_background_color. HarmonyOS resources know dark and light but no third mode, so the
 * window background is the one colour chosen here, from an AppStorage flag every screen observes;
 * everything else stays the dark palette, as in the source.
 */

import { ConfigurationConstant } from '@kit.AbilityKit';
import {
  auto_device_theme_key, black_theme_key, default_night_theme_value, default_theme_value,
  night_theme_key, theme_key
} from '../prefs/SettingsKeys';
import { AppPreferences } from '../prefs/Preferences';

/** AppStorage key: true while the black window background applies. */
export const BLACK_THEME_KEY: string = 'blackThemeActive';
/** @color/black_background_color. */
const BLACK_BACKGROUND: string = '#000000';

/** android:windowBackground under the current theme. */
export function themedBackground(black: boolean): ResourceColor {
  return black ? BLACK_BACKGROUND : $r('app.color.background');
}

/**
 * ThemeHelper.getSelectedThemeKey + isDeviceDarkThemeEnabled: black when the theme is black, or
 * when it follows the device, the device is in dark mode and the night theme is black.
 */
export function isBlackThemeActive(prefs: AppPreferences, colorMode: ConfigurationConstant.ColorMode):
  boolean {
  const theme: string = prefs.getStringResolvedSync(theme_key, default_theme_value);
  if (theme === black_theme_key) {
    return true;
  }
  if (theme !== auto_device_theme_key) {
    return false;
  }
  return colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK
    && prefs.getStringResolvedSync(night_theme_key, default_night_theme_value) === black_theme_key;
}

/** Publishes the flag; every screen's background follows it. */
export function applyBlackTheme(active: boolean): void {
  AppStorage.setOrCreate<boolean>(BLACK_THEME_KEY, active);
}
