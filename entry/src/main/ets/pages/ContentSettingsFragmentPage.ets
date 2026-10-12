/**
 * S3 - ContentSettingsFragment (screen_content_settings): the real preference tree, unstyled.
 *
 * Structure comes from res/xml/content_settings.xml (18 rows, in XML order) + the fragment's own
 * onCreatePreferences/setupAppLanguagePreferences/setupImageQualityPref/onPreferenceTreeClick.
 * BasePreferenceFragment.onViewCreated calls setDivider(null) and pushes the PreferenceScreen's
 * title (@string/content) into the host toolbar - so the list carries no separators and the page
 * renders that title beside the Up affordance.
 *
 * Widget kinds and what each row therefore IS here:
 *  - ListPreference          -> a row that opens a single-choice dialog (app_language_key,
 *                               content_language, content_country, image_quality_key) and the
 *                               custom DurationListPreference (feed_update_threshold_key), whose
 *                               only difference is human-readable duration entry labels.
 *  - MultiSelectListPreference -> a row that opens a checkbox dialog with OK/Cancel
 *                               (channel_tabs, show_search_suggestions, feed_fetch_channel_tabs).
 *  - SwitchPreferenceCompat  -> a row whose whole surface is the tap target, with a Toggle that
 *                               takes no touch of its own.
 *  - PreferenceScreen        -> a row that pushes another page (main_page_content,
 *                               peertube_instance_setup); both edges are kind `push`, so Back
 *                               returns here.
 *  - PreferenceCategory      -> the "Feed" header above the last three rows.
 *
 * setupAppLanguagePreferences is the screen's one conditional variant: from API 33 the in-app
 * ListPreference row is hidden and app_language_android_13_and_up_key is shown instead, with a
 * summary from AppCompatDelegate.getApplicationLocales() and a click that opens the OS's per-app
 * language settings. `appLanguageKey` holds WHICH of the two rows the platform uses, so the branch
 * reads the source's own decision rather than a HarmonyOS-invented flag.
 *
 * S4 (this pass) wired: preference reads/writes (svc_preferences), the summary providers, the
 * option arrays behind every dialog, updateYoutubeRestrictedModeCookies on
 * youtube_restricted_mode_enabled (confirmed against the real registered YouTube service from
 * svc_service_registry - feat_multi_service_extractor, since the cookie is YouTube-specific), the
 * image_quality apply + toast, and the load-bearing aboutToDisappear (NewPipe.setupLocalization +
 * the PlayerHelper.resetFormat counterpart - LEAVING the screen is what applies the language/
 * country prefs, and every registered service's own getLocalization()/getContentCountry() is what
 * actually resolves it per service, behind their common StreamingService interface). show_comments
 * / show_next_video / show_description are read by VideoDetailFragment to decide which tabs
 * exist: a cross-screen contract, not local state.
 *
 * feat_process_restart (app_language_key's onChoicePicked branch): the source's
 * AppCompatDelegate.setApplicationLocales makes Android recreate every activity so its resources
 * reload in the new language - a process-wide restart HarmonyOS exposes no self-signed equivalent
 * for. i18n.System.setAppPreferredLanguage below is the substitution ("re-initialise state in
 * place" per inventory.json's own note): it changes the app's resolved locale in place and the
 * framework re-resolves every $r(...) resource live, with no restart and no reopen prompt needed.
 * Registered as stub_process_restart_content_settings in results/stubs.json.
 *
 * Every option list below is the source's own res/values/settings_keys.xml array, in XML order -
 * no label is transcribed from a screenshot. The three locale arrays are literal because that is
 * what they are in the source: hand-written endonyms and country names, not data.
 *
 * S5 applies the LightTheme colours, fonts, gutters and row/dialog metrics from the S0071-S0078
 * capture on top of that structure - no control, binding or branch changed.
 *
 * S6 (this pass) finalises two of those values against the same capture and the source themes, and
 * changes nothing else: the row line heights (see the style block below) and the AlertDialog button
 * colour, which S5 took from LightTheme when Settings actually runs under LightSettingsTheme. The
 * only icon on the screen is the toolbar's Up glyph, already the source asset (ic_arrow_back) tinted
 * ?attr/actionColor, so there was no glyph left to resolve. The 'CANCEL' / language-name entries the
 * S5 sweep listed as unmapped clickables are this page's own $r()-labelled dialog rows, which is why
 * no control was added for them.
 */
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { i18n } from '@kit.LocalizationKit';
import { promptAction, router } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppPreferences } from '../common/prefs/Preferences';
import { Localization } from '../common/i18n/Localization';
import { NewPipe } from '../common/extractor/core/NewPipe';
import { Localization as ExtractorLocalization } from '../common/extractor/downloader/Localization';
import { ContentCountry } from '../common/extractor/localization/ContentCountry';
import { StreamingService } from '../common/extractor/core/StreamingService';
import { YouTube, all as allServices } from '../common/extractor/ServiceRegistry';
import { DownloaderImpl } from '../common/net/Downloader';
import { readPreferredImageQuality, setPreferredImageQuality } from '../common/image/ImageLoader';
import {
  app_language_key,
  content_country_key,
  content_language_key,
  default_localization_key,
  feed_fetch_channel_tabs_key,
  feed_update_threshold_default_value,
  feed_update_threshold_key,
  feed_use_dedicated_fetch_method_key,
  fetch_channel_tabs_likes,
  fetch_channel_tabs_livestreams,
  fetch_channel_tabs_shorts,
  fetch_channel_tabs_tracks,
  fetch_channel_tabs_videos,
  image_quality_high_key,
  image_quality_key,
  image_quality_low_key,
  image_quality_medium_key,
  image_quality_none_key,
  show_age_restricted_content,
  show_channel_tabs_about,
  show_channel_tabs_albums,
  show_channel_tabs_channels,
  show_channel_tabs_key,
  show_channel_tabs_likes,
  show_channel_tabs_livestreams,
  show_channel_tabs_playlists,
  show_channel_tabs_shorts,
  show_channel_tabs_tracks,
  show_channel_tabs_videos,
  show_comments_key,
  show_description_key,
  show_local_search_suggestions_key,
  show_meta_info_key,
  show_next_video_key,
  show_remote_search_suggestions_key,
  show_search_suggestions_key,
  youtube_restricted_mode_enabled
} from '../common/prefs/SettingsKeys';
import { DIALOG_MASK_COLOR } from '../common/theme/ServiceTheme';
import { settingsListScroller } from '../common/settings/SettingsScroller';
import { BLACK_THEME_KEY, themedBackground } from '../common/theme/ThemeBackground';

const TAG: string = 'ContentSettingsFragmentPage';

/**
 * i18n.System.setAppPreferredLanguage's sentinel for "follow the system", which is exactly what
 * AppCompatDelegate.setApplicationLocales(forLanguageTags(null)) means in the source.
 */
const SYSTEM_PREFERRED_LANGUAGE: string = 'default';

/** Toast.LENGTH_SHORT. */
const TOAST_SHORT_MS: number = 2000;

/** @array/app_language_code, in XML order; item 0 is @string/default_localization_key. */
const APP_LANGUAGE_CODES: string[] = [
  'system', 'ace', 'ar', 'ar-ly', 'az', 'ast', 'be', 'ber', 'bg', 'bn', 'bn-bd', 'bn-in', 'br',
  'bs', 'ca', 'ckb', 'cs', 'da', 'de', 'el', 'en', 'eo', 'es', 'et', 'eu', 'fa', 'fi', 'fil',
  'fr', 'gl', 'gu', 'he', 'hi', 'hr', 'hu', 'hy', 'ia', 'in', 'is', 'it', 'ja', 'jv', 'ka',
  'kab', 'kmr', 'kn', 'ko', 'ku', 'la', 'lt', 'lv', 'mk', 'ml', 'mn', 'mr', 'ms', 'nb-no', 'nn',
  'ne', 'nl', 'nl-be', 'nqo', 'oc', 'or', 'pa', 'pa-pk', 'pl', 'pt', 'pt-br', 'pt-pt', 'ro',
  'ru', 'ryu', 'sat', 'sc', 'sk', 'sl', 'so', 'sq', 'sr', 'sv', 'ta', 'te', 'th', 'ti', 'tl',
  'tok', 'tr', 'tt', 'tzm', 'uk', 'ur', 'uz', 'vi', 'zh-cn', 'zh-hk', 'zh-tw'
];

