/*
 * Port of the generated org.schabi.newpipe.extractor.timeago.patterns.* classes plus
 * PatternMap and PatternsHolder (NewPipeExtractor v0.26.5).
 *
 * The 80 pattern classes are code-generated in the source (from
 * timeago-parser/raw/unique_patterns.json), so they are carried over as data rather than as
 * 80 ArkTS classes: PATTERN_ROWS below is transcribed from those generated classes, word for
 * word, in PatternMap's own registration order.
 */

import { ChronoUnit } from './ChronoUnit';

/** Port of PatternsHolder: the ago-phrases of one localization, per time unit. */
export class PatternsHolder {
  private readonly wordSeparatorValue: string;
  private readonly secondsValue: string[];
  private readonly minutesValue: string[];
  private readonly hoursValue: string[];
  private readonly daysValue: string[];
  private readonly weeksValue: string[];
  private readonly monthsValue: string[];
  private readonly yearsValue: string[];
  private readonly specialCasesValue: Map<ChronoUnit, Map<string, number>> =
    new Map<ChronoUnit, Map<string, number>>();

  constructor(wordSeparator: string, seconds: string[], minutes: string[],
    hours: string[], days: string[], weeks: string[], months: string[],
    years: string[]) {
    this.wordSeparatorValue = wordSeparator;
    this.secondsValue = seconds;
    this.minutesValue = minutes;
    this.hoursValue = hours;
    this.daysValue = days;
    this.weeksValue = weeks;
    this.monthsValue = months;
    this.yearsValue = years;
  }

  wordSeparator(): string {
    return this.wordSeparatorValue;
  }

  specialCases(): Map<ChronoUnit, Map<string, number>> {
    return this.specialCasesValue;
  }

  putSpecialCase(unit: ChronoUnit, caseText: string, caseAmount: number): void {
    let item: Map<string, number> | undefined = this.specialCasesValue.get(unit);
    if (item === undefined) {
      item = new Map<string, number>();
      this.specialCasesValue.set(unit, item);
    }
    item.set(caseText, caseAmount);
  }

  /** Port of asMap(): unit -> ago-phrases, in the source's insertion order. */
  asMap(): Map<ChronoUnit, string[]> {
    const returnMap: Map<ChronoUnit, string[]> = new Map<ChronoUnit, string[]>();
    returnMap.set(ChronoUnit.SECONDS, this.secondsValue);
    returnMap.set(ChronoUnit.MINUTES, this.minutesValue);
    returnMap.set(ChronoUnit.HOURS, this.hoursValue);
    returnMap.set(ChronoUnit.DAYS, this.daysValue);
    returnMap.set(ChronoUnit.WEEKS, this.weeksValue);
    returnMap.set(ChronoUnit.MONTHS, this.monthsValue);
    returnMap.set(ChronoUnit.YEARS, this.yearsValue);
    return returnMap;
  }
}

/** One generated pattern class: [localization key, word separator, the seven unit lists]. */
class PatternRow {
  readonly key: string;
  readonly separator: string;
  readonly units: string[][];

  constructor(key: string, separator: string, units: string[][]) {
    this.key = key;
    this.separator = separator;
    this.units = units;
  }
}

