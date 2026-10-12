/*
 * Port of org.schabi.newpipe.extractor.playlist.PlaylistInfoItem (NewPipeExtractor v0.26.5).
 */

import { InfoItem, InfoType } from '../../common/extractor/core/InfoItem';
import { Description } from './Description';
import { PlaylistType } from './PlaylistType';

export class PlaylistInfoItem extends InfoItem {
  uploaderName: string = '';
  uploaderUrl: string | null = null;
  uploaderVerified: boolean = false;
  streamCount: number = 0;
  description: Description = Description.EMPTY_DESCRIPTION;
  playlistType: PlaylistType = PlaylistType.NORMAL;

  constructor(serviceId: number, url: string, name: string) {
    super(InfoType.PLAYLIST, serviceId, url, name);
  }

  getUploaderName(): string {
    return this.uploaderName;
  }

  setUploaderName(uploaderName: string): void {
    this.uploaderName = uploaderName;
  }

  getUploaderUrl(): string | null {
    return this.uploaderUrl;
  }

  setUploaderUrl(uploaderUrl: string | null): void {
    this.uploaderUrl = uploaderUrl;
  }

  getIsUploaderVerified(): boolean {
    return this.uploaderVerified;
  }

  setUploaderVerified(uploaderVerified: boolean): void {
    this.uploaderVerified = uploaderVerified;
  }

  getStreamCount(): number {
    return this.streamCount;
  }

  setStreamCount(streamCount: number): void {
    this.streamCount = streamCount;
  }

  getDescription(): Description {
    return this.description;
  }

  setDescription(description: Description): void {
    this.description = description;
  }

  getPlaylistType(): PlaylistType {
    return this.playlistType;
  }

  setPlaylistType(playlistType: PlaylistType): void {
    this.playlistType = playlistType;
  }
}
