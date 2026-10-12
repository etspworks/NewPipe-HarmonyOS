/*
 * Port of org.schabi.newpipe.extractor.stream.StreamSegment (NewPipeExtractor v0.26.5).
 * One chapter of a stream: its title, its start offset and the frame preview for it.
 */

export class StreamSegment {
  title: string;
  channelName: string | null = null;
  startTimeSeconds: number;
  url: string | null = null;
  previewUrl: string | null = null;

  constructor(title: string, startTimeSeconds: number) {
    this.title = title;
    this.startTimeSeconds = startTimeSeconds;
  }

  getTitle(): string {
    return this.title;
  }

  setTitle(title: string): void {
    this.title = title;
  }

  getStartTimeSeconds(): number {
    return this.startTimeSeconds;
  }

  setStartTimeSeconds(startTimeSeconds: number): void {
    this.startTimeSeconds = startTimeSeconds;
  }

  getChannelName(): string | null {
    return this.channelName;
  }

  setChannelName(channelName: string | null): void {
    this.channelName = channelName;
  }

  getUrl(): string | null {
    return this.url;
  }

  setUrl(url: string | null): void {
    this.url = url;
  }

  getPreviewUrl(): string | null {
    return this.previewUrl;
  }

  setPreviewUrl(previewUrl: string | null): void {
    this.previewUrl = previewUrl;
  }
}
