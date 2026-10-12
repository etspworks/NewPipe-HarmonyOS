/*
 * svc_share (endpoint `youtube_temp_playlist_share_url`) - port of
 * app/src/main/java/org/schabi/newpipe/util/external_communication/ShareUtils.java plus
 * local/playlist/ExportPlaylist.kt (the three playlist share formats).
 *
 * The share sheet is raised through `@kit.ShareKit` `systemShare.ShareController.show`, which is
 * what phase2-logic-contract.md section 2.2 asks for.
 *
 * An earlier version of this file recorded ShareKit as absent from the DevEco SDK and substituted
 * `UIAbilityContext.startAbility` with an implicit `ohos.want.action.sendData` Want. The Kit IS
 * present - `hms/ets/kits/@kit.ShareKit.d.ts` and `hms/ets/api/@hms.collaboration.systemShare.d.ts`
 * - and the substitution is what every "No options to open with" report came from: an implicit
 * startAbility that matches nothing still RESOLVES, the system opens its own empty picker, and the
 * promise never rejects, so the clipboard fallback below could never run.
 *
 * That fallback is what makes this never a silent no-op: `show()` does reject when the panel
 * cannot be raised, and then the content is copied to the clipboard with a toast - the behaviour
 * of the source's openAppChooser + copyToClipboard pair.
 *
 * Dropped with their platform: installApp() (market:// + Play Store, no HarmonyOS analogue -
 * AppGallery has no documented open scheme for a self-signed build), the EXTRA_EXCLUDE_COMPONENTS
 * trick that hid NewPipe from its own chooser, and generateClipDataForImagePreview() (the share
 * sheet's rich preview is built by the system here; the app's only say in it is the record's
 * `thumbnail`, which a link share fills with a QR code of the URL - see qrThumbnail()).
 */

import { common, Want, bundleManager, wantConstant } from '@kit.AbilityKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { USER_AGENT } from '../net/Downloader';
import { systemShare } from '@kit.ShareKit';
import { scanCore, generateBarcode } from '@kit.ScanKit';
import { image } from '@kit.ImageKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { pasteboard } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { Localization } from '../i18n/Localization';
import { PlaylistStreamEntry } from '../../model/db/view/PlaylistStreamEntry';
import { MediaFormat } from '../../model/enums/MediaFormat';
import { DeliveryMethod } from '../../model/enums/DeliveryMethod';
import { VideoStream } from '../../model/extractor/VideoStream';
import { AudioStream } from '../../model/extractor/AudioStream';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

/** ExportPlaylist.PlayListShareMode, verbatim. */
export enum PlayListShareMode {
  WITH_TITLES,
  JUST_URLS,
  YOUTUBE_TEMP_PLAYLIST
}

/**
 * A share whose whole content is ONE http(s) link is a link, and the system share sheet will
 * draw it as a hyperlink card - the target app's icon row over a preview that names the page and
 * shows the address - but only when the record says so. Declaring every share PLAIN_TEXT, which
 * is what this file used to do unconditionally, makes the panel fall back to a text preview
 * instead: the URL rendered as a wall of characters, with no title and nothing to recognise.
 *
 * The branch is deliberately narrow. Everything else keeps PLAIN_TEXT, which is what the
 * error-report JSON (multi-line, not a URL) and the WITH_TITLES / JUST_URLS playlist exports
 * (several lines) actually are; the YOUTUBE_TEMP_PLAYLIST export is a single watch_videos URL
 * and correctly becomes a link. `\S` never matches a newline and there is no `m` flag, so a
 * multi-line export cannot satisfy this pattern.
 */
const SINGLE_URL: RegExp = /^https?:\/\/\S+$/;

/**
 * A player this app knows how to start by name.
 *
 * `bundleManager.queryAbilityInfo` - the call that would list every ability matching a want - is
 * a system API and is not in the public SDK at all, so an app here cannot build the chooser from
 * what is installed; and there is no system chooser to delegate to either
 * (`ohos.want.action.select` answers `10104001`, and no want flag raises a selector). A named list
 * plus a default row is therefore the only way a viewer gets to choose, and the port says so
 * rather than pretending the list is discovered. An entry that is not installed throws
 * `16000001` on start and falls back to the default, so a missing app costs one failed start.
 */
export class ExternalPlayerTarget {
  readonly label: string;
  readonly bundleName: string;
  readonly abilityName: string;

