/*
 * Port of app/src/main/java/org/schabi/newpipe/error/ErrorInfo.kt - the classification of one
 * error into a user-facing message plus the "can this be reported / retried" decisions.
 *
 * Two things change shape:
 *   - `@Parcelize`/`Parcelable` has no analogue: an ErrorInfo travels in-process here, and to a
 *     routed page as its JSON record (toJson/fromJson).
 *   - `ErrorMessage(@StringRes stringRes, vararg formatArgs)` becomes a string-resource NAME plus
 *     its arguments, resolved through svc_localization (`getStringByNameSync`), because the
 *     migrated resources are keyed by the source's own `<string name=...>`.
 *   - The ExoPlayer branches (ExoPlaybackException / HttpDataSource.InvalidResponseCodeException /
 *     Loader.UnexpectedLoaderException) are gone with ExoPlayer itself (contract section 2.5,
 *     AVPlayer substitution). PlayerError below carries the same three outcomes the source
 *     produced - a 403 for YouTube vs. any service, a bad status, and the source/unexpected/
 *     unrecoverable split - so a playback failure still reaches the same string.
 */

import { UserAction } from '../enums/UserAction';
import {
  AccountTerminatedException,
  AgeRestrictedContentException,
  ContentNotAvailableException,
  ContentNotSupportedException,
  ExtractionException,
  GeographicRestrictionException,
  IOException,
  PaidContentException,
  PrivateContentException,
  ReCaptchaException,
  SignInConfirmNotBotException,
  SoundCloudGoPlusContentException,
  UnsupportedContentInCountryException,
  YoutubeMusicPremiumContentException
} from '../../common/extractor/exceptions/Exceptions';

/** ErrorInfo.SERVICE_NONE, verbatim. */
export const SERVICE_NONE: string = '<unknown_service>';
/** ErrorInfo.YOUTUBE_IP_BAN_FAQ_URL, verbatim. */
export const YOUTUBE_IP_BAN_FAQ_URL: string = 'https://newpipe.net/FAQ/#ip-banned-youtube';

/** YouTube's serviceId in ServiceList - the one branch getMessage() needs it for. */
const YOUTUBE_SERVICE_ID: number = 0;

/**
 * Port of ErrorInfo.Companion.ErrorMessage: a string resource plus its format arguments.
 * `stringName` is the source's `<string name=...>`, which the assets pass carried over verbatim.
 */
export class ErrorMessage {
  stringName: string = '';
  formatArgs: string[] = [];

  constructor(stringName: string, formatArgs: string[] = []) {
    this.stringName = stringName;
    this.formatArgs = formatArgs;
  }
}

/**
 * The AVPlayer-side replacement for ExoPlaybackException. Playback failures are raised with one
 * of these so ErrorInfo can classify them exactly as the source classified ExoPlayer's.
 */
export class PlayerError extends Error {
  /** HTTP status when the failure came from the media request, else 0. */
  responseCode: number = 0;
  /** true when the failure is in the media source (bad url, unreadable stream). */
  isSourceError: boolean = false;
  /** true when the failure is unexpected but the player can recover. */
  isRecoverable: boolean = false;

  constructor(message: string, responseCode: number = 0, isSourceError: boolean = false,
    isRecoverable: boolean = false) {
    super(message);
    this.name = 'PlayerError';
    this.responseCode = responseCode;
    this.isSourceError = isSourceError;
    this.isRecoverable = isRecoverable;
  }
}

/** Service names by id, for the `getServiceName()` the source reads off ServiceList. */
const SERVICE_NAMES: Map<number, string> = new Map<number, string>([
  [0, 'YouTube'],
  [1, 'SoundCloud'],
  [2, 'media.ccc.de'],
  [3, 'PeerTube'],
  [4, 'Bandcamp']
]);

export function getServiceName(serviceId: number | null): string {
  if (serviceId === null) {
    return SERVICE_NONE;
  }
  const name: string | undefined = SERVICE_NAMES.get(serviceId);
  return name === undefined ? SERVICE_NONE : name;
}

/** Port of isContentSurelyNotAvailable(ContentNotAvailableException). */
export function isContentSurelyNotAvailable(e: ContentNotAvailableException): boolean {
  return e instanceof AccountTerminatedException
    || e instanceof AgeRestrictedContentException
    || e instanceof GeographicRestrictionException
    || e instanceof PaidContentException
    || e instanceof PrivateContentException
    || e instanceof SoundCloudGoPlusContentException
    || e instanceof UnsupportedContentInCountryException
    || e instanceof YoutubeMusicPremiumContentException;
}

/** Port of `Throwable.isNetworkRelated` (ktx/ExceptionUtils.kt). */
function isNetworkRelated(throwable: Error): boolean {
  return throwable instanceof IOException;
}

