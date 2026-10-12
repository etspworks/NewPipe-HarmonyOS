/*
 * The stream-choosing half of org.schabi.newpipe.util.ListHelper (and SecondaryStreamHelper's
 * getAudioStreamFor) that the download dialog runs: which qualities are offered, in what order,
 * which one is preselected, and which audio a video-only stream is muxed with. The preferences
 * come in through PlayerPrefs, so the rules here are the source's, value for value.
 */

import { MediaFormat } from '../../model/enums/MediaFormat';
import { AudioStream } from '../../model/extractor/AudioStream';
import { AudioTrackType } from '../../model/extractor/AudioTrackType';
import { VideoStream } from '../../model/extractor/VideoStream';
import { best_resolution_key } from '../prefs/SettingsKeys';

/** Video format in order of quality. 0=lowest quality, n=highest quality. */
const VIDEO_FORMAT_QUALITY_RANKING: MediaFormat[] =
  [MediaFormat.v3GPP, MediaFormat.WEBM, MediaFormat.MPEG_4];
/** Audio format in order of quality. 0=lowest quality, n=highest quality. */
const AUDIO_FORMAT_QUALITY_RANKING: MediaFormat[] =
  [MediaFormat.MP3, MediaFormat.WEBMA, MediaFormat.M4A];
/** Audio format in order of efficiency. 0=least efficient, n=most efficient. */
const AUDIO_FORMAT_EFFICIENCY_RANKING: MediaFormat[] =
  [MediaFormat.MP3, MediaFormat.M4A, MediaFormat.WEBMA];
const HIGH_RESOLUTION_LIST: string[] = ['1440p', '2160p'];
/** Audio track types in order of priority. 0=lowest, n=highest. */
const AUDIO_TRACK_TYPE_RANKING: AudioTrackType[] = [AudioTrackType.DESCRIPTIVE,
  AudioTrackType.SECONDARY, AudioTrackType.DUBBED, AudioTrackType.ORIGINAL];
const AUDIO_TRACK_TYPE_RANKING_DESCRIPTIVE: AudioTrackType[] = [AudioTrackType.SECONDARY,
  AudioTrackType.DUBBED, AudioTrackType.ORIGINAL, AudioTrackType.DESCRIPTIVE];

type AudioComparator = (a: AudioStream, b: AudioStream) => number;

function formatIndex(ranking: MediaFormat[], format: MediaFormat | null): number {
  return format === null ? -1 : ranking.indexOf(format);
}

/** compareVideoStreamResolution(): '720p60' ranks 721, an unreadable one counts as greater. */
export function compareVideoStreamResolution(r1: string, r2: string): number {
  const res1: number = parseInt(r1.replace(/0p\d+$/, '1').replace(/[^\d.]/g, ''), 10);
  const res2: number = parseInt(r2.replace(/0p\d+$/, '1').replace(/[^\d.]/g, ''), 10);
  if (isNaN(res1) || isNaN(res2)) {
    return 1;
  }
  return res1 - res2;
}

/** sortStreamList(videoStreams, ascendingOrder). */
function sortStreamList(videoStreams: VideoStream[], ascendingOrder: boolean): VideoStream[] {
  videoStreams.sort((a: VideoStream, b: VideoStream): number => {
    let cmp: number = compareVideoStreamResolution(a.getResolution(), b.getResolution());
    if (cmp === 0) {
      cmp = formatIndex(VIDEO_FORMAT_QUALITY_RANKING, a.getFormat())
        - formatIndex(VIDEO_FORMAT_QUALITY_RANKING, b.getFormat());
    }
    return ascendingOrder ? cmp : -cmp;
  });
  return videoStreams;
}

/**
 * getSortedStreamVideosList(defaultFormat, showHigherResolutions, videoStreams,
 * videoOnlyStreams, ascendingOrder, preferVideoOnlyStreams): one stream per resolution - the
 * later list wins, then the default format wins - with 1440p/2160p left out unless asked for.
 */
export function getSortedStreamVideosList(defaultFormat: MediaFormat | null,
  showHigherResolutions: boolean, videoStreams: VideoStream[], videoOnlyStreams: VideoStream[],
  ascendingOrder: boolean, preferVideoOnlyStreams: boolean): VideoStream[] {
  const ordered: VideoStream[][] = preferVideoOnlyStreams
    ? [videoStreams, videoOnlyStreams] : [videoOnlyStreams, videoStreams];
  const all: VideoStream[] = [];
  for (const list of ordered) {
    for (const stream of list) {
      if (showHigherResolutions
        || !HIGH_RESOLUTION_LIST.includes(stream.getResolution().replace(/p\d+$/, 'p'))) {
        all.push(stream);
      }
    }
  }
  const byResolution: Map<string, VideoStream> = new Map<string, VideoStream>();
  for (const stream of all) {
    byResolution.set(stream.getResolution(), stream);
  }
  for (const stream of all) {
    if (stream.getFormat() === defaultFormat) {
      byResolution.set(stream.getResolution(), stream);
    }
  }
  return sortStreamList(Array.from(byResolution.values()), ascendingOrder);
}

