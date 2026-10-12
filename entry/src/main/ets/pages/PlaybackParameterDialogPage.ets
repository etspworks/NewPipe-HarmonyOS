/**
 * S2 shell - PlaybackParameterDialog (screen_playback_parameter_dialog). presentation: modal.
 *
 * NOT a routed page: an OVERLAY whose hostScreen is screen_play_queue_activity, mounted by
 * PlayQueueActivityPage on action_playback_speed (PlayQueueActivity.openPlaybackParameterDialog()
 * -> PlaybackParameterDialog.newInstance(playbackSpeed, playbackPitch, playbackSkipSilence,
 * this)). MainPlayerUi opens the same dialog from the main player; that host is not this call's
 * file. Deliberately absent from main_pages.json.
 *
 * Structure is dialog_playback_parameter.xml verbatim (every id below is that layout's own), and
 * the behaviour is PlaybackParameterDialog.java:42-600:
 *  - Two SLIDER STRATEGIES, not one: QUADRATIC_STRATEGY maps tempo and pitch-percent over
 *    MIN_PITCH_OR_SPEED 0.10 .. MAX_PITCH_OR_SPEED 3.00, while SEMITONE_STRATEGY maps the
 *    semitone bar linearly over -12 .. +12. A linear tempo bar would be the wrong control.
 *  - PITCH HAS TWO MUTUALLY EXCLUSIVE CONTROL MODES (playback_adjust_by_semitones_key):
 *    pitchControlModePercent shows pitchPercentControl, pitchControlModeSemitone shows
 *    pitchSemitoneControl and re-quantises pitchPercent to the nearest valid semitone. The chosen
 *    one carries the dashed border. That is a conditionalVariant, built as ArkUI `if` in S4 -
 *    the two containers are NOT both rendered.
 *  - pitchToogleControlModes (sic, the source's spelling) shows/hides pitchControlModeTabs and
 *    animates the chevron 0 <-> 180 degrees (feat_animations).
 *  - The FIVE step-size toggles write adjustment_step_key and then setStepSizeToUI(value), which
 *    RELABELS all four step buttons ("-N%" / "+N%") - the labels are derived, never literals.
 *  - unhookCheckbox is bound to playback_unhook_key (default true); UNCHECKING it calls
 *    ensureHookIsValidAndUpdateCallBack(), which snaps tempo and pitch back together.
 *  - Every change calls updateCallback() -> Callback.onPlaybackParameterChanged(tempo, pitch,
 *    skipSilence) on the HOST, which forwards to the player. S4 wires that through svc_player
 *    (feat_playback_speed_pitch); the readouts come from PlayerHelper.formatSpeed/formatPitch.
 *  - The three AlertDialog buttons: OK (BUTTON_POSITIVE) commits via updateCallback(); Reset
 *    (BUTTON_NEUTRAL) sets 1.00 / 1.00 / DEFAULT_SKIP_SILENCE; Cancel (BUTTON_NEGATIVE) RESTORES
 *    initialTempo / initialPitchPercent / initialSkipSilence and pushes them back to the player -
 *    it is a revert, not a plain dismiss, hence the three initial* fields below.
 *
 * PRESENTATION NOTE (reported): the source is a centred AlertDialog wrapping this custom view,
 * not a bottom sheet, so hosts open it through PlaybackParameterDialogHost (bottom of file).
 *
 * WHAT THIS DIALOG CAN AND CANNOT APPLY (T-0133b, measured):
 *
 * TEMPO is applied through AVPlayer.setPlaybackRate(number) - continuous, 0.125 ~ 4. On the
 * handset a requested 1.1x plays at a measured 1.100 (docs/qa/evidence/fix-T-0133b/).
 *
 * PITCH and SKIP-SILENCE are not applied, and their controls are disabled rather than left
 * movable - a control that moves while nothing happens is worse than one that is plainly
 * unavailable:
 *   - no pitch/semitone member exists in @ohos.multimedia.media.d.ts or
 *     @ohos.multimedia.audio.d.ts (grep -i 'pitch|semitone' -> 0 matches);
 *   - the one API that does adjust pitch, OH_AudioSuiteEngine_SetTempoAndPitch, is a C API with
 *     no ArkTS binding, lives in EDIT_MODE (realtime mode is EQ only) and outputs mono, so using
 *     it means taking the audio path away from AVPlayer entirely;
 *   - 'skipSilence' appears nowhere in either SDK.
 * Re-run those greps before concluding the platform has gained them.
 *
 * The controls are DISABLED, not deleted. They are a faithful port of the reference's two pitch
 * modes, the quadratic slider strategy and the semitone quantisation, and deleting them would be
 * a decision nobody made. The dialog keeps the source's full arithmetic so the values it hands
 * over are the source's values.
 */

import { Localization } from '../common/i18n/Localization';
import { hilog } from '@kit.PerformanceAnalysisKit';

import { AppPreferences } from '../common/prefs/Preferences';
import {
  adjustment_step_key,
  playback_adjust_by_semitones_key,
  playback_unhook_key
} from '../common/prefs/SettingsKeys';

