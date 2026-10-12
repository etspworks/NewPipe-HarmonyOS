/*
 * svc_update_check (endpoint `newpipe_update_check`) - port of
 * app/src/main/java/org/schabi/newpipe/NewVersionWorker.kt plus the two expiry helpers of
 * util/ReleaseVersionUtil.kt.
 *
 * androidx.work maps to BackgroundTasksKit (dependency-decisions.json), but the update check is a
 * one-shot network call with no constraints, so what the Worker actually needed - "run this once,
 * off the UI thread" - is an async function here; `svc_background_work` owns the long-running
 * cases. `Result.success()/failure()` becomes the returned UpdateCheckResult.
 *
 * `ReleaseVersionUtil.isReleaseApk` gated the check on NewPipe's own release signing certificate,
 * because an update from newpipe.net cannot be installed over a differently-signed build. This
 * build is self-signed, so that is always false and the check would never run - the gate is
 * therefore the `update_app_key` preference alone (the source's second condition), and a MANUAL
 * check always runs, exactly as it does in the source.
 */

import { DownloaderImpl } from '../net/Downloader';
import { Response } from '../extractor/downloader/Downloader';
import { AppPreferences } from '../prefs/Preferences';
import { update_app_key, update_expiry_key } from '../prefs/SettingsKeys';

/** NewVersionWorker.NEWPIPE_API_URL, verbatim. */
export const NEWPIPE_API_URL: string = 'https://newpipe.net/api/data.json';

/** The `flavors.newpipe` object of the API response. */
interface RawNewPipeFlavor {
  version?: string;
  version_code?: number;
  apk?: string;
}

interface RawNewPipeFlavors {
  newpipe?: RawNewPipeFlavor;
}

interface RawUpdateResponse {
  flavors?: RawNewPipeFlavors;
}

/** What the update check found. */
export class UpdateCheckResult {
  /** true when a newer version than this build is available. */
  updateAvailable: boolean = false;
  versionName: string = '';
  versionCode: number = 0;
  apkLocationUrl: string = '';
  /** true when the check was skipped (disabled, or checked recently enough). */
  skipped: boolean = false;
  /** Set when the check failed; the source logs and returns Result.failure(). */
  error: Error | null = null;
}

/** Port of ReleaseVersionUtil.isLastUpdateCheckExpired(expiry) - expiry is an epoch SECOND. */
export function isLastUpdateCheckExpired(expiry: number): boolean {
  return expiry * 1000 < Date.now();
}

/**
 * Port of ReleaseVersionUtil.coerceUpdateCheckExpiry(expiryString): the server's RFC-1123
 * `Expires` header, clamped between 6 and 72 hours from now. Returns an epoch second.
 */
export function coerceUpdateCheckExpiry(expiryString: string | null): number {
  const nowPlus6Hours: number = Date.now() + 6 * 3600 * 1000;
  const nowPlus72Hours: number = nowPlus6Hours + 66 * 3600 * 1000;
  if (expiryString === null || expiryString.length === 0) {
    return Math.floor(nowPlus6Hours / 1000);
  }
  const parsed: number = Date.parse(expiryString);
  if (isNaN(parsed)) {
    return Math.floor(nowPlus6Hours / 1000);
  }
  const clamped: number = Math.min(Math.max(parsed, nowPlus6Hours), nowPlus72Hours);
  return Math.floor(clamped / 1000);
}

export class UpdateCheck {
  private prefs: AppPreferences | null = null;
  /** This build's version code, from AppScope/app.json5 - set once by ServiceLocator. */
  private currentVersionCode: number = 0;

  init(prefs: AppPreferences, currentVersionCode: number): void {
    this.prefs = prefs;
    this.currentVersionCode = currentVersionCode;
  }

  private requirePrefs(): AppPreferences {
    const prefs: AppPreferences | null = this.prefs;
    if (prefs === null) {
      throw new Error('UpdateCheck used before ServiceLocator.init()');
    }
    return prefs;
  }

  /**
   * Port of checkNewVersion() + handleResponse(). `isManual` is the source's IS_MANUAL input
   * datum: a manual check ignores both the enabled setting's throttle and the expiry.
   */
  async checkNewVersion(isManual: boolean): Promise<UpdateCheckResult> {
    const result: UpdateCheckResult = new UpdateCheckResult();
    const prefs: AppPreferences = this.requirePrefs();

    if (!isManual) {
      // the user enabled searching for and notifying about updates
      // Default ON, as in a release build: an automatic check runs unless the user turned it off.
      if (!prefs.getBooleanSync(update_app_key, true)) {
        result.skipped = true;
        return result;
      }
      // and the app did not recently check: do not DOS our own servers
      const expiry: number = prefs.getLongSync(update_expiry_key, 0);
      if (!isLastUpdateCheckExpired(expiry)) {
        result.skipped = true;
        return result;
      }
    }

    let response: Response;
    try {
      response = await DownloaderImpl.getInstance().get(NEWPIPE_API_URL);
    } catch (err) {
      // "Could not fetch NewPipe API: probably network problem"
      result.error = err as Error;
      return result;
    }

    // store a timestamp which must be exceeded before a new request is made
    try {
      const newExpiry: number = coerceUpdateCheckExpiry(response.getHeader('expires'));
      prefs.putLong(update_expiry_key, newExpiry);
      await prefs.flush();
    } catch (err) {
      // "Could not extract and save new expiry date" - not fatal, the check still ran
    }

    // parse the json from the response; on bad data fail silently, as the source does
    try {
      const raw: RawUpdateResponse = JSON.parse(response.responseBody()) as RawUpdateResponse;
      const flavors: RawNewPipeFlavors | undefined = raw.flavors;
      const newpipe: RawNewPipeFlavor | undefined =
        flavors === undefined ? undefined : flavors.newpipe;
      if (newpipe === undefined) {
        return result;
      }
      result.versionName = newpipe.version === undefined ? '' : newpipe.version;
      result.versionCode = newpipe.version_code === undefined ? 0 : newpipe.version_code;
      result.apkLocationUrl = newpipe.apk === undefined ? '' : newpipe.apk;
      // port of compareAppVersionAndShowNotification()'s first branch
      result.updateAvailable = this.currentVersionCode < result.versionCode;
    } catch (err) {
      // "Could not get NewPipe API: invalid json" - do not alarm the user
    }
    return result;
  }
}
