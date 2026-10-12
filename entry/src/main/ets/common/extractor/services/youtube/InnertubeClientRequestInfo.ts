/*
 * Port of org.schabi.newpipe.extractor.services.youtube.InnertubeClientRequestInfo
 * (NewPipeExtractor v0.26.5).
 *
 * The identity one InnerTube request claims: which client, which device. ClientInfo and
 * DeviceInfo are nested static classes in Java; ArkTS has no nested classes, so they are
 * top-level here and the private constructors become public (the `of*Client()` factories are
 * still the only intended entry points).
 */

import {
  ANDROID_CLIENT_ID,
  ANDROID_CLIENT_NAME,
  ANDROID_CLIENT_VERSION,
  DESKTOP_CLIENT_PLATFORM,
  EMBED_CLIENT_SCREEN,
  IOS_CLIENT_ID,
  IOS_CLIENT_NAME,
  IOS_CLIENT_VERSION,
  IOS_DEVICE_MODEL,
  IOS_OS_VERSION,
  MOBILE_CLIENT_PLATFORM,
  VISIONOS_CLIENT_ID,
  VISIONOS_CLIENT_NAME,
  VISIONOS_CLIENT_VERSION,
  VISIONOS_DEVICE_MODEL,
  VISIONOS_VERSION,
  WATCH_CLIENT_SCREEN,
  WEB_CLIENT_ID,
  WEB_CLIENT_NAME,
  WEB_EMBEDDED_CLIENT_ID,
  WEB_EMBEDDED_CLIENT_NAME,
  WEB_EMBEDDED_CLIENT_VERSION,
  WEB_HARDCODED_CLIENT_VERSION,
  WEB_MUSIC_ANALYTICS_CLIENT_ID,
  WEB_MUSIC_ANALYTICS_CLIENT_NAME,
  WEB_MUSIC_ANALYTICS_CLIENT_VERSION
} from './ClientsConstants';

export class ClientInfo {
  clientName: string;
  clientVersion: string;
  clientId: string;
  clientScreen: string | null;
  visitorData: string | null;

  constructor(clientName: string, clientVersion: string, clientId: string,
    clientScreen: string | null, visitorData: string | null) {
    this.clientName = clientName;
    this.clientVersion = clientVersion;
    this.clientId = clientId;
    this.clientScreen = clientScreen;
    this.visitorData = visitorData;
  }
}

export class DeviceInfo {
  platform: string | null;
  deviceMake: string | null;
  deviceModel: string | null;
  osName: string | null;
  osVersion: string | null;
  androidSdkVersion: number;

  constructor(platform: string | null, deviceMake: string | null, deviceModel: string | null,
    osName: string | null, osVersion: string | null, androidSdkVersion: number) {
    this.platform = platform;
    this.deviceMake = deviceMake;
    this.deviceModel = deviceModel;
    this.osName = osName;
    this.osVersion = osVersion;
    this.androidSdkVersion = androidSdkVersion;
  }
}

export class InnertubeClientRequestInfo {
  clientInfo: ClientInfo;
  deviceInfo: DeviceInfo;

  constructor(clientInfo: ClientInfo, deviceInfo: DeviceInfo) {
    this.clientInfo = clientInfo;
    this.deviceInfo = deviceInfo;
  }

  static ofWebClient(): InnertubeClientRequestInfo {
    return new InnertubeClientRequestInfo(
      new ClientInfo(WEB_CLIENT_NAME, WEB_HARDCODED_CLIENT_VERSION, WEB_CLIENT_ID,
        WATCH_CLIENT_SCREEN, null),
      new DeviceInfo(DESKTOP_CLIENT_PLATFORM, null, null, null, null, -1));
  }

  static ofWebEmbeddedPlayerClient(): InnertubeClientRequestInfo {
    return new InnertubeClientRequestInfo(
      new ClientInfo(WEB_EMBEDDED_CLIENT_NAME, WEB_EMBEDDED_CLIENT_VERSION,
        WEB_EMBEDDED_CLIENT_ID, EMBED_CLIENT_SCREEN, null),
      new DeviceInfo(DESKTOP_CLIENT_PLATFORM, null, null, null, null, -1));
  }

  static ofWebMusicAnalyticsChartsClient(): InnertubeClientRequestInfo {
    return new InnertubeClientRequestInfo(
      new ClientInfo(WEB_MUSIC_ANALYTICS_CLIENT_NAME, WEB_MUSIC_ANALYTICS_CLIENT_VERSION,
        WEB_MUSIC_ANALYTICS_CLIENT_ID, null, null),
      new DeviceInfo(null, null, null, null, null, -1));
  }

  static ofAndroidClient(): InnertubeClientRequestInfo {
    return new InnertubeClientRequestInfo(
      new ClientInfo(ANDROID_CLIENT_NAME, ANDROID_CLIENT_VERSION, ANDROID_CLIENT_ID,
        WATCH_CLIENT_SCREEN, null),
      new DeviceInfo(MOBILE_CLIENT_PLATFORM, null, null, 'Android', '16', 36));
  }

  static ofIosClient(): InnertubeClientRequestInfo {
    return new InnertubeClientRequestInfo(
      new ClientInfo(IOS_CLIENT_NAME, IOS_CLIENT_VERSION, IOS_CLIENT_ID, WATCH_CLIENT_SCREEN,
        null),
      new DeviceInfo(MOBILE_CLIENT_PLATFORM, 'Apple', IOS_DEVICE_MODEL, 'iOS', IOS_OS_VERSION,
        -1));
  }

  static ofVisionOsClient(): InnertubeClientRequestInfo {
    return new InnertubeClientRequestInfo(
      new ClientInfo(VISIONOS_CLIENT_NAME, VISIONOS_CLIENT_VERSION, VISIONOS_CLIENT_ID,
        WATCH_CLIENT_SCREEN, null),
      new DeviceInfo(MOBILE_CLIENT_PLATFORM, 'Apple', VISIONOS_DEVICE_MODEL, 'visionOS',
        VISIONOS_VERSION, -1));
  }
}