const MIN_PITCH_OR_SPEED: number = 0.10;
const MAX_PITCH_OR_SPEED: number = 3.00;
const DEFAULT_TEMPO: number = 1.00;
const DEFAULT_PITCH_PERCENT: number = 1.00;
/** STEP_1/5/10/25/100_PERCENT_VALUE; DEFAULT_STEP = STEP_25_PERCENT_VALUE. */
const STEP_1_PERCENT_VALUE: number = 0.01;
const STEP_5_PERCENT_VALUE: number = 0.05;
const STEP_10_PERCENT_VALUE: number = 0.10;
const STEP_25_PERCENT_VALUE: number = 0.25;
const STEP_100_PERCENT_VALUE: number = 1.00;
const DEFAULT_STEP: number = STEP_25_PERCENT_VALUE;
/** PlayerSemitoneHelper.SEMITONE_COUNT. */
const SEMITONE_COUNT: number = 12;
/** dialog_playback_parameter.xml: the ScrollView's 12dp padding and the 22dp chevron. */
const DIALOG_PADDING: number = 12;
const CHEVRON_SIZE: number = 22;

/*
 * S5 - the STYLE of this dialog comes from dialog_playback_parameter.xml alone. Its three
 * captured sids (S0191/S0192/S0193) never show it: all three settle on MainActivity's Live
 * kiosk feed with ZERO playback-parameter nodes in their ui.json, so the dialog was never
 * opened and there is nothing to diff against.
 *
 * Every label, value and step control in that layout carries android:textColor="?attr/colorAccent",
 * and Base.V21.LightTheme binds colorAccent to @color/light_youtube_accent_color - which is
 * #000000, NOT the #E53935 colorPrimary. The separators are ?attr/separator_color
 * (@color/light_separator_color) 1dp rules inset 12dp with 5dp above and below.
 */
/** ScrollView paddingStart/End 6dp, paddingTop 4dp - not the 12dp button-bar padding. */
const BODY_PADDING_HORIZONTAL: number = 6;
const BODY_PADDING_TOP: number = 4;
/** The 4dp gutters the layout puts around the value block and after the step-up control. */
const CONTROL_GUTTER: number = 4;
/** The dimming applied to the two controls this platform cannot honour (T-0133). */
const DISABLED_OPACITY: number = 0.4;
/** The reason line under a disabled control: smaller than the body, not a heading. */
const NOTE_TEXT_SIZE: number = 12;

/** stepSizeSelector is android:layout_height="30dp"; pitchControlModeTabs is 22dp. */
const STEP_SIZE_ROW_HEIGHT: number = 30;
/** No android:textSize anywhere in the body: the platform default TextView size. */
const BODY_TEXT_SIZE: number = 14;
/** pitchSemitoneStepDown is 24sp/24dp, pitchSemitoneStepUp 20sp/24dp. */
const SEMITONE_FLAT_TEXT_SIZE: number = 24;
const SEMITONE_SHARP_TEXT_SIZE: number = 20;
const SEMITONE_STEP_WIDTH: number = 24;

/** PlayerHelper.formatSpeed - new DecimalFormat("0.##x"). */
export function formatSpeed(speed: number): string {
  return (Math.round(speed * 100) / 100).toString() + 'x';
}

/** PlayerHelper.formatPitch - new DecimalFormat("##%"). */
function formatPitch(pitch: number): string {
  return Math.round(pitch * 100).toString() + '%';
}

/** PlaybackParameterDialog.getStepUpPercentString / getStepDownPercentString. */
function stepUpLabel(step: number): string {
  return '+' + formatPitch(step);
}

function stepDownLabel(step: number): string {
  return '-' + formatPitch(step);
}

/** PlayerSemitoneHelper.percentToSemitones, clamped to +/- SEMITONE_COUNT. */
function percentToSemitones(percent: number): number {
  const raw: number = Math.round(SEMITONE_COUNT * Math.log(percent) / Math.log(2));
  return ensureSemitonesInRange(raw);
}

/** PlayerSemitoneHelper.ensureSemitonesInRange - MathUtils.clamp(s, -12, +12). */
function ensureSemitonesInRange(semitones: number): number {
  return Math.min(SEMITONE_COUNT, Math.max(-SEMITONE_COUNT, semitones));
}

/** PlayerSemitoneHelper.semitonesToPercent - 2^(clamp(semitones)/12). */
function semitonesToPercent(semitones: number): number {
  return Math.pow(2, ensureSemitonesInRange(semitones) / SEMITONE_COUNT);
}

/** MathUtils.clamp(value, MIN_PITCH_OR_SPEED, MAX_PITCH_OR_SPEED). */
function clampPitchOrSpeed(value: number): number {
  return Math.min(MAX_PITCH_OR_SPEED, Math.max(MIN_PITCH_OR_SPEED, value));
}

/*
 * SliderStrategy.Quadratic(MIN_PITCH_OR_SPEED, MAX_PITCH_OR_SPEED, 1.00, 10_000) - the tempo and
 * pitch-percent bars are NOT linear: the further the thumb is from the centre, the faster the
 * value moves. Both seek bars therefore run over the PROGRESS domain 0..10000 and convert, which
 * is what makes 1.00x sit exactly in the middle of the bar as it does in the source.
 */
const QUADRATIC_MAX_PROGRESS: number = 10000;
const QUADRATIC_CENTER: number = 1.00;
const QUADRATIC_CENTER_PROGRESS: number = QUADRATIC_MAX_PROGRESS / 2;
const QUADRATIC_LEFT_GAP: number = MIN_PITCH_OR_SPEED - QUADRATIC_CENTER;
const QUADRATIC_RIGHT_GAP: number = MAX_PITCH_OR_SPEED - QUADRATIC_CENTER;