/** Port of isReportable(Throwable?). */
export function isReportable(throwable: Error | null): boolean {
  if (throwable === null) {
    // manually built error: likely important, so reportable
    return true;
  }
  if (throwable instanceof ContentNotAvailableException) {
    return !isContentSurelyNotAvailable(throwable);
  }
  if (throwable instanceof ContentNotSupportedException) {
    return false;
  }
  // ErrorPanelHelper gates the report action on `!throwable.isNetworkRelated`, so ANY network
  // failure is unreportable - not just the one whose message happens to read "Unknown host".
  // Device-checked: with Wi-Fi off the reference build shows only RETRY and OPEN IN BROWSER,
  // while this port offered REPORT as well, because the narrower string match let a connect
  // failure through. isNetworkRelated() is the same test the panel's message already uses.
  if (isNetworkRelated(throwable)) {
    return false;
  }
  return true;
}

/** Port of isRetryable(Throwable?). */
export function isRetryable(throwable: Error | null): boolean {
  if (throwable instanceof ContentNotAvailableException) {
    return !isContentSurelyNotAvailable(throwable);
  }
  if (throwable instanceof ContentNotSupportedException) {
    return false;
  }
  return true;
}

/** Port of ErrorInfo.Companion.getMessage(throwable, action, serviceId). */
export function getErrorMessage(throwable: Error | null, action: UserAction | null,
  serviceId: number | null): ErrorMessage {
  // player exceptions first: some are IO failures, so they must precede isNetworkRelated
  if (throwable instanceof PlayerError) {
    if (throwable.responseCode === 403) {
      return serviceId === YOUTUBE_SERVICE_ID
        ? new ErrorMessage('youtube_player_http_403')
        : new ErrorMessage('player_http_403');
    }
    if (throwable.responseCode !== 0) {
      return new ErrorMessage('player_http_invalid_status', [`${throwable.responseCode}`]);
    }
    if (throwable.isSourceError) {
      return new ErrorMessage('player_stream_failure');
    }
    if (throwable.isRecoverable) {
      return new ErrorMessage('player_recoverable_failure');
    }
    return new ErrorMessage('player_unrecoverable_failure');
  }

  // content not available exceptions
  if (throwable instanceof AccountTerminatedException) {
    const reason: string = throwable.message;
    if (reason.length > 0) {
      return new ErrorMessage('account_terminated_service_provides_reason',
        [getServiceName(serviceId), reason]);
    }
    return new ErrorMessage('account_terminated');
  }
  if (throwable instanceof AgeRestrictedContentException) {
    return new ErrorMessage('restricted_video_no_stream');
  }
  if (throwable instanceof GeographicRestrictionException) {
    return new ErrorMessage('georestricted_content');
  }
  if (throwable instanceof PaidContentException) {
    return new ErrorMessage('paid_content');
  }
  if (throwable instanceof PrivateContentException) {
    return new ErrorMessage('private_content');
  }
  if (throwable instanceof SoundCloudGoPlusContentException) {
    return new ErrorMessage('soundcloud_go_plus_content');
  }
  if (throwable instanceof UnsupportedContentInCountryException) {
    return new ErrorMessage('unsupported_content_in_country');
  }
  if (throwable instanceof YoutubeMusicPremiumContentException) {
    return new ErrorMessage('youtube_music_premium_content');
  }
  if (throwable instanceof SignInConfirmNotBotException) {
    return new ErrorMessage('sign_in_confirm_not_bot_error',
      [getServiceName(serviceId), YOUTUBE_IP_BAN_FAQ_URL]);
  }
  if (throwable instanceof ContentNotAvailableException) {
    return new ErrorMessage('content_not_available');
  }

  // other extractor exceptions
  if (throwable instanceof ContentNotSupportedException) {
    return new ErrorMessage('content_not_supported');
  }
  // ReCaptchas are handled in a special way anyway
  if (throwable instanceof ReCaptchaException) {
    return new ErrorMessage('recaptcha_request_toast');
  }
  // test this at the end: many exceptions could be a subclass of IOException
  if (throwable !== null && isNetworkRelated(throwable)) {
    return new ErrorMessage('network_error');
  }
  // an extraction exception unrelated to the network is likely a parsing issue
  if (throwable instanceof ExtractionException) {
    return new ErrorMessage('parsing_error');
  }

  // user actions, in case the exception is null or unrecognizable
  if (action === UserAction.UI_ERROR) {
    return new ErrorMessage('app_ui_crash');
  }
  if (action === UserAction.REQUESTED_COMMENTS) {
    return new ErrorMessage('error_unable_to_load_comments');
  }
  if (action === UserAction.SUBSCRIPTION_CHANGE) {
    return new ErrorMessage('subscription_change_failed');
  }
  if (action === UserAction.SUBSCRIPTION_UPDATE) {
    return new ErrorMessage('subscription_update_failed');
  }
  if (action === UserAction.LOAD_IMAGE) {
    return new ErrorMessage('could_not_load_thumbnails');
  }
  if (action === UserAction.DOWNLOAD_OPEN_DIALOG) {
    return new ErrorMessage('could_not_setup_download_menu');
  }
  return new ErrorMessage('error_snackbar_message');
}