const PATTERN_ROWS: PatternRow[] = [
  new PatternRow('af', ' ',
    [['sekonde', 'sekondes'], ['minute', 'minuut'], ['ure', 'uur'], ['dae', 'dag'], ['week', 'weke'], ['maand', 'maande'], ['jaar']]),
  new PatternRow('am', ' ',
    [['ሰኮንዶች', 'ሴኮንድ'], ['ደቂቃ', 'ደቂቃዎች'], ['ሰዓት', 'ሰዓቶች'], ['ቀን', 'ቀኖች'], ['ሳምንታት', 'ሳምንት'], ['ወራት', 'ወር'], ['ዓመታት', 'ዓመት']]),
  new PatternRow('ar', ' ',
    [['ثانية', 'ثانيتين', 'ثوانٍ'], ['دقائق', 'دقيقة', 'دقيقتين'], ['ساعات', 'ساعة', 'ساعتين'], ['أيام', 'يوم', 'يومين'], ['أسابيع', 'أسبوع', 'أسبوعين'], ['أشهر', 'شهر', 'شهرين', 'شهرًا'], ['سنة', 'سنتين', 'سنوات']]),
  new PatternRow('az', ' ',
    [['saniyə'], ['dəqiqə'], ['saat'], ['gün'], ['həftə'], ['ay'], ['il']]),
  new PatternRow('be', ' ',
    [['секунд', 'секунду', 'секунды'], ['хвілін', 'хвіліну', 'хвіліны'], ['гадзін', 'гадзіну', 'гадзіны'], ['дзень', 'дзён', 'дня', 'дні'], ['тыдзень', 'тыдня', 'тыдні'], ['месяц', 'месяца', 'месяцы', 'месяцаў'], ['год', 'года', 'гады', 'гадоў']]),
  new PatternRow('bg', ' ',
    [['секунда', 'секунди'], ['минута', 'минути'], ['час', 'часа'], ['ден', 'дни'], ['седмица', 'седмици'], ['месец', 'месеца'], ['година', 'години']]),
  new PatternRow('bn', ' ',
    [['সেকেন্ড'], ['মিনিট'], ['ঘণ্টা'], ['দিন'], ['সপ্তাহ'], ['মাস'], ['বছর']]),
  new PatternRow('bs', ' ',
    [['sekundi', 'sekunde', 'sekundu'], ['minuta', 'minute', 'minutu'], ['h', 'sat', 'sata', 'sati'], ['dan', 'dana'], ['sedm.'], ['mj.', 'mjesec', 'mjeseca', 'mjeseci'], ['godina', 'godine', 'godinu']]),
  new PatternRow('ca', ' ',
    [['segon', 'segons'], ['minut', 'minuts'], ['hora', 'hores'], ['dia', 'dies'], ['setmana', 'setmanes'], ['mes', 'mesos'], ['any', 'anys']]),
  new PatternRow('cs', ' ',
    [['sekundami', 'sekundou'], ['minutami', 'minutou'], ['hodinami', 'hodinou'], ['dny', 'včera'], ['týdnem', 'týdny'], ['měsícem', 'měsíci'], ['rokem', 'roky', 'lety']]),
  new PatternRow('da', ' ',
    [['sekund', 'sekunder'], ['minut', 'minutter'], ['time', 'timer'], ['dag', 'dage'], ['uge', 'uger'], ['måned', 'måneder'], ['år']]),
  new PatternRow('de', ' ',
    [['Sekunde', 'Sekunden'], ['Minute', 'Minuten'], ['Stunde', 'Stunden'], ['Tag', 'Tagen'], ['Woche', 'Wochen'], ['Monat', 'Monaten'], ['Jahr', 'Jahren']]),
  new PatternRow('el', ' ',
    [['δευτερόλεπτα', 'δευτερόλεπτο'], ['λεπτά', 'λεπτό'], ['ώρα', 'ώρες'], ['ημέρα', 'ημέρες'], ['εβδομάδα', 'εβδομάδες'], ['μήνα', 'μήνες'], ['χρόνια', 'χρόνο']]),
  new PatternRow('en', ' ',
    [['second', 'seconds', 'sec'], ['minute', 'minutes', 'min'], ['hour', 'hours', 'h'], ['day', 'days', 'd'], ['week', 'weeks', 'w'], ['month', 'months', 'mo'], ['year', 'years', 'y']]),
  new PatternRow('en_GB', ' ',
    [['second', 'seconds', 'sec'], ['minute', 'minutes', 'min'], ['hour', 'hours', 'hr'], ['day', 'days'], ['week', 'weeks', 'wk'], ['month', 'months', 'mo'], ['year', 'years', 'yr']]),
  new PatternRow('es', ' ',
    [['segundo', 'segundos'], ['minuto', 'minutos'], ['hora', 'horas'], ['día', 'días'], ['semana', 'semanas'], ['mes', 'meses'], ['año', 'años']]),
  new PatternRow('es_419', ' ',
    [['segundo', 'segundos'], ['minuto', 'minutos'], ['hora', 'horas'], ['día', 'días'], ['semana', 'semanas'], ['mes', 'meses'], ['año', 'años']]),
  new PatternRow('es_US', ' ',
    [['segundo', 'segundos'], ['minuto', 'minutos'], ['hora', 'horas'], ['día', 'días'], ['semana', 'semanas'], ['mes', 'meses'], ['año', 'años']]),
  new PatternRow('et', ' ',
    [['sekund', 'sekundit'], ['minut', 'minutit'], ['tund', 'tundi'], ['päev', 'päeva'], ['nädal', 'nädalat'], ['kuu', 'kuud'], ['aasta', 'aastat']]),
  new PatternRow('eu', ' ',
    [['segundo'], ['minutu'], ['ordu', 'ordubete'], ['egun'], ['aste', 'astebete'], ['hilabete'], ['urte', 'urtebete']]),
  new PatternRow('fa', ' ',
    [['ثانیه'], ['دقیقه'], ['ساعت'], ['روز'], ['هفته'], ['ماه'], ['سال']]),
  new PatternRow('fi', ' ',
    [['sekunti', 'sekuntia'], ['minuutti', 'minuuttia'], ['tunti', 'tuntia'], ['päivä', 'päivää'], ['viikko', 'viikkoa'], ['kuukausi', 'kuukautta'], ['vuosi', 'vuotta']]),
  new PatternRow('fil', ' ',
    [['segundo'], ['minuto'], ['oras'], ['araw'], ['linggo'], ['buwan'], ['taon']]),
  new PatternRow('fr', ' ',
    [['seconde', 'secondes'], ['minute', 'minutes'], ['heure', 'heures'], ['jour', 'jours'], ['semaine', 'semaines'], ['mois'], ['an', 'ans']]),
  new PatternRow('fr_CA', ' ',
    [['seconde', 'secondes'], ['minute', 'minutes'], ['heures', 'heure'], ['jour', 'jours'], ['semaine', 'semaines'], ['mois'], ['an', 'ans']]),
  new PatternRow('gl', ' ',
    [['segundo', 'segundos'], ['minuto', 'minutos'], ['hora', 'horas'], ['día', 'días'], ['semana', 'semanas'], ['mes', 'meses'], ['ano', 'anos']]),
  new PatternRow('gu', ' ',
    [['સેકંડ'], ['મિનિટ'], ['કલાક'], ['દિવસ'], ['અઠવાડિયા'], ['મહિના'], ['વર્ષ']]),
  new PatternRow('hi', ' ',
    [['सेकंड'], ['मिनट'], ['घंटा', 'घंटे'], ['दिन'], ['सप्ताह', 'हफ़्ते'], ['महीना', 'महीने'], ['वर्ष']]),
  new PatternRow('hr', ' ',
    [['sekunde', 'sekundi', 'sekundu'], ['minuta', 'minute', 'minutu'], ['sat', 'sata', 'sati'], ['dan', 'dana'], ['tjedan', 'tjedna'], ['mjesec', 'mjeseca', 'mjeseci'], ['godina', 'godine', 'godinu']]),
  new PatternRow('hu', ' ',
    [['másodperce'], ['perce'], ['órája'], ['napja'], ['hete'], ['hónapja'], ['éve']]),
  new PatternRow('hy', ' ',
    [['վայրկյան'], ['րոպե'], ['ժամ'], ['օր'], ['շաբաթ'], ['ամիս'], ['տարի']]),
  new PatternRow('id', ' ',
    [['detik'], ['menit'], ['jam'], ['hari'], ['minggu'], ['bulan'], ['tahun']]),
  new PatternRow('is', ' ',
    [['sekúndu', 'sekúndum', 'second', 'seconds'], ['mínútu', 'mínútum', 'minute', 'minutes'], ['klukkustund', 'klukkustundum', 'hour', 'hours'], ['degi', 'dögum', 'day', 'days'], ['viku', 'vikum', 'week', 'weeks'], ['mánuði', 'mánuðum'], ['ári', 'árum']]),
  new PatternRow('it', ' ',
    [['secondi', 'secondo'], ['minuti', 'minuto'], ['ora', 'ore'], ['giorni', 'giorno'], ['settimana', 'settimane'], ['mese', 'mesi'], ['anni', 'anno']]),
  new PatternRow('iw', ' ',
    [['שניות', 'שנייה'], ['דקה', 'דקות'], ['שעה', 'שעות'], ['יום', 'ימים'], ['שבוע', 'שבועות'], ['חודש', 'חודשים'], ['שנה', 'שנים']]),
  new PatternRow('ja', '',
    [['秒前'], ['分前'], ['時間前'], ['日前'], ['週間前'], ['か月前'], ['年前']]),
  new PatternRow('ka', ' ',
    [['წამის'], ['წუთის'], ['საათის'], ['დღის'], ['კვირის'], ['თვის'], ['წლის']]),
  new PatternRow('kk', ' ',
    [['секунд'], ['минут'], ['сағат'], ['күн'], ['апта'], ['ай'], ['жыл']]),
  new PatternRow('km', '',
    [['វិនាទី​មុន', '១វិនាទីមុន'], ['នាទីមុន', '១នាទីមុន'], ['ម៉ោង​មុន', '១ម៉ោង​មុន'], ['ថ្ងៃមុន', '១ថ្ងៃ​មុន'], ['ស​ប្តា​ហ៍​មុន', '១ស​ប្តា​ហ៍​មុន'], ['ខែមុន', '១ខែមុន'], ['ឆ្នាំ​មុន', '១ឆ្នាំមុន']]),
  new PatternRow('kn', ' ',
    [['ಸೆಕೆಂಡುಗಳ', 'ಸೆಕೆಂಡ್'], ['ನಿಮಿಷಗಳ', 'ನಿಮಿಷದ'], ['ಗಂಟೆಗಳ', 'ಗಂಟೆಯ'], ['ದಿನಗಳ', 'ದಿನದ'], ['ವಾರಗಳ', 'ವಾರದ'], ['ತಿಂಗಳ', 'ತಿಂಗಳುಗಳ'], ['ವರ್ಷಗಳ', 'ವರ್ಷದ']]),
  new PatternRow('ko', '',
    [['초'], ['분'], ['시간'], ['일'], ['주'], ['개월'], ['년']]),
  new PatternRow('ky', ' ',
    [['секунд'], ['мүнөт'], ['саат'], ['күн'], ['апта'], ['ай'], ['жыл']]),
  new PatternRow('lo', '',
    [['ວິນາທີກ່ອນນີ້'], ['ນາທີກ່ອນນີ້', 'ນາ​ທີ​ກ່ອນ​ນີ້'], ['ຊົ່ວ​ໂມງ​ກ່ອນ​ນີ້'], ['ມື້ກ່ອນນີ້'], ['ອາ​ທິດ​ກ່ອນ​ນີ້'], ['ເດືອນ​ກ່ອນ​ນີ້'], ['ປີ​ກ່ອນ​ນີ້']]),
  new PatternRow('lt', ' ',
    [['sekundes', 'sekundę', 'sekundžių'], ['minutes', 'minutę', 'minučių'], ['valandas', 'valandą', 'valandų'], ['dienas', 'dieną'], ['savaites', 'savaitę'], ['mėnesius', 'mėnesių', 'mėnesį'], ['metus', 'metų']]),
  new PatternRow('lv', ' ',
    [['sekundes', 'sekundēm'], ['minūtes', 'minūtēm', 'minūtes'], ['stundas', 'stundām'], ['dienas', 'dienām'], ['nedēļas', 'nedēļām'], ['mēneša', 'mēnešiem'], ['gada', 'gadiem']]),
  new PatternRow('mk', ' ',
    [['секунда', 'секунди'], ['минута', 'минути'], ['час', 'часа'], ['ден', 'дена'], ['недела', 'недели'], ['месец', 'месеци'], ['година', 'години']]),
  new PatternRow('ml', '',
    [['സെക്കന്റ്', 'സെക്കൻഡ്'], ['മിനിറ്റ്'], ['മണിക്കൂർ'], ['ദിവസം'], ['ആഴ്ച', 'ആഴ്‌ച'], ['മാസം'], ['വർഷം']]),
  new PatternRow('mn', ' ',
    [['секундын'], ['минутын'], ['цагийн'], ['өдрийн'], ['долоо', 'хоногийн'], ['сарын'], ['жилийн']]),
  new PatternRow('mr', '',
    [['सेकंदांपूर्वी', 'सेकंदापूर्वी'], ['मिनिटांपूर्वी', 'मिनिटापूर्वी'], ['तासांपूर्वी', 'तासापूर्वी'], ['दिवसांपूर्वी', 'दिवसापूर्वी'], ['आठवड्यांपूर्वी', 'आठवड्यापूर्वी'], ['महिन्यांपूर्वी', 'महिन्यापूर्वी'], ['वर्षांपूर्वी', 'वर्षापूर्वी']]),
  new PatternRow('ms', ' ',
    [['saat'], ['minit'], ['jam'], ['hari'], ['minggu'], ['bulan'], ['tahun']]),
  new PatternRow('my', ' ',
    [['စက္ကန့်'], ['မိနစ်'], ['နာရီ'], ['ရက်'], ['ပတ်'], ['လ'], ['နှစ်']]),
  new PatternRow('ne', ' ',
    [['सेकेन्ड'], ['मिनेट'], ['घन्टा'], ['दिन'], ['हप्ता'], ['महिना'], ['वर्ष']]),
  new PatternRow('nl', ' ',
    [['seconde', 'seconden'], ['minuten', 'minuut'], ['uur'], ['dag', 'dagen'], ['week', 'weken'], ['maand', 'maanden'], ['jaar']]),
  new PatternRow('no', ' ',
    [['sekund', 'sekunder'], ['minutt', 'minutter'], ['time', 'timer'], ['dag', 'dager'], ['uke', 'uker'], ['md.'], ['år']]),
  new PatternRow('pa', ' ',
    [['ਸਕਿੰਟ'], ['ਮਿੰਟ'], ['ਘੰਟਾ', 'ਘੰਟੇ'], ['ਦਿਨ'], ['ਹਫ਼ਤਾ', 'ਹਫ਼ਤੇ'], ['ਮਹੀਨਾ', 'ਮਹੀਨੇ'], ['ਸਾਲ']]),
  new PatternRow('pl', ' ',
    [['sekund', 'sekundy', 'sekundę'], ['minut', 'minuty', 'minutę'], ['godzin', 'godziny', 'godzinę'], ['dni', 'dzień'], ['tydzień', 'tygodnie'], ['miesiąc', 'miesiące', 'miesięcy'], ['lat', 'lata', 'rok']]),
  new PatternRow('pt', ' ',
    [['segundo', 'segundos'], ['minuto', 'minutos'], ['hora', 'horas'], ['dia', 'dias'], ['semana', 'semanas'], ['meses', 'mês'], ['ano', 'anos']]),
  new PatternRow('pt_PT', ' ',
    [['segundo', 'segundos'], ['minuto', 'minutos'], ['hora', 'horas'], ['dia', 'dias'], ['semana', 'semanas'], ['meses', 'mês'], ['ano', 'anos']]),
  new PatternRow('ro', ' ',
    [['secunde', 'secundă'], ['minut', 'minute'], ['ore', 'oră'], ['zi', 'zile'], ['săptămâni', 'săptămână'], ['luni', 'lună'], ['an', 'ani']]),
  new PatternRow('ru', ' ',
    [['секунд', 'секунду', 'секунды', 'только что'], ['минут', 'минуту', 'минуты'], ['час', 'часа', 'часов'], ['день', 'дней', 'дня'], ['Неделю', 'недели'], ['месяц', 'месяца', 'месяцев'], ['Год', 'года', 'лет']]),
  new PatternRow('si', ' ',
    [['තත්පර'], ['මිනිත්තු'], ['පැය'], ['දින'], ['සති'], ['මාස'], ['වසර']]),
  new PatternRow('sk', ' ',
    [['sekundami', 'sekundou'], ['minútami', 'minútou'], ['hodinami', 'hodinou'], ['dňami', 'dňom'], ['týždňami', 'týždňom'], ['mesiacmi', 'mesiacom'], ['rokmi', 'rokom']]),
  new PatternRow('sl', ' ',
    [['sekundama', 'sekundami', 'sekundo'], ['minutama', 'minutami', 'minuto'], ['urama', 'urami', 'uro'], ['dnem', 'dnevi', 'dnevoma'], ['tedni', 'tednom', 'tednoma'], ['mesecem', 'mesecema', 'meseci'], ['leti', 'letom', 'letoma']]),
  new PatternRow('sq', ' ',
    [['sekonda', 'sekondë'], ['minuta', 'minutë'], ['orë'], ['ditë'], ['javë'], ['muaj'], ['vit', 'vjet']]),
  new PatternRow('sr', ' ',
    [['секунде', 'секунди'], ['минута'], ['сат', 'сата', 'сати'], ['Пре 1 дан', 'Пре 2 дана', 'Пре 3 дана', 'Пре 4 дана', 'Пре 5 дана', 'Пре 6 дана'], ['недеље', 'недељу'], ['месец', 'месеца', 'месеци'], ['година', 'године', 'годину']]),
  new PatternRow('sr_Latn', ' ',
    [['sekunde', 'sekundi'], ['minuta'], ['sat', 'sati', 'sata'], ['Pre 1 dan', 'Pre 2 dana', 'Pre 3 dana', 'Pre 4 dana', 'Pre 5 dana', 'Pre 6 dana'], ['nedelja', 'nedelje', 'nedelju'], ['mesec', 'meseci', 'meseca'], ['godine', 'godina', 'godinu']]),
  new PatternRow('sv', ' ',
    [['sekund', 'sekunder'], ['minut', 'minuter'], ['timmar', 'timme'], ['dag', 'dagar'], ['vecka', 'veckor'], ['månad', 'månader'], ['år']]),
  new PatternRow('sw', ' ',
    [['sekunde'], ['dakika'], ['saa'], ['siku'], ['wiki'], ['Mwezi', 'miezi'], ['Miaka', 'Mwaka']]),
  new PatternRow('ta', ' ',
    [['வினாடி', 'வினாடிகளுக்கு'], ['நிமிடங்கள்', 'நிமிடம்'], ['மணிநேரத்திற்கு'], ['நாட்களுக்கு', 'நாளுக்கு'], ['வாரங்களுக்கு', 'வாரம்'], ['மாதங்கள்', 'மாதம்'], ['ஆண்டு', 'ஆண்டுகளுக்கு']]),
  new PatternRow('te', ' ',
    [['సెకను', 'సెకన్ల'], ['నిమిషం', 'నిమిషాల'], ['గంట', 'గంటల'], ['రోజు', 'రోజుల'], ['వారం', 'వారాల'], ['నెల', 'నెలల'], ['సంవత్సరం', 'సంవత్సరాల']]),
  new PatternRow('th', '',
    [['วินาทีที่ผ่านมา'], ['นาทีที่ผ่านมา'], ['ชั่วโมงที่ผ่านมา'], ['วันที่ผ่านมา'], ['สัปดาห์ที่ผ่านมา'], ['เดือนที่ผ่านมา'], ['ปีที่ผ่านมา']]),
  new PatternRow('tr', ' ',
    [['saniye'], ['dakika'], ['saat'], ['gün'], ['hafta'], ['ay'], ['yıl']]),
  new PatternRow('uk', ' ',
    [['секунд', 'секунди', 'секунду'], ['хвилин', 'хвилини', 'хвилину'], ['годин', 'години', 'годину'], ['день', 'дні', 'днів'], ['тиждень', 'тижні'], ['місяць', 'місяці', 'місяців'], ['роки', 'років', 'рік']]),
  new PatternRow('ur', ' ',
    [['سیکنڈ', 'سیکنڈز'], ['منٹ', 'منٹس'], ['گھنٹہ', 'گھنٹے'], ['دن'], ['ہفتہ', 'ہفتے'], ['ماہ'], ['سال']]),
  new PatternRow('uz', ' ',
    [['soniya'], ['daqiqa'], ['soat'], ['kun'], ['hafta'], ['oy'], ['yil']]),
  new PatternRow('vi', ' ',
    [['giây'], ['phút'], ['giờ', 'tiếng'], ['ngày'], ['tuần'], ['tháng'], ['năm']]),
  new PatternRow('zh_CN', '',
    [['秒前'], ['分钟前'], ['小时前'], ['天前'], ['周前'], ['个月前'], ['年前']]),
  new PatternRow('zh_HK', '',
    [['秒前'], ['分鐘前'], ['小時前'], ['天前'], ['週前'], ['個月前'], ['年前']]),
  new PatternRow('zh_TW', '',
    [['秒前'], ['分鐘前'], ['小時前'], ['天前'], ['週前'], ['個月前'], ['年前']]),
  new PatternRow('zu', ' ',
    [['amasekhondi', 'isekhondi'], ['amaminithi', 'iminithi'], ['amahora', 'ihora'], ['izinsuku', 'usuku'], ['amaviki', 'iviki'], ['inyanga', 'izinyanga'], ['iminyaka', 'unyaka']])
];

