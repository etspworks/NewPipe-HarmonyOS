/**
 * S4 - CustomFilePickerFragment (screen_custom_file_picker). presentation: page.
 *
 * The visible UI belongs to com.nononsenseapps:filepicker, vendored under
 * input/source/NoNonsense-FilePicker. nnf_fragment_filepicker.xml is a bottom-anchored
 * RelativeLayout, and this tree is that layout, id for id:
 *   nnf_picker_toolbar          holding nnf_current_dir (the path, ellipsized at the START)
 *   android:id/list             the RecyclerView between the toolbar and the button bar
 *   divider                     a 1dp rule above the button bar
 *   nnf_buttons_container       a FrameLayout with TWO stacked children, one shown at a time:
 *       nnf_button_container        nnf_button_cancel + nnf_button_ok, each layout_weight 1
 *       nnf_newfile_button_container nnf_text_filename + nnf_button_ok_newfile (MODE_NEW_FILE)
 * A row is nnf_filepicker_listitem_dir (nnf_item_container > item_icon + text1) for a directory
 * and nnf_filepicker_listitem_checkable (the same plus a checkbox) for a selectable entry - the
 * library's getItemViewType, which is the plan's two itemTypes: a directory DESCENDS, a file
 * SELECTS.
 *
 * NewPipe only SUBCLASSES the library - read verbatim off FilePickerActivityHelper.java:27-146
 * via codegraph, the whole delta is five behaviours:
 *   1. onCreate picks FilePickerThemeLight / FilePickerThemeDark from
 *      ThemeHelper.isLightThemeSelected(this)                              -> S5/S6 styling.
 *   2. onCreateViewHolder enlarges android.R.id.text1 to
 *      R.dimen.file_picker_items_text_size                                 -> S5.
 *   3. onClickOk REJECTS an empty name when mode == MODE_NEW_FILE: it cancels the previous toast
 *      and shows R.string.file_name_empty_error, ABORTING the confirm      -> wired below.
 *   4. FilePickerActivityHelper.onBackPressed(): `if (currentFragment.isBackTop())
 *      super.onBackPressed() else currentFragment.goUp()` - Back walks UP the directory tree
 *      before it leaves the picker. isBackTop() compares mCurrentPath against getBackTop()
 *      (the external-storage root, or "/") - that is onBackPress() below, and it is the ONLY
 *      "up" affordance: the library layout has no up BUTTON, so none is invented here.
 *   5. onLoadFinished scrolls the list back to position 0 after every load           -> S4.
 * isItemVisible() additionally shows HIDDEN DIRECTORIES (but not hidden files) - a data filter,
 * so it belongs to svc_file_access in S4, not to this tree.
 *
 * navOut is EMPTY: the picker returns a Uri to whoever launched it (DownloadDialog,
 * DownloadSettingsFragment, MissionsFragment, SubscriptionsImportFragment) - it never pushes.
 * Per phase2-logic-contract §2.4 the primary pick path on HarmonyOS is @kit.CoreFileKit
 * DocumentViewPicker and this ported picker is the FALLBACK (feat_file_picker_fallback);
 * svc_file_access owns both, and S4 binds the list to it. The list starts EMPTY here - never a
 * literal set of files.
 *
 * MISSING ASSETS (reported, not faked): item_icon's nnf_ic_folder_black_48dp and the library's
 * nnf_list_ok / nnf_list_cancel / nnf_filename strings belong to the vendored library and have no
 * migrated resource. The buttons use the app's own ok / cancel strings; item_icon is left out
 * rather than drawn with a wrong glyph, and nnf_button_ok_newfile's nnf_ic_save_black_24dp is
 * stood in for by the nearest bundled glyph until S5 substitutes it.
 *
 * S5/S6 own every colour, size and glyph.
 */