  constructor(label: string, bundleName: string, abilityName: string) {
    this.label = label;
    this.bundleName = bundleName;
    this.abilityName = abilityName;
  }
}

/** The rows the "open with" step offers. The empty one lets the system decide, as before. */
export const EXTERNAL_PLAYERS: ExternalPlayerTarget[] = [
  new ExternalPlayerTarget('Video', 'com.huawei.hmos.videoplayer', 'EntryAbility'),
  new ExternalPlayerTarget('HUAWEI Video', 'com.huawei.hmsapp.himovie', 'MainAbility'),
  new ExternalPlayerTarget('System player', '', '')
];

/** The one cache file an external hand-off writes - overwritten, never piled up. */
const EXTERNAL_COPY: string = 'external-player.mp4';
/** 4 MB a GET, the size DownloadManager's own ranged transfer uses. */
const EXTERNAL_CHUNK: number = 4 * 1024 * 1024;
/** Attempts per chunk before the hand-off gives up and the remote want takes over. */
const EXTERNAL_RETRIES: number = 3;

/**
 * The MIME type a stream must be offered with for a PLAYER to claim it rather than a browser.
 *
 * Android's NavigationHelper.playOnExternalPlayer calls setDataAndType(uri, mimeType); the port
 * passed a bare https uri with no type, which is a web link, so the browser was the correct app
 * to take it. That is the whole of this defect.
 *
 * There is no second format table here: MediaFormat already carries a mimeType per constant, so
 * this reads it. Two degradations to the wildcard, both deliberate - no format at all, and a
 * format of the wrong KIND (a subtitle track handed over as a video would be worse than a
 * wildcard). The wildcard still says video or audio, which is the thing the old call never said.
 */
export function mimeForStream(format: MediaFormat | null, audioOnly: boolean): string {
  const kind: string = audioOnly ? 'audio' : 'video';
  if (format === null || format.mimeType.length === 0) {
    return kind + '/*';
  }
  return format.mimeType.startsWith(kind + '/') ? format.mimeType : kind + '/*';
}

/** One stream an external player can be handed, with the format its MIME type comes from. */
export class ExternalStreamChoice {
  readonly url: string;
  readonly format: MediaFormat | null;
  /** What the chooser shows for this row - a resolution for video, a bitrate for audio. */
  readonly label: string;

  constructor(url: string, format: MediaFormat | null, label: string = '') {
    this.url = url;
    this.format = format;
    this.label = label;
  }
}

/** A stream an external player can open by itself: a URL, and not a manifest to assemble. */
function handable(isUrl: boolean, content: string, delivery: DeliveryMethod): boolean {
  return isUrl && content.length !== 0
    && delivery !== DeliveryMethod.DASH && delivery !== DeliveryMethod.SS;
}

/**
 * The video stream an external player should be handed: the tallest self-contained URL.
 *
 * The same rule MediaSourceResolver applies when it has a choice - the MUXED progressive track,
 * highest resolution. A DASH or SS rung is a manifest the other player would have to assemble and
 * a non-url stream is bytes this app holds, so neither can be handed over; null means there is
 * nothing to hand over at all, which is what raises the no-player dialog.
 *
 * T-0212: this used to be private to RouterActivityPage, which is why the preference only worked
 * on a link opened from outside. The detail page's own play needs the same answer.
 */
export function pickExternalVideo(streams: VideoStream[]): ExternalStreamChoice | null {
  let chosen: VideoStream | null = null;
  let chosenHeight: number = -1;
  for (const v of streams) {
    if (!handable(v.isUrl, v.content, v.deliveryMethod)) {
      continue;
    }
    const height: number = heightOf(v.resolution);
    if (chosen === null || height > chosenHeight) {
      chosen = v;
      chosenHeight = height;
    }
  }
  return chosen === null
    ? null : new ExternalStreamChoice(chosen.content, chosen.getFormat(), chosen.resolution);
}

/**
 * Every rung an external player could open, tallest first - the list behind the chooser.
 *
 * The source asks which resolution to hand over (select_quality_external_players,
 * VideoDetailFragment.showExternalVideoPlaybackDialog) rather than deciding for the viewer. The
 * filtering is pickExternalVideo's: a DASH or SS rung is a manifest the other player would have
 * to assemble, and a non-url stream is bytes this app holds.
 *
 * Hand it the muxed list AND the video-only list, as getSortedStreamVideosList is handed both:
 * the taller rungs only exist video-only, which is what the setting's own summary - "Removes
 * audio at some resolutions" - is warning about. One row per resolution, first list first, so a
 * rung that exists both ways is offered as the muxed one that still carries sound.
 */