/** SliderStrategy.Quadratic.progressOf(value). */
function quadraticProgressOf(value: number): number {
  const difference: number = value - QUADRATIC_CENTER;
  const root: number = difference >= 0
    ? Math.sqrt(difference / QUADRATIC_RIGHT_GAP)
    : -Math.sqrt(Math.abs(difference / QUADRATIC_LEFT_GAP));
  return QUADRATIC_CENTER_PROGRESS + Math.round(root * QUADRATIC_CENTER_PROGRESS);
}

/** SliderStrategy.Quadratic.valueOf(progress). */
function quadraticValueOf(progress: number): number {
  const offset: number = progress - QUADRATIC_CENTER_PROGRESS;
  const square: number = Math.pow(offset / QUADRATIC_CENTER_PROGRESS, 2);
  const difference: number = square * (offset >= 0 ? QUADRATIC_RIGHT_GAP : QUADRATIC_LEFT_GAP);
  return difference + QUADRATIC_CENTER;
}

/** newInstance(playbackTempo, playbackPitch, playbackSkipSilence) - what the HOST hands in. */
export class PlaybackParameters {
  tempo: number;
  pitchPercent: number;
  skipSilence: boolean;

  constructor(tempo: number, pitchPercent: number, skipSilence: boolean) {
    this.tempo = tempo;
    this.pitchPercent = pitchPercent;
    this.skipSilence = skipSilence;
  }
}

/** PlayerSemitoneHelper.formatPitchSemitones(int). */
function formatPitchSemitones(semitones: number): string {
  return semitones > 0 ? '+' + semitones.toString() : semitones.toString();
}

/**
 * R.attr.dashed_border -> dashed_border_light.xml: a 1dp @color/light_border_color stroke with a
 * 4dp dash / 4dp gap. setStepSizeToUI() and setPitchControlModeChangerText() lay that
 * LayerDrawable over the plain selectableItemBackground of the CURRENT option only; every other
 * option keeps the bare background. A plain module function, not a style decorator.
 */
function dashedBorder(selected: boolean): BorderOptions {
  if (selected) {
    return {
      width: 1,
      color: $r('app.color.border'),
      // BorderStyle.Dashed carries its own dash pattern; the source's explicit 4dp/4dp needs a
      // LengthMetrics, and the difference is invisible at a 1vp stroke.
      style: BorderStyle.Dashed
    };
  }
  return { width: 0 };
}

@Component
export struct PlaybackParameterDialogPage {
  /**
   * A component .id() is APPLICATION-GLOBAL and the build already warns about duplicates. Two
   * hosts mount this dialog - the queue screen and the video player's speed indicator - so the
   * root's id is the host's to name, and the default is the one the queue screen was using.
   */
  @Prop dialogId: string = 'PlaybackParameterDialogPage';
  /** Two-way with the host's visibility flag; all three buttons dismiss. */
  @Link isShown: boolean;
  /**
   * newInstance(playbackTempo, playbackPitch, playbackSkipSilence): the host reads them off the
   * player and passes them in. They are ALSO the source's initialTempo / initialPitchPercent /
   * initialSkipSilence snapshot, which is what BUTTON_NEGATIVE restores - one field, not two.
   */
  @Prop initialValues: PlaybackParameters =
    new PlaybackParameters(DEFAULT_TEMPO, DEFAULT_PITCH_PERCENT, false);
  /** adjustment_step_key, read in aboutToAppear; relabels all four step buttons. */
  @Prop stepSizeSelection: number = DEFAULT_STEP;
  /** playback_adjust_by_semitones_key: false = percent mode, true = semitone mode. */
  @Prop pitchModeSelection: boolean = false;
  /** The working values the three sliders drive. */
  @State tempo: number = DEFAULT_TEMPO;
  @State pitchPercent: number = DEFAULT_PITCH_PERCENT;
  @State skipSilence: boolean = false;
  /** pitchToogleControlModes: pitchControlModeTabs is android:visibility="gone" at inflate. */
  @State controlModeTabsShown: boolean = false;
  /** playback_unhook_key, default true. */
  @State unhook: boolean = true;
  /** The three preference reads are async, so the dialog opens before they land. */
  @State isLoading: boolean = true;
  /** A preference read/write that failed - the dialog still works off the defaults. */
  @State errorInfo: string = '';
  /**
   * Callback.onPlaybackParameterChanged(tempo, pitch, skipSilence) - the DialogFragment's only
   * outward channel. onAttach dismisses when the host is not a Callback; here the host always
   * passes one, and the default below keeps the contract explicit rather than silent.
   */
  onPlaybackParameterChanged: (tempo: number, pitchPercent: number, skipSilence: boolean) => void =
    (tempo: number, pitchPercent: number, skipSilence: boolean): void => {
      hilog.warn(0x0000, 'PlaybackParameterDialog',
        'no Callback: tempo=%{public}f pitch=%{public}f skipSilence=%{public}d',
        tempo, pitchPercent, skipSilence ? 1 : 0);
    };

  /*//////////////////////////////////////////////////////////////////////////
  // Lifecycle
  //////////////////////////////////////////////////////////////////////////*/

