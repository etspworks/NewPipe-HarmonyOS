/*
 * Copyright (C) The NewPipe Authors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { Localization } from '../common/i18n/Localization';

const TAG: string = 'ConfirmDeleteDialog';

/**
 * ?attr/colorAccent - the AlertDialog button colour under the settings theme, whose only override
 * is colorAccent = @color/light_settings_accent_color, which is why the captures render CANCEL red
 * rather than the LightTheme black.
 */
const COLOR_ACCENT: Resource = $r('app.color.settings_accent');
/** ?android:textColorPrimary. */
const COLOR_ON_SURFACE: Resource = $r('app.color.on_surface');
/** The AlertDialog surface: white in the captures, NOT light_dialog_background_color. */
const COLOR_DIALOG_SURFACE: Resource = $r('app.color.dialog_surface');
/** Theme.AppCompat.Dialog's window background is a square 9-patch: no corner rounding. */
const DIALOG_CORNER_RADIUS: number = 0;
const DIALOG_WIDTH: number = 294;

/**
 * The AlertDialog behind every "delete all of this?" confirmation: a title, then CANCEL (button2,
 * which only dismisses) and DELETE (button1, the one path that touches the database), side by side
 * at the bottom right.
 *
 * It lives here because two screens raise the same dialog - the history settings rows and the
 * statistics screen's Clear watch history - and the second one used to raise the generic
 * context-menu dialog instead, which stacks its actions vertically and leaves them in sentence
 * case.
 */
@CustomDialog
export struct ConfirmDeleteDialog {
  controller?: CustomDialogController;
  title: ResourceStr = '';
  onConfirm: () => void = (): void => {
    hilog.debug(0x0000, TAG, 'ConfirmDeleteDialog: confirm not bound');
  };

  build() {
    Column() {
      Text(this.title)
        .width('100%')
        .fontSize(20)
        .fontColor(COLOR_ON_SURFACE)
        .padding({ left: 24, right: 24, top: 18, bottom: 8 })

      Row() {
        Button(Localization.buttonLabel('cancel'))
          .id('button2')
          .height(42)
          .backgroundColor(Color.Transparent)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_ACCENT)
          .onClick(() => {
            this.controller?.close();
          })

        Button(Localization.buttonLabel('delete'))
          .id('button1')
          .height(42)
          .backgroundColor(Color.Transparent)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_ACCENT)
          .onClick(() => {
            this.controller?.close();
            this.onConfirm();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .padding({ right: 12, bottom: 8 })
    }
    .width(DIALOG_WIDTH)
    .backgroundColor(COLOR_DIALOG_SURFACE)
    .borderRadius(DIALOG_CORNER_RADIUS)
    .alignItems(HorizontalAlign.Start)
  }
}
