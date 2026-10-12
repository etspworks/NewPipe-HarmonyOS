/*
 * THIS SUITE RUNS. From the repo root:
 *
 *   node hvigorw.js --mode module -p module=entry@default -p product=default  *        -p buildMode=test -p coverage=false test --no-daemon
 *
 * (the same node + hvigorw.js under DevEco Studio's tools that assembleHap uses; there is no
 * hvigorw wrapper script in the repo, which is what "no test target exists" was really seeing -
 * entry/build-profile.json5 has declared its ohosTest target since the init commit).
 *
 * READ THE OUTPUT, NOT THE EXIT CODE. A failing assertion prints
 *   ERROR: Error in <testName>, <message>
 * and hvigor still finishes BUILD SUCCESSFUL with exit 0. No "Tests run: N" line is ever
 * printed, so "BUILD SUCCESSFUL" alone has never been evidence that anything passed. The gate
 * is: zero `ERROR: Error in` lines.
 *
 * WHAT THE HOST RUNNER CANNOT DO. It is the LOCAL source set: no device, and no ArkTS device
 * kits. `url.URL` from @kit.ArkTS constructs here and then parses NOTHING - host, hostname,
 * pathname and protocol all read empty - and anything that reaches its query side dies with
 * "URLSearchParams is not defined". youtubeChannelGetIdTrailingSlash used to print ERROR on
 * every run for exactly that; it now detects the stub, asserts it, and leaves the real
 * expectations to a runtime that has a parser. THE GATE IS THEREFORE ZERO `ERROR: Error in`
 * LINES, with no exceptions to remember. A check that needs a kit belongs in
 * entry/src/ohosTest; that target needs its testability scaffolding generated before it will
 * build.
 */
import { describe, beforeAll, beforeEach, afterEach, afterAll, it, expect } from '@ohos/hypium';
import { htmlToPlainText } from '../main/ets/pages/DescriptionFragmentPage';
import { toError } from '../main/ets/common/extractor/core/Errors';
import { stringToURL } from '../main/ets/common/extractor/core/Utils';
import { DECLARED_PERMISSIONS } from '../main/ets/common/perm/PermissionHelper';
import { Fragment, parseSidx } from '../main/ets/common/player/SegmentIndex';
import { preferredHeightOf } from '../main/ets/common/settings/PreferredHeight';
import { backTopOf, friendlyPathOf } from '../main/ets/common/file/FilePicker';
import { javaHashMapKeyOrder } from '../main/ets/common/extractor/info/KioskList';
import { resolveItemViewMode } from '../main/ets/common/settings/ViewModeResolver';
import { ItemViewMode } from '../main/ets/components/InfoListAdapter';
import {
  list_view_mode_auto_key, list_view_mode_card_key, list_view_mode_grid_key,
  list_view_mode_list_key
} from '../main/ets/common/prefs/SettingsKeys';
import {
  CaptionBackground, CueStyle, normalizeFontScale, resolveCueStyle, SystemCaptionStyle,
  UserCaptionStyle
} from '../main/ets/common/player/CaptionStyle';
import { AudioTrack, HlsManifestBuilder, VideoTrack } from '../main/ets/common/player/PlayerService';
import { PERSIST_SYSCAP, StoredFile } from '../main/ets/common/file/FileAccess';
import { clampPlaybackRate, RepeatMode } from '../main/ets/common/player/PlayerService';
import {
  AV_LOOP_LIST, AV_LOOP_SEQUENCE, AV_LOOP_SHUFFLE, AV_LOOP_SINGLE, fromLoopMode, toLoopMode
} from '../main/ets/common/player/LoopModeMapping';
import { uniformTypeDescriptor } from '@kit.ArkData';
import {
  shareUtdFor, mimeForStream, pickExternalVideo, pickExternalAudio, ExternalStreamChoice,
  externalVideoChoices
} from '../main/ets/common/share/ShareUtils';
import { VideoStream } from '../main/ets/model/extractor/VideoStream';
import { AudioStream, AudioStreamBuilder } from '../main/ets/model/extractor/AudioStream';
import { DeliveryMethod } from '../main/ets/model/enums/DeliveryMethod';
import { MediaFormat } from '../main/ets/model/enums/MediaFormat';
import { BandcampChannelLinkHandlerFactory }
  from '../main/ets/common/extractor/services/bandcamp/linkHandler/BandcampChannelLinkHandlerFactory';
import { YoutubeChannelLinkHandlerFactory }
  from '../main/ets/common/extractor/services/youtube/linkHandler/YoutubeChannelLinkHandlerFactory';
import { Element, Elements, Jsoup } from '../main/ets/common/extractor/html/Jsoup';
import { moveInstance } from '../main/ets/components/InstanceListAdapter';
import { PeertubeInstance } from '../main/ets/model/extractor/PeertubeInstance';

/**
 * The host runner has no URLSearchParams, and @kit.ArkTS's url.URL builds one while it is being
 * constructed - so without this, every call into stringToURL THROWS here rather than returning
 * something to check. The class is given to the host so the call returns; what it returns is
 * still a stub (every field empty), which the one test that cares asserts for itself.
 *
 * Test-only: entry/src/test is the LOCAL source set, nothing here ships, and a real
 * implementation is left alone if the host ever grows one.
 */
class HostURLSearchParams {
  private pairs: string[][] = [];