  /**
   * newInstance() seeds tempo/pitch/skipSilence from the initial values, and initUI() reads
   * adjustment_step_key, playback_adjust_by_semitones_key and playback_unhook_key out of the
   * default SharedPreferences.
   */
  aboutToAppear(): void {
    this.tempo = this.initialValues.tempo;
    this.pitchPercent = this.initialValues.pitchPercent;
    this.skipSilence = this.initialValues.skipSilence;
    this.isLoading = true;
    this.errorInfo = '';
    this.loadPreferences()
      .catch((err: Error): void => {
        this.isLoading = false;
        this.errorInfo = err.message;
        hilog.error(0x0000, 'PlaybackParameterDialog', 'reading playback prefs: %{public}s',
          err.message);
      });
  }

  private async loadPreferences(): Promise<void> {
    // getCurrentStepSize() / isCurrentPitchControlModeSemitone() / bindCheckboxWithBoolPref.
    this.stepSizeSelection = await AppPreferences.getFloat(adjustment_step_key, DEFAULT_STEP);
    this.pitchModeSelection =
      await AppPreferences.getBoolean(playback_adjust_by_semitones_key, false);
    this.unhook = await AppPreferences.getBoolean(playback_unhook_key, true);
    this.isLoading = false;
  }

  /*//////////////////////////////////////////////////////////////////////////
  // Sliders
  //////////////////////////////////////////////////////////////////////////*/

  /** updateCallback(): callback.onPlaybackParameterChanged(tempo, pitchPercent, skipSilence). */
  private updateCallback(): void {
    this.onPlaybackParameterChanged(this.tempo, this.pitchPercent, this.skipSilence);
  }

  /** setAndUpdateTempo(newTempo). */
  private setAndUpdateTempo(newTempo: number): void {
    this.tempo = clampPitchOrSpeed(newTempo);
  }

  /** setAndUpdatePitch(newPitch) - through calcValidPitch, so semitone mode stays on-grid. */
  private setAndUpdatePitch(newPitch: number): void {
    this.pitchPercent = this.calcValidPitch(newPitch);
  }

  /** setSliders(newValue): tempo AND pitch together - the hooked case. */
  private setSliders(newValue: number): void {
    this.setAndUpdateTempo(newValue);
    this.setAndUpdatePitch(newValue);
  }

  /**
   * calcValidPitch(newPitch): clamp, and in SEMITONE mode snap to the nearest whole semitone.
   * Reads pitchModeSelection, which is isCurrentPitchControlModeSemitone()'s preference.
   */
  private calcValidPitch(newPitch: number): number {
    const calcPitch: number = clampPitchOrSpeed(newPitch);
    if (!this.pitchModeSelection) {
      return calcPitch;
    }
    return semitonesToPercent(percentToSemitones(calcPitch));
  }

  /** onTempoSliderUpdated(newTempo): unhooked drives both, hooked drives tempo alone. */
  private onTempoSliderUpdated(newTempo: number): void {
    if (!this.unhook) {
      this.setSliders(newTempo);
    } else {
      this.setAndUpdateTempo(newTempo);
    }
  }

  /** onPitchPercentSliderUpdated(newPitch). */
  private onPitchPercentSliderUpdated(newPitch: number): void {
    if (!this.unhook) {
      this.setSliders(newPitch);
    } else {
      this.setAndUpdatePitch(newPitch);
    }
  }

  /** ensureHookIsValidAndUpdateCallBack(): snap tempo and pitch back together. */
  private ensureHookIsValidAndUpdateCallBack(): void {
    if (this.tempo !== this.pitchPercent) {
      this.setSliders(Math.min(this.tempo, this.pitchPercent));
      this.updateCallback();
    }
  }

  /**
   * bindCheckboxWithBoolPref(playback_unhook_key, true): persist, then - when UNCHECKED - drag
   * tempo and pitch back together.
   */
  private setUnhook(value: boolean): void {
    if (value === this.unhook) {
      return;
    }
    this.unhook = value;
    this.putBoolean(playback_unhook_key, value);
    if (!value) {
      this.ensureHookIsValidAndUpdateCallBack();
    }
  }

  /** registerOnSemitoneStepClickListener(view, direction): the flat / sharp buttons. */
  private stepSemitone(direction: number): void {
    this.onPitchPercentSliderUpdated(
      semitonesToPercent(percentToSemitones(this.pitchPercent) + direction));
    this.updateCallback();
  }

  /*//////////////////////////////////////////////////////////////////////////
  // Pitch control mode / step size - both write their preference first
  //////////////////////////////////////////////////////////////////////////*/

  /** setupPitchControlModeTextView(semitones): write the pref, then changePitchControlMode(). */
  private selectPitchControlMode(semitones: boolean): void {
    this.putBoolean(playback_adjust_by_semitones_key, semitones);
    this.changePitchControlMode(semitones);
  }

  /**
   * changePitchControlMode(semitones): swap which control is visible and, when moving TO
   * semitone mode, re-quantise an off-grid pitch; when moving back to percent with the sliders
   * hooked, snap tempo and pitch together again.
   */
  private changePitchControlMode(semitones: boolean): void {
    this.pitchModeSelection = semitones;
    if (semitones) {
      const newPitchPercent: number = this.calcValidPitch(this.pitchPercent);
      if (this.pitchPercent !== newPitchPercent) {
        this.onPitchPercentSliderUpdated(newPitchPercent);
        this.updateCallback();
      }
    } else if (!this.unhook) {
      this.ensureHookIsValidAndUpdateCallBack();
    }
  }

