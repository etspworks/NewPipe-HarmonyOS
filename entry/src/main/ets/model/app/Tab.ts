/*
 * Port of app/src/main/java/org/schabi/newpipe/settings/tabs/Tab.java - the main-screen tabs the
 * user configures, and their JSON serialization.
 *
 * The tab ids and the JSON key names below are the on-disk format of the `saved_tabs_key`
 * preference and of an exported settings file, so every one of them is verbatim.
 *
 * Two things change shape:
 *   - `getFragment(Context)` returned the Android Fragment to show. ArkUI has no Fragment: each
 *     tab now names the migrated page/component it renders (`getContentName()`), which the main
 *     screen maps to a component.
 *   - nanojson (JsonObject / JsonStringWriter) is the EXTRACTOR's parser
 *     (phase2-logic-contract.md section 8); app-level JSON uses ArkTS JSON.parse/JSON.stringify.
 *
 * KioskTranslator is inlined here because the kiosk name and icon are only needed to render a
 * kiosk tab, and it is a pure lookup table in the source too.
 */

import { Localization } from '../../common/i18n/Localization';
import { LocalItemType } from '../enums/LocalItemLocalItemType';

const JSON_TAB_ID_KEY: string = 'tab_id';
const NO_NAME: string = '<no-name>';
const NO_ID: string = '<no-id>';
const NO_URL: string = '<no-url>';

/** The JSON record of any tab; the subtype keys are optional. */
export interface TabJson {
  tab_id: number;
  service_id?: number;
  kiosk_id?: string;
  channel_service_id?: number;
  channel_url?: string;
  channel_name?: string;
  playlist_service_id?: number;
  playlist_url?: string;
  playlist_name?: string;
  playlist_id?: number;
  playlist_type?: string;
  feed_group_id?: number;
  feed_group_name?: string;
  feed_group_icon?: string;
}

/* //////////////////////////////////////////////////////////////////////////
// KioskTranslator (port of util/KioskTranslator.kt)
////////////////////////////////////////////////////////////////////////// */

/** Port of KioskTranslator.getTranslatedKioskName(kioskId, context). */
export function getTranslatedKioskName(kioskId: string): string {
  const names: Map<string, string> = new Map<string, string>([
    ['Trending', 'trending'],
    ['Top 50', 'top_50'],
    ['New & hot', 'new_and_hot'],
    ['Local', 'local'],
    ['Recently added', 'recently_added'],
    ['Most liked', 'most_liked'],
    ['conferences', 'conferences'],
    ['recent', 'recent'],
    ['live', 'duration_live'],
    ['Featured', 'featured'],
    ['Radio', 'radio'],
    ['trending_gaming', 'trending_gaming'],
    ['trending_music', 'trending_music'],
    ['trending_movies_and_shows', 'trending_movies'],
    ['trending_podcasts_episodes', 'trending_podcasts']
  ]);
  const resourceName: string | undefined = names.get(kioskId);
  return resourceName === undefined ? kioskId : Localization.getString(resourceName);
}

/** Port of KioskTranslator.getKioskIcon(kioskId); '' where the source returned 0. */
export function getKioskIcon(kioskId: string): string {
  const icons: Map<string, string> = new Map<string, string>([
    ['Trending', 'ic_whatshot'],
    ['Top 50', 'ic_whatshot'],
    ['New & hot', 'ic_whatshot'],
    ['conferences', 'ic_whatshot'],
    ['Local', 'ic_home'],
    ['Recently added', 'ic_add_circle_outline'],
    ['recent', 'ic_add_circle_outline'],
    ['Most liked', 'ic_thumb_up'],
    ['live', 'ic_live_tv'],
    ['Featured', 'ic_stars'],
    ['Radio', 'ic_radio'],
    ['trending_gaming', 'ic_videogame_asset'],
    ['trending_music', 'ic_music_note'],
    ['trending_movies_and_shows', 'ic_movie'],
    ['trending_podcasts_episodes', 'ic_podcasts']
  ]);
  const icon: string | undefined = icons.get(kioskId);
  return icon === undefined ? '' : icon;
}

/**
 * DefaultKioskTab reads the default kiosk id of the currently selected service, which comes from
 * the extractor's KioskList. That lives in the extractor wave, so the lookup is injected once at
 * startup rather than imported. Until it is, the tab falls back to an empty kiosk id exactly as
 * the source does when getKioskList() throws.
 */
export type DefaultKioskIdProvider = () => string;

let defaultKioskIdProvider: DefaultKioskIdProvider | null = null;

export function setDefaultKioskIdProvider(provider: DefaultKioskIdProvider): void {
  defaultKioskIdProvider = provider;
}

