/**
 * S2 shell - SelectKioskFragment (screen_select_kiosk). presentation: modal.
 *
 * NOT a routed page: an OVERLAY whose hostScreen is screen_choose_tabs, mounted by
 * ChooseTabsFragmentPage on its showSelectKiosk flag (ChooseTabsFragment.addTab(tabId) case
 * KIOSK). Deliberately absent from main_pages.json.
 *
 * Read off SelectKioskFragment.java:33-148 (codegraph). It is the ODD ONE OUT of the four
 * pickers: select_kiosk_fragment.xml holds only the select_a_kiosk title (a NewPipeTextView with
 * NO android:id) and items_list - there is NO progressBar and NO empty_state_view, because the
 * kiosk list is built SYNCHRONOUSLY in the adapter constructor from NewPipe.getServices() ->
 * service.getKioskList().getAvailableKiosks(), with no database or network step. A loading or
 * empty view here would be an invented control, so neither is rendered.
 *  - Each entry's label is R.string.service_kiosk_string formatted with the service name and
 *    KioskTranslator.getTranslatedKioskName(kioskId) - so it is bound to svc_service_registry /
 *    svc_extractor in S4, never a literal kiosk list. The icon is ServiceHelper.getIcon(serviceId).
 *  - The adapter constructor THROWS: onCreateView wraps it and falls back to
 *    ErrorUtil.showUiErrorSnackbar("Selecting kiosk", e), leaving the adapter null. S4 keeps that
 *    failure path (feat_multi_service_extractor) rather than crashing.
 *  - The row is select_kiosk_item, repeated, so ONE shared slug: select_kiosk_itemroot
 *    (instrumenter-injected).
 *  - clickedItem(entry) -> onKioskSelected(serviceId, kioskId, kioskName) then dismiss(). The
 *    listener half (Tab.KioskTab) is the HOST's, wired in S4; dismiss is `show = false`, this
 *    screen's only navOut edge (kind pop, back to screen_choose_tabs).
 *  - The plan's implicit `platform:dialog-outside-tap` dismiss is the sheet's own swipe-down /
 *    scrim on HarmonyOS (the source dialog is cancelable) and carries no addressable id.
 */


import { hilog } from '@kit.PerformanceAnalysisKit';

import { all } from '../common/extractor/ServiceRegistry';
import { StreamingService } from '../common/extractor/core/StreamingService';
import { Localization } from '../common/i18n/Localization';
import { getTranslatedKioskName } from '../model/app/Tab';
import {
  SelectKioskAdapter,
  SelectKioskDataSource,
  SelectKioskRow
} from '../components/SelectKioskAdapter';

/** select_kiosk_fragment.xml: the LinearLayout's own 13dp padding. */
const DIALOG_PADDING: number = 13;
/** ?android:attr/textAppearanceLarge; S0224 puts the title line box at [126..214] of 2340. */
const TITLE_TEXT_SIZE: number = 22;
const COLOR_ON_SURFACE: Resource = $r('app.color.on_surface');
const COLOR_SECONDARY_TEXT: Resource = $r('app.color.on_surface_variant');

@Component
export struct SelectKioskFragmentPage {
  /** Two-way with the host's visibility flag; clickedItem() dismisses. */
  @Link isShown: boolean;
  /**
   * The adapter's own `kioskList`, built from the in-process service registry - EVERY kiosk of
   * EVERY service. Never a literal list of kiosk names.
   */
  @Watch('onKiosksChanged') @Prop kioskList: SelectKioskRow[] = [];
  /** format(service_kiosk_string, serviceName, getTranslatedKioskName(kioskId)), one per row. */
  @Prop rowTitle: string[] = [];
  /** ServiceHelper.getIcon(service.getServiceId()), one per row. */
  @Prop rowIcon: string[] = [];
  /**
   * The registry walk is in-process, but getKioskList() can still throw, so the build is
   * guarded exactly as onCreateView guards the constructor. No progressBar exists in
   * select_kiosk_fragment.xml, so this is never rendered as a spinner - it only records that
   * the list is still being built.
   */
  @State isLoading: boolean = true;
  /**
   * "the SelectKioskAdapter constructor throws" -> ErrorUtil.showUiErrorSnackbar and
   * selectKioskAdapter stays NULL, so setAdapter(null) leaves the dialog empty. The empty
   * dialog is the source's real behaviour - there is no empty_state_view in this layout.
   */
  @State errorInfo: string = '';
  /** setOnSelectedListener(...) - the OnSelectedListener return channel. */
  onKioskSelected: (serviceId: number, kioskId: string, kioskName: string) => void =
    (serviceId: number, kioskId: string, kioskName: string): void => {
      console.info('SelectKioskFragmentPage: no OnSelectedListener (' + kioskId + ')');
    };