import { promptAction, router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { FilePicker, FilePickerMode, PickerEntry, isItemVisible } from '../common/file/FilePicker';
import { FileAccess } from '../common/file/FileAccess';
import { ServiceLocator } from '../common/di/ServiceLocator';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

const TAG: string = 'CustomFilePickerFragmentPage';

/** Where the picked path is handed back to whoever pushed this page. */
export const FILE_PICKER_RESULT_KEY: string = 'filePickerResult';

@Entry
@Component
export struct CustomFilePickerFragmentPage {
  /** ThemeHelper's black theme: the window background follows it. */
  @StorageProp(BLACK_THEME_KEY) blackTheme: boolean = false;

  /** mCurrentPath. Seeded from KEY_START_PATH; an absent one falls back to the storage root. */
  @State currentPath: string = '';
  /** The library Loader's SortedList<File>, listed through svc_file_access. */
  @State fileList: PickerEntry[] = [];
  @State isLoading: boolean = false;
  /** ErrorPanelHelper equivalent. */
  @State errorInfo: string = '';
  /** getNewFileName(); onClickOk rejects it empty in MODE_NEW_FILE. */
  @State newFileName: string = '';
  /** isBackTop(): mCurrentPath == getBackTop() || mCurrentPath == "/". True until we descend. */
  @State isBackTop: boolean = true;
  /** KEY_MODE - which of the two button containers is shown, and whether rows are checkable. */
  @State mode: FilePickerMode = FilePickerMode.FILE;
  /** The checked entries; a checkable row reads its own membership. */
  @State selectedPaths: string[] = [];
  /** nnf_action_createdir's name field, shown while a new folder is being named. */
  @State creatingFolder: boolean = false;
  @State newFolderName: string = '';

  /** Behaviour 5: onLoadFinished scrolls the list back to position 0 after every load. */
  private listScroller: Scroller = new Scroller();

  private picker(): FilePicker {
    return ServiceLocator.get().filePicker;
  }

  aboutToAppear(): void {
    this.readArguments();
    this.reload();
  }

  /**
   * setArgs(KEY_START_PATH, KEY_MODE, ...). getFragment() falls back to the external-storage
   * root when startPath is null; svc_file_access's sandbox root is its analogue.
   */
  private readArguments(): void {
    const access: FileAccess = ServiceLocator.get().fileAccess;
    let startPath: string = access.filesDir();
    let mode: FilePickerMode = FilePickerMode.FILE;
    const params: Record<string, Object> | undefined =
      router.getParams() as Record<string, Object> | undefined;
    if (params !== undefined && params !== null) {
      const start: Object | undefined = params['startPath'];
      if (start !== undefined && start !== null && start.toString().length > 0) {
        startPath = start.toString();
      }
      const requested: Object | undefined = params['mode'];
      if (requested !== undefined && requested !== null) {
        mode = Number(requested.toString()) as FilePickerMode;
      }
    }
    this.mode = mode;
    // FilePickerActivityHelper.getPicker(context, startPath): a DIRECTORY pick may create one.
    this.picker().setArgs(startPath, mode, false, mode === FilePickerMode.DIR, true, false);
  }

  /**
   * The library Loader over mCurrentPath, plus isItemVisible() - NewPipe's override keeps HIDDEN
   * DIRECTORIES in the list. Behaviour 5 then scrolls back to position 0.
   */
  private reload(): void {
    const picker: FilePicker = this.picker();
    this.isLoading = true;
    try {
      this.fileList = picker.listDirectory().filter((entry: PickerEntry): boolean =>
        isItemVisible(entry, picker.mode, picker.showHiddenItems, picker.allowExistingFile));
      this.currentPath = picker.currentPath;
      this.isBackTop = picker.isBackTop();
      this.listScroller.scrollEdge(Edge.Top);
    } catch (err) {
      this.errorInfo = (err as BusinessError).message;
    } finally {
      this.isLoading = false;
    }
  }

  /** nnf_action_createdir: make the folder under the current one and descend into it. */
  private createFolder(): void {
    const name: string = this.newFolderName.trim();
    if (name.length === 0) {
      return;
    }
    const path: string | null = this.picker().createDirectory(name);
    if (path === null) {
      promptAction.showToast({ message: $r('app.string.nnf_create_folder_error'), duration: 2000 });
      return;
    }
    this.creatingFolder = false;
    this.newFolderName = '';
    this.picker().goTo(path);
    this.reload();
  }

  /** currentFragment.goUp() - walk one directory up, never past getBackTop(). */
  private goUp(): void {
    this.picker().goUp();
    this.reload();
  }

  /**
   * FilePickerActivityHelper.onBackPressed(): at the top level Back leaves the picker (return
   * false lets the system pop this page); otherwise it goes up one level and consumes the press.
   */
  onBackPress(): boolean {
    if (this.isBackTop) {
      return false;
    }
    this.goUp();
    return true;
  }

  /** A checkable row shows its own checked state. */
  private isChecked(item: PickerEntry): boolean {
    return this.selectedPaths.indexOf(item.path) >= 0;
  }

  /** onClickCheckable / the checkbox: toggle membership in the picked set. */
  private toggleChecked(item: PickerEntry): void {
    const pos: number = this.selectedPaths.indexOf(item.path);
    const next: string[] = this.selectedPaths.slice();
    if (pos >= 0) {
      next.splice(pos, 1);
    } else {
      next.push(item.path);
    }
    this.selectedPaths = next;
  }

  /**
   * FilePickerActivityHelper.onClickOk(): in MODE_NEW_FILE an EMPTY name cancels the previous
   * toast, shows file_name_empty_error and ABORTS - super.onClickOk() (which returns the Uri) is
   * never reached. S4 wires the return through svc_file_access.
   */
  private onClickOk(): void {
    if (this.mode === FilePickerMode.NEW_FILE && this.newFileName.trim().length === 0) {
      promptAction.showToast({ message: $r('app.string.file_name_empty_error'), duration: 2000 });
      return;
    }
    // AbstractFilePickerFragment.onClickOk(): with (allowMultiple || mode == MODE_FILE) and
    // nothing checked, the nnf_select_something_first toast shows and super.onClickOk() - the
    // call that returns the Uri and finishes - is never reached.
    if ((this.picker().allowMultiple || this.mode === FilePickerMode.FILE)
      && this.selectedPaths.length === 0) {
      promptAction.showToast({
        message: $r('app.string.nnf_select_something_first'),
        duration: 2000
      });
      return;
    }
    this.errorInfo = '';
    // super.onClickOk(): setResult(RESULT_OK, uri); finish(). The result is published where the
    // launcher can read it, then the page pops - the picker never pushes anywhere itself.
    const picked: string = this.mode === FilePickerMode.NEW_FILE
      ? `${this.currentPath}/${this.newFileName.trim()}`
      : (this.selectedPaths.length > 0 ? this.selectedPaths[0] : this.currentPath);
    AppStorage.setOrCreate(FILE_PICKER_RESULT_KEY, picked);
    this.finish();
  }

  /** setResult(...); finish() - back to whoever pushed the picker. */
  private finish(): void {
    try {
      router.back();
    } catch (err) {
      hilog.error(0x0000, TAG, 'picker back failed: %{public}s', (err as BusinessError).message);
    }
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Builders - the library's two row view types
  ////////////////////////////////////////////////////////////////////////// */

  /**
   * nnf_filepicker_listitem_dir / _checkable: the same container and text1, with the checkbox
   * present only on the selectable type. item_icon is omitted - see MISSING ASSETS above.
   *
   * Rule 12: the row repeats, so ONE shared id. The contract addresses it by its inner
   * android.R.id.text1, which does NOT end in `itemroot`, so the replay's index-based tap-card-N
   * resolution does not apply to this list.
   */
  @Builder
  fileRow(item: PickerEntry) {
    Row() {
      // CustomFilePickerFragment.onCreateViewHolder() overrides text1's size with
      // R.dimen.file_picker_items_text_size; ?android:textAppearanceLarge carries the colour.
      Text(item.name)
        .id('text1')
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding(8)
        .fontSize($r('app.float.file_picker_items_text_size'))
        .fontColor($r('app.color.on_surface'))

      // VIEWTYPE_CHECKABLE: a selectable entry carries a checkbox; a directory row does not.
      if (!item.isDirectory) {
        Checkbox()
          .id('checkbox')
          .select(this.isChecked(item))
          .width(20)
          .height(20)
          .margin({ right: 8 })
          // FilePickerThemeLight: colorAccent = @color/light_settings_accent_color.
          .selectedColor($r('app.color.settings_accent'))
          .hitTestBehavior(HitTestMode.None)
      }
    }
    .id('nnf_item_container')
    .width('100%')
    // android:minHeight="?android:listPreferredItemHeight"
    .constraintSize({ minHeight: 64 })
    .padding({ left: 16, right: 8 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      // The two itemTypes have DIFFERENT effects: a directory descends into itself, a file is
      // selected. S4 routes both through svc_file_access.
      if (item.isDirectory) {
        this.picker().goTo(item.path);
        this.reload();
      } else {
        this.toggleChecked(item);
      }
    })
  }

  build() {
    Column() {
      // nnf_picker_toolbar: the current path, ellipsized at the START so the leaf stays visible.
      Row() {
        // TextAppearance.AppCompat.Widget.ActionBar.Title on ?nnf_toolbarTheme (= ToolbarTheme,
        // whose title colour is @color/white).
        Text(this.picker().displayPath(this.currentPath))
          .id('nnf_current_dir')
          .width('100%')
          .maxLines(1)
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_primary'))
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          // android:ellipsize="start" - the leaf directory stays readable.
          .ellipsisMode(EllipsisMode.START)
          .layoutWeight(1)
        // nnf_action_createdir: the library's toolbar action while allowCreateDir is set.
        if (this.mode === FilePickerMode.DIR) {
          Image($r('app.media.ic_create_new_folder'))
            .id('nnf_action_createdir')
            .accessibilityText($r('app.string.nnf_new_folder'))
            .width(48)
            .height(48)
            .padding(12)
            .fillColor($r('app.color.on_primary'))
            .objectFit(ImageFit.Contain)
            .onClick(() => {
              this.creatingFolder = !this.creatingFolder;
            })
        }
      }
      .id('nnf_picker_toolbar')
      .width('100%')
      // android:minHeight="?attr/actionBarSize" on ?attr/colorPrimary.
      .constraintSize({ minHeight: 56 })
      .padding({ left: 16, right: 16 })
      .backgroundColor($r('app.color.primary'))
      .alignItems(VerticalAlign.Center)

      if (this.creatingFolder) {
        Row() {
          TextInput({ text: this.newFolderName, placeholder: $r('app.string.nnf_new_folder') })
            .id('nnf_new_folder_name')
            .maxLines(1)
            .layoutWeight(1)
            .height(48)
            .fontSize(16)
            .fontColor($r('app.color.on_surface'))
            .placeholderColor($r('app.color.on_surface_variant'))
            .backgroundColor(Color.Transparent)
            .borderRadius(0)
            .showUnderline(true)
            .defaultFocus(true)
            .onChange((value: string) => {
              this.newFolderName = value;
            })
            .onSubmit(() => {
              this.createFolder();
            })
          Button($r('app.string.create'))
            .id('nnf_new_folder_ok')
            .type(ButtonType.Normal)
            .height(48)
            .backgroundColor(Color.Transparent)
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.settings_accent'))
            .onClick(() => {
              this.createFolder();
            })
        }
        .width('100%')
        .padding({ left: 8, right: 8 })
        .alignItems(VerticalAlign.Center)
      }

      List({ scroller: this.listScroller }) {
        ForEach(this.fileList, (item: PickerEntry) => {
          ListItem() {
            this.fileRow(item)
          }
        }, (item: PickerEntry) => item.path)
      }
      .id('list')
      .width('100%')
      .layoutWeight(1)

      Divider()
        .id('divider')
        .strokeWidth(1)
        // FilePickerThemeLight: nnf_separator_color = @color/light_separator_color.
        .color($r('app.color.separator'))

      // nnf_buttons_container: ONE FrameLayout, two stacked children, exactly one shown per mode.
      Column() {
        if (this.mode === FilePickerMode.NEW_FILE) {
          Row() {
            TextInput({ text: this.newFileName, placeholder: $r('app.string.caption_file_name') })
              .id('nnf_text_filename')
              .maxLines(1)
              .layoutWeight(1)
              .height(48)
              .padding({ left: 8, right: 8 })
              .fontSize(16)
              .fontColor($r('app.color.on_surface'))
              .placeholderColor($r('app.color.on_surface_variant'))
              .backgroundColor(Color.Transparent)
              .borderRadius(0)
              .showUnderline(true)
              .onChange((value: string) => {
                this.newFileName = value;
              })

            // nnf_ic_save_black_24dp is a LIBRARY drawable with no migrated asset; the app's own
            // download glyph is the nearest bundled one. android:tint="?attr/nnf_save_icon_color".
            Image($r('app.media.ic_file_download'))
              .id('nnf_button_ok_newfile')
              .width(48)
              .height(48)
              .padding(12)
              .fillColor($r('app.color.settings_accent'))
              .objectFit(ImageFit.Contain)
              .onClick(() => {
                this.onClickOk();
              })
          }
          .id('nnf_newfile_button_container')
          .width('100%')
          .alignItems(VerticalAlign.Center)
        } else {
          Row() {
            // style="?attr/borderlessButtonStyle": a flat 48dp button with the accent label.
            Button($r('app.string.cancel'))
              .id('nnf_button_cancel')
              .type(ButtonType.Normal)
              .layoutWeight(1)
              .height(48)
              .backgroundColor(Color.Transparent)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.on_surface'))
              .onClick(() => {
                // setResult(RESULT_CANCELED); finish() - nothing is handed back.
                this.selectedPaths = [];
                AppStorage.setOrCreate(FILE_PICKER_RESULT_KEY, '');
                this.finish();
              })

            Button($r('app.string.ok'))
              .id('nnf_button_ok')
              .type(ButtonType.Normal)
              .layoutWeight(1)
              .height(48)
              .backgroundColor(Color.Transparent)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.on_surface'))
              .onClick(() => {
                this.onClickOk();
              })
          }
          .id('nnf_button_container')
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }
      }
      .id('nnf_buttons_container')
      .width('100%')
    }
    .id('CustomFilePickerFragmentPage')
    .width('100%')
    .height('100%')
    // FilePickerThemeLight: android:windowBackground = @color/light_background_color.
    .backgroundColor(themedBackground(this.blackTheme))
  }
}
