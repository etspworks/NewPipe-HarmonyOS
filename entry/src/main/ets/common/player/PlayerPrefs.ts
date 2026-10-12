/*
 * PlayerHelper's preference half: the Video & audio settings the player has to obey, read in one
 * place so the detail page, the queue screen and the player service all honour the same values.
 *
 * Every read is guarded: the store is opened by EntryAbility, and a player surface built before it
 * (or a host test) must get the source's defaults rather than an exception.
 */

import connection from '@ohos.net.connection';
import { deviceInfo } from '@kit.BasicServicesKit';
import { AppPreferences } from '../prefs/Preferences';
import { MediaFormat } from '../../model/enums/MediaFormat';
import {
  brightness_control_key, clear_queue_confirmation_key, ignore_hardware_media_buttons_key,
  last_resize_mode, left_gesture_control_key, minimize_on_exit_key, minimize_on_exit_none_key,
  minimize_on_exit_popup_key, playback_pitch_key, playback_skip_silence_key, playback_speed_key,
  resume_on_audio_focus_gain_key, right_gesture_control_key, screen_brightness_key,
  screen_brightness_timestamp_key, seek_duration_default_value, seek_duration_key,
  start_main_player_fullscreen_key, use_inexact_seek_key, volume_control_key,
  best_resolution_key, limit_data_usage_none_key, limit_mobile_data_usage_key,
  default_video_format_key, video_mp4_key, video_webm_key, video_3gp_key,
  default_audio_format_key, audio_m4a_key, audio_webm_key, default_resolution_key,
  default_resolution_value, show_higher_resolutions_key, tablet_mode_key, tablet_mode_on_key,
  tablet_mode_off_key
} from '../prefs/SettingsKeys';

/** PlayerHelper.MinimizeMode. */
export enum MinimizeMode {
  NONE,
  BACKGROUND,
  POPUP
}

/**
 * AspectRatioFrameLayout's RESIZE_MODE_* values, which is what the source stores under
 * last_resize_mode - kept so a settings backup moves between the two apps unchanged.
 */
export const RESIZE_MODE_FIT: number = 0;
export const RESIZE_MODE_FILL: number = 3;
export const RESIZE_MODE_ZOOM: number = 4;

/** PlayerHelper.getScreenBrightness(): a remembered level older than this is not reused. */
const BRIGHTNESS_MEMORY_MS: number = 4 * 60 * 60 * 1000;

function store(): AppPreferences | null {
  try {
    return AppPreferences.instance();
  } catch (err) {
    return null;
  }
}

function readString(key: string, defValue: string): string {
  const prefs: AppPreferences | null = store();
  return prefs === null ? defValue : prefs.getStringSync(key, defValue);
}

function readBoolean(key: string, defValue: boolean): boolean {
  const prefs: AppPreferences | null = store();
  return prefs === null ? defValue : prefs.getBooleanSync(key, defValue);
}

function readNumber(key: string, defValue: number): number {
  const prefs: AppPreferences | null = store();
  return prefs === null ? defValue : prefs.getFloatSync(key, defValue);
}

/**
 * PreferredHeight.preferredHeightOf(), restated: a .ts module may not import an .ets one. '720p60'
 * is 720; 'best_resolution' and anything unreadable are 0, "no ceiling".
 */
function preferredHeightOf(preference: string): number {
  if (preference.length === 0 || preference === best_resolution_key) {
    return 0;
  }
  const height: number = Number.parseInt(preference, 10);
  return Number.isNaN(height) || height <= 0 ? 0 : height;
}

/** apply(): the write lands in memory at once and reaches disk in the background. */
function apply(prefs: AppPreferences): void {
  prefs.flush().catch((): void => {
  });
}