export function externalVideoChoices(streams: VideoStream[]): ExternalStreamChoice[] {
  const out: ExternalStreamChoice[] = [];
  const seen: Set<string> = new Set<string>();
  for (const v of streams) {
    if (handable(v.isUrl, v.content, v.deliveryMethod) && !seen.has(v.resolution)) {
      seen.add(v.resolution);
      out.push(new ExternalStreamChoice(v.content, v.getFormat(), v.resolution));
    }
  }
  out.sort((a: ExternalStreamChoice, b: ExternalStreamChoice): number =>
    heightOf(b.label) - heightOf(a.label));
  return out;
}

/** `1080p60` -> 1080. The resolution string is the only height an extractor stream carries. */
function heightOf(resolution: string): number {
  const match: RegExpMatchArray | null = resolution.match(/(\d+)/);
  return match !== null ? Number.parseInt(match[1], 10) : 0;
}

/** The audio stream an external player should be handed: the loudest self-contained URL. */
export function pickExternalAudio(streams: AudioStream[]): ExternalStreamChoice | null {
  let best: AudioStream | null = null;
  for (const a of streams) {
    if (!handable(a.isUrl, a.content, a.deliveryMethod)) {
      continue;
    }
    if (best === null || a.averageBitrate > best.averageBitrate) {
      best = a;
    }
  }
  return best === null ? null
    : new ExternalStreamChoice(best.content, best.getFormat(), best.averageBitrate + ' kbps');
}

export function shareUtdFor(content: string): uniformTypeDescriptor.UniformDataType {
  return SINGLE_URL.test(content.trim())
    ? uniformTypeDescriptor.UniformDataType.HYPERLINK
    : uniformTypeDescriptor.UniformDataType.PLAIN_TEXT;
}

/**
 * Edge of the QR thumbnail handed to the share panel. The panel scales it into its link card,
 * so this only bounds how crisp the code stays on a large slot; the PNG is a few KB either way.
 *
 * MEASURED ON DEVICE: the code lands 8.6 mm across, 0.26 mm per module - it decodes from a
 * screenshot but not off another phone's screen with a camera. RAISING THIS NUMBER CANNOT FIX
 * THAT, and neither can any other value in this file. `thumbnail` is a byte array and
 * `thumbnailUri` a path; SharedRecord has no size, scale or placement field, and
 * ShareController.show() takes only selectionMode/previewMode plus an anchor whose Size is the
 * panel's own anchor rect, not the thumbnail's. The rendered edge and the slot it sits in -
 * inside the link row, where UIE-G4-0135 puts it below - are the system panel's layout, drawn
 * in the panel's process. The app supplies pixels and nothing else.
 *
 * So a QR big enough to scan would have to be drawn by the app in its own surface, which is a
 * new screen rather than a number here. Worth weighing against what this QR is for: upstream
 * NewPipe has no QR share at all, and this one exists only so the OS-drawn link card has a
 * picture instead of a bare link glyph (see the file header). 512 keeps it crisp wherever the
 * panel does scale it, and the target app receives the same PNG at full resolution.
 */
const QR_THUMBNAIL_PX: number = 512;

/** The temp-playlist share URL, verbatim from ExportPlaylist.exportAsYoutubeTempPlaylist(). */
const YOUTUBE_TEMP_PLAYLIST_URL: string = 'https://www.youtube.com/watch_videos?video_ids=';

/** YouTube limitation: a temp playlist cannot have more than 50 items. */
const YOUTUBE_TEMP_PLAYLIST_MAX_ITEMS: number = 50;

/** Extracts a YouTube video id from a watch URL; null when the URL is not one. */
export function getYouTubeId(url: string): string | null {
  const patterns: RegExp[] = [
    /[?&]v=([A-Za-z0-9_-]{11})/,
    /youtu\.be\/([A-Za-z0-9_-]{11})/,
    /\/(?:embed|v|shorts|live)\/([A-Za-z0-9_-]{11})/
  ];
  for (const pattern of patterns) {
    const match: RegExpMatchArray | null = url.match(pattern);
    if (match !== null && match.length > 1) {
      return match[1];
    }
  }
  return null;
}