  /** setupStepTextView(value): putFloat(adjustment_step_key, value), then setStepSizeToUI(). */
  private selectStepSize(value: number): void {
    this.stepSizeSelection = value;
    const store: AppPreferences = AppPreferences.instance();
    store.putFloat(adjustment_step_key, value);
    store.flush()
      .catch((err: Error): void => {
        this.errorInfo = err.message;
        hilog.error(0x0000, 'PlaybackParameterDialog', 'writing %{public}s: %{public}s',
          adjustment_step_key, err.message);
      });
  }

  /** bindCheckboxWithBoolPref(): the checkbox value is persisted on every change. */
  private putBoolean(key: string, value: boolean): void {
    AppPreferences.putBoolean(key, value)
      .catch((err: Error): void => {
        this.errorInfo = err.message;
        hilog.error(0x0000, 'PlaybackParameterDialog', 'writing %{public}s: %{public}s',
          key, err.message);
      });
  }

  /**
   * setStepSizeToUI(newStepSize) marks the chosen TextView with a LayerDrawable of
   * R.attr.dashed_border over selectableItemBackground - not a checkbox, not a radio. S5 styles
   * that border; the structural half is that all five exist and one is current.
   */
  @Builder
  stepSizeOption(slug: string, value: number) {
    Text(formatPitch(value))
      .id(slug)
      .fontSize(BODY_TEXT_SIZE)
      .fontColor($r('app.color.accent'))
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height('100%')
      // setStepSizeToUI(newStepSize): the selected TextView gets the dashed_border LayerDrawable.
      .border(dashedBorder(this.stepSizeSelection === value))
      .onClick((): void => {
        this.selectStepSize(value);
      })
  }