export class PlayerPrefs {
  /** retrieveSeekDurationFromPreferences(): the fast-seek step, in milliseconds. */
  static seekDurationMs(): number {
    const parsed: number = Number.parseInt(readString(seek_duration_key, seek_duration_default_value), 10);
    return Number.isNaN(parsed) || parsed <= 0 ? Number.parseInt(seek_duration_default_value, 10) : parsed;
  }

  /** getSeekParameters(): CLOSEST_SYNC when inexact seek is on, EXACT otherwise. */
  static isUsingInexactSeek(): boolean {
    return readBoolean(use_inexact_seek_key, false);
  }

  static leftGestureAction(): string {
    return readString(left_gesture_control_key, brightness_control_key);
  }

  static rightGestureAction(): string {
    return readString(right_gesture_control_key, volume_control_key);
  }

  static isStartMainPlayerFullscreenEnabled(): boolean {
    return readBoolean(start_main_player_fullscreen_key, false);
  }

  static isResumeAfterAudioFocusGain(): boolean {
    return readBoolean(resume_on_audio_focus_gain_key, false);
  }

  static isClearingQueueConfirmationRequired(): boolean {
    return readBoolean(clear_queue_confirmation_key, false);
  }

  static isIgnoringHardwareMediaButtons(): boolean {
    return readBoolean(ignore_hardware_media_buttons_key, false);
  }

  /** getMinimizeOnExitAction(): anything but the two other keys is the background default. */
  static minimizeOnExitAction(): MinimizeMode {
    const action: string = readString(minimize_on_exit_key, '');
    if (action === minimize_on_exit_popup_key) {
      return MinimizeMode.POPUP;
    }
    return action === minimize_on_exit_none_key ? MinimizeMode.NONE : MinimizeMode.BACKGROUND;
  }

  /** retrieveResizeModeFromPrefs(). */
  static resizeMode(): number {
    return readNumber(last_resize_mode, RESIZE_MODE_FIT);
  }

  /** nextResizeModeAndSaveToPrefs(): fit -> fill -> zoom -> fit, saved for the next session. */
  static nextResizeModeAndSave(current: number): number {
    const next: number = current === RESIZE_MODE_FIT
      ? RESIZE_MODE_FILL : (current === RESIZE_MODE_FILL ? RESIZE_MODE_ZOOM : RESIZE_MODE_FIT);
    const prefs: AppPreferences | null = store();
    if (prefs !== null) {
      prefs.putInt(last_resize_mode, next);
      apply(prefs);
    }
    return next;
  }

  /** getScreenBrightness(): -1 (follow the system) unless a level was set in the last 4 hours. */
  static screenBrightness(): number {
    const timestamp: number = readNumber(screen_brightness_timestamp_key, 0);
    if (Date.now() - timestamp > BRIGHTNESS_MEMORY_MS) {
      return -1;
    }
    return readNumber(screen_brightness_key, -1);
  }

  static saveScreenBrightness(level: number): void {
    const prefs: AppPreferences | null = store();
    if (prefs === null) {
      return;
    }
    prefs.putFloat(screen_brightness_key, level);
    prefs.putLong(screen_brightness_timestamp_key, Date.now());
    apply(prefs);
  }

  /** retrievePlaybackParametersFromPrefs(): the speed the last session ended on. */
  static playbackSpeed(defValue: number): number {
    return readNumber(playback_speed_key, defValue);
  }

  static playbackPitch(defValue: number): number {
    return readNumber(playback_pitch_key, defValue);
  }

  static playbackSkipSilence(): boolean {
    return readBoolean(playback_skip_silence_key, false);
  }

  /** savePlaybackParametersToPrefs(). */
  static savePlaybackParameters(speed: number, pitch: number, skipSilence: boolean): void {
    const prefs: AppPreferences | null = store();
    if (prefs === null) {
      return;
    }
    prefs.putFloat(playback_speed_key, speed);
    prefs.putFloat(playback_pitch_key, pitch);
    prefs.putBoolean(playback_skip_silence_key, skipSilence);
    apply(prefs);
  }

