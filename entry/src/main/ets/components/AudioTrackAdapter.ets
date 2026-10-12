/*
 * S3 - port of org.schabi.newpipe.util.AudioTrackAdapter (a BaseAdapter over
 * stream_quality_item.xml), the rows behind the player's audio-track popup and the download
 * dialog's audio-track spinner.
 *
 * getItem(position) returns a GROUP of AudioStreams (one audio track can have several qualities);
 * getView() renders the group's first stream: its track id as the format name and
 * Localization.audioTrackName(stream) as the quality line, with wo_sound_icon AND sizeView both
 * GONE.
 *
 * The row VIEW is not here any more: it was a second, thinner copy of stream_quality_item.xml
 * that drew one flat line and printed the raw average bitrate ("48") where the source hides the
 * size view. The track spinner now feeds StreamItemAdapter like the other two spinners in the
 * download dialog, so all three share one row layout and one floating dropdown. What stays is the
 * grouping type and the label, which the dialog and the player both need.
 */
import { AudioStream } from '../model/extractor/AudioStream';
import { AudioTrackType } from '../model/extractor/AudioTrackType';
import { Localization } from '../common/i18n/Localization';

/** AudioTrackAdapter.AudioTracksWrapper: the grouped streams, one group per selectable track. */
export class AudioTrackGroup {
  readonly streams: AudioStream[];

  constructor(streams: AudioStream[]) {
    this.streams = streams;
  }

  /** getItem(position).get(0) - the stream the row is labelled from. */
  first(): AudioStream | null {
    return this.streams.length === 0 ? null : this.streams[0];
  }
}

/** Localization.audioTrackType(context, type). */
function audioTrackTypeName(type: AudioTrackType | null): string {
  switch (type) {
    case AudioTrackType.ORIGINAL:
      return Localization.getString('audio_track_type_original');
    case AudioTrackType.DUBBED:
      return Localization.getString('audio_track_type_dubbed');
    case AudioTrackType.DESCRIPTIVE:
      return Localization.getString('audio_track_type_descriptive');
    case AudioTrackType.SECONDARY:
      return Localization.getString('audio_track_type_secondary');
    default:
      return '';
  }
}

/**
 * Localization.audioTrackName(context, stream): the language, then the track's type appended
 * through `audio_track_name` ("%1$s %2$s") - "English original", "French dubbed". The type was
 * being dropped, so every row and the closed spinner read as a bare language name.
 */
export function audioTrackName(stream: AudioStream | null): string {
  if (stream === null) {
    return '';
  }
  const name: string | null = stream.getAudioTrackName();
  const locale: string | null = stream.getAudioLocale();
  let label: string = name !== null && name.length > 0 ? name : '';
  if (label.length === 0) {
    label = locale !== null && locale.length > 0
      ? locale : Localization.getString('unknown_audio_track');
  }
  const typeName: string = audioTrackTypeName(stream.getAudioTrackType());
  // The source builds the label from the LOCALE's display language, so the type is always
  // appended exactly once. YouTube already spells the qualifier into getAudioTrackName() for the
  // original track ("English original") but not for a dubbed one ("French"), so appending blindly
  // produced "English original original" on device.
  if (typeName.length === 0 || label.toLowerCase().endsWith(typeName.toLowerCase())) {
    return label;
  }
  return Localization.getStringArgs('audio_track_name', [label, typeName]);
}

/**
 * AudioTrackAdapter.AudioTracksWrapper's grouping: one group per audioTrackId, listed by the
 * label a user reads - the order the reference's popup shows.
 */
export function groupAudioTracks(streams: AudioStream[]): AudioTrackGroup[] {
  const byTrack: Map<string, AudioStream[]> = new Map<string, AudioStream[]>();
  for (const stream of streams) {
    const id: string | null = stream.getAudioTrackId();
    const key: string = id === null ? '' : id;
    const bucket: AudioStream[] | undefined = byTrack.get(key);
    if (bucket === undefined) {
      byTrack.set(key, [stream]);
    } else {
      bucket.push(stream);
    }
  }
  const groups: AudioTrackGroup[] = [];
  byTrack.forEach((value: AudioStream[]) => {
    groups.push(new AudioTrackGroup(value));
  });
  groups.sort((a: AudioTrackGroup, b: AudioTrackGroup): number =>
    audioTrackName(a.first()).localeCompare(audioTrackName(b.first())));
  return groups;
}