function currentDefaultKioskId(): string {
  const provider: DefaultKioskIdProvider | null = defaultKioskIdProvider;
  if (provider === null) {
    return '';
  }
  try {
    return provider();
  } catch (err) {
    return '';
  }
}

/**
 * The source writes `playlistType.toString()` - the enum CONSTANT NAME - into the tab record, and
 * reads it back with `LocalItemType.valueOf(...)`. The ArkTS enum is numeric, so the two helpers
 * below keep that on-disk format byte for byte: a settings file written by NewPipe still reads.
 */
const LOCAL_ITEM_TYPE_NAMES: Map<LocalItemType, string> = new Map<LocalItemType, string>([
  [LocalItemType.PLAYLIST_LOCAL_ITEM, 'PLAYLIST_LOCAL_ITEM'],
  [LocalItemType.PLAYLIST_REMOTE_ITEM, 'PLAYLIST_REMOTE_ITEM'],
  [LocalItemType.PLAYLIST_STREAM_ITEM, 'PLAYLIST_STREAM_ITEM'],
  [LocalItemType.STATISTIC_STREAM_ITEM, 'STATISTIC_STREAM_ITEM']
]);

export function localItemTypeToName(type: LocalItemType): string {
  const name: string | undefined = LOCAL_ITEM_TYPE_NAMES.get(type);
  return name === undefined ? 'PLAYLIST_LOCAL_ITEM' : name;
}

export function localItemTypeFromName(name: string): LocalItemType {
  for (const entry of LOCAL_ITEM_TYPE_NAMES.entries()) {
    if (entry[1] === name) {
      return entry[0];
    }
  }
  return LocalItemType.PLAYLIST_LOCAL_ITEM;
}

/* //////////////////////////////////////////////////////////////////////////
// Tab
////////////////////////////////////////////////////////////////////////// */

export abstract class Tab {
  abstract getTabId(): number;

  /** The tab's label. */
  abstract getTabName(): string;

  /** Base name of the migrated media resource for the tab icon. */
  abstract getTabIconRes(): string;

  /**
   * Replaces getFragment(Context): the migrated component this tab renders. The main screen maps
   * the name to a component; the mapping lives there, not in the model.
   */
  abstract getContentName(): string;

  /** Port of equals(Object): tabs are equal when their id is. Subclasses widen this. */
  equalsTab(other: Tab | null): boolean {
    return other !== null && this.getTabId() === other.getTabId();
  }

  /** Port of writeDataToJson(JsonStringWriter): a no-op for the tabs that carry no data. */
  protected writeDataToJson(out: TabJson): void {
  }

  /** Port of readDataFromJson(JsonObject): a no-op for the tabs that carry no data. */
  protected readDataFromJson(raw: TabJson): void {
  }

  toJson(): TabJson {
    const out: TabJson = { tab_id: this.getTabId() };
    this.writeDataToJson(out);
    return out;
  }

  /** Port of Tab.from(JsonObject). */
  static fromJson(raw: TabJson): Tab | null {
    const tabId: number = raw.tab_id === undefined ? -1 : raw.tab_id;
    if (tabId === -1) {
      return null;
    }
    const tab: Tab | null = Tab.fromId(tabId);
    if (tab === null) {
      return null;
    }
    tab.readDataFromJson(raw);
    return tab;
  }

  /** Port of Tab.from(int tabId). */
  static fromId(tabId: number): Tab | null {
    switch (tabId) {
      case BlankTab.ID:
        return new BlankTab();
      case SubscriptionsTab.ID:
        return new SubscriptionsTab();
      case FeedTab.ID:
        return new FeedTab();
      case BookmarksTab.ID:
        return new BookmarksTab();
      case HistoryTab.ID:
        return new HistoryTab();
      case KioskTab.ID:
        return new KioskTab();
      case ChannelTab.ID:
        return new ChannelTab();
      case DefaultKioskTab.ID:
        return new DefaultKioskTab();
      case PlaylistTab.ID:
        return new PlaylistTab();
      case FeedGroupTab.ID:
        return new FeedGroupTab();
      default:
        return null;
    }
  }

  /** Port of Tab.typeFrom(int): whether an id names a known tab type. */
  static typeFrom(tabId: number): Tab | null {
    return Tab.fromId(tabId);
  }

  /** The saved_tabs_key preference value: a JSON array of tab records. */
  static listToJsonString(tabs: Tab[]): string {
    const records: TabJson[] = [];
    for (const tab of tabs) {
      records.push(tab.toJson());
    }
    return JSON.stringify(records);
  }