  /**
   * ListHelper.isMeteredNetwork(): the source asks ConnectivityManager and, with no active
   * network, answers false. ponytail: cellular stands for metered; a metered Wi-Fi would need
   * NET_CAPABILITY_NOT_METERED read off the same capabilities.
   */
  static isMeteredNetwork(): boolean {
    try {
      const caps: connection.NetCapabilities =
        connection.getNetCapabilitiesSync(connection.getDefaultNetSync());
      const bearers: connection.NetBearType[] = caps.bearerTypes;
      return bearers !== undefined && bearers !== null
        && bearers.includes(connection.NetBearType.BEARER_CELLULAR);
    } catch (err) {
      return false;
    }
  }

  /** getResolutionLimit(): the mobile-data ceiling, only while on a metered network. */
  static resolutionLimit(): string | null {
    if (!PlayerPrefs.isMeteredNetwork()) {
      return null;
    }
    const value: string = readString(limit_mobile_data_usage_key, limit_data_usage_none_key);
    return value === limit_data_usage_none_key || value.length === 0 ? null : value;
  }

  static isLimitingDataUsage(): boolean {
    return PlayerPrefs.resolutionLimit() !== null;
  }

  /**
   * computeDefaultResolution(): the stored resolution, lowered to the mobile-data limit when one
   * applies ("best" counts as above any limit).
   */
  static computeDefaultResolution(key: string = default_resolution_key,
    defValue: string = default_resolution_value): string {
    let resolution: string = readString(key, defValue);
    const limit: string | null = PlayerPrefs.resolutionLimit();
    if (limit !== null && (resolution === best_resolution_key
      || preferredHeightOf(limit) <= preferredHeightOf(resolution))) {
      resolution = limit;
    }
    return resolution;
  }

  /**
   * The height a start with no quality control behind it - a queue row, a list's in-place start -
   * asks the player for: the default resolution as the detail page reads it. "Best" and anything
   * above 1080p ask for 1080p, the tallest rung this player can build (README, Known limits) -
   * which is also all show_higher_resolutions could add here.
   */
  static defaultPlaybackHeight(): number {
    const height: number = preferredHeightOf(PlayerPrefs.computeDefaultResolution());
    return height === 0 || height > 1080 ? 1080 : height;
  }

  static showHigherResolutions(): boolean {
    return readBoolean(show_higher_resolutions_key, false);
  }

  /** getDefaultFormat(default_video_format): MPEG-4 unless the user chose otherwise. */
  static defaultVideoFormat(): MediaFormat | null {
    const key: string = readString(default_video_format_key, video_mp4_key);
    if (key === video_webm_key) {
      return MediaFormat.WEBM;
    }
    if (key === video_3gp_key) {
      return MediaFormat.v3GPP;
    }
    return key === video_mp4_key || key.startsWith('@string/') ? MediaFormat.MPEG_4 : null;
  }

  /** getDefaultFormat(default_audio_format): M4A unless the user chose otherwise. */
  static defaultAudioFormat(): MediaFormat | null {
    const key: string = readString(default_audio_format_key, audio_m4a_key);
    if (key === audio_webm_key) {
      return MediaFormat.WEBMA;
    }
    return key === audio_m4a_key || key.startsWith('@string/') ? MediaFormat.M4A : null;
  }

  /**
   * DeviceUtils.isTablet(): the Tablet mode setting decides when it is On or Off; Automatic asks
   * the device itself (a tablet or a 2-in-1 - the large-screen layouts the source's
   * SCREENLAYOUT_SIZE_LARGE stands for).
   */
  static isTablet(): boolean {
    const mode: string = readString(tablet_mode_key, '');
    if (mode === tablet_mode_on_key) {
      return true;
    }
    if (mode === tablet_mode_off_key) {
      return false;
    }
    const type: string = deviceInfo.deviceType;
    return type === 'tablet' || type === '2in1';
  }
}
