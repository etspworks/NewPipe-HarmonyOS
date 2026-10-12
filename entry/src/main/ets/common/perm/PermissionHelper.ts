/*
 * svc_permissions - port of app/src/main/java/org/schabi/newpipe/util/PermissionHelper.java.
 *
 * Most of the Java class asks for permissions that DO NOT EXIST on HarmonyOS, and the answer for
 * each is a decision already taken in phase2-logic-contract.md section 2, not something this
 * module may re-open:
 *
 *   - READ/WRITE_EXTERNAL_STORAGE (checkStoragePermissions / checkRead… / checkWrite…) - section
 *     2.4: there is no broad storage permission on HarmonyOS. Every user-visible file goes
 *     through DocumentViewPicker, which grants access to exactly the file the user picked, and
 *     app-private data lives in the sandbox. This is the same branch the source already took
 *     when `NewPipeSettings.useStorageAccessFramework()` was true - it returned true without
 *     asking - so `checkStoragePermissions()` below returns true, as the SAF branch does.
 *   - SYSTEM_ALERT_WINDOW (checkSystemAlertWindowPermission / isPopupEnabledElseAsk) - section
 *     2.1: `SYSTEM_FLOAT_WINDOW` is not grantable to a self-signed build and must never be
 *     requested; the popup player becomes PiP with the in-app minimized player as its fallback.
 *     `isPopupEnabled()` therefore reports whether PiP is available on this device.
 *   - POST_NOTIFICATIONS (checkPostNotificationsPermission) - HarmonyOS has no runtime
 *     notification permission; the user switches notifications off per app in system settings,
 *     which svc_notification reads with `isNotificationEnabled()`.
 *
 * `module.json5` carries INTERNET, GET_NETWORK_INFO and KEEP_BACKGROUND_RUNNING, all
 * system_grant: none of them is ever requested at runtime. `requestPermissions()` exists for a
 * user_grant permission a later wave may legitimately need, and refuses anything not declared.
 */

import { abilityAccessCtrl, common, PermissionRequestResult, Permissions } from '@kit.AbilityKit';
import { PiPWindow } from '@kit.ArkUI';

/**
 * The permissions module.json5 declares.
 *
 * All four are system_grant and none of them is ever requested at runtime.
 *
 * READ_WRITE_DOWNLOAD_DIRECTORY was added here and removed again, deliberately. It is user_grant,
 * availableLevel normal, provisionEnable true - so the declaration is legal and the signed HAP
 * installs with it. Requesting it on this handset answers authResults=2, "the request is
 * invalid", 271 ms after the call with no human involved, and the public Download root keeps
 * answering 13900001. A permission prompt that buys nothing is worse than none, so it is gone.
 * The measurement that settles it is docs/qa/evidence/fix-T-0183b/probe2.txt; re-run that probe
 * before re-adding it.
 */
export const DECLARED_PERMISSIONS: string[] = [
  'ohos.permission.INTERNET',
  'ohos.permission.GET_NETWORK_INFO',
  'ohos.permission.KEEP_BACKGROUND_RUNNING',
  'ohos.permission.FILE_ACCESS_PERSIST'
];

export class PermissionHelper {
  private context: common.UIAbilityContext | null = null;

  /** Called once from EntryAbility through ServiceLocator. */
  init(context: common.UIAbilityContext): void {
    this.context = context;
  }

  private requireContext(): common.UIAbilityContext {
    const ctx: common.UIAbilityContext | null = this.context;
    if (ctx === null) {
      throw new Error('PermissionHelper used before ServiceLocator.init()');
    }
    return ctx;
  }

  /**
   * Port of checkStoragePermissions(activity, requestCode): always true, which is the branch the
   * source takes under the Storage Access Framework. See the header.
   */
  checkStoragePermissions(): boolean {
    return true;
  }

  /**
   * Port of isPopupEnabledElseAsk(context): whether the popup player can be shown. PiP replaces
   * the float window; when PiP is unavailable the caller falls back to the in-app minimized
   * player, so this never blocks the action - it only picks which of the two is used.
   */
  isPopupEnabled(): boolean {
    try {
      return PiPWindow.isPiPEnabled();
    } catch (err) {
      return false;
    }
  }

  /** Whether a permission is currently granted to this app. */
  async isPermissionGranted(permission: Permissions): Promise<boolean> {
    try {
      const manager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const tokenId: number = this.requireContext().applicationInfo.accessTokenId;
      const status: abilityAccessCtrl.GrantStatus = manager.checkAccessTokenSync(tokenId,
        permission);
      return status === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch (err) {
      return false;
    }
  }

  /**
   * Requests one or more user_grant permissions. Anything outside DECLARED_PERMISSIONS is
   * refused here rather than at install time: a permission the manifest does not declare cannot
   * be granted, and a permission outside the self-signed allowlist gets the install REJECTED, so
   * adding one is a manifest decision, never a runtime one.
   */
  async requestPermissions(permissions: Permissions[]): Promise<boolean> {
    for (const permission of permissions) {
      if (!DECLARED_PERMISSIONS.includes(permission)) {
        return false;
      }
    }
    try {
      const manager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
      const result: PermissionRequestResult =
        await manager.requestPermissionsFromUser(this.requireContext(), permissions);
      for (const granted of result.authResults) {
        if (granted !== 0) {
          return false;
        }
      }
      return true;
    } catch (err) {
      return false;
    }
  }

}
