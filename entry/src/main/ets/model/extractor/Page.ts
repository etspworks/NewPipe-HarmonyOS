/*
 * Port of org.schabi.newpipe.extractor.Page (NewPipeExtractor v0.26.5).
 *
 * Java declares eight constructors; ArkTS has no overloading, so there is one constructor with
 * defaults plus the ids-only factory the source's List<String> constructors were.
 * `byte[] body` becomes ArrayBuffer, which is what the ported Downloader posts.
 */

export class Page {
  private readonly url: string | null;
  private readonly id: string | null;
  private readonly ids: string[] | null;
  private readonly cookies: Map<string, string> | null;
  private readonly body: ArrayBuffer | null;

  constructor(url: string | null, id: string | null = null, ids: string[] | null = null,
    cookies: Map<string, string> | null = null, body: ArrayBuffer | null = null) {
    this.url = url;
    this.id = id;
    this.ids = ids;
    this.cookies = cookies;
    this.body = body;
  }

  /** Port of the Page(List<String> ids[, Map cookies]) constructors. */
  static ofIds(ids: string[], cookies: Map<string, string> | null = null): Page {
    return new Page(null, null, ids, cookies, null);
  }

  getUrl(): string | null {
    return this.url;
  }

  getId(): string | null {
    return this.id;
  }

  getIds(): string[] | null {
    return this.ids;
  }

  getCookies(): Map<string, string> | null {
    return this.cookies;
  }

  getBody(): ArrayBuffer | null {
    return this.body;
  }

  /** A page is valid when it carries either a non-empty url or a non-empty id list. */
  static isValid(page: Page | null): boolean {
    if (page === null) {
      return false;
    }
    const pageUrl: string | null = page.getUrl();
    const pageIds: string[] | null = page.getIds();
    const hasUrl: boolean = pageUrl !== null && pageUrl.length > 0;
    const hasIds: boolean = pageIds !== null && pageIds.length > 0;
    return hasUrl || hasIds;
  }
}