  constructor(init?: string) {
    const raw: string = (init ?? '').replace(/^[?]/, '');
    for (const part of raw.split('&')) {
      if (part.length === 0) {
        continue;
      }
      const at: number = part.indexOf('=');
      const key: string = at < 0 ? part : part.substring(0, at);
      const value: string = at < 0 ? '' : part.substring(at + 1);
      this.pairs.push([key.replace(/[+]/g, ' '), value.replace(/[+]/g, ' ')]);
    }
  }

  append(name: string, value: string): void {
    this.pairs.push([name, value]);
  }

  get(name: string): string | null {
    for (const pair of this.pairs) {
      if (pair[0] === name) {
        return pair[1];
      }
    }
    return null;
  }

  getAll(name: string): string[] {
    return this.pairs.filter((pair: string[]): boolean => pair[0] === name)
      .map((pair: string[]): string => pair[1]);
  }

  has(name: string): boolean {
    return this.get(name) !== null;
  }

  delete(name: string): void {
    this.pairs = this.pairs.filter((pair: string[]): boolean => pair[0] !== name);
  }

  set(name: string, value: string): void {
    this.delete(name);
    this.append(name, value);
  }

  toString(): string {
    return this.pairs.map((pair: string[]): string => pair[0] + '=' + pair[1]).join('&');
  }
}

const hostScope: Record<string, Object> = globalThis as object as Record<string, Object>;
if (hostScope.URLSearchParams === undefined) {
  hostScope.URLSearchParams = HostURLSearchParams;
}


/** A HarmonyOS BusinessError as it really arrives: a plain object, NOT an Error. */
class FakeBusinessError {
  code: number = 2300006;
  message: string = 'Could not resolve host';
}

/** Something that is neither: no message to read, so only its fields describe it. */
class Opaque {
  detail: string = 'nothing else to say';
}

