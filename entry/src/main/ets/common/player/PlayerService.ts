/**
 * PlayerService — svc_player. The whole AVPlayer-facing playback layer.
 *
 * Ported from org.schabi.newpipe.player.Player + the resolver package
 * (VideoPlaybackResolver / AudioPlaybackResolver / PlaybackResolver).
 *
 * ExoPlayer has no HarmonyOS counterpart, so the ExoPlayer artifacts are a
 * `platform-capability` SUBSTITUTION, not a port (phase2-logic-contract.md §2.5):
 *   - DASH (`.mpd`) and SmoothStreaming are DROPPED. SmoothStreaming because nothing here reads
 *     it; DASH **not** because AVPlayer refuses it - that claim was in this header for a long
 *     time and it is WRONG. Measured 2026-10-02 on the port handset
 *     (docs/qa/evidence/fix-T-0198b/dash-probe.txt): media.createMediaSourceWithUrl() +
 *     setMediaSource() on a public MPD walked initialized -> prepared -> playing and play()
 *     resolved. DASH is playable through setMediaSource; it is simply a path this player has
 *     never been built on, and changing that is an epic, not a comment.
 *     The source prefers DASH for live (an ExoPlayer bug workaround); we invert that and use
 *     the service HLS manifest, which AVPlayer does support.
 *   - MergingMediaSource (video-only + audio-only merged at playback time) is replaced by a
 *     locally synthesized HLS manifest served over 127.0.0.1.
 *
 * Source resolution order (harmonyos-media-streaming.md §3 — MS03):
 *   1. muxed progressive MP4        2. service HLS (m3u8)
 *   3. synthesized local HLS        4. best audio-only
 * Never a `.mpd`, never a `file://` (MS01 / MS02).
 *
 * MediaSourceResolver / HlsManifestBuilder / LocalHlsServer are the drop-in modules from
 * pipeline/template/media/, inlined here because this lane owns exactly four files.
 */