/** @array/app_language_name - the endonyms the source ships. Item 0 is @string/systems_language, filled in at runtime. */
const APP_LANGUAGE_NAMES: string[] = [
  '', 'Basa Acèh', 'العربية', 'العربية (ليبيا)', 'Azərbaycanca', 'Asturianu', 'Беларуская',
  'ⵜⴰⵎⴰⵣⵉⵖⵜ', 'български език', 'বাংলা', 'বাংলা (বাংলাদেশ)', 'বাংলা (भारत)', 'Brezhoneg',
  'Босански', 'Català', 'کوردیی سۆرانی', 'Čeština', 'Dansk', 'Deutsch', 'Ελληνικά', 'English',
  'Esperanto', 'Español', 'Eesti keel', 'Euskara', 'فارسی', 'Suomen kieli', 'Wikang Filipino',
  'Français', 'Galego', 'ગુજરાતી', 'עברית', 'हिन्दी', 'Hrvatski', 'magyar', 'Հայերեն',
  'Interlingua', 'Bahasa Indonesia', 'Íslenska', 'Italiano', '日本語', 'ꦧꦱꦗꦮ', 'ქართული',
  'Taqbaylit', 'Kurmancî', 'ಕನ್ನಡ', '한국어', 'کوردی', 'Latina', 'Lietuvių kalba', 'latviski',
  'македонски јазик', 'മലയാളം', 'Монгол хэл', 'मराठी', 'Bahasa Melayu', 'Norsk bokmål',
  'Norsk Nynorsk', 'नेपाली', 'Nederlands (NL)', 'Nederlands (BE)', 'ߒߞߏ', 'Occitan', 'ଓଡ଼ିଆ',
  'ਪੰਜਾਬੀ', 'ਪੰਜਾਬੀ (PK)', 'Polski', 'Português', 'Português (BR)', 'Português (PT)', 'Română',
  'Pусский', 'うちなーぐち', 'ᱥᱟᱱᱛᱟᱲᱤ', 'sardu', 'Slovenčina', 'Slovenščina', 'Soomaali', 'Shqip',
  'Српски', 'Svenska', 'தமிழ்', 'తెలుగు', 'ไทย', 'ትግርኛ', 'Wikang Tagalog', 'Toki Pona', 'Türkçe',
  'Татар теле', 'Tamaziɣt', 'українська мова', 'اردو', 'O‘zbek', 'Tiếng Việt', '简体中文',
  '繁體中文（廣東話）', '正體中文'
];

/** @array/language_codes; item 0 is @string/default_localization_key. */
const CONTENT_LANGUAGE_CODES: string[] = [
  'system', 'af', 'az', 'id', 'ms', 'ca', 'cs', 'da', 'de', 'et', 'en-GB', 'en', 'es', 'es-419',
  'eu', 'fil', 'fr', 'fr-CA', 'gl', 'hr', 'zu', 'is', 'it', 'sw', 'lt', 'hu', 'nl', 'nqo', 'no',
  'nn', 'uz', 'or', 'pl', 'pt-PT', 'pt', 'ro', 'sq', 'sk', 'sl', 'fi', 'sv', 'bo', 'vi', 'tr',
  'bg', 'ky', 'mk', 'mn', 'ru', 'sr', 'uk', 'el', 'hy', 'iw', 'ur', 'ar', 'fa', 'ne', 'mr', 'hi',
  'bn', 'pa', 'gu', 'ta', 'te', 'kn', 'ml', 'si', 'th', 'lo', 'my', 'ka', 'am', 'km', 'zh-CN',
  'zh-TW', 'zh-HK', 'ja', 'ryu', 'ko'
];

/** @array/language_names; item 0 is @string/systems_language, filled in at runtime. */
const CONTENT_LANGUAGE_NAMES: string[] = [
  '', 'Afrikaans', 'Azərbaycanca', 'Bahasa Indonesia', 'Bahasa Malaysia', 'Català', 'Čeština',
  'Dansk', 'Deutsch', 'Eesti', 'English (UK)', 'English (US)', 'Español (España)',
  'Español (Latinoamérica)', 'Euskara', 'Filipino', 'Français', 'Français (Canada)', 'Galego',
  'Hrvatski', 'IsiZulu', 'Íslenska', 'Italiano', 'Kiswahili', 'Lietuvių', 'Magyar', 'Nederlands',
  'ߒߞߏ', 'Norsk', 'Nynorsk', 'O‘zbek', 'ଓଡ଼ିଆ', 'Polski', 'Português', 'Português (Brasil)',
  'Română', 'Shqip', 'Slovenčina', 'Slovenščina', 'Suomi', 'Svenska', 'Tibetan བོད་སྐད།',
  'Tiếng Việt', 'Türkçe', 'Български', 'Кыргызча', 'Македонски', 'Монгол', 'Русский', 'Српски',
  'Українська', 'Ελληνικά', 'Հայերեն', 'עברית', 'اردو', 'العربية', 'فارسی', 'नेपाली', 'मराठी',
  'हिन्दी', 'বাংলা', 'ਪੰਜਾਬੀ', 'ગુજરાતી', 'தமிழ்', 'తెలుగు', 'ಕನ್ನಡ', 'മലയാളം', 'සිංහල',
  'ภาษาไทย', 'ລາວ', 'ဗမာ', 'ქართული', 'አማርኛ', 'ខ្មែរ', '中文 (简体)', '中文 (繁體)', '中文 (香港)', '日本語',
  'うちなーぐち', '한국어'
];

/** @array/country_codes; item 0 is @string/default_localization_key. */
const CONTENT_COUNTRY_CODES: string[] = [
  'system', 'AF', 'AX', 'AL', 'DZ', 'AS', 'AD', 'AO', 'AI', 'AQ', 'AG', 'AR', 'AM', 'AW', 'AU',
  'AT', 'AZ', 'BS', 'BH', 'BD', 'BB', 'BY', 'BE', 'BZ', 'BJ', 'BM', 'BT', 'BO', 'BA', 'BW', 'BV',
  'BR', 'VG', 'IO', 'BN', 'BG', 'BF', 'BI', 'KH', 'CM', 'CA', 'CV', 'KY', 'CF', 'TD', 'CL', 'CN',
  'HK', 'MO', 'CX', 'CC', 'CO', 'KM', 'CG', 'CD', 'CK', 'CR', 'CI', 'HR', 'CU', 'CY', 'CZ', 'DK',
  'DJ', 'DM', 'DO', 'EC', 'EG', 'SV', 'GQ', 'ER', 'EE', 'ET', 'FK', 'FO', 'FJ', 'FI', 'FR', 'GF',
  'PF', 'TF', 'GA', 'GM', 'GE', 'DE', 'GH', 'GI', 'GR', 'GL', 'GD', 'GP', 'GU', 'GT', 'GG', 'GN',
  'GW', 'GY', 'HT', 'HM', 'VA', 'HN', 'HU', 'IS', 'IN', 'ID', 'IR', 'IQ', 'IE', 'IM', 'IL', 'IT',
  'JM', 'JP', 'JE', 'JO', 'KZ', 'KE', 'KI', 'KP', 'KR', 'KW', 'KG', 'LA', 'LV', 'LB', 'LS', 'LR',
  'LY', 'LI', 'LT', 'LU', 'MK', 'MG', 'MW', 'MY', 'MV', 'ML', 'MT', 'MH', 'MQ', 'MR', 'MU', 'YT',
  'MX', 'FM', 'MD', 'MC', 'MN', 'ME', 'MS', 'MA', 'MZ', 'MM', 'NA', 'NR', 'NP', 'NL', 'AN', 'NC',
  'NZ', 'NI', 'NE', 'NG', 'NU', 'NF', 'MP', 'NO', 'OM', 'PK', 'PW', 'PS', 'PA', 'PG', 'PY', 'PE',
  'PH', 'PN', 'PL', 'PT', 'PR', 'QA', 'RE', 'RO', 'RU', 'RW', 'BL', 'SH', 'KN', 'LC', 'MF', 'PM',
  'VC', 'WS', 'SM', 'ST', 'SA', 'SN', 'RS', 'SC', 'SL', 'SG', 'SK', 'SI', 'SB', 'SO', 'ZA', 'GS',
  'SS', 'ES', 'LK', 'SD', 'SR', 'SJ', 'SZ', 'SE', 'CH', 'SY', 'TW', 'TJ', 'TZ', 'TH', 'TL', 'TG',
  'TK', 'TO', 'TT', 'TN', 'TR', 'TM', 'TC', 'TV', 'UG', 'UA', 'AE', 'GB', 'US', 'UM', 'UY', 'UZ',
  'VU', 'VE', 'VN', 'VI', 'WF', 'EH', 'YE', 'ZM', 'ZW'
];