export default function localUnitTest() {
  describe('localUnitTest', () => {
    // Defines a test suite. Two parameters are supported: test suite name and test suite function.
    beforeAll(() => {
      // Presets an action, which is performed only once before all test cases of the test suite start.
      // This API supports only one parameter: preset action function.
    });
    beforeEach(() => {
      // Presets an action, which is performed before each unit test case starts.
      // The number of execution times is the same as the number of test cases defined by **it**.
      // This API supports only one parameter: preset action function.
    });
    afterEach(() => {
      // Presets a clear action, which is performed after each unit test case ends.
      // The number of execution times is the same as the number of test cases defined by **it**.
      // This API supports only one parameter: clear action function.
    });
    afterAll(() => {
      // Presets a clear action, which is performed after all test cases of the test suite end.
      // This API supports only one parameter: clear action function.
    });
    it('assertContain', 0, () => {
      // Defines a test case. This API supports three parameters: test case name, filter parameter, and test case function.
      let a = 'abc';
      let b = 'b';
      // Defines a variety of assertion methods, which are used to declare expected boolean conditions.
      expect(a).assertContain(b);
      expect(a).assertEqual(a);
    });

    // The one check the HTML description strip has to pass: tags out, the two line-breaking
    // tags kept as breaks, entities resolved, and escaped markup left alone.
    it('htmlToPlainText', 0, () => {
      expect(htmlToPlainText('<p>Hello <b>world</b><br />see <a href="https://x/y">12:03</a>'
        + ' &amp; more</p>')).assertEqual('Hello world\nsee 12:03 & more\n\n');
      expect(htmlToPlainText('&lt;b&gt;')).assertEqual('<b>');
      // TC-NAV-473: Bandcamp writes the album description with the page's own indentation,
      // which HTML collapses. Uncollapsed, those lines render pushed in from the margin.
      expect(htmlToPlainText('a   b\n            released September 4, 2026'))
        .assertEqual('a b\nreleased September 4, 2026');
      expect(htmlToPlainText('one<br>   two')).assertEqual('one\ntwo');
    });

    // The one check toError() has to pass: a BusinessError is a plain object, so it fails
    // instanceof and stringifies to "[object Object]" - its own fields are the message.
    it('toError', 0, () => {
      expect(toError(new FakeBusinessError()).message)
        .assertEqual('Could not resolve host (2300006)');
      expect(toError(new Error('boom')).message).assertEqual('boom');
      expect(toError('plain string').message).assertEqual('plain string');
      expect(toError(new Opaque()).message).assertEqual('{"detail":"nothing else to say"}');
    });

    // WG-INSTANCE's check for the PeerTube reorder (T-1168/T-1169): the List reports ONE
    // onMove(from, to) on release, so a multi-row drag has to splice - a swap of the two ends
    // would scramble the rows between them. A move to its own index, or off either end, must
    // hand the SAME array back, which is what keeps the page from re-submitting and flagging a
    // save for a drag that went nowhere (T-1169's drag past the top).
    it('moveInstance', 0, () => {
      const list: PeertubeInstance[] = ['a', 'b', 'c', 'd'].map(
        (name: string): PeertubeInstance => new PeertubeInstance(`https://${name}`, name));
      const names: (moved: PeertubeInstance[]) => string =
        (moved: PeertubeInstance[]): string =>
          moved.map((one: PeertubeInstance): string => one.getName()).join('');
      // Down two rows: b and c close up behind the dragged row, they do not swap with it.
      expect(names(moveInstance(list, 0, 2))).assertEqual('bcad');
      // Up two rows, the same drag backwards.
      expect(names(moveInstance(list, 2, 0))).assertEqual('cabd');
      // The whole point of a swap still holding for neighbours.
      expect(names(moveInstance(list, 1, 2))).assertEqual('acbd');
      // Nowhere to go, and past both ends: the same array, so nothing is submitted or saved.
      expect(moveInstance(list, 1, 1) === list).assertTrue();
      expect(moveInstance(list, 0, -1) === list).assertTrue();
      expect(moveInstance(list, 3, 4) === list).assertTrue();
    });

    // WG-LEAVES' check for the share branch, transcribed from T-0925: a single http(s) URL is
    // shared as a link, anything multi-line (an export, an error report) as plain text.
    it('shareUtdFor', 0, () => {
      expect(shareUtdFor('https://youtu.be/x'))
        .assertEqual(uniformTypeDescriptor.UniformDataType.HYPERLINK);
      expect(shareUtdFor('https://a/1\nhttps://a/2'))
        .assertEqual(uniformTypeDescriptor.UniformDataType.PLAIN_TEXT);
    });

    // T-1106: Java's String.split discards trailing empty strings, JS keeps them. The uploader
    // url BandcampPlaylistExtractor hands over always ends in '/', and the four-part split with
    // an empty tail used to be refused as "URL not accepted". The refusals must still refuse.
    it('bandcampChannelOnAcceptUrl', 0, () => {
      const factory: BandcampChannelLinkHandlerFactory =
        BandcampChannelLinkHandlerFactory.getInstance();
      expect(factory.onAcceptUrl('https://zachbenson.bandcamp.com/')).assertTrue();
      expect(factory.onAcceptUrl('https://zachbenson.bandcamp.com')).assertTrue();
      expect(factory.onAcceptUrl('https://zachbenson.bandcamp.com/music/')).assertTrue();
      expect(factory.onAcceptUrl('https://zachbenson.bandcamp.com/nonexistent')).assertFalse();
      expect(factory.onAcceptUrl('https://daily.bandcamp.com/')).assertFalse();
    });

    // The same split divergence in the YouTube channel factory: youtube.com/SomeCustomName/ split
    // to ['SomeCustomName', ''] here, so isCustomShortChannelUrl's length === 1 failed and the url
    // was rejected as "not a channel, a user or a handle URL". channel/ and @handle survived only
    // by reading a fixed index. The excluded segments must still be refused.
    it('youtubeChannelGetIdTrailingSlash', 0, () => {
      // `url.URL` from @kit.ArkTS is a STUB on the host: it constructs, and then every field it
      // should have parsed reads empty - measured, `host=`, `hostname=`, `pathname=`,
      // `protocol=` for `https://www.youtube.com/SomeCustomName/`. (The older
      // "URLSearchParams is not defined" was the same hole one layer down; giving the host that
      // class only moves the failure to the empty fields.) So this check cannot run here and
      // used to print ERROR on every run, which trains a reader to ignore the one line that is
      // supposed to mean something.
      //
      // It is asserted where it can be: the stub is detected and ASSERTED - if a later SDK ever
      // makes url.URL work on the host, this fails and the guard comes out - and the real
      // expectations run wherever the parser does, which is the device.
      if (stringToURL('https://www.youtube.com/SomeCustomName/').host.length === 0) {
        expect(stringToURL('https://www.youtube.com/SomeCustomName/').pathname).assertEqual('');
        return;
      }
      const factory: YoutubeChannelLinkHandlerFactory =
        YoutubeChannelLinkHandlerFactory.getInstance();
      expect(factory.getId('https://www.youtube.com/SomeCustomName/')).assertEqual('SomeCustomName');
      expect(factory.getId('https://www.youtube.com/SomeCustomName')).assertEqual('SomeCustomName');
      expect(factory.getId('https://www.youtube.com/@yourhandle/')).assertEqual('@yourhandle');
      expect(factory.getId('https://www.youtube.com/channel/UCsXVk37bltHxD1rDPwtNM8Q/'))
        .assertEqual('channel/UCsXVk37bltHxD1rDPwtNM8Q');
      expect(factory.getId('https://www.youtube.com/user/Gronkh/')).assertEqual('user/Gronkh');
      expect(factory.onAcceptUrl('https://www.youtube.com/playlist/')).assertFalse();
      expect(factory.onAcceptUrl('https://www.youtube.com/watch/')).assertFalse();
      expect(factory.onAcceptUrl('https://www.youtube.com/')).assertFalse();
    });

    // Bandcamp writes a stray quote into the Radio show caption:
    //   Hosted by <a href="https://bandcamp.com/tinaedwards"_blank">Tina Edwards</a>.
    // findTagEnd treated that quote as opening an attribute value, so the tag's '>' was
    // swallowed, no '>' was ever found, and the whole caption - both anchors - degraded to
    // text. BandcampRadioStreamExtractor.getUploaderName() then found no <a> and threw, which
    // is why the radio detail screen had no uploader name. A quote only opens a value after
    // '=', as in the tokenizer's before-attribute-value state.
    it('jsoupStrayQuoteInTag', 0, () => {
      const caption: string = 'Hosted by <a href="https://bandcamp.com/tinaedwards"_blank">'
        + 'Tina Edwards</a>. Featuring <a href="https://orchestramambointernational.bandcamp.com/'
        + 'album/ap-ntalo">Orchestra Mambo International</a>.';
      const anchors: Elements = Jsoup.parse(caption).getElementsByTag('a');
      expect(anchors.size()).assertEqual(2);
      expect((anchors.first() as Element).text()).assertEqual('Tina Edwards');
      expect(Jsoup.parse(caption).text())
        .assertEqual('Hosted by Tina Edwards. Featuring Orchestra Mambo International.');
      // well-formed attributes keep parsing as before
      expect(Jsoup.parse('a <a href="u">b</a> c').text()).assertEqual('a b c');
    });

    it('isVerifiableCoversPathsAndPersistedUris', 0, () => {
      // A plain sandbox path has always been verifiable.
      const sandbox: StoredFile = new StoredFile('/data/storage/el2/base/f.mp4', 'f.mp4');
      expect(sandbox.isVerifiable()).assertTrue();
      // A picked URI with no persisted grant is NOT verifiable - a failed open there means the
      // grant died, not that the file is gone. This is the case the pruning bug came from.
      const picked: StoredFile = new StoredFile('file://docs/storage/x/f.mp4', 'f.mp4');
      expect(picked.isVerifiable()).assertFalse();
      // The same URI once its grant has been persisted.
      picked.persisted = true;
      expect(picked.isVerifiable()).assertTrue();
    });

    it('canPersistUrisAsksForTheSyscap', 0, () => {
      // The gate must be the syscap, never a device-class guess - the same mistake
      // canPickDirectory() documents in FileAccess.ts.
      expect(PERSIST_SYSCAP)
        .assertEqual('SystemCapability.FileManagement.AppFileService.FolderAuthorization');
    });

    it('mediaPlaylistFollowsTheFragmentList', 0, () => {
      const t: VideoTrack = new VideoTrack();
      t.url = 'https://example/v.mp4';
      t.initStart = 0;
      t.initEnd = 799;
      t.indexStart = 800;
      t.indexEnd = 1599;
      t.contentLength = 10000;
      t.approxDurationMs = 5000;
      const frags: Fragment[] = [
        { offset: 1600, length: 4000, durationMs: 2000 },
        { offset: 5600, length: 4400, durationMs: 3000 }
      ];

      const m: string = HlsManifestBuilder.mediaPlaylistFrom(t, frags);
      // One EXTINF per fragment, with the fragment's OWN duration, not a byte-proportional guess.
      expect(m.includes('#EXTINF:2.000,')).assertTrue();
      expect(m.includes('#EXTINF:3.000,')).assertTrue();
      // Byte ranges come from the sidx, and the first one starts after the index, not after init.
      expect(m.includes('#EXT-X-BYTERANGE:4000@1600')).assertTrue();
      expect(m.includes('#EXT-X-BYTERANGE:4400@5600')).assertTrue();
      // The init segment is still the EXT-X-MAP and still covers initStart..initEnd.
      expect(m.includes('#EXT-X-MAP:URI="https://example/v.mp4",BYTERANGE="800@0"')).assertTrue();
      // TARGETDURATION must cover the longest fragment, or players stall.
      expect(m.includes('#EXT-X-TARGETDURATION:3')).assertTrue();
      expect(m.includes('#EXT-X-ENDLIST')).assertTrue();
    });

    it('synthesisCarriesOnlyFmp4Tracks', 0, () => {
      // The synthesized playlists are fMP4: an avc1 video and an AAC audio track fit, WebM does
      // not. Opus 251 used to be picked because the itag table rates it above AAC 140, and
      // AVPlayer then refused the whole pair with 5400103 DEM_PARSE_ERR.
      const v: VideoTrack = new VideoTrack();
      v.mimeType = 'video/mp4; codecs="avc1.4d401f"';
      expect(HlsManifestBuilder.canCarry(v)).assertTrue();
      v.mimeType = 'video/webm; codecs="vp9"';
      expect(HlsManifestBuilder.canCarry(v)).assertFalse();
      v.mimeType = 'video/mp4; codecs="av01.0.05M.08"';
      expect(HlsManifestBuilder.canCarry(v)).assertFalse();
      const a: AudioTrack = new AudioTrack();
      a.mimeType = 'audio/mp4; codecs="mp4a.40.2"';
      expect(HlsManifestBuilder.canCarry(a)).assertTrue();
      a.mimeType = 'audio/webm; codecs="opus"';
      expect(HlsManifestBuilder.canCarry(a)).assertFalse();
    });

    it('hasSegmentIndexNeedsASaneRange', 0, () => {
      const t: VideoTrack = new VideoTrack();
      t.url = 'https://example/v.mp4';
      t.initStart = 0;
      t.initEnd = 799;
      t.contentLength = 1000000;
      // No index range: today's flat chunking must still be chosen.
      expect(HlsManifestBuilder.hasSegmentIndex(t)).assertFalse();
      // A real one.
      t.indexStart = 800;
      t.indexEnd = 1599;
      expect(HlsManifestBuilder.hasSegmentIndex(t)).assertTrue();
      // Nonsense must not be trusted: an index that ends before it starts, or one that runs past
      // the end of the file.
      t.indexStart = 1600;
      t.indexEnd = 800;
      expect(HlsManifestBuilder.hasSegmentIndex(t)).assertFalse();
      t.indexStart = 800;
      t.indexEnd = 2000000;
      expect(HlsManifestBuilder.hasSegmentIndex(t)).assertFalse();
    });

    it('preferredHeightOfReadsAResolutionPreference', 0, () => {
      // `Default popup resolution` ships as 480p and nothing read it (T-0197): the popup called
      // prepare() with no height at all, so the resolver picked its own rendition.
      expect(preferredHeightOf('480p')).assertEqual(480);
      expect(preferredHeightOf('720p60')).assertEqual(720);
      expect(preferredHeightOf('144p')).assertEqual(144);
    });

    it('preferredHeightOfAsksForNoCeilingWhenItCannot', 0, () => {
      // 0 means "no ceiling" to PlayerService.prepare(), which is what `best_resolution` asks for
      // and also the only safe answer to a value nobody wrote on purpose.
      expect(preferredHeightOf('best_resolution')).assertEqual(0);
      expect(preferredHeightOf('')).assertEqual(0);
      expect(preferredHeightOf('nonsense')).assertEqual(0);
    });

    it('backTopOfStopsAtTheRootTheStartPathLivesIn', 0, () => {
      const sandbox: string = '/data/storage/el2/base/haps/entry/files';
      const marker: string = '/Download/com.hmos.mobile';
      // Inside the sandbox: the sandbox root is the ceiling, whatever depth we start at.
      expect(backTopOf(sandbox + '/pending_downloads', sandbox, marker)).assertEqual(sandbox);
      // Inside the one public root this platform grants: that root, NOT the folder we opened on.
      // This is T-0183/T-0186 - the start path was used as the ceiling, so a row holding a deep
      // folder reopened there with no siblings and a Back that left the picker.
      expect(backTopOf('/storage/Users/currentUser/Download/com.hmos.mobile/Muzikler',
        sandbox, marker)).assertEqual('/storage/Users/currentUser/Download/com.hmos.mobile');
      expect(backTopOf('/storage/Users/currentUser/Download/com.hmos.mobile', sandbox, marker))
        .assertEqual('/storage/Users/currentUser/Download/com.hmos.mobile');
      // Neither root: there is nowhere higher we are allowed to go, so the start path stands.
      expect(backTopOf('/storage/Users/currentUser/Movies', sandbox, marker))
        .assertEqual('/storage/Users/currentUser/Movies');
      // No context yet - init() has not run - must not turn every path into the empty string.
      expect(backTopOf('/storage/Users/currentUser/Movies', '', ''))
        .assertEqual('/storage/Users/currentUser/Movies');
    });

    it('friendlyPathOfNamesThePublicRootInsteadOfTheSystemPath', 0, () => {
      const marker: string = '/Download/com.hmos.mobile';
      const root: string = '/storage/Users/currentUser/Download/com.hmos.mobile';
      expect(friendlyPathOf(root, marker, 'Downloads', 'NewPipe'))
        .assertEqual('Downloads › NewPipe');
      expect(friendlyPathOf(root + '/Muzikler/', marker, 'Downloads', 'NewPipe'))
        .assertEqual('Downloads › NewPipe › Muzikler');
      // Outside the root, or a sibling that only shares its prefix: the path stays as it is.
      expect(friendlyPathOf(root + 'x', marker, 'Downloads', 'NewPipe')).assertEqual(root + 'x');
      expect(friendlyPathOf('/data/storage/el2/base/haps/entry/files', marker, 'Downloads',
        'NewPipe')).assertEqual('/data/storage/el2/base/haps/entry/files');
      expect(friendlyPathOf(root, '', 'Downloads', 'NewPipe')).assertEqual(root);
    });

    it('javaHashMapKeyOrderMatchesTheReferenceDrawer', 0, () => {
      // Read off the reference app's drawer (NewPipe 0.29.1 on the Huawei Android device).
      expect(javaHashMapKeyOrder(['live', 'trending_podcasts_episodes', 'trending_gaming',
        'trending_movies_and_shows', 'trending_music', 'Trending']).join(','))
        .assertEqual('trending_gaming,trending_music,trending_movies_and_shows,' +
          'trending_podcasts_episodes,Trending,live');
      expect(javaHashMapKeyOrder(['conferences', 'recent', 'live']).join(','))
        .assertEqual('recent,conferences,live');
      expect(javaHashMapKeyOrder(['Featured', 'Radio']).join(',')).assertEqual('Featured,Radio');
    });

    it('resolveItemViewModeHonoursAnExplicitChoice', 0, () => {
      expect(resolveItemViewMode(list_view_mode_list_key)).assertEqual(ItemViewMode.LIST);
      expect(resolveItemViewMode(list_view_mode_grid_key)).assertEqual(ItemViewMode.GRID);
      expect(resolveItemViewMode(list_view_mode_card_key)).assertEqual(ItemViewMode.CARD);
    });

    it('resolveItemViewModeDrawsAutoAsAList', 0, () => {
      // Measured on the reference, six verified runs: `auto` drew a LIST in every combination
      // this hardware can produce - tablet_mode auto and on, before and after a restart, at
      // 360 dp and at 720 dp. docs/qa/evidence/tablet/reference-auto.md.
      expect(resolveItemViewMode(list_view_mode_auto_key)).assertEqual(ItemViewMode.LIST);
    });

    it('resolveItemViewModeSurvivesGarbage', 0, () => {
      // An unknown stored value must behave like `auto`, never crash and never silently become
      // CARD. Old installs and hand-edited preferences both produce these.
      expect(resolveItemViewMode('')).assertEqual(ItemViewMode.LIST);
      expect(resolveItemViewMode('nonsense')).assertEqual(ItemViewMode.LIST);
    });

    it('resolveCueStyleFallsBackToWhatShipsToday', 0, () => {
      // No system style, no override: byte-for-byte what VideoDetailFragmentPage draws now.
      const s: CueStyle = resolveCueStyle(null, null);
      expect(s.fontSizeFp).assertEqual(16);
      expect(s.fontColor).assertEqual('#FFFFFF');
      expect(s.backgroundColor).assertEqual('#CC000000');
    });

    it('resolveCueStyleAppliesTheSystemStyle', 0, () => {
      const sys: SystemCaptionStyle =
        { fontScale: 1.5, fontColor: '#FFFF00', backgroundColor: '#80000000' };
      const s: CueStyle = resolveCueStyle(sys, null);
      expect(s.fontSizeFp).assertEqual(24);
      expect(s.fontColor).assertEqual('#FFFF00');
      expect(s.backgroundColor).assertEqual('#80000000');
    });

    it('resolveCueStyleLetsTheUserWin', 0, () => {
      const sys: SystemCaptionStyle =
        { fontScale: 1.5, fontColor: '#FFFF00', backgroundColor: '#80000000' };
      const user: UserCaptionStyle = { scale: 2.0, background: CaptionBackground.NONE };
      const s: CueStyle = resolveCueStyle(sys, user);
      expect(s.fontSizeFp).assertEqual(32);
      // Colour is NOT something the in-app screen offers, so the system keeps it - which is what
      // the reference does.
      expect(s.fontColor).assertEqual('#FFFF00');
      expect(s.backgroundColor).assertEqual('#00000000');
    });

    it('normalizeFontScaleReadsThePlatformsPercentage', 0, () => {
      // Measured on the port handset: the untouched system default reads 100, not 1.0.
      expect(normalizeFontScale(100)).assertEqual(1);
      expect(normalizeFontScale(150)).assertEqual(1.5);
      // Android's own unit still has to survive, in case a device answers in multipliers.
      expect(normalizeFontScale(1.5)).assertEqual(1.5);
      expect(normalizeFontScale(0)).assertEqual(1);
    });

    it('resolveCueStyleClampsNonsense', 0, () => {
      // A scale of 0 would make the cue invisible; a huge one would cover the picture.
      const zero: SystemCaptionStyle = { fontScale: 0, fontColor: '', backgroundColor: '' };
      expect(resolveCueStyle(zero, null).fontSizeFp).assertEqual(16);
      const tiny: UserCaptionStyle = { scale: 0.01, background: CaptionBackground.BLACK };
      expect(resolveCueStyle(null, tiny).fontSizeFp).assertEqual(8);
      const huge: UserCaptionStyle = { scale: 99, background: CaptionBackground.BLACK };
      expect(resolveCueStyle(null, huge).fontSizeFp).assertEqual(48);
      // An empty colour from the system is not a colour - keep the default rather than drawing
      // transparent text on a transparent ground.
      const blank: SystemCaptionStyle = { fontScale: 1, fontColor: '', backgroundColor: '' };
      expect(resolveCueStyle(blank, null).fontColor).assertEqual('#FFFFFF');
      expect(resolveCueStyle(blank, null).backgroundColor).assertEqual('#CC000000');
    });

    it('parseSidxYieldsContiguousFragments', 0, () => {
      // One hand-built version-0 sidx with two references:
      //   ref 1: 1000 bytes, 2000 ticks   ref 2: 1500 bytes, 3000 ticks   timescale 1000
      const total: number = 12 + 20 + 24;
      const buf: ArrayBuffer = new ArrayBuffer(total);
      const dv: DataView = new DataView(buf);
      let p: number = 0;
      dv.setUint32(p, total); p += 4;
      dv.setUint8(p, 0x73); dv.setUint8(p + 1, 0x69);
      dv.setUint8(p + 2, 0x64); dv.setUint8(p + 3, 0x78); p += 4;   // 'sidx'
      dv.setUint32(p, 0); p += 4;                                    // version 0 + flags
      dv.setUint32(p, 1); p += 4;                                    // reference_ID
      dv.setUint32(p, 1000); p += 4;                                 // timescale
      dv.setUint32(p, 0); p += 4;                                    // earliest_presentation_time
      dv.setUint32(p, 0); p += 4;                                    // first_offset
      dv.setUint16(p, 0); p += 2;                                    // reserved
      dv.setUint16(p, 2); p += 2;                                    // reference_count
      dv.setUint32(p, 1000); p += 4; dv.setUint32(p, 2000); p += 4; dv.setUint32(p, 0); p += 4;
      dv.setUint32(p, 1500); p += 4; dv.setUint32(p, 3000); p += 4; dv.setUint32(p, 0);

      // mediaStart 5000: the first fragment begins right after the sidx box.
      const frags: Fragment[] = parseSidx(buf, 0, 5000);
      expect(frags.length).assertEqual(2);
      expect(frags[0].offset).assertEqual(5000);
      expect(frags[0].length).assertEqual(1000);
      expect(frags[0].durationMs).assertEqual(2000);
      // Contiguity is the whole point - fragment 2 starts exactly where fragment 1 ended.
      expect(frags[1].offset).assertEqual(6000);
      expect(frags[1].length).assertEqual(1500);
      expect(frags[1].durationMs).assertEqual(3000);
    });

    it('parseSidxRefusesNonSidxBuffers', 0, () => {
      const buf: ArrayBuffer = new ArrayBuffer(16);
      new DataView(buf).setUint32(0, 16);          // a size, but no 'sidx' type
      expect(parseSidx(buf, 0, 100).length).assertEqual(0);
      expect(parseSidx(new ArrayBuffer(0), 0, 100).length).assertEqual(0);
    });

    it('declaredPermissionsCoverStorage', 0, () => {
      // FILE_ACCESS_PERSIST is what fileShare.persistPermission needs, and it IS granted on the
      // port handset. READ_WRITE_DOWNLOAD_DIRECTORY is deliberately absent: it installs, and
      // requesting it answers authResults=2, "the request is invalid", while the public Download
      // root keeps answering 13900001 (docs/qa/evidence/fix-T-0183b/probe2.txt).
      expect(DECLARED_PERMISSIONS.includes('ohos.permission.FILE_ACCESS_PERSIST')).assertTrue();
      expect(DECLARED_PERMISSIONS.includes('ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY'))
        .assertFalse();
      // The three the port already had must survive the edit.
      expect(DECLARED_PERMISSIONS.includes('ohos.permission.INTERNET')).assertTrue();
      expect(DECLARED_PERMISSIONS.length).assertEqual(4);
    });

    it('toLoopModeFoldsRepeatAndShuffleIntoOneField', 0, () => {
      // AVSession has ONE field. LOOP_MODE_SHUFFLE is a mode, not a flag alongside repeat, so
      // shuffle wins when it is on - and that choice is pinned here, not left to a reader.
      expect(toLoopMode(RepeatMode.OFF, false)).assertEqual(AV_LOOP_SEQUENCE);
      expect(toLoopMode(RepeatMode.ONE, false)).assertEqual(AV_LOOP_SINGLE);
      expect(toLoopMode(RepeatMode.ALL, false)).assertEqual(AV_LOOP_LIST);
      expect(toLoopMode(RepeatMode.OFF, true)).assertEqual(AV_LOOP_SHUFFLE);
      expect(toLoopMode(RepeatMode.ALL, true)).assertEqual(AV_LOOP_SHUFFLE);
    });

    it('fromLoopModeRoundTrips', 0, () => {
      expect(fromLoopMode(AV_LOOP_SEQUENCE).repeat).assertEqual(RepeatMode.OFF);
      expect(fromLoopMode(AV_LOOP_SEQUENCE).shuffled).assertFalse();
      expect(fromLoopMode(AV_LOOP_SINGLE).repeat).assertEqual(RepeatMode.ONE);
      expect(fromLoopMode(AV_LOOP_LIST).repeat).assertEqual(RepeatMode.ALL);
      expect(fromLoopMode(AV_LOOP_SHUFFLE).shuffled).assertTrue();
      // An unknown value from the system shell must not change the player's mode silently.
      expect(fromLoopMode(99).repeat).assertEqual(RepeatMode.OFF);
      expect(fromLoopMode(99).shuffled).assertFalse();
    });

    it('pickExternalVideoTakesTheTallestSelfContainedUrl', 0, () => {
      // T-0212: an external player gets ONE url it can open on its own. A DASH or SS rung is a
      // manifest it would have to assemble, and a non-url stream is bytes this app holds, so
      // neither can be handed over - the tallest progressive url is the answer.
      const v = (res: string, url: string, delivery: DeliveryMethod,
        isUrl: boolean): VideoStream =>
        new VideoStream('id', url, isUrl, MediaFormat.MPEG_4, delivery, res, false, null, null);

      const picked: ExternalStreamChoice | null = pickExternalVideo([
        v('360p', 'https://a/360', DeliveryMethod.PROGRESSIVE_HTTP, true),
        v('1080p', 'https://a/1080', DeliveryMethod.PROGRESSIVE_HTTP, true),
        v('720p', 'https://a/720', DeliveryMethod.PROGRESSIVE_HTTP, true)
      ]);
      expect(picked !== null).assertTrue();
      expect((picked as ExternalStreamChoice).url).assertEqual('https://a/1080');

      // A taller DASH rung must not win over a shorter progressive one.
      const overDash: ExternalStreamChoice | null = pickExternalVideo([
        v('2160p', 'https://a/dash', DeliveryMethod.DASH, true),
        v('480p', 'https://a/480', DeliveryMethod.PROGRESSIVE_HTTP, true)
      ]);
      expect((overDash as ExternalStreamChoice).url).assertEqual('https://a/480');

      // Nothing handable at all is null, which is what raises the no-player dialog.
      expect(pickExternalVideo([]) === null).assertTrue();
      expect(pickExternalVideo([v('720p', '', DeliveryMethod.PROGRESSIVE_HTTP, false)]) === null)
        .assertTrue();
    });

    it('externalVideoChoicesListsEveryHandableRungTallestFirst', 0, () => {
      // T-0212: the source asks which resolution to hand over
      // (select_quality_external_players), so the hand-off needs the whole list, not just the
      // winner - in the order the dialog shows it, tallest first, with the rungs no other player
      // could open already filtered out.
      const v = (res: string, url: string, delivery: DeliveryMethod,
        isUrl: boolean): VideoStream =>
        new VideoStream('id', url, isUrl, MediaFormat.MPEG_4, delivery, res, false, null, null);

      const choices: ExternalStreamChoice[] = externalVideoChoices([
        v('360p', 'https://a/360', DeliveryMethod.PROGRESSIVE_HTTP, true),
        v('1080p', 'https://a/1080', DeliveryMethod.PROGRESSIVE_HTTP, true),
        v('2160p', 'https://a/dash', DeliveryMethod.DASH, true),
        v('720p', 'https://a/720', DeliveryMethod.PROGRESSIVE_HTTP, true),
        v('480p', '', DeliveryMethod.PROGRESSIVE_HTTP, false)
      ]);
      expect(choices.length).assertEqual(3);
      expect(choices[0].label).assertEqual('1080p');
      expect(choices[1].label).assertEqual('720p');
      expect(choices[2].label).assertEqual('360p');
      expect(choices[0].url).assertEqual('https://a/1080');
      // The first row is the one pickExternalVideo would have taken on its own.
      expect((pickExternalVideo([
        v('360p', 'https://a/360', DeliveryMethod.PROGRESSIVE_HTTP, true),
        v('1080p', 'https://a/1080', DeliveryMethod.PROGRESSIVE_HTTP, true)
      ]) as ExternalStreamChoice).url).assertEqual(choices[0].url);
      expect(externalVideoChoices([]).length).assertEqual(0);

      // The source's dialog lists the video-only rungs too - that is what "Removes audio at some
      // resolutions" on the setting means - so this is handed both lists at once. One rung per
      // resolution: the muxed one comes first and wins, because it still carries sound.
      const merged: ExternalStreamChoice[] = externalVideoChoices([
        v('360p', 'https://muxed/360', DeliveryMethod.PROGRESSIVE_HTTP, true),
        v('360p', 'https://videoonly/360', DeliveryMethod.PROGRESSIVE_HTTP, true),
        v('1080p', 'https://videoonly/1080', DeliveryMethod.PROGRESSIVE_HTTP, true)
      ]);
      expect(merged.length).assertEqual(2);
      expect(merged[0].label).assertEqual('1080p');
      expect(merged[1].url).assertEqual('https://muxed/360');
    });

    it('pickExternalAudioTakesTheLoudestSelfContainedUrl', 0, () => {
      const a = (bitrate: number, url: string, delivery: DeliveryMethod): AudioStream =>
        new AudioStreamBuilder()
          .setId('id')
          .setContent(url, true)
          .setMediaFormat(MediaFormat.M4A)
          .setDeliveryMethod(delivery)
          .setAverageBitrate(bitrate)
          .build();

      const picked: ExternalStreamChoice | null = pickExternalAudio([
        a(128, 'https://a/128', DeliveryMethod.PROGRESSIVE_HTTP),
        a(256, 'https://a/256', DeliveryMethod.PROGRESSIVE_HTTP)
      ]);
      expect((picked as ExternalStreamChoice).url).assertEqual('https://a/256');
      expect(pickExternalAudio([a(320, 'https://a/dash', DeliveryMethod.DASH)]) === null)
        .assertTrue();
    });

    it('mimeForStreamNamesAPlayableType', 0, () => {
      // A video stream must not be offered as a web page - a bare https uri with no type is a
      // web link, which is exactly why the browser took every hand-off.
      expect(mimeForStream(MediaFormat.MPEG_4, false)).assertEqual('video/mp4');
      expect(mimeForStream(MediaFormat.WEBM, false)).assertEqual('video/webm');
      expect(mimeForStream(MediaFormat.M4A, true)).assertEqual('audio/mp4');
      expect(mimeForStream(MediaFormat.MP3, true)).assertEqual('audio/mpeg');
      // audio/opus, which is what MediaFormat.OPUS carries. The plan guessed audio/ogg; the
      // source is the authority and OGG is a separate constant with that type.
      expect(mimeForStream(MediaFormat.OPUS, true)).assertEqual('audio/opus');
      expect(mimeForStream(MediaFormat.OGG, true)).assertEqual('audio/ogg');
      // No format still has to say video or audio - a wildcard is better than nothing, and far
      // better than no type at all.
      expect(mimeForStream(null, false)).assertEqual('video/*');
      expect(mimeForStream(null, true)).assertEqual('audio/*');
      // A format of the wrong KIND degrades too: handing a player text/vtt as a video would be
      // worse than handing it a wildcard.
      expect(mimeForStream(MediaFormat.VTT, false)).assertEqual('video/*');
      expect(mimeForStream(MediaFormat.MPEG_4, true)).assertEqual('audio/*');
    });

    it('clampPlaybackRateHoldsTheSdkRange', 0, () => {
      // The SDK's own range: 0.125 ~ 4, and 5400108 outside it. Clamp rather than throw - the
      // dialog's slider should never be able to stop playback.
      expect(clampPlaybackRate(1.1)).assertEqual(1.1);
      expect(clampPlaybackRate(0.125)).assertEqual(0.125);
      expect(clampPlaybackRate(4)).assertEqual(4);
      // 0.1 is what the card asks for and the platform floor is 0.125 - a one-step ceiling that
      // is NOT the pitch ceiling and must not be reported as one. Measured on the handset: below
      // 0.125 setPlaybackRate does not throw, it is silently ignored, so clamping is the only
      // thing that keeps the readout honest (docs/qa/evidence/fix-T-0133b/rate-probe.txt).
      expect(clampPlaybackRate(0.1)).assertEqual(0.125);
      expect(clampPlaybackRate(0)).assertEqual(0.125);
      expect(clampPlaybackRate(99)).assertEqual(4);
      // NaN from a slider mid-drag must not reach the player.
      expect(clampPlaybackRate(Number.NaN)).assertEqual(1);
    });
  });
}