/**
 * getVideoStreamIndex(): a format+resolution match, then ignoring the refresh rate, then the
 * resolution alone, then the next resolution down; -1 when nothing fits.
 */
export function getVideoStreamIndex(targetResolution: string, targetFormat: MediaFormat | null,
  videoStreams: VideoStream[]): number {
  let fullMatchIndex: number = -1;
  let fullMatchNoRefreshIndex: number = -1;
  let resMatchOnlyIndex: number = -1;
  let resMatchOnlyNoRefreshIndex: number = -1;
  let lowerResMatchNoRefreshIndex: number = -1;
  const targetResolutionNoRefresh: string = targetResolution.replace(/p\d+$/, 'p');

  for (let idx: number = 0; idx < videoStreams.length; idx++) {
    const format: MediaFormat | null = targetFormat === null ? null : videoStreams[idx].getFormat();
    const resolution: string = videoStreams[idx].getResolution();
    const resolutionNoRefresh: string = resolution.replace(/p\d+$/, 'p');

    if (format === targetFormat && resolution === targetResolution) {
      fullMatchIndex = idx;
    }
    if (format === targetFormat && resolutionNoRefresh === targetResolutionNoRefresh) {
      fullMatchNoRefreshIndex = idx;
    }
    if (resMatchOnlyIndex === -1 && resolution === targetResolution) {
      resMatchOnlyIndex = idx;
    }
    if (resMatchOnlyNoRefreshIndex === -1 && resolutionNoRefresh === targetResolutionNoRefresh) {
      resMatchOnlyNoRefreshIndex = idx;
    }
    if (lowerResMatchNoRefreshIndex === -1
      && compareVideoStreamResolution(resolutionNoRefresh, targetResolutionNoRefresh) < 0) {
      lowerResMatchNoRefreshIndex = idx;
    }
  }

  if (fullMatchIndex !== -1) {
    return fullMatchIndex;
  }
  if (fullMatchNoRefreshIndex !== -1) {
    return fullMatchNoRefreshIndex;
  }
  if (resMatchOnlyIndex !== -1) {
    return resMatchOnlyIndex;
  }
  if (resMatchOnlyNoRefreshIndex !== -1) {
    return resMatchOnlyNoRefreshIndex;
  }
  return lowerResMatchNoRefreshIndex;
}

/** getDefaultResolutionIndex(defaultResolution, best, defaultFormat, videoStreams). */
export function getDefaultResolutionIndex(defaultResolution: string,
  defaultFormat: MediaFormat | null, videoStreams: VideoStream[]): number {
  if (videoStreams.length === 0) {
    return -1;
  }
  sortStreamList(videoStreams, false);
  if (defaultResolution === best_resolution_key) {
    return 0;
  }
  const index: number = getVideoStreamIndex(defaultResolution, defaultFormat, videoStreams);
  return index === -1 ? 0 : index;
}

/**
 * getAudioFormatComparator(defaultFormat, limitDataUsage): the default format first, then the
 * bitrate (lowest first when saving data), then the format ranking. The best ranks LAST.
 */
export function getAudioFormatComparator(defaultFormat: MediaFormat | null,
  limitDataUsage: boolean): AudioComparator {
  const formatRanking: MediaFormat[] = limitDataUsage
    ? AUDIO_FORMAT_EFFICIENCY_RANKING : AUDIO_FORMAT_QUALITY_RANKING;
  return (a: AudioStream, b: AudioStream): number => {
    if (defaultFormat !== null) {
      const cmp: number = Number(a.getFormat() === defaultFormat)
        - Number(b.getFormat() === defaultFormat);
      if (cmp !== 0) {
        return cmp;
      }
    }
    let bitrate: number = a.getAverageBitrate() - b.getAverageBitrate();
    if (limitDataUsage) {
      bitrate = -bitrate;
    }
    if (bitrate !== 0) {
      return bitrate;
    }
    return formatIndex(formatRanking, a.getFormat()) - formatIndex(formatRanking, b.getFormat());
  };
}

function languageOf(locale: string | null): string | null {
  if (locale === null || locale.length === 0) {
    return null;
  }
  return locale.split(/[-_]/)[0].toLowerCase();
}

/** Comparator.nullsFirst(comparing(predicate)): null < false < true. */
function compareNullableFlags(a: boolean | null, b: boolean | null): number {
  const rank = (v: boolean | null): number => v === null ? 0 : (v ? 2 : 1);
  return rank(a) - rank(b);
}

