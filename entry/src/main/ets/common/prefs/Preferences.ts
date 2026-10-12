/*
 * svc_preferences - the app's key/value store, replacing androidx.preference /
 * SharedPreferences with `@kit.ArkData` preferences (dependency-decisions.json: androidx.preference
 * -> native).
 *
 * Every key is one of the 230 constants in common/prefs/SettingsKeys.ts, which were generated
 * verbatim from res/values/settings_keys.xml. No bare string key is written anywhere in the app:
 * a stored preference name must match the original byte for byte or an imported settings file
 * reads back as defaults (phase2-logic-contract.md section 4).
 *
 * Android's `PreferenceManager.getDefaultSharedPreferences()` reads one implicit file named
 * `<packageName>_preferences`. The HarmonyOS equivalent is an explicitly named store, so the name
 * is pinned here once and never spelled again.
 *
 * `getPreferencesSync` + the `*Sync` accessors are used deliberately: the source's
 * SharedPreferences reads are synchronous and are called from render paths (Tab names, image
 * quality, duration formatting). `flush()` is the only asynchronous step and is awaited by the
 * callers that must not lose a write (settings import, download path change).
 */

import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

/** The single preferences store of the app. */
export const PREFERENCES_STORE_NAME: string = 'newpipe_preferences';

/** A value as it round-trips through the JSON settings backup. */
export type PrefValue = string | number | boolean | string[];

export class AppPreferences {
  /**
   * The one instance ServiceLocator builds. The persistence layer reads preferences from static
   * helpers (`Preferences.getBoolean(key, false)`) rather than threading an instance through every
   * DAO, so the static accessors at the bottom of this file delegate here. There is exactly one
   * preference store in the app, so there is exactly one instance.
   */
  private static shared: AppPreferences | null = null;

  private store: preferences.Preferences | null = null;
  private context: common.Context | null = null;

  /** Called once from EntryAbility through ServiceLocator. */
  init(context: common.Context): void {
    this.context = context;
    const options: preferences.Options = { name: PREFERENCES_STORE_NAME };
    this.store = preferences.getPreferencesSync(context, options);
    AppPreferences.shared = this;
  }

