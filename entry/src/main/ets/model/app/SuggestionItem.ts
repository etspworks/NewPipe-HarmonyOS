/*
 * Port of app/src/main/java/org/schabi/newpipe/fragments/list/search/SuggestionItem.kt -
 * one row of the search-suggestion list, from history or from the service.
 */

import { javaStringHashCode } from './FeedUpdateInfo';

export class SuggestionItem {
  fromHistory: boolean = false;
  query: string = '';

  constructor(fromHistory: boolean, query: string) {
    this.fromHistory = fromHistory;
    this.query = query;
  }

  /** Port of equals(): two suggestions are the same when their query is, history or not. */
  equalsItem(other: SuggestionItem | null): boolean {
    return other !== null && this.query === other.query;
  }

  hashCode(): number {
    return javaStringHashCode(this.query);
  }

  toString(): string {
    return `[${this.fromHistory}→${this.query}]`;
  }
}