/**
 * getAudioTrackComparator(preferredLanguage, preferOriginalAudio, preferDescriptiveAudio): the
 * original track (when preferred), the preferred language, the track type, then English. The
 * best ranks LAST. Languages compare by their primary subtag (the source compares ISO-3 codes).
 */
export function getAudioTrackComparator(preferredLanguage: string, preferOriginalAudio: boolean,
  preferDescriptiveAudio: boolean): AudioComparator {
  const langCode: string | null = languageOf(preferredLanguage);
  const trackTypeRanking: AudioTrackType[] = preferDescriptiveAudio
    ? AUDIO_TRACK_TYPE_RANKING_DESCRIPTIVE : AUDIO_TRACK_TYPE_RANKING;
  return (a: AudioStream, b: AudioStream): number => {
    if (preferOriginalAudio) {
      const cmp: number = Number(a.getAudioTrackType() === AudioTrackType.ORIGINAL)
        - Number(b.getAudioTrackType() === AudioTrackType.ORIGINAL);
      if (cmp !== 0) {
        return cmp;
      }
    }
    const langA: string | null = languageOf(a.getAudioLocale());
    const langB: string | null = languageOf(b.getAudioLocale());
    let cmp: number = compareNullableFlags(langA === null ? null : langA === langCode,
      langB === null ? null : langB === langCode);
    if (cmp !== 0) {
      return cmp;
    }
    const typeA: AudioTrackType | null = a.getAudioTrackType();
    const typeB: AudioTrackType | null = b.getAudioTrackType();
    if (typeA === null || typeB === null) {
      cmp = (typeA === null ? 0 : 1) - (typeB === null ? 0 : 1);
    } else {
      cmp = trackTypeRanking.indexOf(typeA) - trackTypeRanking.indexOf(typeB);
    }
    if (cmp !== 0) {
      return cmp;
    }
    return compareNullableFlags(langA === null ? null : langA === 'en',
      langB === null ? null : langB === 'en');
  };
}

/**
 * getFilteredAudioStreams(context, audioStreams): the preferred stream of every audio track - by
 * the format comparator - dropping the unnamed track when real ones exist. The caller sorts the
 * result by track name (the name is a UI string).
 */
export function getFilteredAudioStreams(audioStreams: AudioStream[],
  defaultFormat: MediaFormat | null, limitDataUsage: boolean): AudioStream[] {
  const cmp: AudioComparator = getAudioFormatComparator(defaultFormat, limitDataUsage);
  const collected: Map<string, AudioStream> = new Map<string, AudioStream>();
  for (const stream of audioStreams) {
    const id: string | null = stream.getAudioTrackId();
    const trackId: string = id === null ? '' : id;
    const present: AudioStream | undefined = collected.get(trackId);
    if (present === undefined || cmp(stream, present) > 0) {
      collected.set(trackId, stream);
    }
  }
  if (collected.size > 1) {
    collected.delete('');
  }
  return Array.from(collected.values());
}

/** getAudioIndexByHighestRank(audioStreams, comparator): -1 for an empty list. */
export function getAudioIndexByHighestRank(audioStreams: AudioStream[],
  comparator: AudioComparator): number {
  let best: number = -1;
  for (let i: number = 0; i < audioStreams.length; i++) {
    // Stream.max() is BinaryOperator.maxBy: the FIRST of equal maxima stays.
    if (best === -1 || comparator(audioStreams[i], audioStreams[best]) > 0) {
      best = i;
    }
  }
  return best;
}

/**
 * SecondaryStreamHelper.getAudioStreamFor(): the audio a video-only stream is muxed with - WebM
 * audio (Vorbis or Opus) for a WebM video, M4A for an MPEG-4 one, nothing for anything else.
 */
export function getAudioStreamFor(audioStreams: AudioStream[], videoStream: VideoStream,
  limitDataUsage: boolean): AudioStream | null {
  const mediaFormat: MediaFormat | null = videoStream.getFormat();
  let candidates: AudioStream[] = [];
  let preferred: MediaFormat = MediaFormat.M4A;
  if (mediaFormat === MediaFormat.WEBM) {
    candidates = audioStreams.filter((s: AudioStream): boolean =>
      s.getFormat() === MediaFormat.WEBMA || s.getFormat() === MediaFormat.WEBMA_OPUS);
    preferred = MediaFormat.WEBMA;
  } else if (mediaFormat === MediaFormat.MPEG_4) {
    candidates = audioStreams.filter((s: AudioStream): boolean =>
      s.getFormat() === MediaFormat.M4A);
  } else {
    return null;
  }
  const index: number = getAudioIndexByHighestRank(candidates,
    getAudioFormatComparator(preferred, limitDataUsage));
  return index < 0 ? null : candidates[index];
}
