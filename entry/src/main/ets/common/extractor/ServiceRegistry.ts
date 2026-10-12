/*
 * Port of org.schabi.newpipe.extractor.ServiceList (the plan's svc_service_registry) (NewPipeExtractor v0.26.5).
 *
 * DEVIATION, deliberate (phase2-logic-contract.md §9): Java reads the service list straight out of
 * ServiceList's static initialiser via `ServiceList.all()`. Doing that here would be an
 * init-time ES-module cycle (NewPipe -> services -> Extractor -> NewPipe), so the list is
 * REGISTERED instead: importing this module calls NewPipe.registerServices() once, and everything
 * else reads NewPipe.getServices() / getService(id).
 *
 * Import this module once at app startup (beside NewPipe.init) so the registration runs. Its ids
 * are the Java ones and must not be renumbered — they are persisted in the database and in
 * every stored subscription, playlist and history row.
 */

import { StreamingService } from './core/StreamingService';
import { NewPipe } from './core/NewPipe';
import { YoutubeService } from './services/youtube/YoutubeService';
import { SoundcloudService } from './services/soundcloud/SoundcloudService';
import { MediaCCCService } from './services/media_ccc/MediaCCCService';
import { PeertubeService } from './services/peertube/PeertubeService';
import { BandcampService } from './services/bandcamp/BandcampService';

export const YouTube: YoutubeService = new YoutubeService(0);
export const SoundCloud: SoundcloudService = new SoundcloudService(1);
export const MediaCCC: MediaCCCService = new MediaCCCService(2);
export const PeerTube: PeertubeService = new PeertubeService(3);
export const Bandcamp: BandcampService = new BandcampService(4);

/**
 * When adding a service, put it at the END of this list and give it the next free id — the ids
 * are stored in the database.
 */
const SERVICES: StreamingService[] = [YouTube, SoundCloud, MediaCCC, PeerTube, Bandcamp];

// Stands in for Java's static initialiser; see the deviation note above.
NewPipe.registerServices(SERVICES);

/** Port of ServiceList.all(). */
export function all(): StreamingService[] {
  return SERVICES;
}