  /** The initialised store; throws rather than silently answering with defaults. */
  static instance(): AppPreferences {
    const shared: AppPreferences | null = AppPreferences.shared;
    if (shared === null) {
      throw new Error('AppPreferences used before ServiceLocator.init()');
    }
    return shared;
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Static accessors - the shape the persistence layer calls
  ////////////////////////////////////////////////////////////////////////// */

  static async getString(key: string, defValue: string): Promise<string> {
    return AppPreferences.instance().getStringSync(key, defValue);
  }

  static async getBoolean(key: string, defValue: boolean): Promise<boolean> {
    return AppPreferences.instance().getBooleanSync(key, defValue);
  }

  static async getInt(key: string, defValue: number): Promise<number> {
    return AppPreferences.instance().getIntSync(key, defValue);
  }

  static async getLong(key: string, defValue: number): Promise<number> {
    return AppPreferences.instance().getLongSync(key, defValue);
  }

  static async getFloat(key: string, defValue: number): Promise<number> {
    return AppPreferences.instance().getFloatSync(key, defValue);
  }

  static async getStringSet(key: string, defValue: string[]): Promise<string[]> {
    return AppPreferences.instance().getStringSetSync(key, defValue);
  }

  /** A static write is followed by a flush, because its caller has no instance to flush. */
  static async putString(key: string, value: string): Promise<void> {
    const store: AppPreferences = AppPreferences.instance();
    store.putString(key, value);
    await store.flush();
  }

  static async putBoolean(key: string, value: boolean): Promise<void> {
    const store: AppPreferences = AppPreferences.instance();
    store.putBoolean(key, value);
    await store.flush();
  }

  static async putInt(key: string, value: number): Promise<void> {
    const store: AppPreferences = AppPreferences.instance();
    store.putInt(key, value);
    await store.flush();
  }

  static async putLong(key: string, value: number): Promise<void> {
    const store: AppPreferences = AppPreferences.instance();
    store.putLong(key, value);
    await store.flush();
  }

  private require(): preferences.Preferences {
    const store: preferences.Preferences | null = this.store;
    if (store === null) {
      throw new Error('AppPreferences used before ServiceLocator.init()');
    }
    return store;
  }

  /**
   * 16 of the SettingsKeys constants hold an Android resource reference (`@string/...`) rather
   * than a plain default value. Resolve one against the migrated string resources; anything else
   * is returned unchanged.
   */
  resolveDefault(value: string): string {
    if (!value.startsWith('@string/')) {
      return value;
    }
    const name: string = value.substring('@string/'.length);
    const ctx: common.Context | null = this.context;
    if (ctx === null) {
      return value;
    }
    try {
      return ctx.resourceManager.getStringByNameSync(name);
    } catch (err) {
      return value;
    }
  }

  has(key: string): boolean {
    return this.require().hasSync(key);
  }

  getStringSync(key: string, defValue: string): string {
    const raw: preferences.ValueType = this.require().getSync(key, defValue);
    return typeof raw === 'string' ? raw : defValue;
  }

  /** getString() with the `@string/...` default resolved first. */
  getStringResolvedSync(key: string, defValue: string): string {
    return this.getStringSync(key, this.resolveDefault(defValue));
  }

  getBooleanSync(key: string, defValue: boolean): boolean {
    const raw: preferences.ValueType = this.require().getSync(key, defValue);
    return typeof raw === 'boolean' ? raw : defValue;
  }

  getIntSync(key: string, defValue: number): number {
    const raw: preferences.ValueType = this.require().getSync(key, defValue);
    return typeof raw === 'number' ? raw : defValue;
  }

  /** Java `long` and `float` are both `number` here; kept as separate names for call-site parity. */
  getLongSync(key: string, defValue: number): number {
    return this.getIntSync(key, defValue);
  }

  getFloatSync(key: string, defValue: number): number {
    return this.getIntSync(key, defValue);
  }

  /** Port of getStringSet(): the source stores selected services / tabs this way. */
  getStringSetSync(key: string, defValue: string[]): string[] {
    const raw: preferences.ValueType = this.require().getSync(key, defValue);
    return Array.isArray(raw) ? raw as string[] : defValue;
  }

  putString(key: string, value: string): void {
    this.require().putSync(key, value);
  }

  putBoolean(key: string, value: boolean): void {
    this.require().putSync(key, value);
  }

  putInt(key: string, value: number): void {
    this.require().putSync(key, value);
  }

  putLong(key: string, value: number): void {
    this.require().putSync(key, value);
  }

  putFloat(key: string, value: number): void {
    this.require().putSync(key, value);
  }

  putStringSet(key: string, value: string[]): void {
    this.require().putSync(key, value);
  }

  /** Writes one value of whichever type the settings backup carried. */
  put(key: string, value: PrefValue): void {
    this.require().putSync(key, value);
  }

  remove(key: string): void {
    this.require().deleteSync(key);
  }

  /** Port of `editor.clear()`, used by settings import before loading the backup. */
  clear(): void {
    this.require().clearSync();
  }

  /**
   * Port of `SharedPreferences.getAll()` - what the settings export writes out.
   * Values come back as string / number / boolean / string[].
   */
  getAll(): Map<string, PrefValue> {
    const out: Map<string, PrefValue> = new Map<string, PrefValue>();
    const all: object = this.require().getAllSync();
    const record: Record<string, PrefValue> = all as Record<string, PrefValue>;
    for (const key of Object.keys(record)) {
      out.set(key, record[key]);
    }
    return out;
  }

  /**
   * Port of `editor.commit()` / `apply()`: persists the in-memory store to disk. Awaited by
   * callers that must not lose the write (settings import, ProcessPhoenix-style re-init).
   */
  async flush(): Promise<void> {
    await this.require().flush();
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Async accessors
  //
  // The persistence layer reads preferences from `async` code and awaits every read. The store
  // itself answers synchronously (the `*Sync` methods above), so these are thin wrappers rather
  // than a second implementation - they exist so a caller in an async context reads the same way
  // it reads the database, and so a future backing store that is genuinely async needs no call
  // site changed.
  ////////////////////////////////////////////////////////////////////////// */

  async getString(key: string, defValue: string): Promise<string> {
    return this.getStringSync(key, defValue);
  }

  async getStringResolved(key: string, defValue: string): Promise<string> {
    return this.getStringResolvedSync(key, defValue);
  }

  async getBoolean(key: string, defValue: boolean): Promise<boolean> {
    return this.getBooleanSync(key, defValue);
  }

  async getInt(key: string, defValue: number): Promise<number> {
    return this.getIntSync(key, defValue);
  }

  async getLong(key: string, defValue: number): Promise<number> {
    return this.getLongSync(key, defValue);
  }

  async getFloat(key: string, defValue: number): Promise<number> {
    return this.getFloatSync(key, defValue);
  }

  async getStringSet(key: string, defValue: string[]): Promise<string[]> {
    return this.getStringSetSync(key, defValue);
  }
}

/**
 * The persistence layer imports this store as `Preferences`. Both names name the same class.
 */
export { AppPreferences as Preferences };