  /** Reads back what listToJsonString wrote, skipping records with an unknown tab id. */
  static listFromJsonString(json: string): Tab[] {
    const records: TabJson[] = JSON.parse(json) as TabJson[];
    const tabs: Tab[] = [];
    for (const record of records) {
      const tab: Tab | null = Tab.fromJson(record);
      if (tab !== null) {
        tabs.push(tab);
      }
    }
    return tabs;
  }
}

export class BlankTab extends Tab {
  static readonly ID: number = 0;

  getTabId(): number {
    return BlankTab.ID;
  }

  getTabName(): string {
    // the source hardcodes this, with a TODO about finding a better name
    return 'NewPipe';
  }

  getTabIconRes(): string {
    return 'ic_crop_portrait';
  }

  getContentName(): string {
    return 'BlankFragment';
  }
}

export class SubscriptionsTab extends Tab {
  static readonly ID: number = 1;

  getTabId(): number {
    return SubscriptionsTab.ID;
  }

  getTabName(): string {
    return Localization.getString('tab_subscriptions');
  }

  getTabIconRes(): string {
    return 'ic_tv';
  }

  getContentName(): string {
    return 'SubscriptionFragment';
  }
}

export class FeedTab extends Tab {
  static readonly ID: number = 2;

  getTabId(): number {
    return FeedTab.ID;
  }

  getTabName(): string {
    return Localization.getString('fragment_feed_title');
  }

  getTabIconRes(): string {
    return 'ic_subscriptions';
  }

  getContentName(): string {
    return 'FeedFragment';
  }
}

export class BookmarksTab extends Tab {
  static readonly ID: number = 3;

  getTabId(): number {
    return BookmarksTab.ID;
  }

  getTabName(): string {
    return Localization.getString('tab_bookmarks');
  }

  getTabIconRes(): string {
    return 'ic_bookmark';
  }

  getContentName(): string {
    return 'BookmarkFragment';
  }
}

export class HistoryTab extends Tab {
  static readonly ID: number = 4;

  getTabId(): number {
    return HistoryTab.ID;
  }

  getTabName(): string {
    return Localization.getString('title_activity_history');
  }

  getTabIconRes(): string {
    return 'ic_history';
  }

  getContentName(): string {
    return 'StatisticsPlaylistFragment';
  }
}

export class KioskTab extends Tab {
  static readonly ID: number = 5;

  kioskServiceId: number = -1;
  kioskId: string = NO_ID;

  getTabId(): number {
    return KioskTab.ID;
  }

  getTabName(): string {
    return getTranslatedKioskName(this.kioskId);
  }

  getTabIconRes(): string {
    return getKioskIcon(this.kioskId);
  }

  getContentName(): string {
    return 'KioskFragment';
  }

  getKioskServiceId(): number {
    return this.kioskServiceId;
  }

  getKioskId(): string {
    return this.kioskId;
  }

  protected writeDataToJson(out: TabJson): void {
    out.service_id = this.kioskServiceId;
    out.kiosk_id = this.kioskId;
  }

  protected readDataFromJson(raw: TabJson): void {
    this.kioskServiceId = raw.service_id === undefined ? -1 : raw.service_id;
    this.kioskId = raw.kiosk_id === undefined ? NO_ID : raw.kiosk_id;
  }

  equalsTab(other: Tab | null): boolean {
    if (!(other instanceof KioskTab)) {
      return false;
    }
    return super.equalsTab(other)
      && this.kioskServiceId === other.kioskServiceId
      && this.kioskId === other.kioskId;
  }
}

export class ChannelTab extends Tab {
  static readonly ID: number = 6;

  channelServiceId: number = -1;
  channelUrl: string = NO_URL;
  channelName: string = NO_NAME;

  getTabId(): number {
    return ChannelTab.ID;
  }

  getTabName(): string {
    return this.channelName;
  }

  getTabIconRes(): string {
    return 'ic_tv';
  }

  getContentName(): string {
    return 'ChannelFragment';
  }

  getChannelServiceId(): number {
    return this.channelServiceId;
  }

  getChannelUrl(): string {
    return this.channelUrl;
  }

  getChannelName(): string {
    return this.channelName;
  }

  protected writeDataToJson(out: TabJson): void {
    out.channel_service_id = this.channelServiceId;
    out.channel_url = this.channelUrl;
    out.channel_name = this.channelName;
  }

  protected readDataFromJson(raw: TabJson): void {
    this.channelServiceId = raw.channel_service_id === undefined ? -1 : raw.channel_service_id;
    this.channelUrl = raw.channel_url === undefined ? NO_URL : raw.channel_url;
    this.channelName = raw.channel_name === undefined ? NO_NAME : raw.channel_name;
  }

