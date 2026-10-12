/*
 * Port of org.schabi.newpipe.extractor.exceptions (NewPipeExtractor v0.26.5, vendored at
 * input/source/NewPipeExtractor). The hierarchy is reproduced exactly as in the source, because
 * the app branches on the concrete type: ReCaptchaException drives the reCaptcha screen, and each
 * ContentNotAvailableException subclass drives a different "why you cannot watch this" message.
 *
 * Java's Throwable.getCause() is kept as getCause(); ArkTS's own Error has no portable `cause`
 * field, so the chained error is stored explicitly.
 */

export class ExtractionException extends Error {
  private readonly causeError: Error | null;

  constructor(message: string, cause: Error | null = null) {
    super(message);
    this.name = 'ExtractionException';
    this.causeError = cause;
  }

  getCause(): Error | null {
    return this.causeError;
  }
}

export class ParsingException extends ExtractionException {
  constructor(message: string, cause: Error | null = null) {
    super(message, cause);
    this.name = 'ParsingException';
  }
}

/**
 * Signalled when the service answered HTTP 429. Carries the URL the challenge must be solved
 * against - the reCaptcha screen loads exactly this URL in a WebView and stores the cookies it
 * gets back (see svc_downloader).
 */
export class ReCaptchaException extends ExtractionException {
  private readonly url: string;

  constructor(message: string, url: string) {
    super(message);
    this.name = 'ReCaptchaException';
    this.url = url;
  }

  getUrl(): string {
    return this.url;
  }
}

export class ContentNotAvailableException extends ParsingException {
  constructor(message: string, cause: Error | null = null) {
    super(message, cause);
    this.name = 'ContentNotAvailableException';
  }
}

export class ContentNotSupportedException extends ParsingException {
  constructor(message: string, cause: Error | null = null) {
    super(message, cause);
    this.name = 'ContentNotSupportedException';
  }
}

export class FoundAdException extends ParsingException {
  constructor(message: string, cause: Error | null = null) {
    super(message, cause);
    this.name = 'FoundAdException';
  }
}

export class SignInConfirmNotBotException extends ParsingException {
  constructor(message: string) {
    super(message);
    this.name = 'SignInConfirmNotBotException';
  }
}

export enum AccountTerminatedReason {
  UNKNOWN,
  VIOLATION
}

export class AccountTerminatedException extends ContentNotAvailableException {
  private readonly reason: AccountTerminatedReason;

  constructor(message: string, reason: AccountTerminatedReason = AccountTerminatedReason.UNKNOWN,
    cause: Error | null = null) {
    super(message, cause);
    this.name = 'AccountTerminatedException';
    this.reason = reason;
  }

  getReason(): AccountTerminatedReason {
    return this.reason;
  }
}

export class AgeRestrictedContentException extends ContentNotAvailableException {
  constructor(message: string, cause: Error | null = null) {
    super(message, cause);
    this.name = 'AgeRestrictedContentException';
  }
}

export class GeographicRestrictionException extends ContentNotAvailableException {
  constructor(message: string, cause: Error | null = null) {
    super(message, cause);
    this.name = 'GeographicRestrictionException';
  }
}

export class PaidContentException extends ContentNotAvailableException {
  constructor(message: string, cause: Error | null = null) {
    super(message, cause);
    this.name = 'PaidContentException';
  }
}

export class PrivateContentException extends ContentNotAvailableException {
  constructor(message: string, cause: Error | null = null) {
    super(message, cause);
    this.name = 'PrivateContentException';
  }
}

export class SoundCloudGoPlusContentException extends ContentNotAvailableException {
  constructor(cause: Error | null = null) {
    super('This track is a SoundCloud Go+ track', cause);
    this.name = 'SoundCloudGoPlusContentException';
  }
}

export class UnsupportedContentInCountryException extends ContentNotAvailableException {
  constructor(message: string, cause: Error | null = null) {
    super(message, cause);
    this.name = 'UnsupportedContentInCountryException';
  }
}

export class YoutubeMusicPremiumContentException extends ContentNotAvailableException {
  constructor(cause: Error | null = null) {
    super('This video is a YouTube Music Premium video', cause);
    this.name = 'YoutubeMusicPremiumContentException';
  }
}

/** Port of UnsupportedTabException (extends UnsupportedOperationException in the source). */
export class UnsupportedTabException extends Error {
  constructor(unsupportedTab: string) {
    super(`Unsupported tab ${unsupportedTab}`);
    this.name = 'UnsupportedTabException';
  }
}

/**
 * Java's checked java.io.IOException, which the Downloader contract throws alongside
 * ReCaptchaException. ArkTS has no checked exceptions, so it is a plain Error subclass and
 * callers distinguish it with `instanceof`.
 */
export class IOException extends Error {
  private readonly causeError: Error | null;

  constructor(message: string, cause: Error | null = null) {
    super(message);
    this.name = 'IOException';
    this.causeError = cause;
  }

  getCause(): Error | null {
    return this.causeError;
  }
}