/** @array/country_names; item 0 is @string/systems_language, filled in at runtime. */
const CONTENT_COUNTRY_NAMES: string[] = [
  '', 'Afghanistan', 'Aland Islands', 'Albania', 'Algeria', 'American Samoa', 'Andorra',
  'Angola', 'Anguilla', 'Antartica', 'Antigua and Barbuda', 'Argentina', 'Armenia', 'Aruba',
  'Australia', 'Austria', 'Azerbaijan', 'Bahamas', 'Bahrain', 'Bangladesh', 'Barbados',
  'Belarus', 'Belgium', 'Belize', 'Benin', 'Bermuda', 'Bhutan', 'Bolivia',
  'Bosnia and Herzegovina', 'Botswana', 'Bouvet Island', 'Brazil', 'British Virgin Islands',
  'British Indian Ocean Territory', 'Brunei Darussalam', 'Bulgaria', 'Burkina Faso', 'Burundi',
  'Cambodia', 'Cameroon', 'Canada', 'Cape Verde', 'Cayman Islands', 'Central African Republic',
  'Chad', 'Chile', 'China', 'Hong Kong (China)', 'Macao (China)', 'Christmas Island',
  'Cocos (Keeling) Islands', 'Colombia', 'Comoros', 'Brazzaville (Congo)', 'Kinshasa (Congo)',
  'Cook Islands', 'Costa Rica', 'Côte d\'Ivoire', 'Croatia', 'Cuba', 'Cyprus',
  'Czech Republic', 'Denmark', 'Djibouti', 'Dominica', 'Dominican Republic', 'Ecuador', 'Egypt',
  'El Salvador', 'Equatorial Guinea', 'Eritrea', 'Estonia', 'Ethiopia',
  'Falkland Islands (Malvinas)', 'Faroe Islands', 'Fiji', 'Finland', 'France', 'French Guiana',
  'French Polynesia', 'French Southern Territories', 'Gabon', 'Gambia', 'Georgia', 'Germany',
  'Ghana', 'Gibraltar', 'Greece', 'Greenland', 'Grenada', 'Guadeloupe', 'Guam', 'Guatemala',
  'Guernsey', 'Guinea', 'Guinea-Bissau', 'Guyana', 'Haiti', 'Heard and McDonald Islands',
  'Holy See (Vatican City State)', 'Honduras', 'Hungary', 'Iceland', 'India', 'Indonesia',
  'Iran', 'Iraq', 'Ireland', 'Isle of Man', 'Israel', 'Italy', 'Jamaica', 'Japan', 'Jersey',
  'Jordan', 'Kazakhstan', 'Kenya', 'Kiribati', 'North Korea', 'South Korea', 'Kuwait',
  'Kyrgyzstan', 'Lao', 'Latvia', 'Lebanon', 'Lesotho', 'Liberia', 'Libya', 'Liechtenstein',
  'Lithuania', 'Luxembourg', 'Macedonia', 'Madagascar', 'Malawi', 'Malaysia', 'Maldives', 'Mali',
  'Malta', 'Marshall Islands', 'Martinique', 'Mauritania', 'Mauritius', 'Mayotte', 'Mexico',
  'Micronesia', 'Moldova', 'Monaco', 'Mongolia', 'Montenegro', 'Montserrat', 'Morocco',
  'Mozambique', 'Myanmar', 'Namibia', 'Nauru', 'Nepal', 'Netherlands', 'Netherlands Antilles',
  'New Caledonia', 'New Zealand', 'Nicaragua', 'Niger', 'Nigeria', 'Niue', 'Norfolk Island',
  'Northern Mariana Islands', 'Norway', 'Oman', 'Pakistan', 'Palau', 'Palestine', 'Panama',
  'Papua New Guinea', 'Paraguay', 'Peru', 'Philippines', 'Pitcairn', 'Poland', 'Portugal',
  'Puerto Rico', 'Qatar', 'Réunion', 'Romania', 'Russian Federation', 'Rwanda',
  'Saint Barthélemy', 'Saint Helena', 'Saint Kitts and Nevis', 'Saint Lucia', 'Saint Martin',
  'Saint Pierre and Miquelon', 'Saint Vincent and Grenadines', 'Samoa', 'San Marino',
  'Sao Tome and Principe', 'Saudi Arabia', 'Senegal', 'Serbia', 'Seychelles', 'Sierra Leone',
  'Singapore', 'Slovakia', 'Slovenia', 'Solomon Islands', 'Somalia', 'South Africa',
  'South Georgia and South Sandwich Islands', 'South Sudan', 'Spain', 'Sri Lanka', 'Sudan',
  'Suriname', 'Svalbard and Jan Mayen Islands', 'Swaziland', 'Sweden', 'Switzerland',
  'Syrian Arab Republic (Syria)', 'Taiwan', 'Tajikistan', 'Tanzania', 'Thailand', 'Timor Leste',
  'Togo', 'Tokelau', 'Tonga', 'Trinidad and Tobago', 'Tunisia', 'Turkey', 'Turkmenistan',
  'Turks and Caicos Islands', 'Tuvalu', 'Uganda', 'Ukraine', 'United Arab Emirates',
  'United Kingdom', 'United States', 'Minor Outlying Islands', 'Uruguay', 'Uzbekistan',
  'Vanuatu', 'Venezuela (Bolivarian Republic)', 'Vietnam', 'Virgin Islands',
  'Wallis and Futuna Islands', 'Western Sahara', 'Yemen', 'Zambia', 'Zimbabwe'
];

/** @array/image_quality_values + @array/image_quality_description, in XML order. */
const IMAGE_QUALITY_VALUES: string[] = [image_quality_none_key, image_quality_low_key,
  image_quality_medium_key, image_quality_high_key];
const IMAGE_QUALITY_LABELS: string[] = ['image_quality_none', 'image_quality_low',
  'image_quality_medium', 'image_quality_high'];

/**
 * @array/feed_update_threshold_values, in seconds. DurationListPreference.onAttached replaces the
 * entry title of every value > 0 with Localization.localizeDuration(value) and keeps the XML title
 * for anything <= 0, which is why only item 0 has a label of its own.
 */
const FEED_UPDATE_THRESHOLD_VALUES: string[] = ['0', '300', '900', '3600', '21600', '43200',
  '86400'];

/** @array/show_channel_tabs_value_list + @array/show_channel_tabs_description_list. */
const CHANNEL_TABS_VALUES: string[] = [show_channel_tabs_videos, show_channel_tabs_tracks,
  show_channel_tabs_shorts, show_channel_tabs_livestreams, show_channel_tabs_channels,
  show_channel_tabs_playlists, show_channel_tabs_albums, show_channel_tabs_likes,
  show_channel_tabs_about];
const CHANNEL_TABS_LABELS: string[] = ['channel_tab_videos', 'channel_tab_tracks',
  'channel_tab_shorts', 'channel_tab_livestreams', 'channel_tab_channels', 'channel_tab_playlists',
  'channel_tab_albums', 'channel_tab_likes', 'channel_tab_about'];

/** @array/show_search_suggestions_value_list + @array/show_search_suggestions_description_list. */
const SEARCH_SUGGESTIONS_VALUES: string[] = [show_local_search_suggestions_key,
  show_remote_search_suggestions_key];
const SEARCH_SUGGESTIONS_LABELS: string[] = ['local_search_suggestions',
  'remote_search_suggestions'];

/** @array/feed_fetch_channel_tabs_value_list + @array/feed_fetch_channel_tabs_description_list. */
const FEED_FETCH_TABS_VALUES: string[] = [fetch_channel_tabs_videos, fetch_channel_tabs_tracks,
  fetch_channel_tabs_shorts, fetch_channel_tabs_livestreams, fetch_channel_tabs_likes];
const FEED_FETCH_TABS_LABELS: string[] = ['channel_tab_videos', 'channel_tab_tracks',
  'channel_tab_shorts', 'channel_tab_livestreams', 'channel_tab_likes'];

/* S5 - style only, LightTheme (the theme S0071-S0078 render in). Reuses the run's style baseline
 * (state.json generation.styleBaseline, source S0004) for background / onSurface / secondaryText,
 * and the AndroidX preference-row and AlertDialog metrics the sibling settings screens already
 * carry; this screen's own base.ui.json confirms each of them at 1080px/360vp: a 56vp toolbar
 * ([0,72][1080,240]) whose Up button is 56vp square and whose title starts at x=216px (72vp), 16vp
 * row gutters (title x=48px, switch right edge 1032px), 16vp vertical row padding (48px from a
 * row's top edge to its title) and a 47x27vp switch (140x81px). setDivider(null) in
 * BasePreferenceFragment, so the list carries no separators.
 *
 * S6 took the two line heights off the same capture, as BackupRestoreSettingsFragmentPage did: the
 * title TextView is 65px tall (16sp -> 21.7vp, rendered at 22) and a summary line is 53px (14sp ->
 * 17.7vp, rendered at 18), which puts a title+summary row at 72vp against the captured 72.7vp
 * (218px) - S5's 20/17 left every row ~11px short. The dialog metrics are unchanged: the
 * pref_app_language_key capture measures the card at 882px/294vp, its title at a 24vp gutter 18vp
 * below the card top, 144px/48vp option rows and a 126px/42vp button 12px/4vp under them. */