  equalsTab(other: Tab | null): boolean {
    if (!(other instanceof ChannelTab)) {
      return false;
    }
    return super.equalsTab(other)
      && this.channelServiceId === other.channelServiceId
      && this.channelUrl === other.channelUrl
      && this.channelName === other.channelName;
  }
}

export class DefaultKioskTab extends Tab {
  static readonly ID: number = 7;

  getTabId(): number {
    return DefaultKioskTab.ID;
  }

  getTabName(): string {
    return getTranslatedKioskName(currentDefaultKioskId());
  }

  getTabIconRes(): string {
    return getKioskIcon(currentDefaultKioskId());
  }

  getContentName(): string {
    return 'DefaultKioskFragment';
  }
}

export class PlaylistTab extends Tab {
  static readonly ID: number = 8;

  playlistServiceId: number = -1;
  playlistUrl: string = NO_URL;
  playlistName: string = NO_NAME;
  playlistId: number = -1;
  playlistType: LocalItemType = LocalItemType.PLAYLIST_LOCAL_ITEM;

  getTabId(): number {
    return PlaylistTab.ID;
  }

  getTabName(): string {
    return this.playlistName;
  }

  getTabIconRes(): string {
    return 'ic_bookmark';
  }

  getContentName(): string {
    return this.playlistId === -1 ? 'PlaylistFragment' : 'LocalPlaylistFragment';
  }

  getPlaylistServiceId(): number {
    return this.playlistServiceId;
  }

  getPlaylistUrl(): string {
    return this.playlistUrl;
  }

  getPlaylistName(): string {
    return this.playlistName;
  }

  getPlaylistId(): number {
    return this.playlistId;
  }

  getPlaylistType(): LocalItemType {
    return this.playlistType;
  }

  protected writeDataToJson(out: TabJson): void {
    out.playlist_service_id = this.playlistServiceId;
    out.playlist_url = this.playlistUrl;
    out.playlist_name = this.playlistName;
    out.playlist_id = this.playlistId;
    out.playlist_type = localItemTypeToName(this.playlistType);
  }

  protected readDataFromJson(raw: TabJson): void {
    this.playlistServiceId =
      raw.playlist_service_id === undefined ? -1 : raw.playlist_service_id;
    this.playlistUrl = raw.playlist_url === undefined ? NO_URL : raw.playlist_url;
    this.playlistName = raw.playlist_name === undefined ? NO_NAME : raw.playlist_name;
    this.playlistId = raw.playlist_id === undefined ? -1 : raw.playlist_id;
    this.playlistType = raw.playlist_type === undefined
      ? LocalItemType.PLAYLIST_LOCAL_ITEM
      : localItemTypeFromName(raw.playlist_type);
  }

  equalsTab(other: Tab | null): boolean {
    if (!(other instanceof PlaylistTab)) {
      return false;
    }
    return super.equalsTab(other)
      && this.playlistServiceId === other.playlistServiceId
      && this.playlistId === other.playlistId
      && this.playlistUrl === other.playlistUrl
      && this.playlistName === other.playlistName
      && this.playlistType === other.playlistType;
  }
}

export class FeedGroupTab extends Tab {
  static readonly ID: number = 9;

  feedGroupId: number = -1;
  feedGroupName: string = NO_NAME;
  /** Base name of the migrated media resource; the source default is R.drawable.ic_asterisk. */
  iconId: string = 'ic_asterisk';

  getTabId(): number {
    return FeedGroupTab.ID;
  }

  getTabName(): string {
    return this.feedGroupName;
  }

  getTabIconRes(): string {
    return this.iconId;
  }

  getContentName(): string {
    return 'FeedFragment';
  }

  getFeedGroupId(): number {
    return this.feedGroupId;
  }

  getFeedGroupName(): string {
    return this.feedGroupName;
  }

  protected writeDataToJson(out: TabJson): void {
    out.feed_group_id = this.feedGroupId;
    out.feed_group_name = this.feedGroupName;
    out.feed_group_icon = this.iconId;
  }

  protected readDataFromJson(raw: TabJson): void {
    this.feedGroupId = raw.feed_group_id === undefined ? -1 : raw.feed_group_id;
    this.feedGroupName = raw.feed_group_name === undefined ? NO_NAME : raw.feed_group_name;
    this.iconId = raw.feed_group_icon === undefined ? 'ic_asterisk' : raw.feed_group_icon;
  }

  equalsTab(other: Tab | null): boolean {
    if (!(other instanceof FeedGroupTab)) {
      return false;
    }
    return super.equalsTab(other)
      && this.feedGroupId === other.feedGroupId
      && this.feedGroupName === other.feedGroupName
      && this.iconId === other.iconId;
  }
}