/** The JSON record an ErrorInfo travels to the error page as. */
export interface ErrorInfoJson {
  stackTraces: string[];
  userAction: UserAction;
  request: string;
  serviceId: number | null;
  messageName: string;
  messageArgs: string[];
  isReportable: boolean;
  isRetryable: boolean;
  recaptchaUrl: string | null;
  openInBrowserUrl: string | null;
}

export class ErrorInfo {
  stackTraces: string[] = [];
  userAction: UserAction = UserAction.SOMETHING_ELSE;
  request: string = '';
  serviceId: number | null = null;
  message: ErrorMessage = new ErrorMessage('error_snackbar_message');
  /** A report button is shown for this error. */
  isReportable: boolean = true;
  /** The process causing this error can be retried. */
  isRetryable: boolean = true;
  /** Set when the exception was a ReCaptchaException: the URL that solves the challenge. */
  recaptchaUrl: string | null = null;
  /** Set when the resource can alternatively be opened in a browser. */
  openInBrowserUrl: string | null = null;

  getServiceName(): string {
    return getServiceName(this.serviceId);
  }

  /** Port of the primary `ErrorInfo(throwable, userAction, request, serviceId, url)`. */
  static fromThrowable(throwable: Error, userAction: UserAction, request: string,
    serviceId: number | null = null, openInBrowserUrl: string | null = null): ErrorInfo {
    const info: ErrorInfo = new ErrorInfo();
    info.stackTraces = ErrorInfo.throwableToStringList(throwable);
    info.userAction = userAction;
    info.request = request;
    info.serviceId = serviceId;
    info.message = getErrorMessage(throwable, userAction, serviceId);
    info.isReportable = isReportable(throwable);
    info.isRetryable = isRetryable(throwable);
    info.recaptchaUrl = throwable instanceof ReCaptchaException ? throwable.getUrl() : null;
    info.openInBrowserUrl = openInBrowserUrl;
    return info;
  }

  /** Port of `ErrorInfo(throwables, userAction, request, serviceId, url)`. */
  static fromThrowables(throwables: Error[], userAction: UserAction, request: string,
    serviceId: number | null = null, openInBrowserUrl: string | null = null): ErrorInfo {
    const info: ErrorInfo = new ErrorInfo();
    info.stackTraces = ErrorInfo.throwableListToStringList(throwables);
    info.userAction = userAction;
    info.request = request;
    info.serviceId = serviceId;
    info.message = getErrorMessage(throwables.length === 0 ? null : throwables[0], userAction,
      serviceId);

    let anyReportable: boolean = false;
    let anyRetryable: boolean = false;
    let recaptchaUrl: string | null = null;
    for (const t of throwables) {
      if (isReportable(t)) {
        anyReportable = true;
      }
      if (isRetryable(t)) {
        anyRetryable = true;
      }
      if (recaptchaUrl === null && t instanceof ReCaptchaException) {
        recaptchaUrl = t.getUrl();
      }
    }
    info.isReportable = anyReportable;
    info.isRetryable = throwables.length === 0 || anyRetryable;
    info.recaptchaUrl = recaptchaUrl;
    info.openInBrowserUrl = openInBrowserUrl;
    return info;
  }

  /** Port of the manual constructor used when no throwable is available. */
  static fromMessage(stackTraces: string[], userAction: UserAction, request: string,
    serviceId: number | null, messageName: string): ErrorInfo {
    const info: ErrorInfo = new ErrorInfo();
    info.stackTraces = stackTraces;
    info.userAction = userAction;
    info.request = request;
    info.serviceId = serviceId;
    info.message = new ErrorMessage(messageName);
    info.isReportable = true;
    info.isRetryable = false;
    info.recaptchaUrl = null;
    info.openInBrowserUrl = null;
    return info;
  }

  static throwableToStringList(throwable: Error): string[] {
    return [`${throwable.name}: ${throwable.message}\n${throwable.stack}`];
  }

  static throwableListToStringList(throwables: Error[]): string[] {
    const out: string[] = [];
    for (const t of throwables) {
      out.push(`${t.name}: ${t.message}\n${t.stack}`);
    }
    return out;
  }

  toJson(): ErrorInfoJson {
    const out: ErrorInfoJson = {
      stackTraces: this.stackTraces,
      userAction: this.userAction,
      request: this.request,
      serviceId: this.serviceId,
      messageName: this.message.stringName,
      messageArgs: this.message.formatArgs,
      isReportable: this.isReportable,
      isRetryable: this.isRetryable,
      recaptchaUrl: this.recaptchaUrl,
      openInBrowserUrl: this.openInBrowserUrl
    };
    return out;
  }

  static fromJson(raw: ErrorInfoJson): ErrorInfo {
    const info: ErrorInfo = new ErrorInfo();
    info.stackTraces = raw.stackTraces;
    info.userAction = raw.userAction;
    info.request = raw.request;
    info.serviceId = raw.serviceId;
    info.message = new ErrorMessage(raw.messageName, raw.messageArgs);
    info.isReportable = raw.isReportable;
    info.isRetryable = raw.isRetryable;
    info.recaptchaUrl = raw.recaptchaUrl;
    info.openInBrowserUrl = raw.openInBrowserUrl;
    return info;
  }
}