/** Special cases: the source calls putSpecialCase() in exactly these pattern classes. */
class SpecialCaseRow {
  readonly key: string;
  readonly unit: ChronoUnit;
  readonly caseText: string;
  readonly caseAmount: number;

  constructor(key: string, unit: ChronoUnit, caseText: string, caseAmount: number) {
    this.key = key;
    this.unit = unit;
    this.caseText = caseText;
    this.caseAmount = caseAmount;
  }
}

const SPECIAL_CASE_ROWS: SpecialCaseRow[] = [
  new SpecialCaseRow('iw', ChronoUnit.HOURS, 'שעתיים', 2),
  new SpecialCaseRow('iw', ChronoUnit.DAYS, 'יומיים', 2),
  new SpecialCaseRow('iw', ChronoUnit.WEEKS, 'שבועיים', 2),
  new SpecialCaseRow('iw', ChronoUnit.MONTHS, 'חודשיים', 2),
  new SpecialCaseRow('iw', ChronoUnit.YEARS, 'שנתיים', 2)
];

function buildPatternMap(): Map<string, PatternsHolder> {
  const map: Map<string, PatternsHolder> = new Map<string, PatternsHolder>();
  for (const row of PATTERN_ROWS) {
    map.set(row.key, new PatternsHolder(row.separator, row.units[0], row.units[1],
      row.units[2], row.units[3], row.units[4], row.units[5], row.units[6]));
  }
  for (const special of SPECIAL_CASE_ROWS) {
    const holder: PatternsHolder | undefined = map.get(special.key);
    if (holder !== undefined) {
      holder.putSpecialCase(special.unit, special.caseText, special.caseAmount);
    }
  }
  return map;
}

const PATTERN_MAP: Map<string, PatternsHolder> = buildPatternMap();

/** Port of PatternsManager.getPatterns(): `language` or `language_COUNTRY`. */
export function getPatterns(languageCode: string,
  countryCode: string | null): PatternsHolder | null {
  const targetKey: string = languageCode
    + (countryCode === null || countryCode.length === 0 ? '' : '_' + countryCode);
  const holder: PatternsHolder | undefined = PATTERN_MAP.get(targetKey);
  return holder === undefined ? null : holder;
}