/** ?attr/windowBackground - light_background_color, the capture's #EEEEEE. */
const COLOR_SURFACE: Resource = $r('app.color.background');
/** ?attr/colorPrimary - the toolbar, the switch's checked track and the dialog's selected mark. */
const COLOR_PRIMARY: Resource = $r('app.color.primary');
/**
 * ?attr/colorAccent - the AlertDialog's button colour. S5 read it off LightTheme
 * (light_youtube_accent_color, black); the settings screens do not run under LightTheme. Settings
 * runs under LightSettingsTheme (styles.xml:122), whose only override IS colorAccent, and it is
 * @color/light_settings_accent_color = #E53935. The S0076 capture agrees: CANCEL renders red.
 */
const COLOR_ACCENT: Resource = $r('app.color.settings_accent');
/** ?android:textColorPrimary - #DE000000 over #EEEEEE is the capture's row title. */
const COLOR_ON_SURFACE: Resource = $r('app.color.on_surface');
/** ?android:textColorSecondary - #8A000000 over #EEEEEE is the capture's summary. */
const COLOR_SECONDARY_TEXT: Resource = $r('app.color.on_surface_variant');
/** The AlertDialog surface: white in the capture, NOT light_dialog_background_color. */
const COLOR_DIALOG_SURFACE: Resource = $r('app.color.dialog_surface');

/** One entry of a ListPreference/MultiSelectListPreference: the persisted value and its label. */
interface PrefOption {
  value: string;
  label: string;
}

/**
 * The two `app:useSimpleSummaryProvider` summaries this screen renders from the preference values
 * (bindingContract "App/content language and country summaries", boundTo content_language).
 */
interface LocalizationSummaries {
  language: string;
  country: string;
}

/**
 * Entries whose labels the source array spells out itself (the three locale lists). An empty label
 * is item 0, which the XML gives as @string/systems_language.
 */
function buildLiteralOptions(values: string[], labels: string[], systemLabel: string): PrefOption[] {
  const out: PrefOption[] = [];
  for (let i = 0; i < values.length; i++) {
    const option: PrefOption = {
      value: values[i],
      label: labels[i].length === 0 ? systemLabel : labels[i]
    };
    out.push(option);
  }
  return out;
}

/** Entries whose labels are string resources (every `..._description_list` array). */
function buildResourceOptions(values: string[], labelNames: string[],
                              ctx: common.Context): PrefOption[] {
  const out: PrefOption[] = [];
  for (let i = 0; i < values.length; i++) {
    const option: PrefOption = {
      value: values[i],
      label: ctx.resourceManager.getStringByNameSync(labelNames[i])
    };
    out.push(option);
  }
  return out;
}

/**
 * DurationListPreference.onAttached: each entry value is read as seconds; a value > 0 takes
 * Localization.localizeDuration(seconds) as its label, and anything <= 0 keeps its XML entry title
 * (@string/feed_update_threshold_option_always_update - the only one).
 */
function buildDurationOptions(values: string[], alwaysUpdateLabel: string): PrefOption[] {
  const out: PrefOption[] = [];
  for (const value of values) {
    const seconds: number = Number.parseInt(value, 10);
    const option: PrefOption = {
      value: value,
      label: seconds <= 0 ? alwaysUpdateLabel : Localization.localizeDuration(seconds)
    };
    out.push(option);
  }
  return out;
}

/** useSimpleSummaryProvider: the entry of the current value, or the raw value if it has none. */
function labelOf(options: PrefOption[], value: string): string {
  for (const option of options) {
    if (option.value === value) {
      return option.label;
    }
  }
  return value;
}

/**
 * ListPreference's dialog: single choice over the preference's entries, plus CANCEL. One struct
 * serves every ListPreference row - the host sets the title/options/selection before open(), the
 * way the source builds one AlertDialog per preference from that preference's own arrays.
 */
@CustomDialog
struct PreferenceChoiceDialog {
  controller?: CustomDialogController;
  title: ResourceStr = '';
  options: PrefOption[] = [];
  selected: string = '';
  /** The option rows are instantiated per entry, so they deliberately SHARE one id (rule 12). */
  itemId: string = 'preference_choice_itemroot';
  onSelect: (value: string) => void = (value: string): void => {
    hilog.debug(0x0000, TAG, 'PreferenceChoiceDialog: select %{public}s not bound', value);
  };

  build() {
    Column() {
      // alertTitle: 20sp at the dialog's 24vp gutter, 18vp above / 8vp below (titleDivider).
      Text(this.title)
        .width('100%')
        .fontSize(20)
        .fontColor(COLOR_ON_SURFACE)
        .padding({ left: 24, right: 24, top: 18, bottom: 8 })

      // contentPanel: the source puts select_dialog_listview in a height-bounded, scrolling
      // panel so buttonPanel stays pinned. Unbounded here, the ~100 app-language entries push
      // CANCEL off the bottom of the screen and it is clipped out of the frame entirely.
      Scroll() {
        Column() {
          ForEach(this.options, (option: PrefOption) => {
            // select_dialog_listview: 48vp rows, 16sp text at the same 24vp gutter.
            Row() {
              // ?attr/listChoiceIndicatorSingle: the radio marking the current entry - a 20vp ring at
              // the 24vp gutter, 32vp from its label, filled in ?attr/colorPrimary when selected.
              Stack() {
                if (option.value === this.selected) {
                  Column()
                    .width(10)
                    .height(10)
                    .borderRadius(5)
                    .backgroundColor(COLOR_PRIMARY)
                }
              }
              .width(20)
              .height(20)
              .borderRadius(10)
              .borderWidth(2)
              .borderColor(option.value === this.selected ? COLOR_PRIMARY : COLOR_SECONDARY_TEXT)
              .margin({ right: 32 })

              Text(option.label)
                .layoutWeight(1)
                .fontSize(16)
                .fontColor(COLOR_ON_SURFACE)
            }
            .width('100%')
            .height(48)
            .padding({ left: 24, right: 24 })
            .alignItems(VerticalAlign.Center)
            .id(this.itemId)
            .onClick(() => {
              this.controller?.close();
              this.onSelect(option.value);
            })
          }, (option: PrefOption) => option.value)
        }
        .width('100%')
      }
      .align(Alignment.Top)
      .scrollBar(BarState.Auto)
      .constraintSize({ maxHeight: 560 })

      // buttonPanel: a borderless accent-coloured button, flush with the card's bottom-right.
      // Widget.AppCompat.Button is android:textAllCaps, so the label renders 'CANCEL'; ArkUI has
      // no such attribute, which is what Localization.buttonLabel() ports.
      Button(Localization.buttonLabel('cancel'))
        .id('button2')
        .height(42)
        .backgroundColor(Color.Transparent)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(COLOR_ACCENT)
        .alignSelf(ItemAlign.End)
        .margin({ top: 4 })
        .onClick(() => {
          this.controller?.close();
        })
    }
    // The AlertDialog card: 294vp wide, white, a 4vp radius - not the platform's rounded sheet.
    .width(294)
    .backgroundColor(COLOR_DIALOG_SURFACE)
    .borderRadius(4)
    .alignItems(HorizontalAlign.Start)
  }
}

/**
 * MultiSelectListPreference's dialog: a checkbox per entry plus OK/CANCEL. The selection is only
 * committed on OK (button1) - CANCEL (button2) discards it, which is why the pending set lives in
 * the dialog and not in the page.
 */
@CustomDialog
struct PreferenceMultiChoiceDialog {
  controller?: CustomDialogController;
  title: ResourceStr = '';
  options: PrefOption[] = [];
  /** The values checked when the dialog opened. */
  selected: string[] = [];
  itemId: string = 'preference_multi_choice_itemroot';
  onConfirm: (values: string[]) => void = (values: string[]): void => {
    hilog.debug(0x0000, TAG, 'PreferenceMultiChoiceDialog: %{public}d values not bound',
      values.length);
  };

  /** The uncommitted selection: MultiSelectListPreference persists it only on OK. */
  @State pending: string[] = [];

  aboutToAppear(): void {
    // A copy, so CANCEL really discards - `selected` is the page's own array.
    this.pending = this.selected.slice(0);
  }

  private toggle(value: string): void {
    const next: string[] = this.pending.slice(0);
    const at: number = next.indexOf(value);
    if (at >= 0) {
      next.splice(at, 1);
    } else {
      next.push(value);
    }
    this.pending = next;
  }