import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { NodeController, PiPWindow } from '@kit.ArkUI';
import { ApplicationStateChangeCallback, common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { Fragment, parseSidx } from './SegmentIndex';
import { USER_AGENT } from '../net/Downloader';
import { BehaviorSubject, CompositeDisposable } from '../rx/Rx';
import { PlayQueue, currentPlayQueue } from '../../model/app/PlayQueue';
import { Localization } from '../i18n/Localization';
import { Image as StreamImage } from '../../model/extractor/Image';
import { choosePreferredImage } from '../image/ImageLoader';
import { StreamInfo } from '../../model/extractor/StreamInfo';
import { VideoStream } from '../../model/extractor/VideoStream';
import { AudioStream } from '../../model/extractor/AudioStream';
import { AudioTrackType } from '../../model/extractor/AudioTrackType';
import { Stream } from '../../model/extractor/Stream';
import { MediaFormat } from '../../model/enums/MediaFormat';
import { ServiceLocator } from '../di/ServiceLocator';
import {
  enable_watch_history_key, prefer_descriptive_audio_key, prefer_original_audio_key
} from '../prefs/SettingsKeys';
import { StreamType } from '../../model/enums/StreamType';
import { DeliveryMethod } from '../../model/enums/DeliveryMethod';
import { ItagItem } from '../extractor/core/ItagItem';
import { ItagItem as YoutubeItagItem } from '../extractor/services/youtube/ItagItem';
import { MinimizeMode, PlayerPrefs, RESIZE_MODE_FILL, RESIZE_MODE_ZOOM } from './PlayerPrefs';
import { HistoryRecordManager } from '../db/HistoryRecordManager';
import { ExtractorHelper } from '../extractor/ExtractorHelper';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'PlayerService';
/** AVERR_IO and AVERR_UNSUPPORT_FORMAT: AVPlayer could not read what it was handed. */
const AVERR_IO: number = 5400103;
const AVERR_UNSUPPORT_FORMAT: number = 5400106;

/** Only the host of a stream url goes into the log - the rest carries the session's tokens. */
function hostOf(url: string): string {
  const m: RegExpMatchArray | null = url.match(/^[a-z]+:\/\/([^/?#]+)/i);
  return m !== null && m.length >= 2 ? m[1] : '';
}

/**
 * PiPConfiguration.defaultWindowSizeType: 1 = small. Unset, the system opened the popup at its
 * large size - about twice the Android popup (popup_default_width = 180dp wide).
 */
const PIP_SMALL_WINDOW: number = 1;
/**
 * TC-PLAYER-205: how many times a mid-playback network error is re-opened before the error panel
 * is shown, and how long to wait between tries - together about **30 seconds** of spinner.
 *
 * The reference buffers indefinitely: cut its connection and it was still spinning 40 s later. A
 * port that never gives up would match it exactly and would also hang forever on a source that is
 * genuinely gone, which is the failure the error panel exists for. 30 s rides out a lift, a tunnel
 * or a cell hand-over, and a viewer who really is offline is told rather than left watching.
 *
 * Any real progress refunds the budget (see the `time > 0` guard in 'timeUpdate'), so a stream
 * that keeps recovering keeps its full 30 s each time.
 */
const NETWORK_RETRY_LIMIT: number = 10;
/** Wait between re-opens, so a dead connection is not hammered. */
const NETWORK_RETRY_DELAY_MS: number = 3000;

// ---------------------------------------------------------------------------
// Typed track descriptors (template/media/HlsManifestBuilder + MediaSourceResolver)
// ---------------------------------------------------------------------------

export enum Delivery {
  PROGRESSIVE = 'progressive',
  HLS = 'hls'
}

/** Minimal byte-range descriptor every synthesizable track must provide. */
export interface MediaTrack {
  url: string;
  /** The service's format id (YouTube itag), -1 when it has none. For the log only. */
  itag: number;
  initStart: number;
  initEnd: number;
  /**
   * Byte range of the fMP4 `sidx` box, from YouTube's `indexRange`. 0 when the format carries
   * none. Without it the playlist can only GUESS where fragments begin, and a guess is what made
   * everything above 360p die a few seconds in - see SegmentIndex.ts and T-0198.
   */
  indexStart: number;
  indexEnd: number;
  contentLength: number;
  approxDurationMs: number;
  mimeType: string;
  width: number;
  height: number;
  bitrate: number;
}

export class VideoTrack implements MediaTrack {
  url: string = '';
  itag: number = -1;
  initStart: number = -1;
  initEnd: number = -1;
  indexStart: number = 0;
  indexEnd: number = 0;
  contentLength: number = -1;
  approxDurationMs: number = 0;
  mimeType: string = '';
  width: number = 0;
  height: number = 0;
  bitrate: number = 0;
  /** True when this track already carries audio (a muxed progressive format). */
  isMuxed: boolean = false;
  /** True when the service delivers this track only via DASH/SS — skip it (MS01). */
  isDashDelivered: boolean = false;
  resolution: string = '';
}

export class AudioTrack implements MediaTrack {
  url: string = '';
  itag: number = -1;
  /**
   * AudioStream.getAudioTrackId() - "ar.4", "en-US.4". The resolver had no way to tell two
   * language tracks apart, so it always took the loudest one and the audio-track control could
   * not change what played.
   */
  trackId: string = '';
  /**
   * AudioStream.getAudioTrackType() === ORIGINAL. The player had no idea which of a video's ten
   * dubs was the one the uploader recorded, so bestAudio() took the loudest - T-0206.
   */
  isOriginal: boolean = false;
  /** AudioStream.getAudioTrackType() === DESCRIPTIVE - the audio-description track (T-0209). */
  isDescriptive: boolean = false;
  initStart: number = -1;
  initEnd: number = -1;
  indexStart: number = 0;
  indexEnd: number = 0;
  contentLength: number = -1;
  approxDurationMs: number = 0;
  mimeType: string = '';
  width: number = 0;
  height: number = 0;
  bitrate: number = 0;
  averageBitrate: number = 0;
}

/** Everything the extractor produced for one item, in AVPlayer terms. */
export class StreamSet {
  muxed: VideoTrack[] = [];
  videoOnly: VideoTrack[] = [];
  audio: AudioTrack[] = [];
  /** Service-provided HLS manifest URL, '' if none. A DASH URL is deliberately absent. */
  hlsUrl: string = '';
  isLive: boolean = false;
}

export class PlayableSource {
  /**
   * The audio track this source actually plays, '' when it is whatever the stream defaults to -
   * a muxed progressive file carries the original track and nothing else. The control reads it
   * back, so it can never claim a language the player is not playing.
   */
  audioTrackId: string = '';
  url: string;
  delivery: Delivery;
  resolution: string = '';
  /** Carried from StreamSet.isLive: AVPlayer rejects setSpeed() on a live stream (err 801). */
  isLive: boolean = false;
  audioOnly: boolean;

  constructor(url: string, delivery: Delivery, audioOnly: boolean) {
    this.url = url;
    this.delivery = delivery;
    this.audioOnly = audioOnly;
  }
}

// ---------------------------------------------------------------------------
// HlsManifestBuilder (MS06 / MS07 / MS08)
// ---------------------------------------------------------------------------

export class HlsManifestBuilder {
  /** Segment CDNs 403 one huge Range but serve <=10MB chunks (206); ~2MB seeks smoothly. */
  private static readonly CHUNK_BYTES: number = 2 * 1024 * 1024;

  static hasByteRanges(t: MediaTrack): boolean {
    return t.initStart >= 0 && t.initEnd > t.initStart
      && t.contentLength > t.initEnd && t.url.length > 0;
  }

  /**
   * Can a rendition of these playlists carry this track at all? They are fMP4 - EXT-X-MAP names
   * an ftyp+moov init segment and every byte range must start on a moof - so only an MP4-boxed
   * H.264 video or AAC audio track qualifies. YouTube also lists Opus and VP9 in WebM, whose
   * "init range" is an EBML header and whose "index range" is a Cues element: put one in here and
   * AVPlayer's demuxer fails with 5400103 DEM_PARSE_ERR.
   *
   * The video side always filtered on avc1; the audio side never filtered at all, and the itag
   * table rates Opus 251 at 160 kbps against AAC 140's 128, so bestAudio() handed EVERY synthesis
   * the WebM track whenever a client (ANDROID) listed it, and only a video whose formats came
   * from the iOS client alone, which lists no WebM, got a playable pair. That is the most likely
   * cause of 5400103 on ordinary videos ("2 of 3 fail") and of T-0202's open question below -
   * read from the code, not yet proven on a device; synthesize() logs the pair it builds.
   */
  static canCarry(t: MediaTrack): boolean {
    return t.mimeType.indexOf('avc1') !== -1 || t.mimeType.indexOf('mp4a') !== -1;
  }

  /**
   * Whether this track's sidx range is usable. Mirrors hasByteRanges(): a track that fails this
   * keeps the flat-chunk playlist, which is wrong for fMP4 but is what shipped - it must not
   * become a hard failure for a format that carries no index.
   */
  static hasSegmentIndex(t: MediaTrack): boolean {
    return t.indexStart > 0 && t.indexEnd > t.indexStart && t.contentLength > t.indexEnd;
  }

  static masterPlaylist(video: MediaTrack, audioTrack: MediaTrack,
    videoName: string, audioName: string): string {
    const codecs: string = HlsManifestBuilder.codecsAttr(video, audioTrack);
    const bandwidth: number = (video.bitrate > 0 ? video.bitrate : 0)
      + (audioTrack.bitrate > 0 ? audioTrack.bitrate : 0);
    let s: string = '#EXTM3U\n'
      + '#EXT-X-VERSION:7\n'
      + '#EXT-X-INDEPENDENT-SEGMENTS\n'
      + '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="audio",DEFAULT=YES,'
      + 'AUTOSELECT=YES,URI="' + audioName + '"\n'
      + '#EXT-X-STREAM-INF:BANDWIDTH=' + (bandwidth > 0 ? bandwidth : 1000000);
    if (codecs.length > 0) {
      s = s + ',CODECS="' + codecs + '"';
    }
    if (video.width > 0 && video.height > 0) {
      s = s + ',RESOLUTION=' + video.width + 'x' + video.height;
    }
    s = s + ',AUDIO="aud"\n' + videoName + '\n';
    return s;
  }

  /**
   * fMP4 media playlist built from the REAL fragment list.
   *
   * mediaPlaylist() below cuts flat CHUNK_BYTES ranges, which do not land on `moof` boundaries -
   * the first segment plays and the second starts inside an `mdat`, which is the 5400103 of
   * T-0198 (AVERR_IO, a generic I/O error; the format error 5400106 never arrives). This one
   * emits exactly the fragments the sidx names, with their own durations instead of a
   * byte-proportional guess.
   */
  static mediaPlaylistFrom(t: MediaTrack, frags: Fragment[]): string {
    const initLen: number = t.initEnd - t.initStart + 1;
    let segments: string = '';
    let maxSeg: number = 0;
    for (const f of frags) {
      const segDur: number = f.durationMs / 1000;
      if (segDur > maxSeg) {
        maxSeg = segDur;
      }
      segments = segments
        + '#EXTINF:' + segDur.toFixed(3) + ',\n'
        + '#EXT-X-BYTERANGE:' + f.length + '@' + f.offset + '\n'
        + t.url + '\n';
    }
    const target: number = Math.ceil(maxSeg > 0 ? maxSeg : 1);
    return '#EXTM3U\n'
      + '#EXT-X-VERSION:7\n'
      + '#EXT-X-PLAYLIST-TYPE:VOD\n'
      + '#EXT-X-TARGETDURATION:' + target + '\n'
      + '#EXT-X-MAP:URI="' + t.url + '",BYTERANGE="' + initLen + '@' + t.initStart + '"\n'
      + segments
      + '#EXT-X-ENDLIST\n';
  }

  /** fMP4 media playlist: EXT-X-MAP init segment + <=CHUNK_BYTES byte-range segments. */
  static mediaPlaylist(t: MediaTrack): string {
    const initLen: number = t.initEnd - t.initStart + 1;
    const mediaStart: number = t.initEnd + 1;
    const mediaLen: number = t.contentLength - mediaStart;
    const dur: number = t.approxDurationMs > 0 ? t.approxDurationMs / 1000 : 1;

    let segments: string = '';
    let maxSeg: number = 0;
    let offset: number = mediaStart;
    let remaining: number = mediaLen;
    while (remaining > 0) {
      const len: number = remaining > HlsManifestBuilder.CHUNK_BYTES
        ? HlsManifestBuilder.CHUNK_BYTES : remaining;
      const segDur: number = dur * (len / mediaLen);
      if (segDur > maxSeg) {
        maxSeg = segDur;
      }
      segments = segments
        + '#EXTINF:' + segDur.toFixed(3) + ',\n'
        + '#EXT-X-BYTERANGE:' + len + '@' + offset + '\n'
        + t.url + '\n';
      offset = offset + len;
      remaining = remaining - len;
    }
    const target: number = Math.ceil(maxSeg > 0 ? maxSeg : dur);
    return '#EXTM3U\n'
      + '#EXT-X-VERSION:7\n'
      + '#EXT-X-PLAYLIST-TYPE:VOD\n'
      + '#EXT-X-TARGETDURATION:' + target + '\n'
      + '#EXT-X-MAP:URI="' + t.url + '",BYTERANGE="' + initLen + '@' + t.initStart + '"\n'
      + segments
      + '#EXT-X-ENDLIST\n';
  }

  private static codecsAttr(video: MediaTrack, audioTrack: MediaTrack): string {
    const v: string = HlsManifestBuilder.extractCodec(video.mimeType);
    const a: string = HlsManifestBuilder.extractCodec(audioTrack.mimeType);
    if (v.length > 0 && a.length > 0) {
      return v + ',' + a;
    }
    return v.length > 0 ? v : a;
  }

  private static extractCodec(mimeType: string): string {
    const m: RegExpMatchArray | null = mimeType.match(/codecs="([^"]+)"/);
    return m !== null && m.length >= 2 ? m[1] : '';
  }
}

// ---------------------------------------------------------------------------
// LocalHlsServer (MS09) — AVPlayer rejects file://, so the manifests are served from
// 127.0.0.1. Only the small text playlists pass through; the media segments are absolute
// CDN URLs AVPlayer fetches itself. No media bytes are ever proxied.
// ---------------------------------------------------------------------------

export class LocalHlsServer {
  private static instance: LocalHlsServer | null = null;
  private server: socket.TCPSocketServer | null = null;
  private port: number = 0;
  private started: boolean = false;
  private routes: Map<string, string> = new Map<string, string>();

  static getInstance(): LocalHlsServer {
    if (LocalHlsServer.instance === null) {
      LocalHlsServer.instance = new LocalHlsServer();
    }
    return LocalHlsServer.instance;
  }

  async start(): Promise<number> {
    if (this.started) {
      return this.port;
    }
    const server: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();
    // port 0: let the OS pick a free ephemeral port.
    await server.listen({ address: '127.0.0.1', family: 1, port: 0 });
    const local: socket.NetAddress = await server.getLocalAddress();
    this.port = local.port !== undefined ? local.port : 0;
    server.on('connect', (client: socket.TCPSocketConnection): void => {
      this.handleClient(client);
    });
    this.server = server;
    this.started = true;
    console.info(TAG + ': LocalHlsServer listening on 127.0.0.1:' + this.port);
    return this.port;
  }

  isStarted(): boolean {
    return this.started;
  }

  /** Publish one playlist set (one stream plays at a time); returns the master URL. */
  publish(master: string, video: string, audioPlaylist: string,
    masterName: string, videoName: string, audioName: string): string {
    const routes: Map<string, string> = new Map<string, string>();
    routes.set('/' + masterName, master);
    routes.set('/' + videoName, video);
    routes.set('/' + audioName, audioPlaylist);
    this.routes = routes;
    return 'http://127.0.0.1:' + this.port + '/' + masterName;
  }

  stop(): void {
    const server: socket.TCPSocketServer | null = this.server;
    if (server === null) {
      return;
    }
    try {
      server.off('connect');
    } catch (e) {
      console.warn(TAG + ': LocalHlsServer stop failed: ' + describeError(e));
    } finally {
      this.server = null;
      this.started = false;
      this.routes = new Map<string, string>();
    }
  }

  private handleClient(client: socket.TCPSocketConnection): void {
    client.on('message', (value: socket.SocketMessageInfo): void => {
      const path: string = LocalHlsServer.requestPath(LocalHlsServer.decode(value.message));
      const body: string | undefined = this.routes.get(path);
      const response: string = body !== undefined
        ? LocalHlsServer.httpOk(body)
        : LocalHlsServer.httpNotFound();
      client.send({ data: response })
        .then((): void => {
          client.close();
        })
        .catch((): void => {
          client.close();
        });
    });
  }

  private static requestPath(request: string): string {
    // First line: "GET /np_master.m3u8 HTTP/1.1"
    const firstLine: string = request.split('\r\n')[0];
    const parts: string[] = firstLine.split(' ');
    if (parts.length >= 2) {
      const p: string = parts[1];
      const q: number = p.indexOf('?');
      return q >= 0 ? p.substring(0, q) : p;
    }
    return '/';
  }

  private static httpOk(body: string): string {
    const bytes: number = new util.TextEncoder().encodeInto(body).length;
    return 'HTTP/1.1 200 OK\r\n'
      + 'Content-Type: application/vnd.apple.mpegurl\r\n'
      + 'Content-Length: ' + bytes + '\r\n'
      + 'Access-Control-Allow-Origin: *\r\n'
      + 'Connection: close\r\n\r\n'
      + body;
  }

  private static httpNotFound(): string {
    return 'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n';
  }

  private static decode(message: ArrayBuffer): string {
    return util.TextDecoder.create('utf-8').decodeWithStream(new Uint8Array(message));
  }
}

/** One place that turns an unknown thrown value into a loggable string. */
export function describeError(e: ESObject): string {
  const err: BusinessError = e as BusinessError;
  if (err !== undefined && err !== null && err.message !== undefined) {
    return 'code ' + err.code + ': ' + err.message;
  }
  return String(e);
}

// ---------------------------------------------------------------------------
// MediaSourceResolver (MS03) — the §3 decision tree.
// ---------------------------------------------------------------------------

export class MediaSourceResolver {
  /**
   * Tallest rendition the synthesized branch is measured to sustain.
   *
   * Raised from 720 after the sidx fix: 720 was a guard against the flat-chunk bug, never a
   * measured limit. 1080 is the highest rung that played 60+ seconds on all three ladder videos
   * (docs/qa/evidence/fix-T-0198b/ladder.txt).
   *
   * Raising it further would be theatre: bestVideoOnly() only accepts 'avc1' tracks, and YouTube
   * publishes nothing above 1080p in H.264 - 1440p and 2160p are VP9/AV1 only. The ladder was run
   * with this constant at 4320 and a 2160p request still served 1080p, so the binding constraint
   * is the codec filter, not this number.
   */
  private static readonly SYNTH_CEILING: number = 1080;

  /**
   * targetHeight is the quality the user asked for, in pixels of height; 0 means "whatever is
   * best", which is what every caller but the quality menu passes and what this did before.
   */
  static async resolve(set: StreamSet, server: LocalHlsServer,
    audioOnly: boolean, targetHeight: number = 0,
    audioTrackId: string = ''): Promise<PlayableSource | null> {
    if (audioOnly) {
      // AudioPlaybackResolver: live first, then the best audio stream, then — when the
      // service has no separate audio at all — a video stream used as the audio source.
      if (set.isLive && set.hlsUrl.length > 0) {
        const live: PlayableSource = new PlayableSource(set.hlsUrl, Delivery.HLS, true);
        live.resolution = 'auto';
        live.isLive = true;
        return live;
      }
      const bestAudio: AudioTrack | null = MediaSourceResolver.bestAudio(set, audioTrackId);
      if (bestAudio !== null) {
        const src: PlayableSource = new PlayableSource(bestAudio.url, Delivery.PROGRESSIVE, true);
        src.audioTrackId = bestAudio.trackId;
        return src;
      }
      const muxedForAudio: VideoTrack | null = MediaSourceResolver.bestMuxed(set, targetHeight);
      if (muxedForAudio !== null) {
        return new PlayableSource(muxedForAudio.url, Delivery.PROGRESSIVE, true);
      }
      return null;
    }

    // Live: the source prefers DASH here to work around an ExoPlayer bug. This port uses the
    // service HLS manifest instead - not because AVPlayer refuses DASH (measured: it does not,
    // see the file header and docs/qa/evidence/fix-T-0198b/dash-probe.txt) but because nothing
    // in this player is built on setMediaSource, which is the API DASH needs (MS01).
    if (set.isLive && set.hlsUrl.length > 0) {
      const live: PlayableSource = new PlayableSource(set.hlsUrl, Delivery.HLS, false);
      live.resolution = 'auto';
      live.isLive = true;
      return live;
    }

    // A language the user picked can only be honoured by a source that carries THAT audio
    // stream. Muxed progressive carries exactly one soundtrack - the original - so taking it
    // first is why the control could read "Arabic" over English audio. When the stream really
    // does carry the requested track, the muxed shortcut is skipped and the video-only + chosen
    // audio synthesis below is used instead; if that cannot be built, the muxed file is still
    // better than no video, and resolve() reports the track it actually applied.
    const wantsOtherTrack: boolean =
      audioTrackId.length > 0 && MediaSourceResolver.carriesTrack(set, audioTrackId);
    if (wantsOtherTrack) {
      const dubbed: PlayableSource | null =
        await MediaSourceResolver.synthesize(set, server, targetHeight, audioTrackId);
      if (dubbed !== null) {
        return dubbed;
      }
      console.info(TAG + ': audio track ' + audioTrackId
        + ' could not be synthesised (server started=' + server.isStarted()
        + ', hlsUrl=' + (set.hlsUrl.length > 0) + '); the original soundtrack stays');
    }

    // A height the user PICKED and the muxed set cannot give is synthesised, the same way a
    // picked audio language is. Without this the quality control could offer a resolution that
    // only exists as a video-only stream and then quietly play a muxed one instead - measured:
    // choosing "MPEG-4 144p" left the decoder at 320x240, because bestMuxed() rounds to the
    // nearest muxed rendition and the muxed set held only 360p.
    if (targetHeight > 0 && !MediaSourceResolver.muxedHas(set, targetHeight)
      && MediaSourceResolver.synthesisBeatsMuxed(set, targetHeight)) {
      const picked: PlayableSource | null =
        await MediaSourceResolver.synthesize(set, server, targetHeight, audioTrackId);
      if (picked !== null) {
        return picked;
      }
      console.info(TAG + ': height ' + targetHeight + ' could not be synthesised; '
        + 'falling back to the nearest muxed rendition');
    }

    // 1. Muxed progressive — most reliable. DASH-delivered "muxed" tracks are skipped.
    const muxed: VideoTrack | null = MediaSourceResolver.bestMuxed(set, targetHeight);
    if (muxed !== null) {
      hilog.info(0x0000, TAG, 'muxed itag=%{public}d mime=%{public}s res=%{public}s '
        + 'host=%{public}s', muxed.itag, muxed.mimeType, muxed.resolution, hostOf(muxed.url));
      const src: PlayableSource = new PlayableSource(muxed.url, Delivery.PROGRESSIVE, false);
      src.resolution = muxed.resolution;
      return src;
    }

    // 2. Service HLS manifest (VOD HLS — PeerTube, media.ccc.de).
    if (set.hlsUrl.length > 0) {
      const src: PlayableSource = new PlayableSource(set.hlsUrl, Delivery.HLS, false);
      src.resolution = 'auto';
      return src;
    }

    // 3. Separate video-only + audio-only fMP4 -> synthesize local HLS over loopback.
    const synth: PlayableSource | null =
      await MediaSourceResolver.synthesize(set, server, targetHeight, audioTrackId);
    if (synth !== null) {
      return synth;
    }

    // 4. Audio-only fallback.
    const fallback: AudioTrack | null = MediaSourceResolver.bestAudio(set, audioTrackId);
    if (fallback === null) {
      return null;
    }
    const last: PlayableSource = new PlayableSource(fallback.url, Delivery.PROGRESSIVE, true);
    last.audioTrackId = fallback.trackId;
    return last;
  }

  /**
   * Is there anything to GAIN by synthesising at this height?
   *
   * bestVideoOnly() only accepts avc1, and a video whose avc1 ladder stops at 360p gives back a
   * 360p track - the same height the muxed file already carries. The synthesis path is then all
   * risk and no benefit: measured on T-0202 (iG9CE55wbtY, whose avc1 stops at 360p while 480p and
   * 720p exist only as VP9/AV1), the synthesized 360p playlist is byte-exact - ftyp at 0, moof at
   * every computed fragment offset, last fragment ending on contentLength - and AVPlayer still
   * refuses it with 5400103, while the muxed 360p of the same video plays. The reference plays
   * that video too.
   *
   * So: synthesise only when it actually reaches higher than the muxed set can. Why the
   * synthesized 360p is refused at all is NOT explained by this and is recorded as an open
   * question in docs/qa/evidence/fix-T-0202/.
   */
  private static synthesisBeatsMuxed(set: StreamSet, targetHeight: number): boolean {
    const video: VideoTrack | null = MediaSourceResolver.bestVideoOnly(set, targetHeight);
    if (video === null) {
      return false;
    }
    const muxed: VideoTrack | null = MediaSourceResolver.bestMuxed(set, targetHeight);
    if (muxed === null || video.height > muxed.height) {
      return true;
    }
    // T-0205: and when the muxed set OVERSHOOTS what was asked for. bestMuxed() rounds to the
    // nearest muxed rendition, which on YouTube is 360p and nothing below, so a user asking for
    // 144p or 240p was handed 360p - measured on the port, `MPEG-4 144p` served 640x360 in both
    // the popup and the quality menu while the reference played 144p. T-0202's risk was a
    // synthesis that gains NOTHING over the muxed file; a rung the user explicitly asked for and
    // that bestVideoOnly() can hit exactly is the opposite case, so it is allowed through.
    //
    // ...but only for a stream whose synthesis is known to work at all, and the test for that is
    // T-0202's own rule read against the STREAM instead of against the requested rung. Measured
    // on the port while reviewing T-0205: iG9CE55wbtY, whose avc1 video-only ladder tops out at
    // 360p - exactly its muxed height - is refused by AVPlayer at EVERY synthesized rung, not
    // only at 360p. A cold open with `Default resolution` 144p and a popup at `Default popup
    // resolution` 144p both died with `5400103 DEM_PARSE_ERR-video/avc`, deterministically, and
    // the detail page showed the error where before T-0205 the muxed 360p simply played:
    //
    //   T0205L target=144 topVideoOnly=360/avc1.4d400d topMuxed=360   -> refused, 5400103
    //   T0205L target=144 topVideoOnly=1080/avc1.640028 topMuxed=360  -> plays, 256x144
    //
    // ponytail: a ladder that reaches past the muxed set is a PROXY for "this stream synthesises",
    // not a proof - why AVPlayer refuses the other kind is still T-0202's open question. If a
    // stream ever turns up that clears this test and still fails, the upgrade is a runtime
    // fallback to the muxed rendition on 5400103 rather than a cleverer static guess.
    const topVideo: VideoTrack | null = MediaSourceResolver.bestVideoOnly(set, 0);
    const topMuxed: VideoTrack | null = MediaSourceResolver.bestMuxed(set, 0);
    const synthesisReachesPastMuxed: boolean =
      topVideo !== null && topMuxed !== null && topVideo.height > topMuxed.height;
    return muxed.height > targetHeight && video.height <= targetHeight
      && synthesisReachesPastMuxed;
  }

  private static async synthesize(set: StreamSet, server: LocalHlsServer,
    targetHeight: number, audioTrackId: string = ''): Promise<PlayableSource | null> {
    if (!server.isStarted()) {
      return null;
    }
    const video: VideoTrack | null = MediaSourceResolver.bestVideoOnly(set, targetHeight);
    const audioTrack: AudioTrack | null = MediaSourceResolver.bestAudio(set, audioTrackId, true);
    if (video === null || audioTrack === null
      || !HlsManifestBuilder.hasByteRanges(video)
      || !HlsManifestBuilder.hasByteRanges(audioTrack)) {
      console.info(TAG + ': synthesis unavailable: video=' + (video === null ? 'none'
        : video.resolution + ' ranges=' + HlsManifestBuilder.hasByteRanges(video))
        + ' audio=' + (audioTrack === null ? 'none'
          : audioTrack.trackId + ' ranges=' + HlsManifestBuilder.hasByteRanges(audioTrack)));
      return null;
    }
    const masterName: string = 'np_master.m3u8';
    const videoName: string = 'np_video.m3u8';
    const audioName: string = 'np_audio.m3u8';
    // T-0198: cut on real fragment boundaries when the format carries a sidx, and keep the old
    // flat chunking when it does not. One extra Range GET of a few KB per track.
    const videoFrags: Fragment[] = await MediaSourceResolver.fetchSegmentIndex(video);
    const audioFrags: Fragment[] = await MediaSourceResolver.fetchSegmentIndex(audioTrack);
    // One device run of this line says which pair a failing video got: 0 frags means the sidx
    // could not be fetched and the flat-chunk playlist (T-0198's 5400103) went out instead.
    hilog.info(0x0000, TAG, 'synth video itag=%{public}d mime=%{public}s res=%{public}s '
      + 'dash=%{public}s host=%{public}s init=%{public}d-%{public}d index=%{public}d-%{public}d '
      + 'clen=%{public}s frags=%{public}d', video.itag, video.mimeType, video.resolution,
      String(video.isDashDelivered), hostOf(video.url), video.initStart, video.initEnd,
      video.indexStart, video.indexEnd, String(video.contentLength), videoFrags.length);
    hilog.info(0x0000, TAG, 'synth audio itag=%{public}d mime=%{public}s track=%{public}s '
      + 'host=%{public}s clen=%{public}s frags=%{public}d', audioTrack.itag, audioTrack.mimeType,
      audioTrack.trackId, hostOf(audioTrack.url), String(audioTrack.contentLength),
      audioFrags.length);
    const url: string = server.publish(
      HlsManifestBuilder.masterPlaylist(video, audioTrack, videoName, audioName),
      videoFrags.length > 0
        ? HlsManifestBuilder.mediaPlaylistFrom(video, videoFrags)
        : HlsManifestBuilder.mediaPlaylist(video),
      audioFrags.length > 0
        ? HlsManifestBuilder.mediaPlaylistFrom(audioTrack, audioFrags)
        : HlsManifestBuilder.mediaPlaylist(audioTrack),
      masterName, videoName, audioName);
    const src: PlayableSource = new PlayableSource(url, Delivery.HLS, false);
    src.resolution = video.resolution;
    src.audioTrackId = audioTrack.trackId;
    return src;
  }

  /**
   * One ranged GET, returned as bytes. Rule 8: the request object is destroyed in `finally`.
   *
   * ArrayBuffer, never a string - a string decode mangles binary and the sidx is binary. Shaped
   * after DownloadManager.fetchRange(): same UA, same timeouts, same 2xx rule.
   */
  private static async rangeGet(url: string, start: number, end: number): Promise<ArrayBuffer> {
    const request: http.HttpRequest = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: {
          'User-Agent': USER_AGENT,
          'Accept': '*/*',
          'Accept-Encoding': '*',
          'Range': `bytes=${start}-${end}`
        } as Record<string, string>,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 30000,
        readTimeout: 30000
      };
      const response: http.HttpResponse = await request.request(url, options);
      if (response.responseCode < 200 || response.responseCode > 299) {
        return new ArrayBuffer(0);
      }
      return response.result instanceof ArrayBuffer
        ? response.result as ArrayBuffer : new ArrayBuffer(0);
    } finally {
      request.destroy();
    }
  }

  /**
   * The track's segment index, fetched and parsed. Returns [] on ANY failure, which sends the
   * caller back to the flat-chunk playlist rather than refusing to play: a format with no usable
   * sidx is no worse off than it was before T-0198.
   */
  private static async fetchSegmentIndex(t: MediaTrack): Promise<Fragment[]> {
    if (!HlsManifestBuilder.hasSegmentIndex(t)) {
      return [];
    }
    try {
      const buf: ArrayBuffer = await MediaSourceResolver.rangeGet(t.url, t.indexStart, t.indexEnd);
      return parseSidx(buf, t.indexStart, t.indexEnd + 1);
    } catch (err) {
      return [];
    }
  }

  private static bestMuxed(set: StreamSet, targetHeight: number): VideoTrack | null {
    let chosen: VideoTrack | null = null;
    for (const c of set.muxed) {
      if (c.isMuxed && !c.isDashDelivered && c.url.length > 0) {
        chosen = chosen === null ? c : MediaSourceResolver.preferred(chosen, c, targetHeight);
      }
    }
    return chosen;
  }

  /**
   * With no target this is the old unconditional max. With one it is the tallest track that
   * still fits under it, and - when nothing fits - the shortest one above it, so a request for
   * a quality this stream does not carry still lands on the nearest thing it does.
   */
  private static preferred(a: VideoTrack, b: VideoTrack, targetHeight: number): VideoTrack {
    if (targetHeight <= 0) {
      return b.height > a.height ? b : a;
    }
    const aFits: boolean = a.height <= targetHeight;
    const bFits: boolean = b.height <= targetHeight;
    if (aFits !== bFits) {
      return aFits ? a : b;
    }
    return aFits ? (b.height > a.height ? b : a) : (b.height < a.height ? b : a);
  }

  /**
   * Best H.264 video-only track <= ceiling (broad decode support + bounded segments). A
   * requested quality lowers that ceiling; it can never raise it past SYNTH_CEILING.
   */
  private static bestVideoOnly(set: StreamSet, targetHeight: number): VideoTrack | null {
    const ceiling: number = targetHeight > 0
      ? Math.min(targetHeight, MediaSourceResolver.SYNTH_CEILING)
      : MediaSourceResolver.SYNTH_CEILING;
    let chosen: VideoTrack | null = null;
    let fallback: VideoTrack | null = null;
    for (const c of set.videoOnly) {
      // The fallback too: it used to take the shortest track of ANY codec when no avc1 fitted
      // under the ceiling, i.e. a WebM VP9 144p into an fMP4 playlist. No avc1 at all now means
      // no synthesis, and resolve() moves on to the muxed file.
      if (!HlsManifestBuilder.hasByteRanges(c) || !HlsManifestBuilder.canCarry(c)) {
        continue;
      }
      if (c.height > 0 && c.height <= ceiling) {
        chosen = chosen === null || c.height > chosen.height ? c : chosen;
      }
      if (fallback === null || (fallback.height > c.height && c.height > 0)) {
        fallback = c;
      }
    }
    return chosen !== null ? chosen : fallback;
  }

  /**
   * The loudest audio stream, and - when the user has picked a language - the loudest one OF
   * THAT TRACK. A track that is asked for but not carried falls back to the unfiltered pick
   * rather than silencing the stream; the caller is told what was applied.
   */
  /** The one preference this resolver reads; a store that is not up yet must not break playback. */
  private static prefBool(key: string, defValue: boolean): boolean {
    try {
      return ServiceLocator.get().preferences.getBooleanSync(key, defValue);
    } catch (err) {
      return defValue;
    }
  }

  /** fmp4Only: for synthesize(), which can only carry an AAC track - see canCarry(). */
  private static bestAudio(set: StreamSet, trackId: string = '',
    fmp4Only: boolean = false): AudioTrack | null {
    // ListHelper.getAudioTrackComparator(): when prefer_original_audio is on - and it ships ON -
    // the ORIGINAL track outranks every dub whatever its language or bitrate, and only then does
    // loudness decide. The port read none of that: bestAudio() was bitrate-only, so a fresh open
    // of a multi-dub video played the loudest DUB while the control read "English original"
    // (T-0206, measured: wanted=[] applied=[ar.3]). An explicitly requested track still wins over
    // everything - that is the audio-track control, not a default.
    const preferOriginal: boolean = trackId.length === 0
      && MediaSourceResolver.prefBool(prefer_original_audio_key, true);
    // ...and the same for the audio-description track, which the source ranks straight after the
    // original (AUDIO_TRACK_TYPE_RANKING_DESCRIPTIVE). prefer_descriptive_audio was the second
    // preference on this screen that the playback path never read - T-0209, filed off T-0206's
    // own review. It ships OFF, so this changes nothing until a user asks for it.
    const preferDescriptive: boolean = trackId.length === 0
      && MediaSourceResolver.prefBool(prefer_descriptive_audio_key, false);
    let chosen: AudioTrack | null = null;
    for (const c of set.audio) {
      if (c.url.length === 0 || (trackId.length > 0 && c.trackId !== trackId)
        || (fmp4Only && !HlsManifestBuilder.canCarry(c))) {
        continue;
      }
      if (chosen === null) {
        chosen = c;
        continue;
      }
      if (preferOriginal && c.isOriginal !== chosen.isOriginal) {
        chosen = c.isOriginal ? c : chosen;
        continue;
      }
      if (preferDescriptive && c.isDescriptive !== chosen.isDescriptive) {
        chosen = c.isDescriptive ? c : chosen;
        continue;
      }
      if (c.averageBitrate > chosen.averageBitrate) {
        chosen = c;
      }
    }
    if (chosen === null && trackId.length > 0) {
      return MediaSourceResolver.bestAudio(set, '', fmp4Only);
    }
    return chosen;
  }

  /** Does the muxed set carry this exact height? Only then can bestMuxed() honour a pick. */
  static muxedHas(set: StreamSet, height: number): boolean {
    for (const c of set.muxed) {
      if (c.isMuxed && !c.isDashDelivered && c.url.length > 0 && c.height === height) {
        return true;
      }
    }
    return false;
  }

  /** Is this language actually one of the separate audio streams? */
  private static carriesTrack(set: StreamSet, trackId: string): boolean {
    for (const c of set.audio) {
      if (c.url.length > 0 && c.trackId === trackId) {
        return true;
      }
    }
    return false;
  }
}

// ---------------------------------------------------------------------------
// StreamInfo -> StreamSet. MS04/MS05 (nsig-free client selection, multi-client
// fallback) live in the extractor's client chain per contract §2.3 — nothing here
// runs client-side cryptography.
// ---------------------------------------------------------------------------

export class StreamSetAdapter {
  /**
   * Byte-range facts come from the stream's ItagItem when the service filled one in. Only
   * YouTube's ItagItem carries contentLength/approxDurationMs (the core seam does not declare
   * them), so the narrowing is nominal, and a stream without an itag falls back to the
   * googlevideo-style `clen` / `dur` query parameters below.
   */
  static contentLengthOf(itagItem: ItagItem | null, url: string): number {
    if (itagItem instanceof YoutubeItagItem) {
      const contentLength: number = itagItem.getContentLength();
      if (contentLength > 0) {
        return contentLength;
      }
    }
    return StreamSetAdapter.queryNumber(url, 'clen');
  }

  /** Duration in milliseconds from the ItagItem, then the `dur` query, then the stream's own. */
  static approxDurationMsOf(itagItem: ItagItem | null, url: string,
    fallbackDurationMs: number): number {
    if (itagItem instanceof YoutubeItagItem) {
      const approxDurationMs: number = itagItem.getApproxDurationMs();
      if (approxDurationMs > 0) {
        return approxDurationMs;
      }
    }
    const dur: number = StreamSetAdapter.queryNumber(url, 'dur');
    return dur > 0 ? dur * 1000 : fallbackDurationMs;
  }

  /** `clen` (bytes) and `dur` (seconds) as googlevideo writes them into the segment URL. */
  static queryNumber(url: string, key: string): number {
    const m: RegExpMatchArray | null = url.match(new RegExp('[?&]' + key + '=([0-9.]+)'));
    if (m === null || m.length < 2) {
      return -1;
    }
    const value: number = Number.parseFloat(m[1]);
    return Number.isNaN(value) ? -1 : value;
  }

  private static containerOf(s: Stream, fallback: string): string {
    const format: MediaFormat | null = s.getFormat();
    return format === null ? fallback : format.mimeType;
  }

  static isLive(streamType: StreamType): boolean {
    return streamType === StreamType.LIVE_STREAM || streamType === StreamType.AUDIO_LIVE_STREAM;
  }

  private static videoTrack(s: VideoStream, fallbackDurationMs: number): VideoTrack {
    const t: VideoTrack = new VideoTrack();
    t.url = s.content;
    t.itag = s.itag;
    t.isMuxed = !s.isVideoOnly;
    t.isDashDelivered = s.deliveryMethod === DeliveryMethod.DASH
      || s.deliveryMethod === DeliveryMethod.SS;
    t.resolution = s.resolution;
    t.initStart = s.initStart;
    t.initEnd = s.initEnd;
    // T-0198: these used to stop here. The sidx range is the only thing that says where
    // a fragment really begins, and the extractor had already parsed it.
    t.indexStart = s.indexStart;
    t.indexEnd = s.indexEnd;
    t.width = s.width;
    // The resolution STRING is the height this port works in - see
    // VideoDetailFragmentPage.heightOf(). A stream the itag table calls 360p can report `height`
    // 240, and the quality control hands this resolver the number the user picked, so both sides
    // have to read it from the same place or a pick lands on the wrong rendition.
    const fromResolution: RegExpMatchArray | null = s.resolution.match(/(\d+)/);
    t.height = fromResolution !== null ? Number.parseInt(fromResolution[1], 10) : s.height;
    t.bitrate = s.bitrate;
    // The stream's real container: this said video/mp4 for WebM VP9 too, which the log repeated.
    t.mimeType = StreamSetAdapter.containerOf(s, 'video/mp4') + '; codecs="' + s.codec + '"';
    t.contentLength = StreamSetAdapter.contentLengthOf(s.itagItem, t.url);
    t.approxDurationMs =
      StreamSetAdapter.approxDurationMsOf(s.itagItem, t.url, fallbackDurationMs);
    return t;
  }

  private static audioTrack(s: AudioStream, fallbackDurationMs: number): AudioTrack {
    const t: AudioTrack = new AudioTrack();
    t.url = s.content;
    t.itag = s.itag;
    t.initStart = s.initStart;
    t.initEnd = s.initEnd;
    t.indexStart = s.indexStart;
    t.indexEnd = s.indexEnd;
    t.bitrate = s.bitrate;
    t.averageBitrate = s.averageBitrate;
    const trackId: string | null = s.getAudioTrackId();
    t.trackId = trackId === null ? '' : trackId;
    t.isOriginal = s.getAudioTrackType() === AudioTrackType.ORIGINAL;
    t.isDescriptive = s.getAudioTrackType() === AudioTrackType.DESCRIPTIVE;
    t.mimeType = StreamSetAdapter.containerOf(s, 'audio/mp4') + '; codecs="' + s.codec + '"';
    t.contentLength = StreamSetAdapter.contentLengthOf(s.itagItem, t.url);
    t.approxDurationMs =
      StreamSetAdapter.approxDurationMsOf(s.itagItem, t.url, fallbackDurationMs);
    return t;
  }

  /** Port of the resolvers' stream selection, minus every DASH/SS/torrent branch. */
  static fromStreamInfo(info: StreamInfo): StreamSet {
    const set: StreamSet = new StreamSet();
    set.isLive = StreamSetAdapter.isLive(info.streamType);
    set.hlsUrl = info.hlsUrl;
    const durationMs: number = info.duration > 0 ? info.duration * 1000 : 0;

    for (const v of info.videoStreams) {
      if (v.isUrl && v.content.length > 0) {
        set.muxed.push(StreamSetAdapter.videoTrack(v, durationMs));
      }
    }
    for (const v of info.videoOnlyStreams) {
      if (v.isUrl && v.content.length > 0) {
        set.videoOnly.push(StreamSetAdapter.videoTrack(v, durationMs));
      }
    }
    for (const a of info.audioStreams) {
      if (a.isUrl && a.content.length > 0
        && a.deliveryMethod !== DeliveryMethod.DASH && a.deliveryMethod !== DeliveryMethod.SS) {
        set.audio.push(StreamSetAdapter.audioTrack(a, durationMs));
      }
    }
    return set;
  }
}

// ---------------------------------------------------------------------------
// Player state, exposed as Rx streams (contract §1: repeated emissions are Observables).
// ---------------------------------------------------------------------------

export enum PlayerStatus {
  IDLE = 'idle',
  BUFFERING = 'buffering',
  PLAYING = 'playing',
  PAUSED = 'paused',
  COMPLETED = 'completed',
  ERROR = 'error'
}

/**
 * Player.RepeatMode: the three states cycleNextRepeatMode() walks, in its order. The player owns
 * this, not a page - both the detail screen and the queue screen show the SAME mode, and it has
 * to survive either of them being rebuilt.
 */
export enum RepeatMode {
  OFF = 0,
  ONE = 1,
  ALL = 2
}


export class PlayerPosition {
  positionMs: number;
  durationMs: number;

  constructor(positionMs: number, durationMs: number) {
    this.positionMs = positionMs;
    this.durationMs = durationMs;
  }
}

/** What actually happened when playback was requested — never a silent failure. */
export class PlaybackReport {
  source: PlayableSource | null;
  /** '' on success; otherwise the user-facing reason the stream could not be played. */
  failureReason: string;

  constructor(source: PlayableSource | null, failureReason: string) {
    this.source = source;
    this.failureReason = failureReason;
  }
}

/** AVPlayer.setPlaybackRate's documented range: 0.125 ~ 4, with 5400108 outside it. */
export const MIN_PLAYBACK_RATE: number = 0.125;
export const MAX_PLAYBACK_RATE: number = 4.0;

/**
 * Keep a requested rate inside what the platform accepts. Clamping rather than throwing is
 * deliberate: the dialog's slider must never be able to stop playback, and 0.1x - which the
 * source offers and this platform's floor of 0.125 forbids - should play at 0.125 rather than
 * fail.
 *
 * It is also not optional. Measured on the handset, setPlaybackRate below 0.125 does NOT throw
 * 5400108 as the doc implies: it returns normally, fires no 'playbackRateDone', and the rate
 * never changes (docs/qa/evidence/fix-T-0133b/rate-probe.txt). Without the clamp the readout
 * would report a rate that is not playing - the exact bug T-0133 is about.
 */
export function clampPlaybackRate(rate: number): number {
  // NaN is not a slow rate, it is no rate at all - a slider mid-drag or a parse that failed. It
  // falls back to real time; everything else, zero and negatives included, clamps into range.
  if (Number.isNaN(rate)) {
    return 1;
  }
  if (rate < MIN_PLAYBACK_RATE) {
    return MIN_PLAYBACK_RATE;
  }
  return rate > MAX_PLAYBACK_RATE ? MAX_PLAYBACK_RATE : rate;
}

/** Popup-player outcome: real PiP, or the in-app mini player. Never "nothing happened". */
export enum PipOutcome {
  PIP = 'pip',
  FALLBACK_MINI_PLAYER = 'fallback-mini-player'
}

/**
 * What the popup's Previous / Next walk: the queue of the screen that owns the playback, the same
 * handler its AVSession uses. A popup started from a list has none.
 */
export interface QueueNavigator {
  playNext(): void;
  playPrevious(): void;
}

export class PlayerService {

  /**
   * The audio LANGUAGE the viewer last picked by hand - `de` out of `de.3`, '' until they do.
   *
   * It lives on the player and not on the detail page because opening another video builds a NEW
   * page: a field there dies at the stream boundary, which is exactly the T-0211 symptom. The
   * player is the one thing that spans streams, the same place the reference keeps its own track
   * selection.
   */
  private lastPickedAudioLanguage: string = '';

  rememberPickedAudioLanguage(language: string): void {
    this.lastPickedAudioLanguage = language;
  }

  pickedAudioLanguage(): string {
    return this.lastPickedAudioLanguage;
  }

  private static instance: PlayerService | null = null;

  private player: media.AVPlayer | null = null;
  private pipController: PiPWindow.PiPController | null = null;

  /**
   * onRepeatModeChanged(): the mode every repeat control reads and writes. It was a bare @State on
   * each page, so the cycle moved a glyph and nothing else - the player never heard about it and a
   * finished stream just stopped.
   */
  private repeatModeValue: RepeatMode = RepeatMode.OFF;
  readonly repeatMode: BehaviorSubject<RepeatMode> =
    new BehaviorSubject<RepeatMode>(RepeatMode.OFF);

  getRepeatMode(): RepeatMode {
    return this.repeatModeValue;
  }

  /** player.cycleNextRepeatMode(): off -> one -> all -> off. */
  cycleNextRepeatMode(): RepeatMode {
    const next: RepeatMode = this.repeatModeValue === RepeatMode.OFF
      ? RepeatMode.ONE
      : (this.repeatModeValue === RepeatMode.ONE ? RepeatMode.ALL : RepeatMode.OFF);
    this.setRepeatMode(next);
    return next;
  }

  setRepeatMode(mode: RepeatMode): void {
    this.repeatModeValue = mode;
    this.repeatMode.onNext(mode);
  }
  private currentSource: PlayableSource | null = null;
  /** Retries spent on the CURRENT stall; reset whenever playback reports progress again. */
  private networkRetries: number = 0;
  /** The last position the player reported, so a stall can re-open where it stopped. */
  private lastKnownPositionMs: number = 0;
  /** The last real duration, so a reset mid-stall cannot blank it. See rememberDuration(). */
  private lastKnownDurationMs: number = 0;
  private playWhenReady: boolean = false;
  private pendingSeekMs: number = -1;
  /**
   * XComponent(SURFACE) id the video renders into. It is REQUIRED in the `initialized` state,
   * and the SDK also accepts it again while prepared/playing/paused/completed/stopped, in which
   * case "the video is played in the new window" (@ohos.multimedia.media AVPlayer.surfaceId).
   * Audio-only playback needs none, so it is stored here and applied in onStateChange.
   */
  private surfaceId: string = '';
  private speedRate: number = 1.0;
  /**
   * retrievePlaybackParametersFromPrefs(): the speed a session ends on is where the next one
   * starts. Read lazily - the preference store opens after this singleton can first be touched.
   */
  private speedRestored: boolean = false;
  /** last_resize_mode, as AVPlayer's videoScaleType; re-applied on every 'prepared'. */
  private resizeMode: number = -1;
  /** The system paused us for another app's audio; RESUME may restart only such a pause. */
  private pausedByInterrupt: boolean = false;
  /**
   * isLiveEdge() for a live source: false once the viewer paused or the stream stalled, which is
   * when playbackLiveSync becomes a button. A fresh live prepare is at the edge again.
   */
  readonly behindLiveEdge: BehaviorSubject<boolean> = new BehaviorSubject<boolean>(false);
  /** AVPlayer has no mute of its own; 0 IS mute. Re-applied on every 'prepared'. */
  private volumeLevel: number = 1.0;
  /** The height the quality menu last asked for; 0 = "best available". */
  private currentTargetHeight: number = 0;
  /**
   * The audio track the CURRENT source carries, '' for "whatever the stream defaults to". The
   * control reads this back after a switch, so it shows the language that is playing rather than
   * the one that was asked for.
   */
  private currentAudioTrackId: string = '';

  readonly state: BehaviorSubject<PlayerStatus> =
    new BehaviorSubject<PlayerStatus>(PlayerStatus.IDLE);
  readonly position: BehaviorSubject<PlayerPosition> =
    new BehaviorSubject<PlayerPosition>(new PlayerPosition(0, 0));
  /** The rate AVPlayer is really playing at, as 'playbackRateDone' reports it (T-0133b). */
  readonly appliedSpeed: BehaviorSubject<number> = new BehaviorSubject<number>(1.0);
  /** Last playback failure, surfaced to the UI. Never swallowed. */
  readonly lastError: BehaviorSubject<string> = new BehaviorSubject<string>('');
  /**
   * Where the buffered range ends, in ms of the stream - Player.onUpdateProgress()'s
   * bufferPercent, which fills playbackSeekBar's secondary progress. 0 until the first report.
   */
  readonly bufferedMs: BehaviorSubject<number> = new BehaviorSubject<number>(0);
  /**
   * The stream the player is on. `state` says whether something is playing; this says what, which
   * is what anything outside the player screen needs in order to show it — the mini player bar in
   * MainActivityPage, and the tap that reopens the full player for it.
   */
  readonly currentInfo: BehaviorSubject<StreamInfo | null> =
    new BehaviorSubject<StreamInfo | null>(null);

  static getInstance(): PlayerService {
    if (PlayerService.instance === null) {
      PlayerService.instance = new PlayerService();
    }
    return PlayerService.instance;
  }

  /**
   * Player.exoPlayerIsNull() — is there an actual player behind this service yet?
   * PlayQueueActivity.onServiceConnected() (PlayQueueActivity.java:228) unbinds instead of
   * observing when it is null, which is what leaves that screen's controls at their layout
   * defaults; a screen that observes unconditionally gets the idle seed instead.
   */
  hasPlayer(): boolean {
    return this.player !== null;
  }

  /**
   * Called by the video page as soon as its XComponent surface exists - and it exists MORE THAN
   * ONCE. Entering fullscreen moves the player between two branches of the page's if/else, so
   * ArkUI tears the XComponent down and builds a new one: the old surface is destroyed and a new
   * id arrives. Storing it and nothing else left AVPlayer rendering into the destroyed surface,
   * which is the whole of "the video cannot be played in full screen mode" - the position kept
   * advancing and the audio kept running while the picture stayed black. Re-setting surfaceId on
   * the live player is the SDK's own documented way to move playback to the new window.
   */
  setSurfaceId(surfaceId: string): void {
    if (this.surfaceId === surfaceId) {
      return;
    }
    this.surfaceId = surfaceId;
    const player: media.AVPlayer | null = this.player;
    if (player === null || surfaceId.length === 0 || this.currentSourceIsAudioOnly()) {
      return;
    }
    // The states the SDK names for a re-set. `initialized` is the FIRST set and is done in
    // onStateChange, where prepare() follows it; setting it twice there would be wasted.
    const state: media.AVPlayerState = player.state;
    if (state === 'prepared' || state === 'playing' || state === 'paused'
      || state === 'completed' || state === 'stopped') {
      try {
        player.surfaceId = surfaceId;
      } catch (err) {
        const failure: BusinessError = err as BusinessError;
        console.warn(TAG + ': surface rebind failed: ' + failure.message);
      }
    }
  }

  /**
   * The page that owned `surfaceId` tore its XComponent down - collapsing the detail page into
   * the mini player pops it. Forgetting the id keeps playback going without a picture: a later
   * re-prepare (a network-stall retry, the next queue item) used to hand AVPlayer the DEAD id,
   * which fails with 401 "SurfaceUtils cannot convert ID to Surface" and stops the stream the
   * viewer had just sent to the background. A newer surface that already replaced it is kept.
   */
  clearSurfaceId(surfaceId: string): void {
    if (this.surfaceId === surfaceId) {
      this.surfaceId = '';
    }
  }

  getSource(): PlayableSource | null {
    return this.currentSource;
  }

  /** The height the current source was asked for (0 = best) - the popup's own resolution there. */
  getTargetHeight(): number {
    return this.currentTargetHeight;
  }

  /** The audio track actually playing, '' when it is the stream's default (original) one. */
  getAudioTrackId(): string {
    return this.currentAudioTrackId;
  }

  /**
   * endpoint media_stream_playback_fetch — resolve one StreamInfo to a playable URL and
   * hand it to AVPlayer. Resolution failures are REPORTED, never swallowed (contract §2.5).
   */
  async prepare(info: StreamInfo, audioOnly: boolean,
    targetHeight: number = 0, audioTrackId: string = '',
    force: boolean = false, startAtMs: number = -1): Promise<PlaybackReport> {
    if (!this.speedRestored) {
      this.speedRestored = true;
      this.speedRate = PlayerPrefs.playbackSpeed(this.speedRate);
    }
    if (this.resizeMode < 0) {
      this.resizeMode = PlayerPrefs.resizeMode();
    }
    const set: StreamSet = StreamSetAdapter.fromStreamInfo(info);
    const server: LocalHlsServer = LocalHlsServer.getInstance();
    // The synthesis branch is also the ONLY way to play a chosen audio language - a muxed file
    // carries the original soundtrack and nothing else - so a requested track needs the loopback
    // server just as much as a stream with no muxed rendition does. Without this the server was
    // never started, synthesize() returned null at its first line, and the picked language fell
    // straight back to the muxed original: the label moved and the audio did not.
    // The hlsUrl exclusion belongs to the no-muxed case only: YouTube hands out a manifest for
    // an ordinary video too, and AVPlayer cannot pick a rendition out of one, so a requested
    // language still has to be synthesised.
    const wantsAudioTrack: boolean = audioTrackId.length > 0 && !audioOnly;
    // A height the user picked that the muxed set cannot give needs the loopback server too -
    // the synthesis branch is the only way to play it. Without this the resolver asked for a
    // video-only rendition, found the server down, and fell back to the nearest muxed one, so
    // picking "MPEG-4 144p" played 320x240 and the control said 144p.
    const wantsOtherHeight: boolean = targetHeight > 0 && !audioOnly
      && !MediaSourceResolver.muxedHas(set, targetHeight);
    const needsLoopback: boolean = set.videoOnly.length > 0
      && (wantsAudioTrack || wantsOtherHeight
        || (set.muxed.length === 0 && set.hlsUrl.length === 0));
    if (needsLoopback) {
      // Only the synthesis branch needs the loopback server, so start it lazily.
      try {
        await server.start();
      } catch (e) {
        console.error(TAG + ': loopback server failed to start: ' + describeError(e));
      }
    }

    const source: PlayableSource | null =
      await MediaSourceResolver.resolve(set, server, audioOnly, targetHeight, audioTrackId);
    hilog.info(0x0000, TAG, 'resolved target=%{public}d audioOnly=%{public}s -> '
      + 'delivery=%{public}s res=%{public}s live=%{public}s host=%{public}s (muxed=%{public}d '
      + 'videoOnly=%{public}d audio=%{public}d hls=%{public}s)', targetHeight, String(audioOnly),
      source === null ? 'none' : source.delivery, source === null ? '' : source.resolution,
      String(set.isLive), source === null ? '' : hostOf(source.url), set.muxed.length,
      set.videoOnly.length, set.audio.length, String(set.hlsUrl.length > 0));
    if (source === null) {
      const reason: string = 'No AVPlayer-playable stream for "' + info.getName()
        + '" (DASH-only or ciphered response). Try another quality or service.';
      this.fail(reason);
      return new PlaybackReport(null, reason);
    }
    if (source.url.startsWith('file://') || source.url.indexOf('.mpd') !== -1) {
      // Defensive: AVPlayer rejects both (MS01 / MS02). Reaching here is a resolver bug.
      const reason: string = 'Unsupported source for AVPlayer: ' + source.url;
      this.fail(reason);
      return new PlaybackReport(null, reason);
    }

    // Switching an already playing stream to background resolves to the SAME url - for a live
    // stream AudioPlaybackResolver returns the service HLS manifest either way - and re-preparing
    // it fails: the device answers `5411006 IO Request Denied: NET_ERR-server-IO` and the player
    // never reaches 'prepared'. Starting the same stream in background from a cold player works,
    // and so does re-creating the AVPlayer instance first, which rules out the instance and the
    // audio-only path and leaves the url itself: these manifests are single-use, and the second
    // request for one is refused.
    //
    // Nothing needs re-preparing anyway. The stream is already playing; background is about where
    // the audio keeps running, which is the session and the continuous task the caller starts
    // next, not a new pipeline. The one thing skipped is audioRendererInfo moving from MOVIE to
    // MUSIC, which is only settable in 'initialized' - a routing hint, not the feature.
    //
    // The guard is keyed on the STREAM, not on the resolved media url: audioOnly resolves
    // bestAudio's url, which is a different string for the same stream, so a url-keyed guard
    // never fired on the one path it was written for and Background restarted the video at 0:00.
    const player: media.AVPlayer | null = this.player;
    const alive: boolean = player !== null && (player.state === 'playing'
      || player.state === 'paused' || player.state === 'prepared');
    const playing: StreamInfo | null = this.currentInfo.getValue();
    const sameStream: boolean =
      alive && playing !== null && playing.getUrl() === info.getUrl();
    // A live stream is resolved to the service HLS manifest and to nothing else: the resolver
    // above ignores targetHeight for it and hands back resolution 'auto', so a "quality switch"
    // on a live stream has nothing to switch TO - while re-sourcing it means asking for that
    // manifest a SECOND time, which is the request the device refuses with 5411006. The quality
    // menu is built from info.videoStreams without a live check, so every row on a live stream
    // took a playing broadcast through a failed prepare and left a black surface behind. The
    // stream guard therefore covers a live source whatever height is asked for.
    // `force` is the live-sync button: a FRESH manifest for the same broadcast, which is the one
    // re-source of a live stream that is not refused.
    if (!force && sameStream && (source.isLive || (targetHeight === this.currentTargetHeight
      && source.audioTrackId === this.currentAudioTrackId))) {
      this.currentInfo.onNext(info);
      this.lastError.onNext('');
      return new PlaybackReport(this.currentSource, '');
    }

    try {
      // A re-source of the stream ALREADY on screen is a quality switch, and it resumes where
      // the viewer is - setSource() resets the player, so without this it would start at 0:00.
      // A caller may name the start itself - a tapped timestamp, or the saved resume position -
      // which a quality switch of the playing stream never does.
      const startAt: number = sameStream && player !== null ? player.currentTime
        : (startAtMs >= 0 ? startAtMs : info.startPosition * 1000);
      if (!sameStream) {
        // A different stream: forget the remembered duration, or the new one would inherit it
        // until its own durationUpdate lands. A quality switch and a stall retry keep theirs.
        this.lastKnownDurationMs = 0;
      }
      this.currentSource = source;
      // T-0132: reset() drops the player's speed, so a new source starts at real time. Without
      // this a live stream opened after a 0.1x track kept claiming 0.1x.
      //
      // appliedSpeed goes with it, and not only to keep the two in step: MediaSessionService reads
      // appliedSpeed for the system controls, and for a live source no rate event ever fires, so
      // without this the session kept publishing 0.125 for a stream running at 1.0. It also
      // refreshes the chip, whose label follows this subscription rather than displayRate().
      this.reportedRate = 1.0;
      this.appliedSpeed.onNext(1.0);
      this.currentTargetHeight = targetHeight;
      this.currentAudioTrackId = source.audioTrackId;
      this.pausedByInterrupt = false;
      await this.setSource(source, startAt);
      this.behindLiveEdge.onNext(false);
      this.currentInfo.onNext(info);
      this.lastError.onNext('');
      if (!sameStream) {
        PlayerService.registerStreamViewed(info);
      }
      return new PlaybackReport(source, '');
    } catch (e) {
      const reason: string = 'Playback could not start: ' + describeError(e);
      this.fail(reason);
      return new PlaybackReport(null, reason);
    }
  }

  /**
   * Player.seekToDefault() on a live stream, which AVPlayer cannot seek: a FRESH StreamInfo carries
   * a fresh manifest that starts at the live edge, and only a forced re-source may take the same
   * broadcast again (the old manifest cannot be requested twice - see prepare()).
   */
  async syncToLiveEdge(): Promise<void> {
    const info: StreamInfo | null = this.currentInfo.getValue();
    const source: PlayableSource | null = this.currentSource;
    if (info === null || source === null || !source.isLive) {
      return;
    }
    this.behindLiveEdge.onNext(false);
    try {
      const fresh: StreamInfo =
        await ExtractorHelper.getStreamInfo(info.getServiceId(), info.getUrl(), true);
      await this.prepare(fresh, source.audioOnly, 0, this.currentAudioTrackId, true);
    } catch (e) {
      console.warn(TAG + ': live edge not reached: ' + describeError(e));
      this.behindLiveEdge.onNext(true);
    }
  }

  /**
   * Player.registerStreamViewed(): EVERY start of a new stream is a view - the detail page's,
   * a list's background or popup start, a queue row. Only the detail page used to write it, so a
   * stream played from anywhere else never reached the history.
   */
  private static registerStreamViewed(info: StreamInfo): void {
    let context: common.Context;
    try {
      context = ServiceLocator.get().getContext();
    } catch (e) {
      return;
    }
    HistoryRecordManager.of(context)
      .then((history: HistoryRecordManager): Promise<number | null> => history.onViewed(info))
      .catch((e: BusinessError): void => {
        console.warn(TAG + ': onViewed failed: ' + describeError(e));
      });
  }

  /**
   * Player.saveStreamProgressState(): the resume position is written when playback pauses, seeks
   * or is released - not only when the detail page goes away, so a pause followed by the app
   * being killed still resumes there - and only while watch history is on. A live stream has no
   * position worth keeping.
   */
  private saveStreamProgressState(): void {
    const info: StreamInfo | null = this.currentInfo.getValue();
    const source: PlayableSource | null = this.currentSource;
    const player: media.AVPlayer | null = this.player;
    if (info === null || source === null || source.isLive || player === null) {
      return;
    }
    const position: number = player.currentTime;
    if (position <= 0) {
      return;
    }
    let context: common.Context;
    try {
      if (!ServiceLocator.get().preferences.getBooleanSync(enable_watch_history_key, true)) {
        return;
      }
      context = ServiceLocator.get().getContext();
    } catch (e) {
      return;
    }
    HistoryRecordManager.of(context)
      .then((history: HistoryRecordManager): Promise<void> => history.saveStreamState(info, position))
      .catch((e: BusinessError): void => {
        console.warn(TAG + ': saveStreamState failed: ' + describeError(e));
      });
  }

  private fail(reason: string): void {
    console.error(TAG + ': ' + reason);
    this.lastError.onNext(reason);
    this.state.onNext(PlayerStatus.ERROR);
  }

  private appStateWatched: boolean = false;

  /**
   * MainPlayerUi.onFragmentStopped(): what leaving the app does to a playing video. Background is
   * what already happens here (the audio carries on); "None" pauses it; Popup is a PiP window the
   * detail page armed beforehand (armAutoPip), which the system opens on its own.
   */
  private watchAppState(): void {
    if (this.appStateWatched) {
      return;
    }
    try {
      const callback: ApplicationStateChangeCallback = {
        onApplicationForeground: (): void => {
        },
        onApplicationBackground: (): void => {
          this.onAppBackground();
        }
      };
      ServiceLocator.get().getContext().getApplicationContext()
        .on('applicationStateChange', callback);
      this.appStateWatched = true;
    } catch (e) {
      console.warn(TAG + ': application state not watched: ' + describeError(e));
    }
  }

  private onAppBackground(): void {
    const player: media.AVPlayer | null = this.player;
    if (player === null || this.currentSourceIsAudioOnly() || this.pipController !== null
      || this.armedPip !== null) {
      return;
    }
    const busy: boolean = player.state === 'playing' || this.playWhenReady;
    if (busy && PlayerPrefs.minimizeOnExitAction() === MinimizeMode.NONE) {
      this.pause();
    }
  }

  /** MS12: reset() between sources; one AVPlayer instance is created and reused. */
  private async setSource(source: PlayableSource, startAtMs: number): Promise<void> {
    this.watchAppState();
    let player: media.AVPlayer | null = this.player;
    if (player === null) {
      // Store on the field BEFORE attach(): if attach() throws, the instance is still
      // reachable from `this.player` and release() will clean it up — never leaked
      // (CLAUDE.md rule 8). Re-reading into the local keeps the non-null narrowing that
      // property access loses across a method call.
      this.player = await media.createAVPlayer();
      player = this.player;
      this.attach(player);
    } else {
      await player.reset();
    }
    this.pendingSeekMs = startAtMs > 0 ? startAtMs : -1;
    this.playWhenReady = true;
    this.bufferedMs.onNext(0);
    this.state.onNext(PlayerStatus.BUFFERING);
    // Assigning `url` moves the player idle -> initialized, which fires 'stateChange'.
    player.url = source.url;
  }

  private attach(player: media.AVPlayer): void {
    // T-0133b: the one authoritative "the rate really changed" signal. It carries the real
    // number now, so there is nothing to map back and nothing to remember - the requested and
    // the applied rate are the same value.
    player.on('playbackRateDone', (rate: number): void => {
      this.reportedRate = rate;
      this.appliedSpeed.onNext(rate);
    });
    player.on('stateChange',
      (state: media.AVPlayerState, reason: media.StateChangeReason): void => {
        this.onStateChange(player, state, reason);
      });
    player.on('timeUpdate', (time: number): void => {
      // Real progress means the stall is over: give the next one its full budget back, and
      // remember where we are so a retry can resume rather than restart. `time > 0` is the whole
      // guard - a re-opened source reports 0 before it has actually played anything, and treating
      // that as progress would refund the budget on every retry and spin forever.
      if (time > 0) {
        this.lastKnownPositionMs = time;
        this.networkRetries = 0;
      }
      this.position.onNext(new PlayerPosition(time, this.rememberDuration(player.duration)));
    });
    // onPositionDiscontinuity(DISCONTINUITY_REASON_SEEK) -> saveStreamProgressState()
    player.on('seekDone', (): void => {
      this.saveStreamProgressState();
    });
    player.on('durationUpdate', (duration: number): void => {
      this.position.onNext(new PlayerPosition(player.currentTime, this.rememberDuration(duration)));
    });
    // AudioReactor.onAudioFocusChange(): the system pauses (or ducks) us for another app's audio
    // on its own; what is left to the app is the GAIN - resume only when the viewer asked for it
    // (resume_on_audio_focus_gain) and only a pause the interruption itself caused.
    player.on('audioInterrupt', (event: audio.InterruptEvent): void => {
      this.onAudioInterrupt(event);
    });
    // ACTION_AUDIO_BECOMING_NOISY: HarmonyOS leaves the headphone-unplug pause to the app, so the
    // stream moved to the speaker and kept playing.
    player.on('audioOutputDeviceChangeWithInfo', (info: audio.AudioStreamDeviceChangeInfo): void => {
      if (info.changeReason === audio.AudioStreamDeviceChangeReason.REASON_OLD_DEVICE_UNAVAILABLE) {
        this.pause();
      }
    });
    // Without this the spinner the player screen already renders for PlayerStatus.BUFFERING
    // could only ever be shown by setSource(); a mid-playback rebuffer never reached the UI.
    player.on('bufferingUpdate', (infoType: media.BufferingInfoType, value: number): void => {
      if (infoType === media.BufferingInfoType.BUFFERING_START) {
        this.state.onNext(PlayerStatus.BUFFERING);
      } else if (infoType === media.BufferingInfoType.BUFFERING_END) {
        this.state.onNext(player.state === 'playing'
          ? PlayerStatus.PLAYING : PlayerStatus.PAUSED);
      } else if (infoType === media.BufferingInfoType.CACHED_DURATION) {
        // "已缓冲数据预估可播放时长 ... 可参考该事件做进度条": the playable ms AHEAD of the
        // position, reported on every >500ms change. currentTime is -1 with no valid position.
        const at: number = player.currentTime > 0 ? player.currentTime : 0;
        this.bufferedMs.onNext(at + value);
      }
      // BUFFERING_PERCENT is how far the CURRENT stall has got (0..100), not a position: the
      // spinner PlayerStatus.BUFFERING drives is the whole of what Android shows for it.
    });
    player.on('error', (err: BusinessError): void => {
      // The raw platform string reached the screen verbatim - "Player error 5411001: IO Cannot
      // Find Host: NET_ERR-server-IO error, IO can not find host" is what a viewer saw when the
      // connection dropped. The reference says "Could not find the server", and this port already
      // carried that string and three of its neighbours unused. The code stays in the log, where
      // it is useful, and off the screen, where it is not.
      console.warn(TAG + ': player error ' + err.code + ': ' + err.message);
      if (this.fallBackFromSynthesis(err)) {
        return;
      }
      // TC-PLAYER-205: a connection lost MID-PLAYBACK is a STALL on the reference - ExoPlayer
      // goes to STATE_BUFFERING and the spinner comes up - but AVPlayer reports it here, on the
      // error channel, as a fatal 5411xxx. Taking it at face value tore the player down and the
      // duration went with it, so a 10-hour video read "00:00" behind a play triangle: the case's
      // "the loading indicator is not displayed".
      //
      // So a network error raised while something was already playing is treated as a stall
      // first: the spinner goes up, the position and duration are left alone, and the source is
      // re-opened where it stopped. Only when the retries are spent does it fall through to the
      // error panel that was always there - a viewer who really is offline still gets told.
      //
      // Once a stall IS under way it owns every error until its budget runs out. Re-opening the
      // source occasionally raises `401 SurfaceUtils cannot convert ID to Surface` in passing -
      // the surface is re-registered a moment later and the next try is fine - and reporting that
      // one put an error panel over a retry that then succeeded.
      const stalling: boolean = this.networkRetries > 0;
      if ((stalling || PlayerService.isNetworkError(err)) && this.canRetryAfterNetworkError()) {
        this.retryAfterNetworkError();
        return;
      }
      this.networkRetries = 0;
      this.fail(PlayerService.describePlayerError(err));
    });
  }

  /**
   * The 5411xxx family is AVPlayer's "the network did something" range; the reason is spelled
   * into the message rather than into a documented code, which is why the message is what is
   * matched here, exactly as describePlayerError() already does.
   */
  private static isNetworkError(err: BusinessError): boolean {
    const text: string = (err.message === undefined || err.message === null ? '' : err.message)
      .toLowerCase();
    return text.indexOf('net_err') !== -1 || text.indexOf('find host') !== -1
      || text.indexOf('unknown host') !== -1 || text.indexOf('timeout') !== -1
      || text.indexOf('time out') !== -1 || text.indexOf('connect') !== -1;
  }

  /** The loopback playlist synthesize() built, as opposed to anything the service handed out. */
  private static isSynthesized(source: PlayableSource): boolean {
    return source.url.startsWith('http://127.0.0.1:');
  }

  /**
   * ExoPlayer moves on to the next source when one cannot be read; AVPlayer just stops, and the
   * page was left behind an error panel. The synthesized playlist is this port's own construction,
   * so when AVPlayer refuses it (5400103 DEM_PARSE_ERR, 5400106) the same stream is resolved ONCE
   * more with no height and no track asked for - the muxed progressive file, else the service
   * HLS - and resumed where it stood. That is the runtime fallback T-0205's ponytail note asked
   * for. A source that is not synthesized never comes here, so this cannot loop.
   */
  private fallBackFromSynthesis(err: BusinessError): boolean {
    const source: PlayableSource | null = this.currentSource;
    const info: StreamInfo | null = this.currentInfo.getValue();
    if (source === null || info === null || !PlayerService.isSynthesized(source)
      || (err.code !== AVERR_IO && err.code !== AVERR_UNSUPPORT_FORMAT)
      || PlayerService.isNetworkError(err)) {
      return false;
    }
    const player: media.AVPlayer | null = this.player;
    const resumeAt: number = player !== null && player.currentTime > 0
      ? player.currentTime : (this.pendingSeekMs > 0 ? this.pendingSeekMs : 0);
    this.networkRetries = 0;
    this.state.onNext(PlayerStatus.BUFFERING);
    MediaSourceResolver.resolve(StreamSetAdapter.fromStreamInfo(info), LocalHlsServer.getInstance(),
      false)
      .then((fallback: PlayableSource | null): Promise<void> => {
        if (this.currentSource !== source) {
          // The viewer started something else meanwhile; that owns the player now.
          return Promise.resolve();
        }
        if (fallback === null || PlayerService.isSynthesized(fallback)) {
          this.fail(PlayerService.describePlayerError(err));
          return Promise.resolve();
        }
        hilog.warn(0x0000, TAG, 'synthesized %{public}s refused (%{public}d); falling back to '
          + '%{public}s %{public}s host=%{public}s at %{public}d ms', source.resolution, err.code,
          fallback.delivery, fallback.resolution, hostOf(fallback.url), resumeAt);
        this.currentSource = fallback;
        this.currentAudioTrackId = fallback.audioTrackId;
        this.lastError.onNext('');
        return this.setSource(fallback, resumeAt);
      })
      .catch((e: BusinessError): void => {
        this.fail('Playback could not start: ' + describeError(e));
      });
    return true;
  }

  /**
   * Only a stream that was ALREADY PLAYING can stall: a source that never opened has nothing to
   * go back to, and pretending it is buffering would spin forever on a genuinely bad url.
   */
  private canRetryAfterNetworkError(): boolean {
    return this.currentSource !== null && this.networkRetries < NETWORK_RETRY_LIMIT;
  }

  /**
   * A stall that recovers must clear the error panel the PREVIOUS stall may have left up; a stall
   * that is still running must not have one. Both are the same one line, so it lives here.
   */
  private clearStallError(): void {
    this.lastError.onNext('');
  }

  /**
   * reset() during a stall makes AVPlayer report duration 0, and the player screen drew that as
   * `00:00` with the thumb at the far right - a 10-hour video suddenly looking like a live stream
   * (TC-PLAYER-205). A duration only ever becomes known, so a 0 is treated as "not reported yet"
   * rather than as a new value. A genuinely live stream reports 0 from the start and keeps it.
   */
  private rememberDuration(reported: number): number {
    if (reported > 0) {
      this.lastKnownDurationMs = reported;
    }
    return this.lastKnownDurationMs;
  }

  /** Hold the position, show the spinner, and re-open the same source where it stopped. */
  private retryAfterNetworkError(): void {
    this.networkRetries = this.networkRetries + 1;
    const source: PlayableSource | null = this.currentSource;
    if (source === null) {
      return;
    }
    const resumeAt: number = this.lastKnownPositionMs;
    console.info(TAG + ': network stall, retry ' + this.networkRetries + '/'
      + NETWORK_RETRY_LIMIT + ' at ' + resumeAt + 'ms');
    this.clearStallError();
    this.state.onNext(PlayerStatus.BUFFERING);
    setTimeout((): void => {
      // A retry that is no longer wanted - the user closed the player, or started something else
      // - must not resurrect it.
      if (this.currentSource !== source) {
        return;
      }
      this.setSource(source, resumeAt).catch((e: BusinessError): void => {
        console.warn(TAG + ': network stall retry failed: ' + e.message);
      });
    }, NETWORK_RETRY_DELAY_MS);
  }

  /**
   * ErrorInfo's job, for the player's own failures: the app's wording for the ones a viewer can
   * act on. AVPlayer reports network trouble in the 5411xxx range with the reason spelled into
   * the message, so the message is what is matched - the codes are not documented one by one.
   * Anything that is not recognisably a network failure keeps its raw text: inventing a friendly
   * sentence for an unknown fault hides it.
   */
  private static describePlayerError(err: BusinessError): string {
    const raw: string = err.message === undefined || err.message === null ? '' : err.message;
    const text: string = raw.toLowerCase();
    if (text.indexOf('find host') !== -1 || text.indexOf('unknown host') !== -1) {
      return Localization.getString('error_unknown_host');
    }
    if (text.indexOf('timeout') !== -1 || text.indexOf('time out') !== -1) {
      return Localization.getString('error_timeout');
    }
    if (text.indexOf('ssl') !== -1 || text.indexOf('certificate') !== -1) {
      return Localization.getString('error_ssl_exception');
    }
    if (text.indexOf('net_err') !== -1 || text.indexOf('connect') !== -1) {
      return Localization.getString('error_connect_host');
    }
    return 'Player error ' + err.code + ': ' + raw;
  }

  private onStateChange(player: media.AVPlayer, state: media.AVPlayerState,
    reason: media.StateChangeReason): void {
    console.info(TAG + ': stateChange=' + state + ' reason=' + reason);
    if (state === 'initialized') {
      // MS10: audioRendererInfo is only settable here, before prepare().
      const rendererInfo: audio.AudioRendererInfo = {
        usage: this.currentSourceIsAudioOnly()
          ? audio.StreamUsage.STREAM_USAGE_MUSIC : audio.StreamUsage.STREAM_USAGE_MOVIE,
        rendererFlags: 0
      };
      player.audioRendererInfo = rendererInfo;
      // Without this AVPlayer has no render target: audio plays, video never appears.
      if (!this.currentSourceIsAudioOnly() && this.surfaceId.length > 0) {
        player.surfaceId = this.surfaceId;
      }
      player.prepare().catch((err: BusinessError): void => {
        // prepare() rejects for two reasons that are not the viewer's business (TC-PLAYER-205):
        // the player went to 'error', in which case the 'error' callback has already fired with
        // the REAL fault - for a dropped connection, a stall being retried; or a retry overlapped
        // the one before it ("current state is not stopped or initialized"). Both put a raw
        // platform sentence on screen over the top of a retry that then succeeded.
        if (player.state === 'error' || this.networkRetries > 0) {
          console.warn(TAG + ': prepare() rejected, the stall owns it: ' + err.message);
          return;
        }
        this.fail('prepare() failed: ' + err.message);
      });
    } else if (state === 'prepared') {
      // Not for a live source: replaying a start position here fires the seek 801 with no user
      // gesture at all. Cleared either way, so a live pending position cannot replay later.
      if (this.pendingSeekMs > 0 && !this.currentSourceIsLive()) {
        player.seek(this.pendingSeekMs, PlayerService.seekMode());
      }
      this.pendingSeekMs = -1;
      this.applySpeed(player);
      this.applyVolume(player);
      this.applyResizeMode(player);
      // MS11: intent recorded while transient, honoured here.
      if (this.playWhenReady) {
        // The seek and the speed change above both run against the player before this line, and a
        // competing prepare()/reset() can land between the callback and the call. AVPlayer then
        // rejects play() outright with "current state is not prepared/paused/completed", which is
        // reported as a playback failure even though the intent is still perfectly good. Re-read
        // the live state and, when it has moved, leave playWhenReady set so the next 'prepared'
        // honours it — the same deferred-intent rule togglePlayPause() already follows.
        const live: media.AVPlayerState = player.state;
        if (live === 'prepared' || live === 'paused' || live === 'completed') {
          player.play().catch((err: BusinessError): void => {
            this.fail('play() failed: ' + err.message);
          });
        } else {
          console.info(TAG + ': play deferred, state moved to ' + live + ' before the call');
        }
      } else {
        this.state.onNext(PlayerStatus.PAUSED);
      }
    } else if (state === 'playing') {
      this.state.onNext(PlayerStatus.PLAYING);
    } else if (state === 'paused') {
      this.state.onNext(PlayerStatus.PAUSED);
      // Player.pause() -> saveStreamProgressState()
      this.saveStreamProgressState();
      // A paused broadcast falls behind its live edge; the LIVE label becomes the way back.
      if (this.currentSourceIsLive()) {
        this.behindLiveEdge.onNext(true);
      }
    } else if (state === 'completed') {
      this.state.onNext(PlayerStatus.COMPLETED);
    } else if (state === 'error') {
      this.state.onNext(PlayerStatus.ERROR);
    } else {
      this.state.onNext(PlayerStatus.IDLE);
    }
  }

  private onAudioInterrupt(event: audio.InterruptEvent): void {
    console.info(TAG + ': audioInterrupt type=' + event.eventType + ' force=' + event.forceType
      + ' hint=' + event.hintType);
    const hint: audio.InterruptHint = event.hintType;
    if (hint === audio.InterruptHint.INTERRUPT_HINT_PAUSE
      || hint === audio.InterruptHint.INTERRUPT_HINT_STOP) {
      const wasPlaying: boolean = this.isPlaying() || this.playWhenReady;
      if (event.forceType === audio.InterruptForceType.INTERRUPT_SHARE) {
        // A shared-mode hint is advice the app acts on itself.
        this.pause();
      } else {
        // The system already paused the stream; the intent goes with it.
        this.playWhenReady = false;
      }
      this.pausedByInterrupt = wasPlaying;
      return;
    }
    if (hint === audio.InterruptHint.INTERRUPT_HINT_RESUME) {
      const resume: boolean = this.pausedByInterrupt && PlayerPrefs.isResumeAfterAudioFocusGain();
      this.pausedByInterrupt = false;
      if (resume) {
        this.play();
      }
    }
  }

  private currentSourceIsAudioOnly(): boolean {
    const source: PlayableSource | null = this.currentSource;
    return source !== null && source.audioOnly;
  }

  private currentSourceIsLive(): boolean {
    const source: PlayableSource | null = this.currentSource;
    return source !== null && source.isLive;
  }

  /** MS11: the decision is taken from the LIVE player.state, never a cached snapshot. */
  async togglePlayPause(): Promise<void> {
    const player: media.AVPlayer | null = this.player;
    if (player === null) {
      this.playWhenReady = true;
      return;
    }
    const live: media.AVPlayerState = player.state;
    try {
      if (live === 'playing') {
        this.playWhenReady = false;
        await player.pause();
      } else if (live === 'prepared' || live === 'paused' || live === 'completed') {
        this.playWhenReady = true;
        await player.play();
      } else {
        // idle / initialized / stopped / error: record intent; 'prepared' honours it.
        this.playWhenReady = true;
      }
    } catch (e) {
      this.lastError.onNext('Play/pause failed: ' + describeError(e));
    }
  }

  async play(): Promise<void> {
    this.playWhenReady = true;
    const player: media.AVPlayer | null = this.player;
    if (player === null) {
      return;
    }
    const live: media.AVPlayerState = player.state;
    if (live === 'prepared' || live === 'paused' || live === 'completed') {
      try {
        await player.play();
      } catch (e) {
        this.lastError.onNext('play() failed: ' + describeError(e));
      }
    }
  }

  async pause(): Promise<void> {
    this.playWhenReady = false;
    const player: media.AVPlayer | null = this.player;
    if (player === null) {
      return;
    }
    if (player.state === 'playing') {
      try {
        await player.pause();
      } catch (e) {
        this.lastError.onNext('pause() failed: ' + describeError(e));
      }
    }
  }

  seekTo(positionMs: number): void {
    if (this.currentSourceIsLive()) {
      // AVPlayer: "Unsupport Capability: The stream is live stream, not support seek" (801).
      // It comes back asynchronously on the 'error' callback, which fails the player behind a
      // fatal panel and stops playback, so the seek is not issued at all - and no position is
      // stashed for the replay above either. Same rule as applySpeed() for speed.
      return;
    }
    const player: media.AVPlayer | null = this.player;
    if (player === null) {
      this.pendingSeekMs = positionMs;
      return;
    }
    const live: media.AVPlayerState = player.state;
    if (live === 'prepared' || live === 'playing' || live === 'paused' || live === 'completed') {
      player.seek(positionMs, PlayerService.seekMode());
    } else {
      this.pendingSeekMs = positionMs;
    }
  }

  /** PlayerHelper.getSeekParameters(): EXACT by default, the nearest key frame when inexact. */
  private static seekMode(): media.SeekMode {
    return PlayerPrefs.isUsingInexactSeek()
      ? media.SeekMode.SEEK_PREV_SYNC : media.SeekMode.SEEK_CLOSEST;
  }

  seekBy(deltaMs: number): void {
    const player: media.AVPlayer | null = this.player;
    const base: number = player !== null ? player.currentTime : 0;
    const target: number = base + deltaMs;
    this.seekTo(target > 0 ? target : 0);
  }

  currentPositionMs(): number {
    const player: media.AVPlayer | null = this.player;
    return player !== null ? player.currentTime : 0;
  }

  isPlaying(): boolean {
    const player: media.AVPlayer | null = this.player;
    return player !== null && player.state === 'playing';
  }

  /**
   * Player.setPlaybackParameters(): rounded to two decimals, saved for the next session, then
   * applied. Pitch and skip-silence are stored as the source stores them even though this
   * platform cannot play them (README, Known limits).
   */
  setPlaybackParameters(speed: number, pitch: number, skipSilence: boolean): number {
    const roundedSpeed: number = Math.round(speed * 100) / 100;
    const roundedPitch: number = Math.round(pitch * 100) / 100;
    PlayerPrefs.savePlaybackParameters(roundedSpeed, roundedPitch, skipSilence);
    return this.setSpeed(roundedSpeed);
  }

  /** Returns the rate that will really be played - the request, clamped to the SDK range. */
  setSpeed(rate: number): number {
    const effective: number = clampPlaybackRate(rate);
    this.speedRestored = true;
    this.speedRate = rate;
    const player: media.AVPlayer | null = this.player;
    if (player !== null) {
      this.applySpeed(player);
    } else {
      // Nothing is playing, so nothing contradicts the choice; the next prepare applies it and
      // playbackRateDone confirms it.
      this.reportedRate = effective;
      this.appliedSpeed.onNext(effective);
    }
    return effective;
  }

  /**
   * player.setVolume(0.0 .. 1.0). AVPlayer exposes NO mute of its own, so mute IS setVolume(0)
   * and there is deliberately no second setMuted() for a caller to get out of step with.
   */
  setVolume(volume: number): void {
    const level: number = volume < 0 ? 0 : (volume > 1 ? 1 : volume);
    this.volumeLevel = level;
    const player: media.AVPlayer | null = this.player;
    if (player !== null) {
      this.applyVolume(player);
    }
  }

  /** The level setVolume() last asked for - what a volume overlay must open on. */
  currentVolume(): number {
    return this.volumeLevel;
  }

  /**
   * What the SPEED CONTROL shows: the rate really in effect (T-0133b).
   *
   * It used to be the rate the user asked for, remembered in a map and replayed when the enum
   * event came back, because AVPlayer.setSpeed takes a ten-value enum and 1.1x snapped to 1.0x.
   * The chip then said 1.1 while the audio played 1.0 - which is what T-0133's "the sound is not
   * updating" looked like from the user's side. setPlaybackRate(number) takes the real rate and
   * 'playbackRateDone' hands it straight back, so request and effect are one value and there is
   * nothing left to reconcile.
   *
   * Written from that event and from a source change, and from nowhere else. Three earlier
   * attempts tried to INFER the applied rate and all three were wrong on a live stream - see
   * docs/qa/evidence/fix-T-0132c/probe.txt. Do not reintroduce an inference here.
   */
  private reportedRate: number = 1.0;

  displayRate(): number {
    return this.reportedRate;
  }

  /**
   * setResizeMode(): FIT keeps the picture's ratio inside the frame, FILL stretches it to the
   * frame, ZOOM crops it to fill - AVPlayer's three scale types, in that order. The surface
   * itself always fills the frame; the player decides how the picture sits in it.
   */
  setResizeMode(mode: number): void {
    this.resizeMode = mode;
    const player: media.AVPlayer | null = this.player;
    if (player !== null) {
      this.applyResizeMode(player);
    }
  }

  getResizeMode(): number {
    if (this.resizeMode < 0) {
      this.resizeMode = PlayerPrefs.resizeMode();
    }
    return this.resizeMode;
  }

  private applyResizeMode(player: media.AVPlayer): void {
    const live: media.AVPlayerState = player.state;
    if (this.currentSourceIsAudioOnly() || (live !== 'prepared' && live !== 'playing'
      && live !== 'paused' && live !== 'completed')) {
      return;
    }
    const mode: number = this.getResizeMode();
    const scale: media.VideoScaleType = mode === RESIZE_MODE_FILL
      ? media.VideoScaleType.VIDEO_SCALE_TYPE_FIT
      : (mode === RESIZE_MODE_ZOOM ? media.VideoScaleType.VIDEO_SCALE_TYPE_FIT_CROP
        : media.VideoScaleType.VIDEO_SCALE_TYPE_SCALED_ASPECT);
    try {
      player.videoScaleType = scale;
    } catch (e) {
      console.warn(TAG + ': videoScaleType not applied: ' + describeError(e));
    }
  }

  private applyVolume(player: media.AVPlayer): void {
    const live: media.AVPlayerState = player.state;
    if (live !== 'prepared' && live !== 'playing' && live !== 'paused' && live !== 'completed') {
      return;
    }
    try {
      player.setVolume(this.volumeLevel);
    } catch (e) {
      this.lastError.onNext('Volume not applied: ' + describeError(e));
    }
  }

  private applySpeed(player: media.AVPlayer): void {
    if (this.currentSourceIsLive()) {
      // AVPlayer: "Unsupport Capability: The stream is live stream, not support speed" (801).
      // NewPipe does not apply the playback-speed control to a live stream either.
      return;
    }
    try {
      // T-0133b: the continuous rate, not the ten-value enum. 1.1x used to bucket into
      // SPEED_FORWARD_1_00_X and play at 1.0 while the chip said 1.1. What the player actually
      // does is reported by 'playbackRateDone', not by this call returning.
      player.setPlaybackRate(clampPlaybackRate(this.speedRate));
    } catch (e) {
      this.lastError.onNext('Playback speed not applied: ' + describeError(e));
    }
  }

  /**
   * Popup / float-window player substitution (contract §2.1). SYSTEM_FLOAT_WINDOW is not
   * grantable to a self-signed build, so PiP is attempted first; when PiP is unavailable
   * the caller docks the in-app mini player instead. The outcome is always returned — the
   * popup entry points must visibly do one or the other, never nothing.
   */
  /**
   * The screen that opened the PiP window, when it is on the stack ONLY to host it. A list screen
   * carries no XComponent, so the popup entry points push VideoDetailFragmentPage for its
   * surface - and PiPWindow renders the popup FROM that surface, so the page has to outlive the
   * window rather than leave as it opens. This is how it learns the window is gone.
   */
  private pipClosedListener: (() => void) | null = null;
  /**
   * A LIST screen lends PiP a 1x1 invisible XComponent and must unmount it once the window is
   * gone - however it goes. That is NOT the same event as pipClosedListener, which the detail
   * page uses to navigate away and which must therefore stay silent when the app itself stops
   * PiP ("Switch to Main"). Unmounting a surface is always right; leaving a screen is not.
   */
  private pipSurfaceListener: (() => void) | null = null;

  setPipSurfaceListener(listener: (() => void) | null): void {
    this.pipSurfaceListener = listener;
  }

  private releasePipSurface(): void {
    const surface: (() => void) | null = this.pipSurfaceListener;
    this.pipSurfaceListener = null;
    if (surface !== null) {
      surface();
    }
  }

  setPipClosedListener(listener: (() => void) | null): void {
    this.pipClosedListener = listener;
  }

  /**
   * @param coverUI the layout PiP draws ABOVE its content - built by the caller, because a
   *        NodeController wraps a @Builder and only an ArkTS file can declare one. Used only when
   *        pipCoverUrl() has something to show, i.e. when the stream has no video at all.
   */
  async enterPip(context: common.UIAbilityContext,
    controller: XComponentController, coverUI?: NodeController): Promise<PipOutcome> {
    if (!PiPWindow.isPiPEnabled()) {
      return PipOutcome.FALLBACK_MINI_PLAYER;
    }
    this.disarmAutoPip();
    try {
      // NO navigationId. It names a Navigation component for PiP's auto-restore, and this app
      // has none - every screen is a router page. startPiP() then fails its navigation-controller
      // lookup and throws 1300013 synchronously, which is what sent EVERY popup entry point down
      // the mini-player fallback instead of opening the float window.
      // TC-KIOSK-179: a stream with no video gives the surface no frames, so the popup was a
      // black rectangle. The in-app cover cannot help - PiP mirrors the SURFACE, not the UI above
      // it (measured: the window's mean luminance stayed 0.0 after that fix). customUIController
      // is the one layer that draws INSIDE the window, so the artwork goes there, and only when
      // there is nothing else to show.
      const queueControls: boolean = this.pipHasQueue();
      const pip: PiPWindow.PiPController = await PiPWindow.create(
        this.pipConfiguration(context, controller, queueControls, coverUI));
      pip.on('stateChange', (state: PiPWindow.PiPState, reason: string): void => {
        this.onPipStateChange(pip, state, reason);
      });
      await pip.startPiP();
      this.pipController = pip;
      this.bindPipControls(pip, queueControls);
      return PipOutcome.PIP;
    } catch (e) {
      console.warn(TAG + ': PiP unavailable, using the in-app mini player: ' + describeError(e));
      this.pipController = null;
      return PipOutcome.FALLBACK_MINI_PLAYER;
    }
  }

  /** A PiP window created ahead of time and left to the system to start on app switch. */
  private armedPip: PiPWindow.PiPController | null = null;

  /**
   * minimize_on_exit = popup: MainPlayerUi.onFragmentStopped() switches to the popup player when the
   * app is left. HarmonyOS cannot start a PiP window from the background, so the window is
   * created while the player is on screen and setAutoStartEnabled() lets the system open it at
   * the moment the app goes to the background.
   */
  async armAutoPip(context: common.UIAbilityContext, controller: XComponentController,
    coverUI?: NodeController): Promise<void> {
    if (this.armedPip !== null || this.pipController !== null || !PiPWindow.isPiPEnabled()) {
      return;
    }
    try {
      const queueControls: boolean = this.pipHasQueue();
      const pip: PiPWindow.PiPController = await PiPWindow.create(
        this.pipConfiguration(context, controller, queueControls, coverUI));
      pip.on('stateChange', (state: PiPWindow.PiPState, reason: string): void => {
        if (state === PiPWindow.PiPState.STARTED) {
          // The system opened it: from here on it is THE popup, closed and restored as any other.
          this.armedPip = null;
          this.pipController = pip;
        }
        this.onPipStateChange(pip, state, reason);
      });
      pip.setAutoStartEnabled(true);
      this.armedPip = pip;
      this.bindPipControls(pip, queueControls);
    } catch (e) {
      console.warn(TAG + ': auto PiP not armed: ' + describeError(e));
      this.armedPip = null;
    }
  }

  disarmAutoPip(): void {
    const pip: PiPWindow.PiPController | null = this.armedPip;
    this.armedPip = null;
    if (pip === null) {
      return;
    }
    this.unbindPipControls(pip);
    try {
      pip.setAutoStartEnabled(false);
      pip.off('stateChange');
    } catch (e) {
      console.warn(TAG + ': auto PiP not disarmed: ' + describeError(e));
    }
  }

  private pipConfiguration(context: common.UIAbilityContext, controller: XComponentController,
    queueControls: boolean, coverUI?: NodeController): PiPWindow.PiPConfiguration {
    const group: PiPWindow.PiPControlGroup = queueControls
      ? PiPWindow.VideoPlayControlGroup.VIDEO_PREVIOUS_NEXT
      : PiPWindow.VideoPlayControlGroup.FAST_FORWARD_BACKWARD;
    return {
      context: context,
      componentController: controller,
      templateType: PiPWindow.PiPTemplateType.VIDEO_PLAY,
      controlGroups: [group],
      customUIController: this.pipCoverUrl().length > 0 ? coverUI : undefined,
      defaultWindowSizeType: PIP_SMALL_WINDOW
    };
  }

  /** The queue the popup's Previous / Next walk; see QueueNavigator. */
  private queueNavigator: QueueNavigator | null = null;

  setQueueNavigator(navigator: QueueNavigator | null): void {
    this.queueNavigator = navigator;
  }

  /**
   * The popup's optional control group. VIDEO_PLAY always draws play/pause and takes ONE more
   * group: VIDEO_PREVIOUS_NEXT and FAST_FORWARD_BACKWARD are mutually exclusive (API reference,
   * VideoPlayControlGroup), and the window keeps its choice for as long as it lives. The source's
   * popup shows Previous/Next only where the queue has somewhere to go (showOrHideButtons()) and
   * seeks by a double tap on either third, so a queue gets Previous/Next and a single stream - both
   * buttons hidden on Android - gets the seek pair.
   */
  private pipHasQueue(): boolean {
    const queue: PlayQueue | null = currentPlayQueue.getValue();
    return this.queueNavigator !== null && queue !== null && queue.size() > 1;
  }

  /** Whether the window was built with Previous/Next rather than the seek pair. */
  private pipQueueControls: boolean = false;
  private readonly pipSubscriptions: CompositeDisposable = new CompositeDisposable();

  private bindPipControls(pip: PiPWindow.PiPController, queueControls: boolean): void {
    this.pipQueueControls = queueControls;
    pip.on('controlEvent', (event: PiPWindow.ControlEventParam): void => {
      this.onPipControl(event);
    });
    // Both subjects replay their value, so the window starts in step and stays so: a pause from
    // the notification or a headset, a new stream from the queue.
    this.pipSubscriptions.add(this.state.subscribeCallbacks((status: PlayerStatus): void => {
      this.syncPipControls(pip);
    }));
    this.pipSubscriptions.add(this.currentInfo.subscribeCallbacks((info: StreamInfo | null): void => {
      this.syncPipControls(pip);
    }));
  }

  private unbindPipControls(pip: PiPWindow.PiPController): void {
    this.pipSubscriptions.clear();
    try {
      pip.off('controlEvent');
    } catch (e) {
      console.warn(TAG + ': PiP controls not released: ' + describeError(e));
    }
  }

  /**
   * The window draws what the player does: play/pause follows the player (the app has to report
   * it - updatePiPControlStatus), Previous/Next follow showOrHideButtons().
   */
  private syncPipControls(pip: PiPWindow.PiPController): void {
    const status: PlayerStatus | null = this.state.getValue();
    const playing: boolean = status === PlayerStatus.PLAYING
      || (status === PlayerStatus.BUFFERING && this.playWhenReady);
    try {
      pip.updatePiPControlStatus(PiPWindow.PiPControlType.VIDEO_PLAY_PAUSE,
        playing ? PiPWindow.PiPControlStatus.PLAY : PiPWindow.PiPControlStatus.PAUSE);
      const queue: PlayQueue | null = currentPlayQueue.getValue();
      if (this.pipQueueControls && queue !== null) {
        pip.setPiPControlEnabled(PiPWindow.PiPControlType.VIDEO_PREVIOUS, queue.getIndex() !== 0);
        pip.setPiPControlEnabled(PiPWindow.PiPControlType.VIDEO_NEXT,
          queue.getIndex() + 1 !== queue.size());
      }
    } catch (e) {
      console.warn(TAG + ': PiP controls not updated: ' + describeError(e));
    }
  }

  /** The popup's buttons, doing what the source popup's controls do. */
  private onPipControl(event: PiPWindow.ControlEventParam): void {
    const navigator: QueueNavigator | null = this.queueNavigator;
    switch (event.controlType) {
      case PiPWindow.PiPControlType.VIDEO_PLAY_PAUSE:
        // The status is the one the button was switched TO.
        if (event.status === PiPWindow.PiPControlStatus.PAUSE) {
          this.pause();
        } else if (event.status === PiPWindow.PiPControlStatus.PLAY) {
          this.play();
        } else {
          this.togglePlayPause();
        }
        break;
      case PiPWindow.PiPControlType.VIDEO_PREVIOUS:
        if (navigator !== null) {
          navigator.playPrevious();
        }
        break;
      case PiPWindow.PiPControlType.VIDEO_NEXT:
        if (navigator !== null) {
          navigator.playNext();
        }
        break;
      case PiPWindow.PiPControlType.FAST_FORWARD:
        // fastForward() / fastRewind(): one seek_duration, the popup's double tap on a side third.
        this.seekBy(PlayerPrefs.seekDurationMs());
        break;
      case PiPWindow.PiPControlType.FAST_BACKWARD:
        this.seekBy(-PlayerPrefs.seekDurationMs());
        break;
      default:
        break;
    }
  }

  /**
   * The popup's fullscreen button: PopupPlayerUi's fullScreenButton opens the MAIN player, and
   * "starting directly in fullscreen if the previous player type was popup" (NavigationHelper.
   * openVideoDetailFragment). PiP takes no app button for it; its restore control is the window's
   * one way back to the app, so the host is told of a restore and goes fullscreen.
   */
  private pipRestoredListener: (() => void) | null = null;

  setPipRestoredListener(listener: (() => void) | null): void {
    this.pipRestoredListener = listener;
  }

  /** A host that goes away takes its own listener with it - and only its own. */
  clearPipRestoredListener(listener: () => void): void {
    if (this.pipRestoredListener === listener) {
      this.pipRestoredListener = null;
    }
  }

  /**
   * The artwork the popup should show, or '' when the stream has video and the surface will carry
   * real frames. Audio-only is the whole of the condition: a video stream needs no substitute.
   */
  pipCoverUrl(): string {
    const info: StreamInfo | null = this.currentInfo.getValue();
    if (info === null || !this.currentSourceIsAudioOnly()) {
      return '';
    }
    const thumbnails: StreamImage[] = info.getThumbnails();
    const preferred: string | null = choosePreferredImage(thumbnails);
    return preferred === null ? '' : preferred;
  }

  /** Set by ABOUT_TO_RESTORE, so the STOPPED that follows a restore is not read as a close. */
  private pipRestoring: boolean = false;

  /**
   * The system draws and owns the popup's drag-to-close target: dragging the PiP window into the
   * trash hotzone at the foot of the screen (PiP guide, "拖动删除画中画窗口") or tapping its close
   * control removes the WINDOW and nothing else - the guide's own FAQ is "the sound keeps playing
   * in the background after drag-delete / close" unless the app acts on STOPPED. Android's
   * player_popup_close_overlay destroys the player, so a close here does the same. A restore
   * (ABOUT_TO_RESTORE, reason "panelActionRestore") also ends in STOPPED but hands the surface
   * back to the page, where playback carries on. Reason strings exist from HarmonyOS 6.1.0 and
   * are "0" before it, which is why the restore is tracked by state as well.
   */
  private onPipStateChange(pip: PiPWindow.PiPController, state: PiPWindow.PiPState,
    reason: string): void {
    console.info(TAG + ': pip state=' + state + ' reason=' + reason);
    if (state === PiPWindow.PiPState.ABOUT_TO_RESTORE) {
      this.pipRestoring = true;
      return;
    }
    if (state !== PiPWindow.PiPState.STOPPED && state !== PiPWindow.PiPState.ERROR) {
      return;
    }
    pip.off('stateChange');
    this.unbindPipControls(pip);
    if (this.pipController === pip) {
      this.pipController = null;
    }
    const restored: boolean = this.pipRestoring || reason === 'panelActionRestore';
    this.pipRestoring = false;
    const onRestored: (() => void) | null = this.pipRestoredListener;
    this.pipRestoredListener = null;
    if (restored) {
      // Back in the app, the main player takes over: a list screen's lent surface unmounts (the
      // detail page the restore opens brings its own), and the host goes fullscreen.
      this.releasePipSurface();
      if (onRestored !== null) {
        onRestored();
      }
      return;
    }
    if (state === PiPWindow.PiPState.ERROR) {
      return;
    }
    // dragDelete / panelActionDelete / other: the user closed the popup, so playback stops.
    this.release().catch((err: BusinessError): void => {
      console.warn(TAG + ': release after the popup closed failed: ' + err.message);
    });
    // ... and the screen that was pushed only to lend the window a surface leaves with it.
    const closed: (() => void) | null = this.pipClosedListener;
    this.pipClosedListener = null;
    if (closed !== null) {
      closed();
    }
    this.releasePipSurface();
  }

  /**
   * Whether the PiP window this service opened is still up. pipController is private and had
   * no accessor, so a screen that wants to offer "popup player" only when one is NOT already
   * running - PlayQueueActivityPage's popupPlayerSelected - had nothing honest to ask.
   * Read-only: entering and leaving PiP stays enterPip()/exitPip()'s business.
   */
  isPipActive(): boolean {
    return this.pipController !== null;
  }

  /**
   * Player.videoPlayerSelected(): the MAIN video player - not the popup (a PiP window) and not
   * the background player (an audio-only source). The one PlayerService.onTaskRemoved() stops.
   */
  isMainVideoPlayer(): boolean {
    return this.player !== null && !this.currentSourceIsAudioOnly() && this.pipController === null;
  }

  async exitPip(): Promise<void> {
    const pip: PiPWindow.PiPController | null = this.pipController;
    if (pip === null) {
      return;
    }
    // This stop is the app's own ("Switch to Main", release()): never a user close, so the
    // listeners that would stop playback and send the host screen away come off first.
    pip.off('stateChange');
    this.unbindPipControls(pip);
    this.pipClosedListener = null;
    this.pipRestoredListener = null;
    this.pipRestoring = false;
    // The window is going either way, so the screen that lent it a surface must unmount one -
    // otherwise popupSurfaceMounted stays true with no window behind it and that screen's Popup
    // control is dead until the app restarts (measured on TC-LIBRARY-457).
    this.releasePipSurface();
    try {
      await pip.stopPiP();
    } catch (e) {
      console.warn(TAG + ': stopPiP failed: ' + describeError(e));
    } finally {
      this.pipController = null;
    }
  }

  /** MS12: release in a finally path so nothing leaks when teardown throws. */
  async release(): Promise<void> {
    // Player.destroy() -> saveStreamProgressState(), while the position is still readable
    this.saveStreamProgressState();
    this.disarmAutoPip();
    await this.exitPip();
    const player: media.AVPlayer | null = this.player;
    if (player !== null) {
      try {
        await player.reset();
      } catch (e) {
        console.warn(TAG + ': reset() during release failed: ' + describeError(e));
      } finally {
        try {
          await player.release();
        } catch (e) {
          console.warn(TAG + ': release() failed: ' + describeError(e));
        } finally {
          this.player = null;
          this.currentSource = null;
          this.currentTargetHeight = 0;
          this.currentAudioTrackId = '';
          this.currentInfo.onNext(null);
          this.playWhenReady = false;
          this.state.onNext(PlayerStatus.IDLE);
        }
      }
    }
    LocalHlsServer.getInstance().stop();
  }
}
