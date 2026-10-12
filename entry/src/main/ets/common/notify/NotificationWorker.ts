/*
 * Port of org.schabi.newpipe.local.feed.notifications.NotificationWorker's companion: the periodic
 * new-streams check is a WorkScheduler deferred task here (WorkManager's counterpart), run by
 * workers/NotificationWorkerAbility.ets, which loads the feed of every channel with notifications
 * on and posts the new streams - the same work as Debug > "Check for new streams".
 *
 * The system decides the real cadence: the interval is a floor, raised to the platform's minimum
 * (20 minutes) and further spaced by the app's activity group (2 h for an app in active use).
 */

import { workScheduler } from '@kit.BackgroundTasksKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppPreferences } from '../prefs/Preferences';
import {
  enable_streams_notifications, streams_notifications_interval_default,
  streams_notifications_interval_key, streams_notifications_network_key,
  streams_notifications_network_wifi
} from '../prefs/SettingsKeys';

const TAG: string = 'NotificationWorker';
/** WORK_TAG: one deferred task, identified by its id. */
const WORK_ID: number = 1;
/** The ExtensionAbility that runs it (module.json5, type workScheduler). */
export const NOTIFICATION_WORKER_ABILITY: string = 'NotificationWorkerAbility';
/**
 * workScheduler's lower bound for repeatCycleTime (a repeating deferred task runs at most every
 * 20 minutes). Settings > Notifications shows it on the one interval below it, 15 minutes, rather
 * than letting the clamp below go unseen.
 */
export const MIN_REPEAT_MS: number = 20 * 60 * 1000;

/** ScheduleOptions.from(context). */
export class ScheduleOptions {
  readonly interval: number;
  readonly isRequireNonMeteredNetwork: boolean;

  constructor(interval: number, isRequireNonMeteredNetwork: boolean) {
    this.interval = interval;
    this.isRequireNonMeteredNetwork = isRequireNonMeteredNetwork;
  }

  static from(prefs: AppPreferences): ScheduleOptions {
    const seconds: number = parseInt(prefs.getStringSync(streams_notifications_interval_key,
      streams_notifications_interval_default), 10);
    const interval: number = (isNaN(seconds)
      ? parseInt(streams_notifications_interval_default, 10) : seconds) * 1000;
    const network: string = prefs.getStringResolvedSync(streams_notifications_network_key,
      streams_notifications_network_wifi);
    return new ScheduleOptions(interval, network === streams_notifications_network_wifi);
  }
}

function workInfo(bundleName: string, options: ScheduleOptions): workScheduler.WorkInfo {
  return {
    workId: WORK_ID,
    bundleName: bundleName,
    abilityName: NOTIFICATION_WORKER_ABILITY,
    // NetworkType.UNMETERED / CONNECTED
    networkType: options.isRequireNonMeteredNetwork
      ? workScheduler.NetworkType.NETWORK_TYPE_WIFI : workScheduler.NetworkType.NETWORK_TYPE_ANY,
    isRepeat: true,
    repeatCycleTime: Math.max(options.interval, MIN_REPEAT_MS)
  };
}

export class NotificationWorker {
  /**
   * schedule(context, options, force): KEEP leaves a scheduled task alone, force replaces it
   * (CANCEL_AND_REENQUEUE) so a changed interval or network takes effect.
   */
  static async schedule(bundleName: string, options: ScheduleOptions, force: boolean):
    Promise<void> {
    if (!force) {
      try {
        await workScheduler.getWorkStatus(WORK_ID);
        return;
      } catch (err) {
        // no task with this id yet: schedule one
      }
    }
    try {
      try {
        workScheduler.stopWork(workInfo(bundleName, options), true);
      } catch (stopErr) {
        // nothing to replace
      }
      workScheduler.startWork(workInfo(bundleName, options));
      hilog.info(0x0000, TAG, 'scheduled every %{public}d ms, unmetered=%{public}s',
        options.interval, String(options.isRequireNonMeteredNetwork));
    } catch (err) {
      hilog.error(0x0000, TAG, 'startWork failed: %{public}s', (err as Error).message);
    }
  }

  /** cancel(context): cancelAllWorkByTag(WORK_TAG). */
  static cancel(bundleName: string, prefs: AppPreferences): void {
    try {
      workScheduler.stopWork(workInfo(bundleName, ScheduleOptions.from(prefs)), true);
    } catch (err) {
      // nothing was scheduled
    }
  }

  /**
   * initialize(context): schedule while the in-app AND the device switches allow new-streams
   * notifications, cancel otherwise. MainActivity runs it on every start.
   */
  static async initialize(bundleName: string, prefs: AppPreferences, deviceAllows: boolean):
    Promise<void> {
    if (prefs.getBooleanSync(enable_streams_notifications, false) && deviceAllows) {
      await NotificationWorker.schedule(bundleName, ScheduleOptions.from(prefs), false);
    } else {
      NotificationWorker.cancel(bundleName, prefs);
    }
  }
}