  /** getItemCount()/getItem(): what LazyForEach reads inside SelectKioskAdapter. */
  private kioskSource: SelectKioskDataSource = new SelectKioskDataSource();

  onKiosksChanged(): void {
    this.kioskSource.submitList(this.kioskList);
  }

  /**
   * onCreateView(): `try { selectKioskAdapter = new SelectKioskAdapter(); } catch (e) {
   * ErrorUtil.showUiErrorSnackbar(this, "Selecting kiosk", e); }`, and the adapter constructor is
   *   for (StreamingService service : NewPipe.getServices())
   *     for (String kioskId : service.getKioskList().getAvailableKiosks())
   *       kioskList.add(new Entry(ServiceHelper.getIcon(service.getServiceId()),
   *           service.getServiceId(), kioskId,
   *           format(service_kiosk_string, service.getServiceInfo().getName(),
   *                  KioskTranslator.getTranslatedKioskName(kioskId, ctx))))
   * It is SYNCHRONOUS - no database, no network - so the whole list exists before the first frame.
   */
  aboutToAppear(): void {
    this.isLoading = true;
    this.errorInfo = '';
    const rows: SelectKioskRow[] = [];
    const titles: string[] = [];
    const icons: string[] = [];
    try {
      for (const service of all()) {
        const serviceId: number = service.getServiceId();
        const serviceName: string = service.getServiceInfo().getName();
        for (const kioskId of SelectKioskFragmentPage.availableKiosks(service)) {
          const name: string = Localization.getStringArgs('service_kiosk_string',
            [serviceName, getTranslatedKioskName(kioskId)]);
          const row: SelectKioskRow = new SelectKioskRow(serviceId, kioskId, name);
          rows.push(row);
          titles.push(name);
          icons.push(row.iconName());
        }
      }
    } catch (err) {
      // The constructor threw: the adapter stays null, so the dialog is left EMPTY.
      this.errorInfo = 'Selecting kiosk: ' + (err as Error).message;
      hilog.error(0x0000, 'SelectKioskFragment', 'Selecting kiosk: %{public}s',
        (err as Error).message);
      this.isLoading = false;
      return;
    }
    this.rowTitle = titles;
    this.rowIcon = icons;
    this.kioskList = rows;
    this.isLoading = false;
  }

  /** service.getKioskList().getAvailableKiosks() - the one call that can throw per service. */
  private static availableKiosks(service: StreamingService): string[] {
    return service.getKioskList().getAvailableKiosks();
  }

  /** clickedItem(entry): call the listener with the ENTRY, then dismiss(). */
  private clickedItem(item: SelectKioskRow): void {
    this.onKioskSelected(item.serviceId, item.kioskId, item.kioskName);
    this.isShown = false;
  }

  build() {
    Column() {
      // A NewPipeTextView with NO android:id; the plan's slug is select_a_kiosk_title.
      Text($r('app.string.select_a_kiosk'))
        .id('select_a_kiosk_title')
        .width('100%')
        .fontSize(TITLE_TEXT_SIZE)
        .fontColor(COLOR_ON_SURFACE)
        // select_kiosk_fragment.xml is the ONE picker whose title carries no marginBottom:
        // S0224 has items_list start at 214, the exact pixel the title box ends on.
        .margin({ left: 10, top: 5, right: 5 })

      // No progressBar and no empty_state_view exist in select_kiosk_fragment.xml: the list is
      // built synchronously, and the failure case is simply an adapter-less (empty) dialog.
      Column() {
        if (this.errorInfo.length === 0) {
          SelectKioskAdapter({
            dataSource: this.kioskSource,
            onItemClicked: (item: SelectKioskRow): void => {
              this.clickedItem(item);
            }
          })
        }
      }
      .id('items_list')
      .width('100%')
      .layoutWeight(1)

      // ErrorUtil.showUiErrorSnackbar("Selecting kiosk", e): on HarmonyOS the same message is
      // rendered in place of the snackbar, over the empty (adapter-less) dialog.
      if (this.errorInfo.length > 0) {
        Text(this.errorInfo)
          .width('100%')
          .fontSize(14)
          .fontColor(COLOR_SECONDARY_TEXT)
          .margin({ top: 8 })
      }
    }
    .id('SelectKioskFragmentPage')
    .width('100%')
    .height('100%')
    .padding(DIALOG_PADDING)
    // getMinWidthDialogTheme(): ?attr/dialogBackground, #EEEEEE in light - S0224 samples the
    // panel at exactly (238,238,238).
    .backgroundColor($r('app.color.dialog_background'))
    .alignItems(HorizontalAlign.Start)
  }
}
