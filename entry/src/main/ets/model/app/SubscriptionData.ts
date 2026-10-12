/*
 * Port of app/src/main/java/org/schabi/newpipe/local/subscription/workers/
 * SubscriptionData.kt - the JSON document NewPipe imports and exports subscriptions as.
 *
 * The `@SerialName` names are the wire format of a file users move between installs and between
 * NewPipe and other apps, so they are preserved exactly: `app_version`, `app_version_int`,
 * `service_id`.
 */

/** Raw JSON shape of one `subscriptions[]` entry. */
export interface RawSubscriptionItem {
  service_id?: number;
  url?: string;
  name?: string;
}

/** Raw JSON shape of the exported document. */
export interface RawSubscriptionData {
  app_version?: string;
  app_version_int?: number;
  subscriptions?: RawSubscriptionItem[];
}

export class SubscriptionItem {
  /** `@SerialName("service_id")`. */
  serviceId: number = 0;
  url: string = '';
  name: string = '';

  constructor(serviceId: number = 0, url: string = '', name: string = '') {
    this.serviceId = serviceId;
    this.url = url;
    this.name = name;
  }

  static fromRaw(raw: RawSubscriptionItem): SubscriptionItem {
    const out: SubscriptionItem = new SubscriptionItem();
    out.serviceId = raw.service_id === undefined ? 0 : raw.service_id;
    out.url = raw.url === undefined ? '' : raw.url;
    out.name = raw.name === undefined ? '' : raw.name;
    return out;
  }

  toRaw(): RawSubscriptionItem {
    const out: RawSubscriptionItem = {
      service_id: this.serviceId,
      url: this.url,
      name: this.name
    };
    return out;
  }
}

export class SubscriptionData {
  subscriptions: SubscriptionItem[] = [];
  /** `@SerialName("app_version")` - BuildConfig.VERSION_NAME in the source. */
  appVersion: string = '';
  /** `@SerialName("app_version_int")` - BuildConfig.VERSION_CODE in the source. */
  appVersionInt: number = 0;

  constructor(subscriptions: SubscriptionItem[] = [], appVersion: string = '',
    appVersionInt: number = 0) {
    this.subscriptions = subscriptions;
    this.appVersion = appVersion;
    this.appVersionInt = appVersionInt;
  }

  static fromRaw(raw: RawSubscriptionData): SubscriptionData {
    const out: SubscriptionData = new SubscriptionData();
    const rawItems: RawSubscriptionItem[] =
      raw.subscriptions === undefined ? [] : raw.subscriptions;
    const items: SubscriptionItem[] = [];
    for (const rawItem of rawItems) {
      items.push(SubscriptionItem.fromRaw(rawItem));
    }
    out.subscriptions = items;
    out.appVersion = raw.app_version === undefined ? '' : raw.app_version;
    out.appVersionInt = raw.app_version_int === undefined ? 0 : raw.app_version_int;
    return out;
  }

  static parse(json: string): SubscriptionData {
    return SubscriptionData.fromRaw(JSON.parse(json) as RawSubscriptionData);
  }

  toRaw(): RawSubscriptionData {
    const items: RawSubscriptionItem[] = [];
    for (const item of this.subscriptions) {
      items.push(item.toRaw());
    }
    const out: RawSubscriptionData = {
      app_version: this.appVersion,
      app_version_int: this.appVersionInt,
      subscriptions: items
    };
    return out;
  }

  stringify(): string {
    return JSON.stringify(this.toRaw());
  }
}
