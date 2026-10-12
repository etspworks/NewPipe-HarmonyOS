/*
 * Port of org.schabi.newpipe.local.subscription.FeedGroupIcon (NewPipe app).
 *
 * The Kotlin enum carries (id, @DrawableRes drawableResource). The id is what the DB stores, so
 * it IS the ArkTS enum value; the drawable becomes the resource NAME, resolved by the UI as
 * $r('app.media.<name>').
 */
export enum FeedGroupIcon {
  ALL = 0,
  MUSIC = 1,
  EDUCATION = 2,
  FITNESS = 3,
  SPACE = 4,
  COMPUTER = 5,
  GAMING = 6,
  SPORTS = 7,
  NEWS = 8,
  FAVORITES = 9,
  CAR = 10,
  MOTORCYCLE = 11,
  TREND = 12,
  MOVIE = 13,
  BACKUP = 14,
  ART = 15,
  PERSON = 16,
  PEOPLE = 17,
  MONEY = 18,
  KIDS = 19,
  FOOD = 20,
  SMILE = 21,
  EXPLORE = 22,
  RESTAURANT = 23,
  MIC = 24,
  HEADSET = 25,
  RADIO = 26,
  SHOPPING_CART = 27,
  WATCH_LATER = 28,
  WORK = 29,
  HOT = 30,
  CHANNEL = 31,
  BOOKMARK = 32,
  PETS = 33,
  WORLD = 34,
  STAR = 35,
  SUN = 36,
  RSS = 37,
  WHATS_NEW = 38
}

/** id -> drawable resource name, verbatim from the source enum's R.drawable references. */
const DRAWABLE_BY_ID: Map<number, string> = new Map<number, string>([
  [0, 'ic_asterisk'], [1, 'ic_music_note'], [2, 'ic_school'], [3, 'ic_fitness_center'],
  [4, 'ic_telescope'], [5, 'ic_computer'], [6, 'ic_videogame_asset'], [7, 'ic_directions_bike'],
  [8, 'ic_campaign'], [9, 'ic_favorite'], [10, 'ic_directions_car'], [11, 'ic_motorcycle'],
  [12, 'ic_trending_up'], [13, 'ic_movie'], [14, 'ic_backup'], [15, 'ic_palette'],
  [16, 'ic_person'], [17, 'ic_people'], [18, 'ic_attach_money'], [19, 'ic_child_care'],
  [20, 'ic_fastfood'], [21, 'ic_insert_emoticon'], [22, 'ic_explore'], [23, 'ic_restaurant'],
  [24, 'ic_mic'], [25, 'ic_headset'], [26, 'ic_radio'], [27, 'ic_shopping_cart'],
  [28, 'ic_watch_later'], [29, 'ic_work'], [30, 'ic_whatshot'], [31, 'ic_tv'],
  [32, 'ic_bookmark'], [33, 'ic_pets'], [34, 'ic_public'], [35, 'ic_stars'],
  [36, 'ic_wb_sunny'], [37, 'ic_rss_feed'], [38, 'ic_subscriptions']
]);

/** Port of FeedGroupIcon.getDrawableRes(). */
export function feedGroupIconDrawable(icon: FeedGroupIcon): string {
  const name: string | undefined = DRAWABLE_BY_ID.get(icon as number);
  return name === undefined ? 'ic_asterisk' : name;
}

/** All icons, in source declaration order — the order the icon picker shows them in. */
export function feedGroupIconValues(): FeedGroupIcon[] {
  const values: FeedGroupIcon[] = [];
  for (let id = 0; id <= 38; id++) {
    values.push(id as FeedGroupIcon);
  }
  return values;
}
