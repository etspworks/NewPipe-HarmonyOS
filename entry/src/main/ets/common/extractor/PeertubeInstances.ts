/*
 * Port of org.schabi.newpipe.util.PeertubeHelper (the plan's svc_peertube_instances), plus the
 * non-UI half of PeertubeInstanceListFragment: the stored instance list, the selected instance,
 * and the validation an instance must pass before it can be added.
 *
 * PeerTube is instance-relative — the base url of every PeerTube request is whichever instance the
 * user picked — so this module and PeertubeService.setInstance() are the only writers of that url.
 *
 * The PeertubeInstance type itself (DEFAULT_INSTANCE, fetchInstanceMetaData) is wave B's
 * model/extractor/PeertubeInstance.ts and is NOT duplicated here.
 *
 * DEVIATIONS:
 *  - nanojson -> JSON.parse/JSON.stringify. The stored value is app preferences, not the extractor
 *    wire format, and the document is two string fields; the shape ({"instances":[{name,url}]}) is
 *    preserved exactly because the settings backup copies preferences verbatim.
 *  - The fragment's toasts become a typed CleanUrlResult, so the Phase-3 screen shows the right
 *    message without this module knowing about the UI.
 */

import { PeertubeInstance } from '../../model/extractor/PeertubeInstance';
import { PeerTube } from './ServiceRegistry';
import { AppPreferences } from '../prefs/Preferences';
import {
  peertube_instance_list_key,
  peertube_selected_instance_key
} from '../prefs/SettingsKeys';

/** Constants.KEY_MAIN_PAGE_CHANGE. */
const KEY_MAIN_PAGE_CHANGE: string = 'key_main_page_change';

/** Raw JSON shape of one stored instance. */
interface RawInstance {
  name?: string;
  url?: string;
}

/** Raw JSON shape of the stored instance list. */
interface RawInstanceList {
  instances?: RawInstance[];
}

/** Why cleanUrl() rejected a url, so the caller can show the source's matching message. */
export enum CleanUrlError {
  NONE,
  /** peertube_instance_add_https_only */
  HTTPS_ONLY,
  /** peertube_instance_add_exists */
  ALREADY_EXISTS
}

export class CleanUrlResult {
  readonly url: string | null;
  readonly error: CleanUrlError;

  constructor(url: string | null, error: CleanUrlError) {
    this.url = url;
    this.error = error;
  }
}

export class PeertubeInstances {
  private constructor() {
    // no instance
  }

  /** Port of PeertubeHelper.currentInstance. */
  static currentInstance(): PeertubeInstance {
    return PeerTube.getInstance();
  }

  /** Port of PeertubeHelper.getInstanceList(context). */
  static getInstanceList(): PeertubeInstance[] {
    const savedJson: string =
      AppPreferences.instance().getStringSync(peertube_instance_list_key, '');
    if (savedJson.length === 0) {
      return [PeertubeInstances.currentInstance()];
    }
    try {
      const raw: RawInstanceList = JSON.parse(savedJson) as RawInstanceList;
      const rawInstances: RawInstance[] = raw.instances === undefined ? [] : raw.instances;
      const list: PeertubeInstance[] = [];
      for (const item of rawInstances) {
        list.push(new PeertubeInstance(item.url === undefined ? '' : item.url,
          item.name === undefined ? '' : item.name));
      }
      return list;
    } catch (e) {
      // runCatching { ... }.getOrDefault(listOf(currentInstance))
      return [PeertubeInstances.currentInstance()];
    }
  }

  /** Port of PeertubeHelper.selectInstance(instance, context). */
  static selectInstance(instance: PeertubeInstance): PeertubeInstance {
    const raw: RawInstance = { name: instance.getName(), url: instance.getUrl() };
    const prefs: AppPreferences = AppPreferences.instance();
    prefs.putString(peertube_selected_instance_key, JSON.stringify(raw));
    // The fragment sets this so the main page rebuilds against the new instance.
    prefs.putBoolean(KEY_MAIN_PAGE_CHANGE, true);
    PeerTube.setInstance(instance);
    return instance;
  }

  /** Port of PeertubeInstanceListFragment.saveChanges(). */
  static saveInstanceList(instances: PeertubeInstance[]): void {
    const rawInstances: RawInstance[] = [];
    for (const instance of instances) {
      rawInstances.push({ name: instance.getName(), url: instance.getUrl() });
    }
    const document: RawInstanceList = { instances: rawInstances };
    AppPreferences.instance().putString(peertube_instance_list_key, JSON.stringify(document));
  }

  /** Port of PeertubeInstanceListFragment.restoreDefaults(). */
  static restoreDefaults(): PeertubeInstance[] {
    AppPreferences.instance().putString(peertube_instance_list_key, '');
    PeertubeInstances.selectInstance(PeertubeInstance.DEFAULT_INSTANCE);
    return PeertubeInstances.getInstanceList();
  }

  /**
   * Port of PeertubeInstanceListFragment.cleanUrl(): https only, no trailing slash, not already
   * in the list.
   */
  static cleanUrl(url: string, existing: PeertubeInstance[]): CleanUrlResult {
    let cleaned: string = url.trim();
    // if protocol not present, add https
    if (!cleaned.startsWith('http')) {
      cleaned = 'https://' + cleaned;
    }
    // remove trailing slash
    cleaned = cleaned.replace(new RegExp('/$'), '');
    // only allow https
    if (!cleaned.startsWith('https://')) {
      return new CleanUrlResult(null, CleanUrlError.HTTPS_ONLY);
    }
    // only allow if not already exists
    for (const instance of existing) {
      if (instance.getUrl() === cleaned) {
        return new CleanUrlResult(null, CleanUrlError.ALREADY_EXISTS);
      }
    }
    return new CleanUrlResult(cleaned, CleanUrlError.NONE);
  }

  /**
   * Port of PeertubeInstanceListFragment.addInstance()'s background half — endpoint
   * `peertube_instance_validate`: an instance is only accepted once `GET <url>/api/v1/config`
   * answers with its name (PeertubeInstance.fetchInstanceMetaData, wave B).
   *
   * Throws when the url is not a reachable PeerTube instance; the caller shows
   * peertube_instance_add_fail, exactly as the source's error branch does.
   */
  static async validateInstance(cleanUrl: string): Promise<PeertubeInstance> {
    const instance: PeertubeInstance = new PeertubeInstance(cleanUrl);
    await instance.fetchInstanceMetaData();
    return instance;
  }

  /**
   * Port of ServiceHelper.initService()'s PeerTube branch: restore the selected instance at
   * startup, before the first PeerTube url is built. A missing or unparseable value leaves the
   * default instance in place, as there.
   */
  static initFromPreferences(): void {
    const json: string =
      AppPreferences.instance().getStringSync(peertube_selected_instance_key, '');
    if (json.length === 0) {
      return;
    }
    try {
      const raw: RawInstance = JSON.parse(json) as RawInstance;
      if (raw.url === undefined || raw.url.length === 0) {
        return;
      }
      PeerTube.setInstance(new PeertubeInstance(raw.url,
        raw.name === undefined ? '' : raw.name));
    } catch (e) {
      // runCatching { ... }.getOrElse { return }
    }
  }
}
