/*
 * svc_deep_link_router - port of app/src/main/java/org/schabi/newpipe/RouterActivity.java, minus
 * its UI.
 *
 * RouterActivity is what makes "share a YouTube link to NewPipe" work: it takes a URL from
 * another app, works out which service and what kind of link it is, and then either applies the
 * user's remembered choice or offers the choices that are valid for that service and link type.
 *
 * Split for HarmonyOS: this module is the DECISION half - resolve(), which returns a
 * RoutingDecision, and rememberChoice(), which persists an "always" answer. The dialog and the
 * navigation are the router page's job (Phase 3); it renders `decision.choices` and calls back
 * into `handleChoice`. That separation is what lets the decision be tested and reused by the
 * `skills` URI entry in module.json5 as well as by the in-app share flow.
 *
 * The extractor's service lookup (NewPipe.getServiceByUrl / getLinkTypeByUrl / the service's
 * media capabilities) lives in the extractor wave, so it is injected once at startup rather than
 * imported from a module this file would have to guess the location of.
 */

import { AppPreferences } from '../prefs/Preferences';
import {
  add_to_playlist_key,
  background_player_key,
  download_key,
  enqueue_key,
  popup_player_key,
  preferred_open_action_key,
  preferred_open_action_last_selected_key,
  show_info_key,
  use_external_audio_player_key,
  use_external_video_player_key,
  video_player_key
} from '../prefs/SettingsKeys';

/** Port of StreamingService.LinkType. */
export enum LinkType {
  NONE,
  STREAM,
  CHANNEL,
  PLAYLIST
}

/** Port of StreamingService.ServiceInfo.MediaCapability, the two values RouterActivity reads. */
export enum MediaCapability {
  AUDIO,
  VIDEO
}

/** What the extractor tells this module about a URL. */
export class ResolvedLink {
  serviceId: number = -1;
  linkType: LinkType = LinkType.NONE;
  url: string = '';
  capabilities: MediaCapability[] = [];

  constructor(serviceId: number, linkType: LinkType, url: string,
    capabilities: MediaCapability[]) {
    this.serviceId = serviceId;
    this.linkType = linkType;
    this.url = url;
    this.capabilities = capabilities;
  }
}

/** The extractor lookup, injected at startup: null when no service claims the URL. */
export type LinkResolver = (url: string) => Promise<ResolvedLink | null>;

/** How many items the play queue currently holds; the "Enqueue" choice depends on it. */
export type QueueSizeProvider = () => number;

/** One row of the "open with" dialog; port of RouterActivity.AdapterChoiceItem. */
export class RouterChoice {
  /** The preference value, e.g. `video_player` - what gets remembered as the always-choice. */
  key: string = '';
  /** Name of the migrated string resource describing it. */
  descriptionResource: string = '';
  /** Base name of the migrated media resource for its icon. */
  iconResource: string = '';

  constructor(key: string, descriptionResource: string, iconResource: string) {
    this.key = key;
    this.descriptionResource = descriptionResource;
    this.iconResource = iconResource;
  }
}

/** The outcome of resolving one incoming URL. */
export class RoutingDecision {
  /** null when nothing could handle the URL - the source finishes the activity in that case. */
  link: ResolvedLink | null = null;
  /** The choices valid for this service and link type, in the source's order. */
  choices: RouterChoice[] = [];
  /**
   * Set when the decision needs no dialog: the user's remembered `preferred_open_action_key`, or
   * the single available choice. The source shows the dialog only when neither applies.
   */
  autoChoiceKey: string | null = null;
  /** The choice the dialog should pre-select; the source's `preferred_open_action_last_selected`. */
  lastSelectedKey: string | null = null;
}

/**
 * Port of getUrl(intent): the URL either came in as the Want's `uri` (another app opened a link)
 * or as shared text, from which the first URL is extracted. Port of UrlFinder.firstUrlFromInput.
 */
