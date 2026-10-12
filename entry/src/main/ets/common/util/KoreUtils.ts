/*
 * KoreUtils: "Play with Kodi" hands the stream url to the Kore remote app, and offers to install
 * Kore when it is missing. Kore is an Android app with no HarmonyOS build, so the install branch
 * is the one this platform can reach: startAbility() on a missing bundle does not fail here, it
 * raises the SYSTEM's "No options to open with" dialog (measured), which the source never shows.
 */

import { promptAction } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { Localization } from '../i18n/Localization';
import { ServiceLocator } from '../di/ServiceLocator';

/** KoreUtils.playWithKore() -> showInstallKoreDialog(). */
export async function playWithKore(): Promise<void> {
  try {
    const choice: promptAction.ShowDialogSuccessResponse = await promptAction.showDialog({
      message: Localization.getString('kore_not_found'),
      buttons: [
        { text: Localization.getString('cancel'), color: '#FF000000' },
        { text: Localization.getString('install'), color: '#FF000000' }
      ]
    });
    if (choice.index === 1) {
      ServiceLocator.get().share.openUrlInBrowser(
        'https://play.google.com/store/apps/details?id=' + Localization.getString('kore_package'));
    }
  } catch (err) {
    console.warn('KoreUtils: install dialog: ' + (err as BusinessError).message);
  }
}