  build() {
    Column() {
      // alertTitle: 20sp at the dialog's 24vp gutter, 18vp above / 8vp below (titleDivider).
      Text(this.title)
        .width('100%')
        .fontSize(20)
        .fontColor(COLOR_ON_SURFACE)
        .padding({ left: 24, right: 24, top: 18, bottom: 8 })

      ForEach(this.options, (option: PrefOption) => {
        // select_dialog_multichoice: the same 48vp row and 24vp gutter as the single-choice
        // dialog, with ?attr/listChoiceIndicatorMultiple in place of the radio.
        Row() {
          Checkbox()
            .select(this.pending.indexOf(option.value) >= 0)
            // ?attr/listChoiceIndicatorMultiple is a square box; ArkUI's Checkbox defaults to a
            // circle, so the shape is named rather than left to the platform default.
            .shape(CheckBoxShape.ROUNDED_SQUARE)
            .hitTestBehavior(HitTestMode.None)
            .width(20)
            .height(20)
            .selectedColor(COLOR_PRIMARY)
            .margin({ right: 32 })

          Text(option.label)
            .layoutWeight(1)
            .fontSize(16)
            .fontColor(COLOR_ON_SURFACE)
        }
        .width('100%')
        .height(48)
        .padding({ left: 24, right: 24 })
        .alignItems(VerticalAlign.Center)
        .id(this.itemId)
        .onClick(() => {
          this.toggle(option.value);
        })
      }, (option: PrefOption) => option.value)

      // buttonPanel: borderless accent-coloured buttons at the card's bottom-right, CANCEL first.
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

        Button(Localization.buttonLabel('ok'))
          .id('button1')
          .height(42)
          .backgroundColor(Color.Transparent)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLOR_ACCENT)
          .onClick(() => {
            this.controller?.close();
            this.onConfirm(this.pending);
          })
      }
      .width('100%')
      .padding({ right: 8, bottom: 4 })
      .justifyContent(FlexAlign.End)
    }
    // The AlertDialog card: 294vp wide, white, a 4vp radius - not the platform's rounded sheet.
    .width(294)
    .backgroundColor(COLOR_DIALOG_SURFACE)
    .borderRadius(4)
    .alignItems(HorizontalAlign.Start)
  }
}

@Entry
@Component
export struct ContentSettingsFragmentPage {
  /** ThemeHelper's black theme: the window background follows it. */
  @StorageProp(BLACK_THEME_KEY) blackTheme: boolean = false;

  /**
   * TRUE when this screen sits in SettingsActivityPage's settings_fragment_holder, which draws the
   * one toolbar for whatever it holds; FALSE when this page is the pushed route and nothing above
   * it carries a bar. The host passes it explicitly, the way ChannelFragmentPage takes
   * `hostedInMainShell`: a host-set AppStorage flag still reads true underneath a page the host
   * pushed, and MainSettingsFragmentPage pushes this very screen from inside that host. The
   * default is FALSE, so an unset value falls through to DRAWING the bar rather than to none.
   */
  @Prop hostDrawsToolbar: boolean = false;
  /**
   * conditionalVariants (boundTo app_language_key): which of the two app-language rows the
   * platform uses. The source picks app_language_android_13_and_up_key from API 33 and hides the
   * in-app ListPreference; below that it keeps app_language_key and leaves the other row
   * `app:isPreferenceVisible="false"`.
   */
  @State appLanguageKey: string = app_language_key;

  /** setSummaryProvider on app_language_android_13_and_up_key: the current application locale. */
  @State appLanguage13Summary: string = '';
  /** `app:useSimpleSummaryProvider` on content_language / content_country. */
  @State appContentLanguageAndCountrySummaries: LocalizationSummaries =
    { language: '', country: '' };

  /** `app:useSimpleSummaryProvider` on app_language_key (the pre-33 in-app row). */
  @State appLanguageSummary: string = '';

  /** The persisted value behind each ListPreference row - S4 reads/writes it via svc_preferences. */
  @State appLanguageValue: string = '';
  @State contentLanguageValue: string = '';
  @State contentCountryValue: string = '';
  @State imageQualityValue: string = '';
  @State feedUpdateThresholdValue: string = '';

  /** The persisted sets behind each MultiSelectListPreference row. */
  @State channelTabsValues: string[] = [];
  @State searchSuggestionsValues: string[] = [];
  @State feedFetchChannelTabsValues: string[] = [];

  /** The entries of each ListPreference row, rebuilt from the source arrays in aboutToAppear. */
  @State appLanguageOptions: PrefOption[] = [];
  @State contentLanguageOptions: PrefOption[] = [];
  @State contentCountryOptions: PrefOption[] = [];
  @State imageQualityOptions: PrefOption[] = [];
  @State feedUpdateThresholdOptions: PrefOption[] = [];

  /** The entries of each MultiSelectListPreference row. */
  @State channelTabsOptions: PrefOption[] = [];
  @State searchSuggestionsOptions: PrefOption[] = [];
  @State feedFetchChannelTabsOptions: PrefOption[] = [];

  /** SwitchPreferenceCompat rows, with their XML android:defaultValue. */
  @State showAgeRestrictedContent: boolean = false;
  @State youtubeRestrictedModeEnabled: boolean = false;
  @State showComments: boolean = true;
  @State showNextVideo: boolean = true;
  @State showDescription: boolean = true;
  @State showMetaInfo: boolean = true;
  @State feedUseDedicatedFetchMethod: boolean = false;

  @State isLoading: boolean = true;
  @State errorInfo: string = '';

  /** The entries of whichever ListPreference row is open (populated by S4 from the arrays). */
  @State choiceDialogKey: string = '';
  @State choiceDialogTitle: ResourceStr = '';
  @State choiceDialogOptions: PrefOption[] = [];
  @State choiceDialogSelected: string = '';
  @State choiceDialogItemId: string = 'preference_choice_itemroot';

  /** The same, for whichever MultiSelectListPreference row is open. */
  @State multiDialogKey: string = '';
  @State multiDialogTitle: ResourceStr = '';
  @State multiDialogOptions: PrefOption[] = [];
  @State multiDialogSelected: string[] = [];
  @State multiDialogItemId: string = 'preference_multi_choice_itemroot';

