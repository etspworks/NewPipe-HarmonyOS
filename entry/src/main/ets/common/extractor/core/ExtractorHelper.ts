import { hilog } from '@kit.PerformanceAnalysisKit';
/*
 * Port of org.schabi.newpipe.extractor.utils.ExtractorHelper (NewPipeExtractor v0.26.5).
 *
 * Both helpers now await the page they fetch, since the list getters are Promises; the "log the
 * error onto the Info instead of throwing" behaviour is unchanged, and it is what keeps one bad
 * related-items block from losing the whole stream page.
 */

import { InfoItemsPage } from '../../../model/extractor/ListExtractorInfoItemsPage';
import { StreamExtractor } from '../info/StreamExtractor';
import { InfoItemExtractor, InfoItemsCollector } from './Collector';
import { toError } from './Errors';
import { Info } from './Info';
import { InfoItem } from './InfoItem';
import { ListExtractor } from './ListExtractor';

export class ExtractorHelper {
  static async getItemsPageOrLogError<T extends InfoItem>(info: Info,
    extractor: ListExtractor<T>): Promise<InfoItemsPage<T>> {
    try {
      const page: InfoItemsPage<T> = await extractor.getInitialPage();
      info.addAllErrors(page.getErrors());
      return page;
    } catch (e) {
      info.addError(toError(e));
      return InfoItemsPage.emptyPage<T>();
    }
  }

  static async getRelatedItemsOrLogError(info: Info,
    extractor: StreamExtractor): Promise<InfoItem[]> {
    try {
      const collector: InfoItemsCollector<InfoItem, InfoItemExtractor> | null =
        await extractor.getRelatedItems();
      if (collector === null) {
        return [];
      }
      info.addAllErrors(collector.getErrors());
      const errors: Error[] = collector.getErrors();
      if (errors.length > 0) {
        hilog.warn(0x0000, 'ExtractorHelper', 'related items: %{public}d kept, %{public}d failed: %{public}s',
          collector.getItems().length, errors.length, errors[0].message);
      }
      return collector.getItems();
    } catch (e) {
      const failure: Error = toError(e);
      hilog.warn(0x0000, 'ExtractorHelper', 'related items: %{public}s', failure.message);
      info.addError(failure);
      return [];
    }
  }
}
