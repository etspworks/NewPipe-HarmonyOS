/*
 * svc_background_work - replaces androidx.work (dependency-decisions.json: androidx.work ->
 * BackgroundTasksKit) for the three long-running jobs NewPipe schedules: the feed update
 * (FeedLoadService / FeedUpdateWorker), the subscription import/export workers, and the download
 * transfers of DownloadManagerService.
 *
 * Substitution (phase2-logic-contract.md section 2.6, self-signed-capabilities.md): the app keeps
 * running in the background through `ohos.permission.KEEP_BACKGROUND_RUNNING` +
 * `backgroundModes: ["audioPlayback", "dataTransfer"]` + a BackgroundTasksKit CONTINUOUS TASK.
 * There is NO `NOTIFICATION_CONTROLLER`: media controls come from AVSession, and this module
 * never posts a notification itself. `module.json5` already carries the permission and the modes
 * and is not touched here.
 *
 * What WorkManager gave that this does not, and what replaces it:
 *   - Constraints (network type, charging) - `canDownloadInCurrentNetwork()` in
 *     common/download/DownloadManager.ts already makes the one constraint NewPipe actually used
 *     (metered network) an explicit check, which is where the source ALSO made it
 *     (DownloadManager.handleConnectivityState), so nothing is lost.
 *   - Persistence across a reboot - a continuous task ends with the app. The feed update is
 *     re-run on next launch, which the source also does when the periodic worker has not fired.
 *
 * Rule 8: `startBackgroundRunning` is always matched by `stopBackgroundRunning`. A caller uses
 * `runWithBackgroundTask()` and the stop happens in `finally` even if the work throws.
 */

import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { common, wantAgent, WantAgent } from '@kit.AbilityKit';

/** The background modes module.json5 declares, and the only two this app may request. */
export enum BackgroundWorkMode {
  /** Playing audio while the app is not in the foreground. */
  AUDIO_PLAYBACK,
  /** Transferring data: the download manager, the feed update, subscription import/export. */
  DATA_TRANSFER
}

function modeName(mode: BackgroundWorkMode): string {
  return mode === BackgroundWorkMode.AUDIO_PLAYBACK ? 'audioPlayback' : 'dataTransfer';
}

export class BackgroundWork {
  private context: common.UIAbilityContext | null = null;
  private bundleName: string = '';
  private abilityName: string = 'EntryAbility';
  /** How many callers currently hold each mode, so nested work does not stop the task early. */
  private readonly holds: Map<BackgroundWorkMode, number> =
    new Map<BackgroundWorkMode, number>();
  /**
   * A UIAbility has exactly ONE continuous task, whatever it was requested for, so this class is
   * its single owner: the mode names it is currently up with, joined, and '' while it is down.
   * MediaSessionService used to request "audioPlayback" on its own while this class requested
   * "dataTransfer" for the feed/download lane; each one's stopBackgroundRunning() then cancelled
   * the other's task, which is what killed background playback on the second start.
   */
  private runningModes: string = '';

  /** Called once from EntryAbility through ServiceLocator. */
  init(context: common.UIAbilityContext, bundleName: string, abilityName: string): void {
    this.context = context;
    this.bundleName = bundleName;
    this.abilityName = abilityName;
  }

  private requireContext(): common.UIAbilityContext {
    const ctx: common.UIAbilityContext | null = this.context;
    if (ctx === null) {
      throw new Error('BackgroundWork used before ServiceLocator.init()');
    }
    return ctx;
  }

  /** The WantAgent the system uses when the user taps the continuous-task entry. */
  private async taskWantAgent(): Promise<WantAgent> {
    const info: wantAgent.WantAgentInfo = {
      wants: [{ bundleName: this.bundleName, abilityName: this.abilityName }],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    return await wantAgent.getWantAgent(info);
  }

  private holdCount(mode: BackgroundWorkMode): number {
    const count: number | undefined = this.holds.get(mode);
    return count === undefined ? 0 : count;
  }

  /** The modes with at least one holder, in a stable order so the joined form compares. */
  private activeModeNames(): string[] {
    const names: string[] = [];
    if (this.holdCount(BackgroundWorkMode.AUDIO_PLAYBACK) > 0) {
      names.push(modeName(BackgroundWorkMode.AUDIO_PLAYBACK));
    }
    if (this.holdCount(BackgroundWorkMode.DATA_TRANSFER) > 0) {
      names.push(modeName(BackgroundWorkMode.DATA_TRANSFER));
    }
    return names;
  }

  /**
   * Brings the ability's single continuous task in line with the modes currently held: started
   * on the first hold, UPDATED rather than restarted when the second mode joins or leaves, and
   * stopped only once nothing is held at all. Never cancels a task another mode still needs.
   */
  private async applyModes(): Promise<boolean> {
    const names: string[] = this.activeModeNames();
    const wanted: string = names.join(',');
    if (wanted === this.runningModes) {
      return true;
    }
    const ctx: common.UIAbilityContext = this.requireContext();
    try {
      if (names.length === 0) {
        await backgroundTaskManager.stopBackgroundRunning(ctx);
      } else if (this.runningModes.length === 0) {
        await backgroundTaskManager.startBackgroundRunning(ctx, names, await this.taskWantAgent());
      } else {
        await backgroundTaskManager.updateBackgroundRunning(ctx, names);
      }
      this.runningModes = wanted;
      return true;
    } catch (err) {
      if (names.length === 0) {
        // The only way the stop fails is that nothing was running, which is the state wanted.
        this.runningModes = '';
        return true;
      }
      return false;
    }
  }

  /**
   * Takes a hold on `mode`, starting or widening the continuous task as needed.
   * Returns false when the task could not be started; the work may still run, it just will not
   * survive the app going to the background - which is what the caller has to decide about.
   */
  async start(mode: BackgroundWorkMode): Promise<boolean> {
    this.holds.set(mode, this.holdCount(mode) + 1);
    const held: boolean = await this.applyModes();
    if (!held) {
      this.holds.set(mode, this.holdCount(mode) - 1);
    }
    return held;
  }

  /** Releases one hold on `mode`, narrowing or stopping the task once it was the last one. */
  async stop(mode: BackgroundWorkMode): Promise<void> {
    const current: number = this.holdCount(mode);
    if (current <= 0) {
      // This caller never started anything: the live task belongs to the other mode's owner and
      // stopping it here is what cancelled background audio from underneath the media session.
      return;
    }
    this.holds.set(mode, current - 1);
    await this.applyModes();
  }

  /**
   * Runs `work` with the continuous task held, releasing it in `finally` whatever happens
   * (Rule 8). This is the only entry point callers should need.
   */
  async runWithBackgroundTask<T>(mode: BackgroundWorkMode, work: () => Promise<T>): Promise<T> {
    await this.start(mode);
    try {
      return await work();
    } finally {
      await this.stop(mode);
    }
  }

  /** Releases every held task; called from EntryAbility.onDestroy. */
  async releaseAll(): Promise<void> {
    this.holds.clear();
    this.runningModes = '';
    try {
      await backgroundTaskManager.stopBackgroundRunning(this.requireContext());
    } catch (err) {
      // nothing was running
    }
  }
}