  @Builder
  tempoControl() {
    Column() {
      Text($r('app.string.playback_tempo'))
        .id('tempoControlText')
        .width('100%')
        .fontSize(BODY_TEXT_SIZE)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.accent'))
        .textAlign(TextAlign.Center)

      Row() {
        // tempoStepDown / tempoStepUp: android:text is a placeholder ("--%" / "+-%") that
        // setStepSizeToUI immediately overwrites, so the label is DERIVED from the step size.
        Text(stepDownLabel(this.stepSizeSelection))
          .id('tempoStepDown')
          .fontSize(BODY_TEXT_SIZE)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.accent'))
          .textAlign(TextAlign.Center)
          .onClick((): void => {
            this.onTempoSliderUpdated(this.tempo - this.stepSizeSelection);
            this.updateCallback();
          })

        Column() {
          Row() {
            Text(formatSpeed(MIN_PITCH_OR_SPEED))
              .id('tempoMinimumText')
              .fontSize(BODY_TEXT_SIZE)
              .fontColor($r('app.color.accent'))
              .margin({ left: CONTROL_GUTTER })
            Text(formatSpeed(this.tempo))
              .id('tempoCurrentText')
              .fontSize(BODY_TEXT_SIZE)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.accent'))
              .layoutWeight(1)
              .textAlign(TextAlign.Center)
            Text(formatSpeed(MAX_PITCH_OR_SPEED))
              .id('tempoMaximumText')
              .fontSize(BODY_TEXT_SIZE)
              .fontColor($r('app.color.accent'))
              .margin({ right: CONTROL_GUTTER })
          }
          .width('100%')

          // QUADRATIC_STRATEGY over MIN_PITCH_OR_SPEED..MAX_PITCH_OR_SPEED. The non-linear
          // progress<->value mapping is S4's; the control and its range are the structure.
          Slider({
            value: quadraticProgressOf(this.tempo),
            min: 0,
            max: QUADRATIC_MAX_PROGRESS,
            step: 1
          })
            .id('tempoSeekbar')
            .width('100%')
            .selectedColor($r('app.color.primary'))
            .blockColor($r('app.color.primary'))
            .onChange((progress: number): void => {
              this.onTempoSliderUpdated(quadraticValueOf(progress));
              this.updateCallback();
            })
        }
        .layoutWeight(1)
        .margin({ left: CONTROL_GUTTER, right: CONTROL_GUTTER })

        Text(stepUpLabel(this.stepSizeSelection))
          .id('tempoStepUp')
          .fontSize(BODY_TEXT_SIZE)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.accent'))
          .textAlign(TextAlign.Center)
          .margin({ right: CONTROL_GUTTER })
          .onClick((): void => {
            this.onTempoSliderUpdated(this.tempo + this.stepSizeSelection);
            this.updateCallback();
          })
      }
      .id('tempoControl')
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  pitchControl() {
    Column() {
      Row() {
        Text($r('app.string.playback_pitch'))
          .id('pitchControlText')
          .fontSize(BODY_TEXT_SIZE)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.accent'))
          .textAlign(TextAlign.Center)
          .layoutWeight(1)

        // ImageView src=@drawable/ic_expand_more, rotated 0 <-> 180 (feat_animations, S4/S6).
        Image($r('app.media.ic_expand_more'))
          .id('pitchToogleControlModes')
          .width(CHEVRON_SIZE)
          .height(CHEVRON_SIZE)
          .objectFit(ImageFit.Contain)
          .fillColor($r('app.color.accent'))
          .rotate({ angle: this.controlModeTabsShown ? 180 : 0 })
          // ViewUtils.animateRotation(pitchToogleControlModes, 0 <-> 180) - feat_animations.
          .animation({ duration: 250, curve: Curve.EaseInOut })
          .onClick((): void => {
            this.controlModeTabsShown = !this.controlModeTabsShown;
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // android:visibility="gone" until the chevron is tapped.
      if (this.controlModeTabsShown) {
        Row() {
          Text($r('app.string.percent'))
            .id('pitchControlModePercent')
            .fontSize(BODY_TEXT_SIZE)
            .fontColor($r('app.color.accent'))
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .height('100%')
            // Mark the selected textview - the percent tab is current while semitones is false.
            .border(dashedBorder(!this.pitchModeSelection))
            .onClick((): void => {
              this.selectPitchControlMode(false);
            })
          Text($r('app.string.semitone'))
            .id('pitchControlModeSemitone')
            .fontSize(BODY_TEXT_SIZE)
            .fontColor($r('app.color.accent'))
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
            .height('100%')
            .border(dashedBorder(this.pitchModeSelection))
            .onClick((): void => {
              this.selectPitchControlMode(true);
            })
        }
        .id('pitchControlModeTabs')
        .width('100%')
        .height(22)
        .margin({ left: 22, right: 22 })
      }

      Column() {
        // changePitchControlMode(semitones): pitchPercentControl and pitchSemitoneControl are
        // MUTUALLY EXCLUSIVE (one GONE while the other is VISIBLE), never both rendered.
        if (this.pitchModeSelection) {
          Row() {
            // The source's own literals: a flat and a sharp sign, not string resources.
            Text('♭')
              .id('pitchSemitoneStepDown')
              .fontSize(SEMITONE_FLAT_TEXT_SIZE)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.accent'))
              .width(SEMITONE_STEP_WIDTH)
              .textAlign(TextAlign.Center)
              .onClick((): void => {
                this.stepSemitone(-1);
              })

            Column() {
              Row() {
                Text(formatPitchSemitones(-SEMITONE_COUNT))
                  .id('pitchSemitoneMinimumText')
                  .fontSize(BODY_TEXT_SIZE)
                  .fontColor($r('app.color.accent'))
                  .margin({ left: CONTROL_GUTTER })
                Text(formatPitchSemitones(percentToSemitones(this.pitchPercent)))
                  .id('pitchSemitoneCurrentText')
                  .fontSize(BODY_TEXT_SIZE)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.accent'))
                  .layoutWeight(1)
                  .textAlign(TextAlign.Center)
                Text(formatPitchSemitones(SEMITONE_COUNT))
                  .id('pitchSemitoneMaximumText')
                  .fontSize(BODY_TEXT_SIZE)
                  .fontColor($r('app.color.accent'))
                  .margin({ right: CONTROL_GUTTER })
              }
              .id('pitchSemitoneDisplay')
              .width('100%')

              // SEMITONE_STRATEGY: linear over -12..+12, step 1.
              // SEMITONE_STRATEGY: percentToSemitones/semitonesToPercent, linear over -12..+12.
              Slider({
                value: percentToSemitones(this.pitchPercent),
                min: -SEMITONE_COUNT,
                max: SEMITONE_COUNT,
                step: 1
              })
                .id('pitchSemitoneSeekbar')
                .width('100%')
                .selectedColor($r('app.color.primary'))
                .blockColor($r('app.color.primary'))
                .onChange((semitones: number): void => {
                  this.onPitchPercentSliderUpdated(semitonesToPercent(Math.round(semitones)));
                  this.updateCallback();
                })
            }
            .layoutWeight(1)
            .margin({ left: CONTROL_GUTTER, right: CONTROL_GUTTER })

            Text('♯')
              .id('pitchSemitoneStepUp')
              .fontSize(SEMITONE_SHARP_TEXT_SIZE)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.accent'))
              .width(SEMITONE_STEP_WIDTH)
              .textAlign(TextAlign.Center)
              .margin({ right: CONTROL_GUTTER })
              .onClick((): void => {
                this.stepSemitone(1);
              })
          }
          .id('pitchSemitoneControl')
          .width('100%')
          .alignItems(VerticalAlign.Center)
        } else {
          Row() {
            Text(stepDownLabel(this.stepSizeSelection))
              .id('pitchPercentStepDown')
              .fontSize(BODY_TEXT_SIZE)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.accent'))
              .textAlign(TextAlign.Center)
              .onClick((): void => {
                this.onPitchPercentSliderUpdated(this.pitchPercent - this.stepSizeSelection);
                this.updateCallback();
              })

            Column() {
              Row() {
                Text(formatPitch(MIN_PITCH_OR_SPEED))
                  .id('pitchPercentMinimumText')
                  .fontSize(BODY_TEXT_SIZE)
                  .fontColor($r('app.color.accent'))
                  .margin({ left: CONTROL_GUTTER })
                Text(formatPitch(this.pitchPercent))
                  .id('pitchPercentCurrentText')
                  .fontSize(BODY_TEXT_SIZE)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.accent'))
                  .layoutWeight(1)
                  .textAlign(TextAlign.Center)
                Text(formatPitch(MAX_PITCH_OR_SPEED))
                  .id('pitchPercentMaximumText')
                  .fontSize(BODY_TEXT_SIZE)
                  .fontColor($r('app.color.accent'))
                  .margin({ right: CONTROL_GUTTER })
              }
              .id('pitchPercentDisplay')
              .width('100%')

              // QUADRATIC_STRATEGY, the same range as the tempo bar.
              Slider({
                value: quadraticProgressOf(this.pitchPercent),
                min: 0,
                max: QUADRATIC_MAX_PROGRESS,
                step: 1
              })
                .id('pitchPercentSeekbar')
                .width('100%')
                .selectedColor($r('app.color.primary'))
                .blockColor($r('app.color.primary'))
                .onChange((progress: number): void => {
                  this.onPitchPercentSliderUpdated(quadraticValueOf(progress));
                  this.updateCallback();
                })
            }
            .layoutWeight(1)
            .margin({ left: CONTROL_GUTTER, right: CONTROL_GUTTER })

            Text(stepUpLabel(this.stepSizeSelection))
              .id('pitchPercentStepUp')
              .fontSize(BODY_TEXT_SIZE)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.accent'))
              .textAlign(TextAlign.Center)
              .margin({ right: CONTROL_GUTTER })
              .onClick((): void => {
                this.onPitchPercentSliderUpdated(this.pitchPercent + this.stepSizeSelection);
                this.updateCallback();
              })
          }
          .id('pitchPercentControl')
          .width('100%')
          .alignItems(VerticalAlign.Center)
        }
      }
      .id('pitchControlContainer')
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    // T-0133: nothing on this platform applies a pitch shift to AVPlayer's output, so the whole
    // block is disabled rather than left movable. The controls are KEPT - they are a faithful
    // port of the reference's two modes, the quadratic slider and the semitone quantisation, and
    // a later platform would want them back. The reason is printed below, outside this scope so
    // it stays readable.
    .enabled(false)
    .opacity(DISABLED_OPACITY)
  }

  @Builder
  stepSizeSelector() {
    Row() {
      Text($r('app.string.playback_step'))
        .id('playback_step_type')
        .fontSize(BODY_TEXT_SIZE)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.accent'))
        .textAlign(TextAlign.Center)
        .layoutWeight(1)
        .height('100%')
      this.stepSizeOption('stepSizeOnePercent', STEP_1_PERCENT_VALUE)
      this.stepSizeOption('stepSizeFivePercent', STEP_5_PERCENT_VALUE)
      this.stepSizeOption('stepSizeTenPercent', STEP_10_PERCENT_VALUE)
      this.stepSizeOption('stepSizeTwentyFivePercent', STEP_25_PERCENT_VALUE)
      this.stepSizeOption('stepSizeOneHundredPercent', STEP_100_PERCENT_VALUE)
    }
    .id('stepSizeSelector')
    .width('100%')
    .height(STEP_SIZE_ROW_HEIGHT)
    .alignItems(VerticalAlign.Center)
  }

  build() {
    // The layout root is a ScrollView: the dialog body scrolls, the three buttons do not.
    Column() {
      Scroll() {
        Column() {
          this.tempoControl()

          Divider()
            .id('separatorPitch')
            .strokeWidth(1)
            .color($r('app.color.separator'))
            .margin({ left: 12, right: 12, top: 5, bottom: 5 })

          this.pitchControl()

          Text($r('app.string.playback_pitch_unsupported'))
            .id('pitchUnsupportedNote')
            .width('100%')
            .fontSize(NOTE_TEXT_SIZE)
            .fontColor($r('app.color.on_surface_variant'))
            .padding({ left: BODY_PADDING_HORIZONTAL, right: BODY_PADDING_HORIZONTAL })

          Divider()
            .id('separatorStepSizeSelector')
            .strokeWidth(1)
            .color($r('app.color.separator'))
            .margin({ left: 12, right: 12, top: 5, bottom: 5 })

          this.stepSizeSelector()

          Divider()
            .id('separatorCheckbox')
            .strokeWidth(1)
            .color($r('app.color.separator'))
            .margin({ left: 12, right: 12, top: 5, bottom: 5 })

          Column() {
            // Two CheckBoxes, as dialog_playback_parameter.xml declares them. ArkUI's Checkbox
            // draws a CIRCLE unless told otherwise - which read as a radio button - and the
            // shared `group` tied them to a CheckboxGroup that does not exist. Like an Android
            // CheckBox, the label toggles it too.
            Row() {
              Checkbox()
                .id('unhookCheckbox')
                .shape(CheckBoxShape.ROUNDED_SQUARE)
                .selectedColor($r('app.color.primary'))
                .select(this.unhook)
                // The ROW takes the tap, box and label alike, so one tap is one toggle - a box
                // that handled its own tap as well would flip the value straight back.
                .hitTestBehavior(HitTestMode.None)
              Text($r('app.string.unhook_checkbox'))
                .fontSize(BODY_TEXT_SIZE)
                .fontColor($r('app.color.on_surface'))
                .layoutWeight(1)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .onClick((): void => {
              this.setUnhook(!this.unhook);
            })

            Row() {
              Checkbox()
                .id('skipSilenceCheckbox')
                .shape(CheckBoxShape.ROUNDED_SQUARE)
                .selectedColor($r('app.color.primary'))
                .select(this.skipSilence)
              Text($r('app.string.skip_silence_checkbox'))
                .fontSize(BODY_TEXT_SIZE)
                .fontColor($r('app.color.on_surface'))
                .layoutWeight(1)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            // T-0133: 'skipSilence' appears nowhere in either SDK - there is nothing to wire, so
            // the box shows the value it was handed and cannot be changed.
            .enabled(false)
            .opacity(DISABLED_OPACITY)

            Text($r('app.string.playback_skip_silence_unsupported'))
              .id('skipSilenceUnsupportedNote')
              .width('100%')
              .fontSize(NOTE_TEXT_SIZE)
              .fontColor($r('app.color.on_surface_variant'))
          }
          .id('additionalOptions')
          .width('100%')
        }
        .width('100%')
        .padding({
          left: BODY_PADDING_HORIZONTAL,
          top: BODY_PADDING_TOP,
          right: BODY_PADDING_HORIZONTAL
        })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      // No layoutWeight: it made the body greedy for every pixel its host offered, which is why
      // the card filled the screen top to bottom with empty bands around the controls. The
      // reference's panel hugs its content and the hosts size nothing.

      // The three AlertDialog buttons, in the order the reference LAYS THEM OUT:
      // NEUTRAL first, then NEGATIVE, then POSITIVE - measured on 0.29.1 as RESET CANCEL OK.
      // The port had Cancel Reset OK, and drew them in sentence case where an AlertDialog
      // button is upper case.
      // S4 wires updateCallback() -> Callback.onPlaybackParameterChanged through svc_player.
      Row() {
        // BUTTON_NEUTRAL: 1.00 / 1.00 / DEFAULT_SKIP_SILENCE, then updateCallback(). It does NOT
        // dismiss - the source leaves the dialog open on reset.
        Text(Localization.buttonLabel('playback_reset'))
          .id('Reset')
          .fontSize(BODY_TEXT_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.accent'))
          .padding({ left: 8, right: 8, top: 6, bottom: 6 })
          .margin({ left: 8 })
          .onClick((): void => {
            this.setAndUpdateTempo(DEFAULT_TEMPO);
            this.setAndUpdatePitch(DEFAULT_PITCH_PERCENT);
            this.skipSilence = false;
            this.updateCallback();
          })
        // AlertDialog puts NEUTRAL at the start edge and NEGATIVE/POSITIVE at the end.
        Blank()
        // BUTTON_NEGATIVE: restore the initial values and PUSH THEM BACK to the player - a
        // revert, not a plain dismiss.
        Text(Localization.buttonLabel('cancel'))
          .id('Cancel')
          .fontSize(BODY_TEXT_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.accent'))
          .padding({ left: 8, right: 8, top: 6, bottom: 6 })
          .margin({ left: 8 })
          .onClick((): void => {
            this.setAndUpdateTempo(this.initialValues.tempo);
            this.setAndUpdatePitch(this.initialValues.pitchPercent);
            this.skipSilence = this.initialValues.skipSilence;
            this.updateCallback();
            this.isShown = false;
          })
        // BUTTON_POSITIVE: updateCallback() commits the current values.
        Text(Localization.buttonLabel('ok'))
          .id('OK')
          .fontSize(BODY_TEXT_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.accent'))
          .padding({ left: 8, right: 8, top: 6, bottom: 6 })
          .margin({ left: 8 })
          .onClick((): void => {
            this.updateCallback();
            this.isShown = false;
          })
      }
      .width('100%')
      .padding(DIALOG_PADDING)
      .justifyContent(FlexAlign.End)

      // A preference read or write that failed. The dialog still operates off the defaults, so
      // this reports rather than blocks - the source has no equivalent panel because
      // SharedPreferences cannot fail synchronously.
      if (!this.isLoading && this.errorInfo.length > 0) {
        Text(this.errorInfo)
          .width('100%')
          .fontSize(BODY_TEXT_SIZE)
          .fontColor($r('app.color.on_surface_variant'))
          .padding({ left: DIALOG_PADDING, right: DIALOG_PADDING, bottom: DIALOG_PADDING })
      }
    }
    .id(this.dialogId)
    .width('100%')
  }
}

/**
 * The source is a centred AlertDialog, so both hosts open this through a CustomDialogController
 * rather than .bindSheet(): the system dialog fades its own scrim in, closes on an outside tap
 * (keeping the values, as the reference's cancel-on-touch-outside does) and sizes the card.
 * A controller's builder must be a @CustomDialog, hence this thin wrapper.
 */
@CustomDialog
export struct PlaybackParameterDialogHost {
  @Prop dialogId: string = 'PlaybackParameterDialogPage';
  @Link isShown: boolean;
  @Prop initialValues: PlaybackParameters =
    new PlaybackParameters(DEFAULT_TEMPO, DEFAULT_PITCH_PERCENT, false);
  onPlaybackParameterChanged: (tempo: number, pitchPercent: number, skipSilence: boolean) => void =
    (): void => {};
  controller?: CustomDialogController;

  build() {
    Column() {
      PlaybackParameterDialogPage({
        dialogId: this.dialogId,
        isShown: this.isShown,
        initialValues: this.initialValues,
        onPlaybackParameterChanged: this.onPlaybackParameterChanged
      })
    }
    // The reference's AlertDialog is ~86% of a phone's width.
    .width('86%')
    .backgroundColor($r('app.color.dialog_surface'))
  }
}
