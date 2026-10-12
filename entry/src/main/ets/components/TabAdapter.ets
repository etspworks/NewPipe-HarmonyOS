/**
 * S3 - port of org.schabi.newpipe.fragments.detail.TabAdapter (the ViewPager adapter behind
 * fragment_channel's view_pager), plus the org.schabi.newpipe.util.ChannelTabHelper predicates that
 * decide WHICH tabs it is fed.
 *
 * The source adapter holds a (Fragment, title) pair per tab and is rebuilt from scratch by
 * ChannelFragment.updateTabs() on every handleResult. A Fragment cannot be held here, so an entry
 * carries what the pager needs to build the child instead: the tab KIND (a ChannelTabFragment page,
 * or the trailing ChannelAboutFragment page) and, for a content tab, its ListLinkHandler. The
 * adapter itself is the pager, because in ArkUI the children ARE the adapter.
 *
 * ChannelTabHelper lives here rather than in ets/common because the data layer has no port of it
 * and this pass may not add one; it is the adapter's own feed rule, so it sits with the adapter.
 */

import { ListLinkHandler } from '../common/extractor/linkhandler/LinkHandler';
import { ChannelTabs } from '../common/extractor/info/ChannelTabExtractor';
import { Preferences } from '../common/prefs/Preferences';
import {
  show_channel_tabs_key,
  show_channel_tabs_videos,
  show_channel_tabs_tracks,
  show_channel_tabs_shorts,
  show_channel_tabs_livestreams,
  show_channel_tabs_channels,
  show_channel_tabs_playlists,
  show_channel_tabs_albums,
  show_channel_tabs_likes
} from '../common/prefs/SettingsKeys';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

/** Which page the pager mounts for an entry: ChannelTabFragment, or the trailing About one. */
export enum ChannelTabKind {
  CONTENT = 0,
  ABOUT = 1
}

/** One entry of the adapter: the source's (Fragment, title) pair. */
export class ChannelTabItem {
  readonly kind: ChannelTabKind;
  /** getString(ChannelTabHelper.getTranslationKey(tab)), or @string/channel_tab_about. */
  readonly title: string;
  /** The tab's ListLinkHandler; null for the About entry, which fetches nothing. */
  readonly linkHandler: ListLinkHandler | null;
  /** Stable ForEach key - the content filter, or 'about'. */
  readonly key: string;

  constructor(kind: ChannelTabKind, title: string, linkHandler: ListLinkHandler | null,
    key: string) {
    this.kind = kind;
    this.title = title;
    this.linkHandler = linkHandler;
    this.key = key;
  }
}

/**
 * view_pager: the ViewPager the adapter is set on. The pages themselves are the adapter's items,
 * so the host supplies them (one ChannelTabFragment per enabled tab plus the trailing
 * ChannelAboutFragment - both declare hostedBy: screen_channel, so they are mounted, never routed
 * to); this owns the paging, the shared selection and setupWithViewPager's two-way binding.
 */
@Component
export struct TabAdapter {
  /** ThemeHelper's black theme: the window background follows it. */
  @StorageProp(BLACK_THEME_KEY) blackTheme: boolean = false;

  /** tabAdapter.getCount() - an adapter with no items shows no pager, as updateTabs() leaves it. */
  @Prop count: number = 0;
  /** The shown tab; shared with the strip, as setupWithViewPager wires it. */
  @Link selectedIndex: number;
  /** The host's ForEach over its ChannelTabItem list. */
  @BuilderParam pages: () => void = this.noPages;

  private pagerController: SwiperController = new SwiperController();

  @Builder
  noPages() {
    Column() {
    }
  }

  build() {
    Column() {
      if (this.count > 0) {
        Swiper(this.pagerController) {
          this.pages()
        }
        .index(this.selectedIndex)
        .loop(false)
        .indicator(false)
        .width('100%')
        .height('100%')
        .onChange((index: number) => {
          this.selectedIndex = index;
        })
      }
    }
    .id('view_pager')
    .width('100%')
    .height('100%')
    // android:windowBackground=@color/light_background_color, behind whatever the tab mounts.
    .backgroundColor(themedBackground(this.blackTheme))
    // ponytail: the source ViewPager answers swipes, not taps, but the action contract requires
    // this node to be tappable - so a tap re-settles it on the selected tab rather than inventing
    // a navigation the source does not have.
    .onClick(() => {
      this.pagerController.changeIndex(this.selectedIndex);
    })
  }
}

/* //////////////////////////////////////////////////////////////////////////
// ChannelTabHelper
////////////////////////////////////////////////////////////////////////// */

/**
 * ChannelTabHelper.getShowTabKey(tab) - the preference entry-value a tab is enabled by, or null
 * where the source returns -1 (a tab the app has no preference for is never shown).
 *
 * The source compares against getString(R.string.show_channel_tabs_*); those resources are not
 * display strings but the multi-select entry values, and the migrated SettingsKeys constants
 * already hold them verbatim, so the lookup is a constant here.
 */
function getShowTabKey(tab: string): string | null {
  switch (tab) {
    case ChannelTabs.VIDEOS:
      return show_channel_tabs_videos;
    case ChannelTabs.TRACKS:
      return show_channel_tabs_tracks;
    case ChannelTabs.SHORTS:
      return show_channel_tabs_shorts;
    case ChannelTabs.LIVESTREAMS:
      return show_channel_tabs_livestreams;
    case ChannelTabs.CHANNELS:
      return show_channel_tabs_channels;
    case ChannelTabs.PLAYLISTS:
      return show_channel_tabs_playlists;
    case ChannelTabs.ALBUMS:
      return show_channel_tabs_albums;
    case ChannelTabs.LIKES:
      return show_channel_tabs_likes;
    default:
      return null;
  }
}

/**
 * ChannelTabHelper.getTranslationKey(tab) - the NAME of the migrated string resource for the
 * tab's label; @string/unknown_content for a tab this build has no label for.
 */
export function getTranslationKey(tab: string): string {
  switch (tab) {
    case ChannelTabs.VIDEOS:
      return 'channel_tab_videos';
    case ChannelTabs.TRACKS:
      return 'channel_tab_tracks';
    case ChannelTabs.SHORTS:
      return 'channel_tab_shorts';
    case ChannelTabs.LIVESTREAMS:
      return 'channel_tab_livestreams';
    case ChannelTabs.CHANNELS:
      return 'channel_tab_channels';
    case ChannelTabs.PLAYLISTS:
      return 'channel_tab_playlists';
    case ChannelTabs.ALBUMS:
      return 'channel_tab_albums';
    case ChannelTabs.LIKES:
      return 'channel_tab_likes';
    default:
      return 'unknown_content';
  }
}

/**
 * ChannelTabHelper.showChannelTab(context, prefs, key): the enabled-tab set decides, and an UNSET
 * preference defaults to true (the source's `enabledTabs == null` branch). `has()` is what tells
 * unset from an empty set, which getStringSetSync's default value cannot.
 */
export function showChannelTabForKey(prefs: Preferences, key: string): boolean {
  if (!prefs.has(show_channel_tabs_key)) {
    return true;
  }
  return prefs.getStringSetSync(show_channel_tabs_key, []).includes(key);
}

/** ChannelTabHelper.showChannelTab(context, prefs, tab) - the String overload. */
export function showChannelTab(prefs: Preferences, tab: string): boolean {
  const key: string | null = getShowTabKey(tab);
  if (key === null) {
    return false;
  }
  return showChannelTabForKey(prefs, key);
}