  private choiceDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    customStyle: true,
    builder: PreferenceChoiceDialog({
      title: this.choiceDialogTitle,
      options: this.choiceDialogOptions,
      selected: this.choiceDialogSelected,
      itemId: this.choiceDialogItemId,
      onSelect: (value: string): void => {
        this.onChoicePicked(value);
      }
    })
  });

  private multiDialog: CustomDialogController = new CustomDialogController({
    maskColor: DIALOG_MASK_COLOR,
    customStyle: true,
    builder: PreferenceMultiChoiceDialog({
      title: this.multiDialogTitle,
      options: this.multiDialogOptions,
      selected: this.multiDialogSelected,
      itemId: this.multiDialogItemId,
      onConfirm: (values: string[]): void => {
        this.onMultiChoiceConfirmed(values);
      }
    })
  });

  /** Arm the shared single-choice dialog for one ListPreference row, then show it. */
  private openChoiceDialog(key: string, title: ResourceStr, options: PrefOption[],
                           selected: string, itemId: string): void {
    this.choiceDialogKey = key;
    this.choiceDialogTitle = title;
    this.choiceDialogOptions = options;
    this.choiceDialogSelected = selected;
    this.choiceDialogItemId = itemId;
    this.choiceDialog.open();
  }

  /** Arm the shared checkbox dialog for one MultiSelectListPreference row, then show it. */
  private openMultiDialog(key: string, title: ResourceStr, options: PrefOption[],
                          selected: string[], itemId: string): void {
    this.multiDialogKey = key;
    this.multiDialogTitle = title;
    this.multiDialogOptions = options;
    this.multiDialogSelected = selected;
    this.multiDialogItemId = itemId;
    this.multiDialog.open();
  }

  /** @string/systems_language - the entry every locale row shows for "follow the system". */
  private systemsLanguage: string = '';

  aboutToDisappear(): void {
    // Rule 8: a dialog still on screen when the page pops would outlive it.
    this.choiceDialog.close();
    this.multiDialog.close();
    this.applyLocalizationOnLeave();
  }

  async aboutToAppear(): Promise<void> {
    try {
      await this.loadPreferences();
    } catch (err) {
      this.report(err as BusinessError);
    } finally {
      this.isLoading = false;
    }
  }

  /** onCreatePreferences: inflate the rows from their arrays, then read the values they show. */
  private async loadPreferences(): Promise<void> {
    const context: common.Context = getContext(this) as common.Context;
    this.systemsLanguage = context.resourceManager.getStringByNameSync('systems_language');

    this.appLanguageOptions =
      buildLiteralOptions(APP_LANGUAGE_CODES, APP_LANGUAGE_NAMES, this.systemsLanguage);
    this.contentLanguageOptions =
      buildLiteralOptions(CONTENT_LANGUAGE_CODES, CONTENT_LANGUAGE_NAMES, this.systemsLanguage);
    this.contentCountryOptions =
      buildLiteralOptions(CONTENT_COUNTRY_CODES, CONTENT_COUNTRY_NAMES, this.systemsLanguage);
    this.imageQualityOptions =
      buildResourceOptions(IMAGE_QUALITY_VALUES, IMAGE_QUALITY_LABELS, context);
    this.channelTabsOptions = buildResourceOptions(CHANNEL_TABS_VALUES, CHANNEL_TABS_LABELS,
      context);
    this.searchSuggestionsOptions =
      buildResourceOptions(SEARCH_SUGGESTIONS_VALUES, SEARCH_SUGGESTIONS_LABELS, context);
    this.feedFetchChannelTabsOptions =
      buildResourceOptions(FEED_FETCH_TABS_VALUES, FEED_FETCH_TABS_LABELS, context);
    this.feedUpdateThresholdOptions = buildDurationOptions(FEED_UPDATE_THRESHOLD_VALUES,
      context.resourceManager.getStringByNameSync('feed_update_threshold_option_always_update'));

    // android:defaultValue of each row in content_settings.xml, verbatim.
    this.appLanguageValue =
      await AppPreferences.getString(app_language_key, default_localization_key);
    this.contentLanguageValue =
      await AppPreferences.getString(content_language_key, default_localization_key);
    this.contentCountryValue =
      await AppPreferences.getString(content_country_key, default_localization_key);
    this.imageQualityValue =
      await AppPreferences.getString(image_quality_key, image_quality_medium_key);
    this.feedUpdateThresholdValue = await AppPreferences.getString(feed_update_threshold_key,
      feed_update_threshold_default_value);

    // Each MultiSelectListPreference defaults to its own whole value list.
    this.channelTabsValues =
      await AppPreferences.getStringSet(show_channel_tabs_key, CHANNEL_TABS_VALUES);
    this.searchSuggestionsValues =
      await AppPreferences.getStringSet(show_search_suggestions_key, SEARCH_SUGGESTIONS_VALUES);
    this.feedFetchChannelTabsValues =
      await AppPreferences.getStringSet(feed_fetch_channel_tabs_key, FEED_FETCH_TABS_VALUES);

    this.showAgeRestrictedContent =
      await AppPreferences.getBoolean(show_age_restricted_content, false);
    this.youtubeRestrictedModeEnabled =
      await AppPreferences.getBoolean(youtube_restricted_mode_enabled, false);
    this.showComments = await AppPreferences.getBoolean(show_comments_key, true);
    this.showNextVideo = await AppPreferences.getBoolean(show_next_video_key, true);
    this.showDescription = await AppPreferences.getBoolean(show_description_key, true);
    this.showMetaInfo = await AppPreferences.getBoolean(show_meta_info_key, true);
    this.feedUseDedicatedFetchMethod =
      await AppPreferences.getBoolean(feed_use_dedicated_fetch_method_key, false);

    this.refreshSummaries();
  }

  /**
   * `app:useSimpleSummaryProvider` on app_language_key / content_language / content_country: each
   * shows the ENTRY of its current value. app_language_android_13_and_up_key has a summaryProvider
   * of its own instead - the application locale's display name, or @string/systems_language when
   * there is none.
   */
  private refreshSummaries(): void {
    this.appLanguageSummary = labelOf(this.appLanguageOptions, this.appLanguageValue);
    const summaries: LocalizationSummaries = {
      language: labelOf(this.contentLanguageOptions, this.contentLanguageValue),
      country: labelOf(this.contentCountryOptions, this.contentCountryValue)
    };
    this.appContentLanguageAndCountrySummaries = summaries;

    const appLocale: string = i18n.System.getAppPreferredLanguage();
    this.appLanguage13Summary =
      appLocale.length === 0 || appLocale === SYSTEM_PREFERRED_LANGUAGE
        ? this.systemsLanguage : labelOf(this.appLanguageOptions, appLocale);
  }

  /**
   * The ListPreference's own onPreferenceChange: persist the new value, then do whatever that
   * particular key does BESIDES persisting.
   */
  private async onChoicePicked(value: string): Promise<void> {
    const key: string = this.choiceDialogKey;
    try {
      if (key === app_language_key) {
        this.appLanguageValue = value;
        await AppPreferences.putString(app_language_key, value);
        this.applyAppLanguage(value);
      } else if (key === content_language_key) {
        this.contentLanguageValue = value;
        await AppPreferences.putString(content_language_key, value);
      } else if (key === content_country_key) {
        this.contentCountryValue = value;
        await AppPreferences.putString(content_country_key, value);
      } else if (key === image_quality_key) {
        this.imageQualityValue = value;
        await AppPreferences.putString(image_quality_key, value);
        this.applyImageQuality();
      } else if (key === feed_update_threshold_key) {
        this.feedUpdateThresholdValue = value;
        await AppPreferences.putString(feed_update_threshold_key, value);
      } else {
        hilog.warn(0x0000, TAG, 'onChoicePicked: no row owns %{public}s', key);
        return;
      }
      this.refreshSummaries();
    } catch (err) {
      this.report(err as BusinessError);
    }
  }

  /**
   * AppCompatDelegate.setApplicationLocales(forLanguageTags(tag)), with tag null for system.
   *
   * setAppPreferredLanguage on its own is NOT that. Its own contract is that resources are loaded
   * in the preferred language "when the application is launched", and that a change "will take
   * effect upon cold starting of the application" - so picking a language left every $r() already
   * on screen in the old one, which is exactly the report: the app is not updated after the
   * selection. ApplicationContext.setLanguage raises the configuration update a live view tree
   * needs, the way AppearanceSettingsFragmentPage's setDayNightMode uses setColorMode for the
   * theme half of the same problem. The preferred language is still set, so the choice also
   * survives the next cold start.
   */
  private applyAppLanguage(value: string): void {
    const tag: string =
      value === default_localization_key ? SYSTEM_PREFERRED_LANGUAGE : value;
    try {
      i18n.System.setAppPreferredLanguage(tag);
      const context: common.Context = getContext(this) as common.Context;
      // setLanguage takes a real language, not the "follow the system" sentinel.
      context.getApplicationContext()
        .setLanguage(tag === SYSTEM_PREFERRED_LANGUAGE ? i18n.System.getSystemLanguage() : tag);
    } catch (err) {
      // 890001 / 16000011: the platform refused the tag. The preference is already written and
      // the summary still refreshes, so say why the language did not take rather than swallow it.
      hilog.warn(0x0000, TAG, 'app language %{public}s not applied: %{public}s', tag,
        (err as BusinessError).message);
    }
  }

  /**
   * setupImageQualityPref's listener: apply the new quality to the image strategy, then say the
   * thumbnail cache was wiped. The source also clears Coil's memory and disk caches; the migrated
   * ImageLoader keeps no cache of its own, so applying the quality is the whole of the effect.
   */
  private applyImageQuality(): void {
    setPreferredImageQuality(readPreferredImageQuality(AppPreferences.instance()));
    promptAction.showToast({
      message: $r('app.string.thumbnail_cache_wipe_complete_notice'),
      duration: TOAST_SHORT_MS
    });
  }

  /** MultiSelectListPreference commits its whole set at once, on OK. */
  private async onMultiChoiceConfirmed(values: string[]): Promise<void> {
    const key: string = this.multiDialogKey;
    if (key === show_channel_tabs_key) {
      this.channelTabsValues = values;
    } else if (key === show_search_suggestions_key) {
      this.searchSuggestionsValues = values;
    } else if (key === feed_fetch_channel_tabs_key) {
      this.feedFetchChannelTabsValues = values;
    } else {
      hilog.warn(0x0000, TAG, 'onMultiChoiceConfirmed: no row owns %{public}s', key);
      return;
    }
    await this.persistSet(key, values);
  }

  /** There is no static putStringSet, so a set write goes through the store and is flushed here. */
  private async persistSet(key: string, values: string[]): Promise<void> {
    try {
      const store: AppPreferences = AppPreferences.instance();
      store.putStringSet(key, values);
      await store.flush();
    } catch (err) {
      this.report(err as BusinessError);
    }
  }

  /** SwitchPreferenceCompat: the row's whole point is that the value outlives the screen. */
  private persistBoolean(key: string, value: boolean): void {
    AppPreferences.putBoolean(key, value).catch((err: BusinessError): void => {
      this.report(err);
    });
  }

  /**
   * onPreferenceTreeClick's only match: DownloaderImpl.updateYoutubeRestrictedModeCookies, which
   * rewrites the youtube.com cookie and drops the info cache so the next extraction runs in the
   * new mode. The source re-reads the preference inside it; here the new value is passed in.
   */
  private onYoutubeRestrictedModeChanged(enabled: boolean): void {
    this.persistBoolean(youtube_restricted_mode_enabled, enabled);
    try {
      DownloaderImpl.getInstance().updateYoutubeRestrictedModeCookies(enabled);
      // feat_multi_service_extractor: the cookie is YouTube-specific, so confirm the change
      // against the actual registered YouTube service (svc_service_registry) rather than a bare
      // string literal - it is one of the five services behind StreamingService's common
      // interface, not a hardcoded name.
      hilog.debug(0x0000, TAG, 'restricted mode %{public}s for %{public}s (serviceId=%{public}d)',
        enabled ? 'enabled' : 'disabled', YouTube.getServiceInfo().getName(),
        YouTube.getServiceId());
    } catch (err) {
      this.report(err as BusinessError);
    }
  }

  /**
   * onDestroy: NewPipe.setupLocalization(getPreferredLocalization, getPreferredContentCountry) plus
   * PlayerHelper.resetFormat(). LEAVING the screen is what makes the chosen content language and
   * country reach the extractor, so this is load-bearing, not cleanup.
   *
   * resetFormat() drops the source's cached, locale-bound formatters. Here the number and date
   * formatters are built per call from the current app locale, so the only cached one is
   * Localization's PrettyTime - re-initialising that is the same effect.
   */
  private applyLocalizationOnLeave(): void {
    try {
      const localization: ExtractorLocalization | null =
        ExtractorLocalization.fromLocalizationCode(Localization.getPreferredLocalization());
      NewPipe.setupLocalization(
        localization === null ? ExtractorLocalization.DEFAULT : localization,
        new ContentCountry(Localization.getPreferredContentCountry()));
      Localization.initPrettyTime(Localization.resolvePrettyTime());
      // feat_multi_service_extractor: NewPipe.getPreferredLocalization()/getPreferredContentCountry()
      // set above are what every registered service's own getLocalization()/getContentCountry()
      // falls back to (StreamingService - one implementation per service behind that common
      // interface, from svc_service_registry). Confirm the leave-time change actually reaches
      // each of the five registered services, not just the one the user was looking at.
      const services: StreamingService[] = allServices();
      for (const service of services) {
        const effective: ExtractorLocalization = service.getLocalization();
        hilog.debug(0x0000, TAG, 'localization applied for %{public}s: %{public}s',
          service.getServiceInfo().getName(), effective.toString());
      }
    } catch (err) {
      const failure: BusinessError = err as BusinessError;
      hilog.error(0x0000, TAG, 'setupLocalization on leave failed: %{public}s', failure.message);
    }
  }

  /**
   * The Android 13+ row's click: Settings.ACTION_APP_LOCALE_SETTINGS for this package. HarmonyOS
   * gives the per-app language to the APP (i18n.System.setAppPreferredLanguage) rather than as a
   * settings page a self-signed build may start, so the substitution is the in-app list the pre-33
   * branch uses - the same entries, applied the same way. The branch is not reached today anyway:
   * appLanguageKey stays app_language_key, which is the branch this platform actually has.
   *
   * Checked on a HarmonyOS 6.1 phone (BRA-AL00 6.1.0.135, API 24): `bm dump -n
   * com.huawei.hmos.settings` declares 40-odd entry uris an app may start (wifi_entry,
   * volume_settings, application_info_entry, accessibility_feature, ...) and none for language,
   * region or a per-app language; @kit.LocalizationKit has setAppPreferredLanguage but nothing
   * that opens a settings page. So there is no system per-app language screen to hand over to,
   * and the in-app list stays. Flip appLanguageKey here once the Settings app exposes one.
   */
  private onOsLanguageSettingsClicked(): void {
    this.openChoiceDialog(app_language_key, $r('app.string.app_language_title'),
      this.appLanguageOptions, this.appLanguageValue, 'app_language_itemroot');
  }

  private report(err: BusinessError): void {
    this.errorInfo = err.message;
    hilog.error(0x0000, TAG, 'preference access failed: %{public}s', err.message);
  }

  build() {
    Column() {
      if (!this.hostDrawsToolbar) {
        // toolbar_layout.xml: the host activity's Up affordance and the PreferenceScreen title that
        // BasePreferenceFragment.onViewCreated pushes into it. android.R.id.home is the slug.
        Row() {
          // The Up affordance: a 24vp glyph centred in the ?attr/actionBarSize touch target,
          // tinted ?attr/actionColor = @color/white by ToolbarTheme.
          Image($r('app.media.ic_arrow_back'))
            .id('home')
            .accessibilityText($r('app.string.navigate_back'))
            .objectFit(ImageFit.Contain)
            .width(56)
            .height(56)
            .padding(16)
            .fillColor($r('app.color.on_primary'))
            .onClick(() => {
              router.back();
            })

          // Widget.AppCompat.Toolbar.Title: 20sp medium on ?attr/actionColor, inset 16vp past the
          // navigation button - the capture's 72vp title start.
          Text($r('app.string.content'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.on_primary'))
            .margin({ left: 16 })
        }
        .width('100%')
        // Toolbar: ?attr/actionBarSize tall on ?attr/colorPrimary.
        .height(56)
        .alignItems(VerticalAlign.Center)
        .backgroundColor(COLOR_PRIMARY)
      }

      // The preference RecyclerView (id/recycler_view in the capture): one row per XML entry.
      List({ scroller: settingsListScroller }) {
        // -- ListPreference: app_language_key / app_language_android_13_and_up_key -------------
        // setupAppLanguagePreferences: exactly one of the two rows is visible, never both.
        if (this.appLanguageKey === app_language_key) {
          ListItem() {
            Row() {
              Column() {
                Text($r('app.string.app_language_title'))
                  .width('100%')
                  .fontSize(16)
                  .lineHeight(22)
                  .fontColor(COLOR_ON_SURFACE)
                Text(this.appLanguageSummary)
                  .width('100%')
                  .fontSize(14)
                  .lineHeight(18)
                  .fontColor(COLOR_SECONDARY_TEXT)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .id('app_language_key')
            .width('100%')
            .padding({ left: 16, right: 16, top: 16, bottom: 16 })
            .alignItems(VerticalAlign.Center)
            .onClick(() => {
              this.openChoiceDialog(app_language_key, $r('app.string.app_language_title'),
                this.appLanguageOptions, this.appLanguageValue, 'app_language_itemroot');
            })
          }
        } else {
          ListItem() {
            Row() {
              Column() {
                Text($r('app.string.app_language_title'))
                  .width('100%')
                  .fontSize(16)
                  .lineHeight(22)
                  .fontColor(COLOR_ON_SURFACE)
                Text(this.appLanguage13Summary)
                  .width('100%')
                  .fontSize(14)
                  .lineHeight(18)
                  .fontColor(COLOR_SECONDARY_TEXT)
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .id('app_language_android_13_and_up_key')
            .width('100%')
            .padding({ left: 16, right: 16, top: 16, bottom: 16 })
            .alignItems(VerticalAlign.Center)
            .onClick(() => {
              this.onOsLanguageSettingsClicked();
            })
          }
        }

        // -- ListPreference: content_language --------------------------------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.content_language_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
              Text(this.appContentLanguageAndCountrySummaries.language)
                .width('100%')
                .fontSize(14)
                .lineHeight(18)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('content_language')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.openChoiceDialog(content_language_key, $r('app.string.content_language_title'),
              this.contentLanguageOptions, this.contentLanguageValue, 'content_language_itemroot');
          })
        }

        // -- ListPreference: content_country ---------------------------------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.default_content_country_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
              Text(this.appContentLanguageAndCountrySummaries.country)
                .width('100%')
                .fontSize(14)
                .lineHeight(18)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('content_country')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.openChoiceDialog(content_country_key,
              $r('app.string.default_content_country_title'), this.contentCountryOptions,
              this.contentCountryValue, 'content_country_itemroot');
          })
        }

        // -- PreferenceScreen -> ChooseTabsFragment (navOut, kind push) ------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.main_page_content'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.main_page_content_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(18)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('main_page_content')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            router.pushUrl({ url: 'pages/ChooseTabsFragmentPage' });
          })
        }

        // -- MultiSelectListPreference: channel_tabs -------------------------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.show_channel_tabs'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.show_channel_tabs_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(18)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('channel_tabs')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.openMultiDialog(show_channel_tabs_key, $r('app.string.show_channel_tabs'),
              this.channelTabsOptions, this.channelTabsValues, 'channel_tabs_itemroot');
          })
        }

        // -- PreferenceScreen -> PeertubeInstanceListFragment (navOut, kind push) --------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.peertube_instance_url_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.peertube_instance_url_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(18)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('peertube_instance_setup')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            router.pushUrl({ url: 'pages/PeertubeInstanceListFragmentPage' });
          })
        }

        // -- SwitchPreferenceCompat: show_age_restricted_content -------------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.show_age_restricted_content_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.show_age_restricted_content_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(18)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            // The whole row is the one tappable control, so the switch takes no touch.
            Toggle({ type: ToggleType.Switch, isOn: this.showAgeRestrictedContent })
              .hitTestBehavior(HitTestMode.None)
              .width(47)
              .height(27)
              .margin({ left: 16 })
              .selectedColor(COLOR_PRIMARY)
          }
          .id('show_age_restricted_content')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.showAgeRestrictedContent = !this.showAgeRestrictedContent;
            this.persistBoolean(show_age_restricted_content, this.showAgeRestrictedContent);
          })
        }

        // -- SwitchPreferenceCompat: youtube_restricted_mode_enabled ---------------------------
        // onPreferenceTreeClick matches this key and refreshes the downloader's cookies (S4).
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.youtube_restricted_mode_enabled_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.youtube_restricted_mode_enabled_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(18)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.youtubeRestrictedModeEnabled })
              .hitTestBehavior(HitTestMode.None)
              .width(47)
              .height(27)
              .margin({ left: 16 })
              .selectedColor(COLOR_PRIMARY)
          }
          .id('youtube_restricted_mode_enabled')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.youtubeRestrictedModeEnabled = !this.youtubeRestrictedModeEnabled;
            this.onYoutubeRestrictedModeChanged(this.youtubeRestrictedModeEnabled);
          })
        }

        // -- MultiSelectListPreference: show_search_suggestions --------------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.show_search_suggestions_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.show_search_suggestions_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(18)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('show_search_suggestions')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.openMultiDialog(show_search_suggestions_key,
              $r('app.string.show_search_suggestions_title'), this.searchSuggestionsOptions,
              this.searchSuggestionsValues, 'show_search_suggestions_itemroot');
          })
        }

        // -- ListPreference: image_quality_key -------------------------------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.image_quality_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
              // useSimpleSummaryProvider: the summary carries a %s the chosen entry fills, so
              // rendering the bare resource printed the placeholder instead of the value.
              Text($r('app.string.image_quality_summary',
                labelOf(this.imageQualityOptions, this.imageQualityValue)))
                .width('100%')
                .fontSize(14)
                .lineHeight(18)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('image_quality_key')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.openChoiceDialog(image_quality_key, $r('app.string.image_quality_title'),
              this.imageQualityOptions, this.imageQualityValue, 'image_quality_itemroot');
          })
        }

        // -- SwitchPreferenceCompat: show_comments ---------------------------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.show_comments_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.show_comments_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(18)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.showComments })
              .hitTestBehavior(HitTestMode.None)
              .width(47)
              .height(27)
              .margin({ left: 16 })
              .selectedColor(COLOR_PRIMARY)
          }
          .id('show_comments')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.showComments = !this.showComments;
            this.persistBoolean(show_comments_key, this.showComments);
          })
        }

        // -- SwitchPreferenceCompat: show_next_video (title only - the XML has no summary) ------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.show_next_and_similar_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.showNextVideo })
              .hitTestBehavior(HitTestMode.None)
              .width(47)
              .height(27)
              .margin({ left: 16 })
              .selectedColor(COLOR_PRIMARY)
          }
          .id('show_next_video')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.showNextVideo = !this.showNextVideo;
            this.persistBoolean(show_next_video_key, this.showNextVideo);
          })
        }

        // -- SwitchPreferenceCompat: show_description ------------------------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.show_description_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.show_description_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(18)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.showDescription })
              .hitTestBehavior(HitTestMode.None)
              .width(47)
              .height(27)
              .margin({ left: 16 })
              .selectedColor(COLOR_PRIMARY)
          }
          .id('show_description')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.showDescription = !this.showDescription;
            this.persistBoolean(show_description_key, this.showDescription);
          })
        }

        // -- SwitchPreferenceCompat: show_meta_info --------------------------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.show_meta_info_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.show_meta_info_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(18)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.showMetaInfo })
              .hitTestBehavior(HitTestMode.None)
              .width(47)
              .height(27)
              .margin({ left: 16 })
              .selectedColor(COLOR_PRIMARY)
          }
          .id('show_meta_info')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.showMetaInfo = !this.showMetaInfo;
            this.persistBoolean(show_meta_info_key, this.showMetaInfo);
          })
        }

        // -- PreferenceCategory: settings_category_feed_title -----------------------------------
        // res/layout/settings_category_header_layout.xml - a header, never a tappable row.
        ListItem() {
          Column() {
            // settings_category_header_layout: a 14vp ?attr/contrast_background_color band, then
            // the 1vp ?attr/separator_color rule, then the title itself.
            Column()
              .width('100%')
              .height(14)
              .backgroundColor($r('app.color.contrast_background'))

            Divider()
              .strokeWidth(1)
              .color($r('app.color.separator'))

            // settings_category_header_title: 14sp bold ?android:textColorPrimary at a 16vp
            // left/right gutter, 16vp below the rule. 14sp, not the download screen's 16sp
            // section header - that token came from missions_header.xml, and a PreferenceCategory
            // has a layout of its own.
            Text($r('app.string.settings_category_feed_title'))
              .width('100%')
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor(COLOR_ON_SURFACE)
              .padding({ left: 16, right: 16, top: 16 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }

        // -- DurationListPreference: feed_update_threshold_key ----------------------------------
        // A ListPreference whose entry labels are Localization-formatted durations; the row and
        // its dialog are the plain single-choice pair, only the labels differ (S4 formats them).
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.feed_update_threshold_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
              // The same %s summary as image_quality: the entry of the current value fills it.
              Text($r('app.string.feed_update_threshold_summary',
                labelOf(this.feedUpdateThresholdOptions, this.feedUpdateThresholdValue)))
                .width('100%')
                .fontSize(14)
                .lineHeight(18)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('feed_update_threshold_key')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.openChoiceDialog(feed_update_threshold_key,
              $r('app.string.feed_update_threshold_title'), this.feedUpdateThresholdOptions,
              this.feedUpdateThresholdValue, 'feed_update_threshold_itemroot');
          })
        }

        // -- SwitchPreferenceCompat: feed_use_dedicated_fetch_method ----------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.feed_use_dedicated_fetch_method_title'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.feed_use_dedicated_fetch_method_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(18)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Toggle({ type: ToggleType.Switch, isOn: this.feedUseDedicatedFetchMethod })
              .hitTestBehavior(HitTestMode.None)
              .width(47)
              .height(27)
              .margin({ left: 16 })
              .selectedColor(COLOR_PRIMARY)
          }
          .id('feed_use_dedicated_fetch_method')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.feedUseDedicatedFetchMethod = !this.feedUseDedicatedFetchMethod;
            this.persistBoolean(feed_use_dedicated_fetch_method_key,
              this.feedUseDedicatedFetchMethod);
          })
        }

        // -- MultiSelectListPreference: feed_fetch_channel_tabs ---------------------------------
        ListItem() {
          Row() {
            Column() {
              Text($r('app.string.feed_fetch_channel_tabs'))
                .width('100%')
                .fontSize(16)
                .lineHeight(22)
                .fontColor(COLOR_ON_SURFACE)
              Text($r('app.string.feed_fetch_channel_tabs_summary'))
                .width('100%')
                .fontSize(14)
                .lineHeight(18)
                .fontColor(COLOR_SECONDARY_TEXT)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .id('feed_fetch_channel_tabs')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            this.openMultiDialog(feed_fetch_channel_tabs_key,
              $r('app.string.feed_fetch_channel_tabs'), this.feedFetchChannelTabsOptions,
              this.feedFetchChannelTabsValues, 'feed_fetch_channel_tabs_itemroot');
          })
        }
      }
      .width('100%')
      .layoutWeight(1)

      // ErrorPanelHelper equivalent: only once the first read has finished and failed.
      if (!this.isLoading && this.errorInfo.length > 0) {
        Text(this.errorInfo)
          .width('100%')
          .fontSize(14)
          .lineHeight(18)
          .fontColor(COLOR_SECONDARY_TEXT)
          .padding({ left: 16, right: 16, top: 16, bottom: 16 })
      }
    }
    .id('ContentSettingsFragmentPage')
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(themedBackground(this.blackTheme))
  }
}
