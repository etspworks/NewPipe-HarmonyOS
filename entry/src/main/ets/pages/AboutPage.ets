/**
 * AboutPage (screen_about_page). presentation: page, hostedBy screen_about_screen.
 *
 * The shared Compose AboutPage (shared/.../screen/about/AboutPage.kt) - page 0 of AboutScreen's
 * two-page HorizontalPager, which mounts it in S3. It is ALSO a registered route
 * (pages/AboutPage in main_pages.json), so the deep link resolves; hence @Entry.
 *
 * Read verbatim off AboutPage.kt:66-160 + LinkListItem.kt:32-58 (codegraph). A LazyColumn of one
 * header item plus one item per link - so the root here is a scrolling List (space: spaceXXSmall
 * = 2vp), NOT a plain Column. Six static items, so ListItem + ForEach is the faithful form; an
 * IDataSource/LazyForEach would be overkill. The source's navigationBars contentPadding needs no
 * code - nothing here expands into the safe area, so the system already insets the page above the
 * nav bar.
 *  - header: ic_foreground clipped to a CircleShape over logoBackground at iconTVDPI, then
 *    BuildConfig.APP_NAME (titleLarge), BuildConfig.VERSION_NAME (titleMedium) and
 *    Res.string.app_description - all centred, inside a Column padded by spaceLarge. Both
 *    BuildConfig values are build constants, so they are read from the bundle info
 *    (label = AppScope app.json5 "$string:app_name", versionName = its versionName), never
 *    hardcoded here.
 *  - each link: title (titleMedium) + description (bodyMedium) above an END-ALIGNED TextButton
 *    carrying the link's own action label, the whole row padded by spaceMedium. FIVE links, in
 *    this order: FAQ (Constants.URL_FAQ), Contribute (URL_GITHUB), Donate (URL_DONATION),
 *    Website (URL_WEBSITE), Privacy policy (URL_PRIVACY). They are a static defaultLinks() list
 *    of string resources - NOT fetched content - so a local const array is the faithful source.
 *  - onAction -> onOpenUrl(link.url) -> ShareHandler.openUrlInBrowser(url). That is svc_share
 *    (feat_share_sheet), wired to the shared ShareUtils.openUrlInBrowser: on this SDK there is no
 *    @kit.ShareKit, so the send path is startAbility with an implicit Want
 *    (phase2-logic-contract §10.1).
 *
 * Dimensions are net/newpipe/app/theme/Dimens.kt (spaceLarge 16, spaceMedium 10, spaceXSmall 4,
 * spaceXXSmall 2, iconTVDPI 64) and Color.kt logoBackground #CD201F (migrated as
 * app.color.ic_launcher_background). Font sizes/line heights are the Material3 type-scale roles
 * the source names: titleLarge 22/28, titleMedium 16/24, bodyLarge 16/24, bodyMedium 14/20,
 * labelLarge 14/20 on a 40vp-high TextButton. Dropping all of that padding is what made the
 * ported page half the source's vertical extent, so the capture's scroll sub-state (S0002) had
 * nothing to scroll to.
 *
 * navOut is empty: the page never navigates; the only pop is AboutScreen's own topbar_navigate_up.
 *
 * SLUG NOTE (reported, not invented): only `about_link_action_itemroot` is a real source testTag
 * (instrumenter-injected in LinkListItem.kt, and the sole entry in
 * results/plan/action-contracts.json for this screen). The five displayOnly ids below -
 * about_logo, about_app_name, about_version, about_description, about_link_text - have no testTag
 * in the Compose source; they are the plan's controlInventory sourceRefs, used verbatim so the
 * contract resolves. The link rows repeat, so they share the one `..._itemroot` slug (Rule 12).
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { bundleManager, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ShareUtils } from '../common/share/ShareUtils';
import { ServiceLocator } from '../common/di/ServiceLocator';
import { Localization } from '../common/i18n/Localization';
import { Link } from '../model/app/Link';
import { LinkListItem } from '../components/LinkListItem';

/** Dimens.kt. */
const SPACE_XXSMALL: number = 2;
const SPACE_XSMALL: number = 4;
const SPACE_LARGE: number = 16;
const ICON_TVDPI: number = 64;
/*
 * S5 - this screen has NO captured sid, so its style comes from the source alone: the shared
 * Compose module's own Material3 scheme in theme/Color.kt (onSurfaceLight #231918,
 * surfaceLight #FFF8F7, primaryLight #904A45) and MaterialTheme.typography, NOT the app-wide
 * XML theme the Android half of NewPipe uses. The host AboutScreenPage already paints
 * about_surface_color behind the pager, so only the foreground is set here.
 */
const COLOR_ON_SURFACE: string = '#231918';

/** net.newpipe.app.Constants - the five URLs defaultLinks() builds its Links from. */
const URL_FAQ: string = 'https://newpipe.net/FAQ/';
const URL_GITHUB: string = 'https://github.com/TeamNewPipe/NewPipe';
const URL_DONATION: string = 'https://newpipe.net/donate/';
const URL_WEBSITE: string = 'https://newpipe.net/';
const URL_PRIVACY: string = 'https://newpipe.net/legal/privacy/';

