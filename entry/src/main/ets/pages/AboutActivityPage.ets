/**
 * S2 shell - AboutActivity (screen_about_activity). SOURCE-ONLY, no captured state.
 *
 * STALE MANIFEST ALIAS: org.schabi.newpipe.about.AboutActivity is declared in
 * AndroidManifest.xml but no such class exists in this fork - the About screen is the shared
 * Compose AboutScreen, and NavigationHelper.openAbout() goes there. The route is kept so the
 * manifest declaration resolves, and it forwards (the plan's single navOut, kind: replace) to
 * pages/AboutScreenPage rather than duplicating that screen.
 */
import { router } from '@kit.ArkUI';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

@Entry
@Component
export struct AboutActivityPage {
  /** ThemeHelper's black theme: the window background follows it. */
  @StorageProp(BLACK_THEME_KEY) blackTheme: boolean = false;

  onPageShow(): void {
    router.replaceUrl({ url: 'pages/AboutScreenPage' });
  }

  build() {
    Column() {
      // The route forwards on the first frame, so all this ever shows is one frame of the app's
      // own window background — never a blank white flash between two red-toolbar screens.
      Text('About')
        .fontSize(16)
        .fontColor($r('app.color.on_surface'))
    }
    .id('AboutActivityPage')
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    // ?attr/windowBackground = @color/light_background_color in the light theme.
    .backgroundColor(themedBackground(this.blackTheme))
  }
}
