/*
 * S3 - port of AddTabDialog: an AlertDialog whose title is R.string.tab_choose and whose body is
 * the DialogListAdapter over the available tabs.
 *
 * The dialog owns no data: ChooseTabsFragment builds getAvailableTabs(context) AND the
 * OnClickListener, so the list is handed in as the body slot (the page instantiates
 * DialogListAdapter with both) and this component is title + body, exactly like the AlertDialog.
 *
 * It renders inside the host page's overlay (ChooseTabsFragmentPage.addTabPicker), because the
 * source REPLACES this dialog with a Select*Fragment dialog for the four picker tab types.
 */

@Component
export struct AddTabDialog {
  /** setAdapter(new DialogListAdapter(context, items), actions) - built by the owning page. */
  @BuilderParam body: () => void = this.emptyBody;

  @Builder
  emptyBody() {
    Column()
  }

  build() {
    Column() {
      // MaterialAlertDialog title: 20sp medium, 24dp in from the panel edge, 18dp above and
      // 8dp below (tap_addtabsbutton.ui.json: alertTitle [147,736][933,817] at density 3.0).
      Text($r('app.string.tab_choose'))
        .id('alertTitle')
        .width('100%')
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.on_surface'))
        .padding({ left: 24, right: 24, top: 18, bottom: 8 })

      Column() {
        this.body();
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.dialog_surface'))
  }
}

/**
 * The @CustomDialog a CustomDialogController's builder has to be. ChooseTabsFragmentPage hands
 * in its chooser/picker slot; the controller draws the AlertDialog's dim and closes on an outside
 * tap, where the bottom sheet it replaced had neither.
 */
@CustomDialog
export struct AddTabDialogHost {
  @BuilderParam body: () => void;
  controller?: CustomDialogController;

  build() {
    Column() {
      this.body();
    }
    // The chooser the capture measures: 348vp of title and six 48vp rows, ~86% of the width.
    .width('86%')
    .height(350)
    .backgroundColor($r('app.color.dialog_surface'))
  }
}
