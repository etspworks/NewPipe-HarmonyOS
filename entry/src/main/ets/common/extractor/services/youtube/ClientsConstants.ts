/*
 * Port of org.schabi.newpipe.extractor.services.youtube.ClientsConstants
 * (NewPipeExtractor v0.26.5).
 *
 * Package-private in Java; exported here because ArkTS has no package visibility. Every value is
 * the source's, verbatim — these are the InnerTube client identities YouTube checks, so a
 * "modernised" version string breaks playback rather than improving it.
 */

// Common client fields

export const DESKTOP_CLIENT_PLATFORM: string = 'DESKTOP';
export const MOBILE_CLIENT_PLATFORM: string = 'MOBILE';
export const WATCH_CLIENT_SCREEN: string = 'WATCH';
export const EMBED_CLIENT_SCREEN: string = 'EMBED';

// WEB (YouTube desktop) client fields

export const WEB_CLIENT_ID: string = '1';
export const WEB_CLIENT_NAME: string = 'WEB';
/** Last fallback when extracting the real WEB client version failed. */
export const WEB_HARDCODED_CLIENT_VERSION: string = '2.20260120.01.00';

// WEB_REMIX (YouTube Music) client fields

export const WEB_REMIX_CLIENT_ID: string = '67';
export const WEB_REMIX_CLIENT_NAME: string = 'WEB_REMIX';
export const WEB_REMIX_HARDCODED_CLIENT_VERSION: string = '1.20260121.03.00';

// WEB_EMBEDDED_PLAYER (YouTube embeds)

export const WEB_EMBEDDED_CLIENT_ID: string = '56';
export const WEB_EMBEDDED_CLIENT_NAME: string = 'WEB_EMBEDDED_PLAYER';
export const WEB_EMBEDDED_CLIENT_VERSION: string = '1.20260122.01.00';

// WEB_MUSIC_ANALYTICS (YouTube charts)

export const WEB_MUSIC_ANALYTICS_CLIENT_ID: string = '31';
export const WEB_MUSIC_ANALYTICS_CLIENT_NAME: string = 'WEB_MUSIC_ANALYTICS';
export const WEB_MUSIC_ANALYTICS_CLIENT_VERSION: string = '2.0';

// IOS (iOS YouTube app) client fields

export const IOS_CLIENT_ID: string = '5';
export const IOS_CLIENT_NAME: string = 'IOS';
/** Latest release version of the iOS app; see the App Store "What's New" section. */
export const IOS_CLIENT_VERSION: string = '21.03.2';
/** iPhone 15 Pro Max machine id — what gets 60fps out of the IOS client. */
export const IOS_DEVICE_MODEL: string = 'iPhone16,2';
/** "iOS major.minor.patch.build" for the `osVersion` field of JSON POST requests. */
export const IOS_OS_VERSION: string = '18.7.2.22H124';
/** The same version, spelled for the HTTP user agent. */
export const IOS_USER_AGENT_VERSION: string = '18_7_2';

// ANDROID (Android YouTube app) client fields

export const ANDROID_CLIENT_ID: string = '3';
export const ANDROID_CLIENT_NAME: string = 'ANDROID';
/** Latest release version of the Android app, as published on APKMirror. */
export const ANDROID_CLIENT_VERSION: string = '21.03.36';

// visionOS client fields

export const VISIONOS_CLIENT_ID: string = '101';
export const VISIONOS_CLIENT_NAME: string = 'VISIONOS';
export const VISIONOS_CLIENT_VERSION: string = '1.02';
export const VISIONOS_DEVICE_MODEL: string = 'RealityDevice14,1';
export const VISIONOS_VERSION: string = '25.6.0.23O471';
export const VISIONOS_USER_AGENT_VERSION: string = '25_6_0';