/**
 * defaultLinks() - a private @Composable that resolves five string resources and pairs them with
 * Constants.URL_*. It is a function, not a module constant, because it resolves resources: the
 * source evaluates it at compose time, and the resource manager is not ready at module load.
 */
function defaultLinks(): Link[] {
  return [
    new Link(Localization.getString('faq_title'), Localization.getString('faq_description'),
      Localization.getString('faq'), URL_FAQ),
    new Link(Localization.getString('contribution_title'),
      Localization.getString('contribution_encouragement'),
      Localization.getString('view_on_github'), URL_GITHUB),
    new Link(Localization.getString('donation_title'),
      Localization.getString('donation_encouragement'),
      Localization.getString('give_back'), URL_DONATION),
    new Link(Localization.getString('website_title'),
      Localization.getString('website_encouragement'),
      Localization.getString('open_in_browser'), URL_WEBSITE),
    new Link(Localization.getString('privacy_policy_title'),
      Localization.getString('privacy_policy_encouragement'),
      Localization.getString('read_privacy_policy'), URL_PRIVACY)
  ];
}

@Entry
@Component
export struct AboutPage {
  /** BuildConfig.APP_NAME / VERSION_NAME - build constants, so read from the bundle info. */
  @State appNameLabel: string = '';
  @State versionLabel: string = '';
  /** `items(items = links, key = { link -> link.url })` - defaultLinks(), resolved once. */
  @State linksList: Link[] = [];
  /** The header block is empty until the bundle info has been read. */
  @State isLoading: boolean = true;
  /** The bundle info could not be read - the ErrorPanelHelper equivalent for this page. */
  @State errorInfo: string = '';

  aboutToAppear(): void {
    this.isLoading = true;
    this.errorInfo = '';
    this.linksList = defaultLinks();
    try {
      const info: bundleManager.BundleInfo = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      // appInfo.label is the RAW token from AppScope app.json5 ("$string:app_name"), and
      // appInfo.labelId resolves to the ABILITY label ("label"), not the app's. Read the very
      // resource the app.json5 label token names - never render the token, never the ability's.
      const ctx: common.Context = getContext(this) as common.Context;
      this.appNameLabel = ctx.resourceManager.getStringByNameSync('app_name');
      this.versionLabel = info.versionName;
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      this.errorInfo = failure.message;
      hilog.warn(0x0000, 'AboutPage', 'bundle info unreadable: %{public}s', failure.message);
    }
    this.isLoading = false;
  }

  /** LinkListItem.kt:32-58 TextButton(onClick) -> onOpenUrl(link.url) -> openUrlInBrowser(url). */
  private openUrl(url: string): void {
    const share: ShareUtils = ServiceLocator.get().share;
    share.openUrlInBrowser(url)
      .catch((err: Error): void => {
        hilog.error(0x0000, 'AboutPage', 'openUrlInBrowser failed: %{public}s', err.message);
      });
  }

  build() {
    // LazyColumn(verticalArrangement = Arrangement.spacedBy(spaceXXSmall)) - spaceXXSmall = 2.dp.
    List({ space: SPACE_XXSMALL }) {
      // Page header item {} - Column(padding(spaceLarge), horizontalAlignment CenterHorizontally).
      ListItem() {
        Column() {
          // Image(requiredSize(iconTVDPI).clip(CircleShape).background(logoBackground)).
          Image($r('app.media.ic_foreground'))
            .id('about_logo')
            .width(ICON_TVDPI)
            .height(ICON_TVDPI)
            .borderRadius(ICON_TVDPI / 2)
            .clip(true)
            .backgroundColor($r('app.color.ic_launcher_background'))
            .objectFit(ImageFit.Contain)
          Text(this.appNameLabel)
            .id('about_app_name')
            .fontSize(22)
            .lineHeight(28)
            .fontColor(COLOR_ON_SURFACE)
            .textAlign(TextAlign.Center)
            .margin({ top: SPACE_XSMALL }) // Spacer(height = spaceXSmall)
          Text(this.versionLabel)
            .id('about_version')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .lineHeight(24)
            .fontColor(COLOR_ON_SURFACE)
            .textAlign(TextAlign.Center)
          Text($r('app.string.app_description'))
            .id('about_description')
            .fontSize(16)
            .lineHeight(24)
            .fontColor(COLOR_ON_SURFACE)
            .textAlign(TextAlign.Center)
            .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .padding(SPACE_LARGE)
      }

      // items(items = links, key = { link -> link.url }) { link -> LinkListItem(link, onAction) }.
      ForEach(this.linksList, (item: Link) => {
        ListItem() {
          LinkListItem({
            link: item,
            onAction: (): void => {
              this.openUrl(item.url);
            }
          })
        }
      }, (item: Link) => item.url)

      // BuildConfig is a build constant in the source and cannot fail; reading it out of the
      // bundle info here can, so the failure is reported instead of shipping a blank version row.
      if (!this.isLoading && this.errorInfo.length > 0) {
        ListItem() {
          Text(this.errorInfo)
            .width('100%')
            .fontSize(14)
            .lineHeight(20)
            .fontColor(COLOR_ON_SURFACE)
            .padding(SPACE_LARGE)
        }
      }
    }
    .id('AboutPage')
    .width('100%')
    .height('100%')
  }
}