export function firstUrlFromInput(text: string): string | null {
  const match: RegExpMatchArray | null = text.match(/https?:\/\/[^\s<>"']+/);
  return match === null ? null : match[0];
}

export class DeepLinkRouter {
  private prefs: AppPreferences | null = null;
  private resolver: LinkResolver | null = null;
  private queueSize: QueueSizeProvider | null = null;

  /** Called once from EntryAbility through ServiceLocator. */
  init(prefs: AppPreferences, resolver: LinkResolver, queueSize: QueueSizeProvider): void {
    this.prefs = prefs;
    this.resolver = resolver;
    this.queueSize = queueSize;
  }

  private requirePrefs(): AppPreferences {
    const prefs: AppPreferences | null = this.prefs;
    if (prefs === null) {
      throw new Error('DeepLinkRouter used before ServiceLocator.init()');
    }
    return prefs;
  }

  /** Port of getUrl(intent): a direct URI, else the first URL in the shared text. */
  extractUrl(uri: string | null, sharedText: string | null): string | null {
    if (uri !== null && uri.length > 0) {
      return uri;
    }
    if (sharedText !== null && sharedText.length > 0) {
      return firstUrlFromInput(sharedText);
    }
    return null;
  }

  /**
   * Port of handleUrl(url) + onSuccess(): resolves the URL and decides whether a dialog is
   * needed. A URL no service claims (LinkType.NONE) yields a decision with a null link, which is
   * the source's "showUnsupportedUrlDialog then finish".
   */
  async resolve(url: string): Promise<RoutingDecision> {
    const decision: RoutingDecision = new RoutingDecision();
    const resolver: LinkResolver | null = this.resolver;
    if (resolver === null) {
      return decision;
    }

    let link: ResolvedLink | null = null;
    try {
      link = await resolver(url);
    } catch (err) {
      return decision;
    }
    if (link === null || link.linkType === LinkType.NONE) {
      return decision;
    }
    decision.link = link;
    decision.choices = this.getChoicesForService(link);

    const prefs: AppPreferences = this.requirePrefs();
    const preferred: string = prefs.getStringSync(preferred_open_action_key, '');
    const lastSelected: string = prefs.getStringSync(preferred_open_action_last_selected_key, '');
    decision.lastSelectedKey = lastSelected.length > 0 ? lastSelected : null;

    // the remembered "always" choice wins, but only if it is still available for this link
    if (preferred.length > 0) {
      for (const choice of decision.choices) {
        if (choice.key === preferred) {
          decision.autoChoiceKey = preferred;
          return decision;
        }
      }
      // port of the fallback: a player choice that no longer applies falls back to show_info
      decision.autoChoiceKey = show_info_key;
      return decision;
    }

    // port of the switch on availableChoices.size(): 1 choice needs no dialog, 0 shows the info
    if (decision.choices.length === 1) {
      decision.autoChoiceKey = decision.choices[0].key;
    } else if (decision.choices.length === 0) {
      decision.autoChoiceKey = show_info_key;
    }
    return decision;
  }

  /**
   * Port of getChoicesForService(service, linkType), including its ordering: "Show info" is
   * always first, then the players the service supports, then Enqueue when the queue is not
   * empty, then Download and Add-to-playlist for a STREAM only.
   */
  getChoicesForService(link: ResolvedLink): RouterChoice[] {
    const showInfo: RouterChoice =
      new RouterChoice(show_info_key, 'show_info', 'ic_info_outline');
    const videoPlayer: RouterChoice =
      new RouterChoice(video_player_key, 'video_player', 'ic_play_arrow');
    const backgroundPlayer: RouterChoice =
      new RouterChoice(background_player_key, 'background_player', 'ic_headset');
    const popupPlayer: RouterChoice =
      new RouterChoice(popup_player_key, 'popup_player', 'ic_picture_in_picture');

    const returnedItems: RouterChoice[] = [];
    returnedItems.push(showInfo); // always present

    const hasVideo: boolean = link.capabilities.includes(MediaCapability.VIDEO);
    const hasAudio: boolean = link.capabilities.includes(MediaCapability.AUDIO);

    if (link.linkType === LinkType.STREAM || link.linkType === LinkType.PLAYLIST) {
      if (hasVideo) {
        returnedItems.push(videoPlayer);
        returnedItems.push(popupPlayer);
      }
      if (hasAudio) {
        returnedItems.push(backgroundPlayer);
      }

      // Enqueue is only shown if the current queue is not empty
      const sizeProvider: QueueSizeProvider | null = this.queueSize;
      if (sizeProvider !== null && sizeProvider() > 0) {
        returnedItems.push(new RouterChoice(enqueue_key, 'enqueue_stream', 'ic_add'));
      }

      if (link.linkType === LinkType.STREAM) {
        // download is redundant for CHANNEL and PLAYLIST (playlist downloading is unsupported)
        returnedItems.push(new RouterChoice(download_key, 'download', 'ic_file_download'));
        // add-to-playlist is not applicable to CHANNEL or PLAYLIST links
        returnedItems.push(
          new RouterChoice(add_to_playlist_key, 'add_to_playlist', 'ic_playlist_add'));
      }
      return returnedItems;
    }

    // LinkType.NONE is filtered out before here; channels play as a list of videos
    const prefs: AppPreferences = this.requirePrefs();
    const isExtVideoEnabled: boolean = prefs.getBooleanSync(use_external_video_player_key, false);
    const isExtAudioEnabled: boolean = prefs.getBooleanSync(use_external_audio_player_key, false);

    if (hasVideo && !isExtVideoEnabled) {
      returnedItems.push(videoPlayer);
      returnedItems.push(popupPlayer);
    }
    if (hasAudio && !isExtAudioEnabled) {
      returnedItems.push(backgroundPlayer);
    }
    return returnedItems;
  }

  /**
   * Port of the dialog's positive ("Always") button: remembers the choice for future links.
   * `rememberAlways` false is the "Just once" button, which only updates the pre-selection.
   */
  async rememberChoice(choiceKey: string, rememberAlways: boolean): Promise<void> {
    const prefs: AppPreferences = this.requirePrefs();
    prefs.putString(preferred_open_action_last_selected_key, choiceKey);
    if (rememberAlways) {
      prefs.putString(preferred_open_action_key, choiceKey);
    }
    await prefs.flush();
  }
}
