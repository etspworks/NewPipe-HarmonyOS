/*
 * Port of shared/src/commonMain/kotlin/net/newpipe/app/model/Link.kt - a link row shown to
 * users on the About screen. Not serialized in the source, so no JSON mapper here.
 */

export class Link {
  title: string = '';
  description: string = '';
  action: string = '';
  url: string = '';

  constructor(title: string = '', description: string = '', action: string = '', url: string = '') {
    this.title = title;
    this.description = description;
    this.action = action;
    this.url = url;
  }
}