export class ShareUtils {
  private context: common.UIAbilityContext | null = null;

  /** Called once from EntryAbility through ServiceLocator. */
  init(context: common.UIAbilityContext): void {
    this.context = context;
  }

  private requireContext(): common.UIAbilityContext {
    const ctx: common.UIAbilityContext | null = this.context;
    if (ctx === null) {
      throw new Error('ShareUtils used before ServiceLocator.init()');
    }
    return ctx;
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Share
  ////////////////////////////////////////////////////////////////////////// */

  /**
   * Port of shareText(context, title, content, imagePreviewUrl): opens the system share sheet.
   * Falls back to clipboard + toast when the panel cannot be raised, so the control always does
   * something visible.
   */
  async shareText(title: string, content: string): Promise<void> {
    try {
      // A single http(s) URL goes as a HYPERLINK so the sheet draws a link card with the stream
      // name on it; anything else (the error-report JSON, a multi-line playlist export) stays
      // PLAIN_TEXT. No caller changes: `content` is already the URL and `title` the stream name.
      const utd: uniformTypeDescriptor.UniformDataType = shareUtdFor(content);
      const isLink: boolean = utd === uniformTypeDescriptor.UniformDataType.HYPERLINK;
      const record: systemShare.SharedRecord = {
        utd: utd,
        content: content,
        title: title,
        // The panel's link card draws `description` as the line under the title; without it a
        // HYPERLINK share shows the stream name over a bare link glyph and never the address
        // it is about to send (TC-PLAYER-803/804/809).
        description: isLink ? content : undefined,
        // ...and `thumbnail` where that bare link glyph sits. A QR code of the URL is the only
        // way the OS-drawn panel can show one (TC-PLAYER-807/808); it is also what the target
        // app receives as the link's picture.
        thumbnail: isLink ? await this.qrThumbnail(content) : undefined
      };
      const controller: systemShare.ShareController =
        new systemShare.ShareController(new systemShare.SharedData(record));
      await controller.show(this.requireContext(), {
        selectionMode: systemShare.SelectionMode.SINGLE,
        previewMode: systemShare.SharePreviewMode.DETAIL
      });
    } catch (err) {
      await this.copyToClipboard(content);
    }
  }

  /**
   * A PNG QR code of `url` for the share record's thumbnail: Scan Kit draws it, Image Kit packs
   * it. Undefined when either fails, so the share still goes out - only without the picture.
   */
  private async qrThumbnail(url: string): Promise<Uint8Array | undefined> {
    try {
      const options: generateBarcode.CreateOptions = {
        scanType: scanCore.ScanType.QR_CODE,
        width: QR_THUMBNAIL_PX,
        height: QR_THUMBNAIL_PX,
        margin: 1,
        level: generateBarcode.ErrorCorrectionLevel.LEVEL_M
      };
      const pixelMap: image.PixelMap = await generateBarcode.createBarcode(url, options);
      const packer: image.ImagePacker = image.createImagePacker();
      const packing: image.PackingOption = { format: 'image/png', quality: 100 };
      const png: ArrayBuffer = await packer.packToData(pixelMap, packing);
      await packer.release();
      await pixelMap.release();
      return new Uint8Array(png);
    } catch (err) {
      return undefined;
    }
  }

  /**
   * Port of openUrlInBrowser(context, url) / openUrlInApp(context, url): hands the URL to
   * whichever app handles it. The source's browser-only selector has no analogue, so this is the
   * single "open this link outside NewPipe" entry point; on failure it says so with a toast,
   * as the source's openIntentInApp() does.
   */
  async openUrlInBrowser(url: string): Promise<void> {
    const want: Want = {
      action: 'ohos.want.action.viewData',
      uri: url
    };
    try {
      await this.requireContext().startAbility(want);
    } catch (err) {
      promptAction.showToast({
        message: Localization.getString('no_app_to_open_intent'),
        duration: 3000
      });
    }
  }

  /**
   * Hand a STREAM to an external player: a typed viewData want, the way
   * NavigationHelper.playOnExternalPlayer does.
   *
   * Deliberately NOT part of openUrlInBrowser(). That method has ~30 callers - "Open in browser",
   * the donation link, the licences, the error-report issue URL, channel feeds - and every one of
   * them wants a browser. Exactly one caller wants a player, so the two must not share a path:
   * adding a type to the shared method would reroute all thirty.
   *
   * @returns true when something claimed it; false when nothing did, so the caller can offer the
   *          no_player_found dialog instead of silently doing nothing.
   */
  /**
   * The chosen rung, fetched into this app's cache so a player can open it as a file.
   *
   * Ranged GETs appended to one file, the way DownloadManager.fetchRange works - one whole-file
   * ARRAY_BUFFER would hold the entire video in memory. Returns the granted uri, or '' when the
   * fetch failed at any point, which leaves the caller to fall back to the remote want.
   *
   * One file, reused: EXTERNAL_COPY is overwritten on every hand-off rather than accumulating a
   * cache of videos nobody will look at again.
   */
  private async cacheForExternalPlayer(url: string, title: string): Promise<string> {
    const path: string = this.requireContext().cacheDir + '/' + EXTERNAL_COPY;
    const request: http.HttpRequest = http.createHttp();
    let file: fileIo.File | null = null;
    try {
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
      file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
      promptAction.showToast({ message: $r('app.string.preferred_player_fetcher_notification_message'),
        duration: 2000 });
      let offset: number = 0;
      while (true) {
        // A rung sometimes answers 403 on the first ranged GET and serves the same range on a
        // retry - measured on this handset, twice, on URLs the in-app player streams fine. The
        // source's own transfer retries too (DownloadMission.MAX_RETRY), so this is not a
        // workaround for a defect here.
        let response: http.HttpResponse | null = null;
        for (let attempt: number = 0; attempt < EXTERNAL_RETRIES; attempt++) {
          response = await request.request(url, {
            method: http.RequestMethod.GET,
            header: {
              'User-Agent': USER_AGENT,
              'Accept': '*/*',
              'Accept-Encoding': '*',
              'Range': `bytes=${offset}-${offset + EXTERNAL_CHUNK - 1}`
            } as Record<string, string>,
            expectDataType: http.HttpDataType.ARRAY_BUFFER,
            connectTimeout: 30000,
            readTimeout: 30000
          });
          if (response.responseCode < 400) {
            break;
          }
          hilog.warn(0x0000, 'EXTPLAYER', 'fetch answered %{public}d, attempt %{public}d',
            response.responseCode, attempt + 1);
        }
        if (response === null) {
          return '';
        }
        if (response.responseCode === 416) {
          break;
        }
        if (response.responseCode < 200 || response.responseCode > 299) {
          return '';
        }
        if (!(response.result instanceof ArrayBuffer)) {
          return '';
        }
        const body: ArrayBuffer = response.result as ArrayBuffer;
        if (body.byteLength === 0) {
          break;
        }
        fileIo.writeSync(file.fd, body, { offset: offset });
        offset += body.byteLength;
        if (body.byteLength < EXTERNAL_CHUNK) {
          break;
        }
      }
      hilog.info(0x0000, 'EXTPLAYER', 'cached %{public}d bytes for %{public}s', offset, title);
      return offset === 0 ? '' : fileUri.getUriFromPath(path);
    } catch (err) {
      hilog.warn(0x0000, 'EXTPLAYER', 'fetch threw %{public}s', (err as BusinessError).message);
      return '';
    } finally {
      if (file !== null) {
        fileIo.closeSync(file);
      }
      request.destroy();
    }
  }

  async playInExternalPlayer(uri: string, mime: string, title: string,
    target: ExternalPlayerTarget | null = null): Promise<boolean> {
    // A player here opens FILES, not URLs. Measured on the handset, every way round:
    // com.huawei.hmos.videoplayer declares only the file and content schemes and, handed the
    // stream URL explicitly, sits on "Loading..." for ever; HUAWEI Video takes himovie:// and its
    // own host and ignores the rest; PreviewKit answers LOAD_STATE_FAILED; ohos.want.action.select
    // does not exist (10104001); and video/mp4, video/* and the UTD general.mpeg-4 all resolve to
    // the browser. So the hand-off fetches the chosen rung into this app's cache first and hands
    // over a granted file uri - which the system player does open and play
    // (docs/qa/evidence/limit-7-handoff/). The remote want stays as the fallback: a browser
    // playing the stream beats nothing happening.
    const local: string = await this.cacheForExternalPlayer(uri, title);
    if (local.length !== 0) {
      const want: Want = {
        action: 'ohos.want.action.viewData',
        uri: local,
        type: mime,
        flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION,
        parameters: { 'title': title }
      };
      // The viewer's pick first - measured, com.huawei.hmos.videoplayer takes the granted uri and
      // plays it - and the system's own answer when they left it to the system or the pick is not
      // installed (16000001).
      if (target !== null && target.bundleName.length !== 0) {
        try {
          await this.requireContext().startAbility({
            bundleName: target.bundleName,
            abilityName: target.abilityName,
            action: want.action,
            uri: want.uri,
            type: want.type,
            flags: want.flags
          });
          hilog.info(0x0000, 'EXTPLAYER', 'handed a local copy to %{public}s', target.bundleName);
          return true;
        } catch (err) {
          hilog.warn(0x0000, 'EXTPLAYER', '%{public}s refused the copy: %{public}s',
            target.bundleName, (err as BusinessError).message);
        }
      }
      try {
        await this.requireContext().startAbility(want);
        hilog.info(0x0000, 'EXTPLAYER', 'handed over a local copy as %{public}s', mime);
        return true;
      } catch (err) {
        hilog.warn(0x0000, 'EXTPLAYER', 'local hand-off threw %{public}s',
          (err as BusinessError).message);
      }
    }
    // canOpenLink is the PRIMARY signal, not the catch below. startAbility does not reject for a
    // want nothing claims - it resolves after the system puts its own "No options to open with"
    // dialog on screen, measured at VideoDetailFragmentPage.ets:1752 - so a start that "succeeded"
    // is no evidence a player took it.
    let claimed: boolean = true;
    try {
      claimed = bundleManager.canOpenLink(uri);
      hilog.info(0x0000, 'EXTPLAYER', 'canOpenLink=%{public}s type=%{public}s',
        String(claimed), mime);
    } catch (err) {
      // 17700055 invalid link / 17700056 scheme not in querySchemes. The probe not applying is
      // not the same as nothing claiming the want, so fall through to the start.
      hilog.warn(0x0000, 'EXTPLAYER', 'canOpenLink threw %{public}s',
        (err as BusinessError).message);
    }
    if (!claimed) {
      return false;
    }
    const want: Want = {
      action: 'ohos.want.action.viewData',
      uri: uri,
      type: mime,
      parameters: { 'title': title }
    };
    try {
      await this.requireContext().startAbility(want);
      hilog.info(0x0000, 'EXTPLAYER', 'startAbility resolved for %{public}s', mime);
      return true;
    } catch (err) {
      hilog.warn(0x0000, 'EXTPLAYER', 'startAbility threw %{public}s',
        (err as BusinessError).message);
      return false;
    }
  }

  /**
   * MissionAdapter.resolveMimeType(): the file's stored type, else what its extension names, else
   * the generic binary type. Returned with the matching UTD, which is what the share sheet takes.
   */
  static fileTypeOf(name: string, mime: string): string[] {
    let utd: string = '';
    try {
      if (mime.length > 0 && mime !== 'application/octet-stream') {
        utd = uniformTypeDescriptor.getUniformDataTypeByMIMEType(mime);
      }
      const dot: number = name.lastIndexOf('.');
      if ((utd.length === 0 || utd.startsWith('flex.')) && dot >= 0) {
        utd = uniformTypeDescriptor.getUniformDataTypeByFilenameExtension(name.substring(dot));
      }
    } catch (err) {
      utd = '';
    }
    if (utd.length === 0 || utd.startsWith('flex.')) {
      return ['general.file', mime.length > 0 ? mime : 'application/octet-stream'];
    }
    let resolved: string = mime;
    if (resolved.length === 0 || resolved === 'application/octet-stream') {
      try {
        const types: string[] = uniformTypeDescriptor.getTypeDescriptor(utd).mimeTypes;
        resolved = types.length > 0 ? types[0] : 'application/octet-stream';
      } catch (err) {
        resolved = 'application/octet-stream';
      }
    }
    return [utd, resolved];
  }

  /**
   * resolveShareableUri(): a download stored by PATH (the in-app folder picker's choice) becomes
   * the file uri the share sheet and other apps can open; a picker uri passes as it is.
   */
  static shareableUri(location: string): string {
    if (location.startsWith('file://') || !location.startsWith('/')) {
      return location;
    }
    try {
      return fileUri.getUriFromPath(location);
    } catch (err) {
      return location;
    }
  }

  /** MissionAdapter.shareFile(): ACTION_SEND with the file itself, typed, not its path as text. */
  async shareFile(location: string, name: string, mime: string): Promise<void> {
    const type: string[] = ShareUtils.fileTypeOf(name, mime);
    const uri: string = ShareUtils.shareableUri(location);
    try {
      const record: systemShare.SharedRecord = { utd: type[0], uri: uri, title: name };
      const controller: systemShare.ShareController =
        new systemShare.ShareController(new systemShare.SharedData(record));
      await controller.show(this.requireContext(), {
        selectionMode: systemShare.SelectionMode.SINGLE,
        previewMode: systemShare.SharePreviewMode.DEFAULT
      });
    } catch (err) {
      hilog.warn(0x0000, 'ShareUtils', 'shareFile: %{public}s', (err as BusinessError).message);
      promptAction.showToast({ message: Localization.getString('no_app_to_open_intent'),
        duration: 3000 });
    }
  }

  /**
   * MissionAdapter.viewWithFileProvider(): ACTION_VIEW with the file's MIME type and a read
   * grant, so a player both claims the file and can open it.
   */
  async openFile(location: string, name: string, mime: string): Promise<void> {
    const want: Want = {
      action: 'ohos.want.action.viewData',
      uri: ShareUtils.shareableUri(location),
      type: ShareUtils.fileTypeOf(name, mime)[1],
      flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION
    };
    try {
      await this.requireContext().startAbility(want);
    } catch (err) {
      promptAction.showToast({ message: Localization.getString('no_app_to_open_intent'),
        duration: 3000 });
    }
  }

  /**
   * Port of copyToClipboard(context, text): copies and confirms with a toast, or says the copy
   * failed. Both the success and the failure path are visible to the user, as in the source.
   */
  async copyToClipboard(text: string): Promise<void> {
    try {
      const data: pasteboard.PasteData =
        pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      await pasteboard.getSystemPasteboard().setData(data);
      promptAction.showToast({
        message: Localization.getString('msg_copied'),
        duration: 2000
      });
    } catch (err) {
      promptAction.showToast({
        message: Localization.getString('msg_failed_to_copy'),
        duration: 2000
      });
    }
  }

  /* //////////////////////////////////////////////////////////////////////////
  // Playlist export (port of local/playlist/ExportPlaylist.kt)
  ////////////////////////////////////////////////////////////////////////// */

  /** Port of export(shareMode, playlist, context). */
  static exportPlaylist(shareMode: PlayListShareMode, playlist: PlaylistStreamEntry[]): string {
    switch (shareMode) {
      case PlayListShareMode.WITH_TITLES:
        return ShareUtils.exportWithTitles(playlist);
      case PlayListShareMode.JUST_URLS:
        return ShareUtils.exportJustUrls(playlist);
      default:
        return ShareUtils.exportAsYoutubeTempPlaylist(playlist);
    }
  }

  /** Port of exportWithTitles(): one `<title>: <url>` line per stream. */
  private static exportWithTitles(playlist: PlaylistStreamEntry[]): string {
    const lines: string[] = [];
    for (const entry of playlist) {
      lines.push(Localization.getStringArgs('video_details_list_item',
        [entry.streamEntity.title, entry.streamEntity.url]));
    }
    return lines.join('\n');
  }

  /** Port of exportJustUrls(). */
  private static exportJustUrls(playlist: PlaylistStreamEntry[]): string {
    const lines: string[] = [];
    for (const entry of playlist) {
      lines.push(entry.streamEntity.url);
    }
    return lines.join('\n');
  }

  /**
   * Port of exportAsYoutubeTempPlaylist(): the LAST 50 YouTube ids, in original order.
   * The source reverses, takes 50, then reverses back, which keeps the tail of a long playlist.
   */
  private static exportAsYoutubeTempPlaylist(playlist: PlaylistStreamEntry[]): string {
    const reversedIds: string[] = [];
    for (let i: number = playlist.length - 1; i >= 0; i--) {
      const id: string | null = getYouTubeId(playlist[i].streamEntity.url);
      if (id !== null) {
        reversedIds.push(id);
        if (reversedIds.length === YOUTUBE_TEMP_PLAYLIST_MAX_ITEMS) {
          break;
        }
      }
    }
    const videoIDs: string = reversedIds.reverse().join(',');
    return `${YOUTUBE_TEMP_PLAYLIST_URL}${videoIDs}`;
  }
}
