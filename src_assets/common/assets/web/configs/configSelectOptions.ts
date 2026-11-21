export type ConfigSelectOption = { label: string; value: string | number; disabled?: boolean };

export type ConfigSelectOptionsContext = {
  t: (key: string) => string;
  platform: string;
  metadata?: any;
  currentValue?: unknown;
};

function isSelectValue(value: unknown): value is string | number {
  return typeof value === 'string' || (typeof value === 'number' && Number.isFinite(value));
}

function ensureIncludesCurrentValue(
  options: ConfigSelectOption[],
  currentValue: unknown,
): ConfigSelectOption[] {
  if (!isSelectValue(currentValue)) return options;
  if (options.some((option) => option.value === currentValue)) return options;
  return options.concat([{ label: String(currentValue), value: currentValue }]);
}

const localeOptions: ConfigSelectOption[] = [
  { label: 'Български', value: 'bg' },
  { label: 'Čeština', value: 'cs' },
  { label: 'Deutsch', value: 'de' },
  { label: 'English', value: 'en' },
  { label: 'English (UK)', value: 'en_GB' },
  { label: 'English (US)', value: 'en_US' },
  { label: 'Español', value: 'es' },
  { label: 'Français', value: 'fr' },
  { label: 'Magyar', value: 'hu' },
  { label: 'Italiano', value: 'it' },
  { label: '日本語', value: 'ja' },
  { label: '한국어', value: 'ko' },
  { label: 'Polski', value: 'pl' },
  { label: 'Português', value: 'pt' },
  { label: 'Português (Brasil)', value: 'pt_BR' },
  { label: 'Русский', value: 'ru' },
  { label: 'Svenska', value: 'sv' },
  { label: 'Türkçe', value: 'tr' },
  { label: 'Українська', value: 'uk' },
  { label: 'Tiếng Việt', value: 'vi' },
  { label: '简体中文', value: 'zh' },
  { label: '繁體中文', value: 'zh_TW' },
];

export function getConfigSelectOptions(
  key: string,
  ctx: ConfigSelectOptionsContext,
): ConfigSelectOption[] {
  const { t } = ctx;

  switch (key) {
    case 'locale':
      return ensureIncludesCurrentValue(localeOptions, ctx.currentValue);
    case 'min_log_level': {
      const options = [0, 1, 2, 3, 4, 5, 6].map((value) => ({
        label: t(`config.min_log_level_${value}`),
        value,
      }));
      return ensureIncludesCurrentValue(options, ctx.currentValue);
    }
    case 'address_family': {
      const options = [
        { label: t('config.address_family_ipv4'), value: 'ipv4' },
        { label: t('config.address_family_both'), value: 'both' },
      ];
      return ensureIncludesCurrentValue(options, ctx.currentValue);
    }
    case 'origin_web_ui_allowed': {
      const options = [
        { label: t('config.origin_web_ui_allowed_pc'), value: 'pc' },
        { label: t('config.origin_web_ui_allowed_lan'), value: 'lan' },
        { label: t('config.origin_web_ui_allowed_wan'), value: 'wan' },
      ];
      return ensureIncludesCurrentValue(options, ctx.currentValue);
    }
    case 'lan_encryption_mode': {
      const options = [
        { label: t('_common.disabled_def'), value: 0 },
        { label: t('config.lan_encryption_mode_1'), value: 1 },
        { label: t('config.lan_encryption_mode_2'), value: 2 },
      ];
      return ensureIncludesCurrentValue(options, ctx.currentValue);
    }
    case 'wan_encryption_mode': {
      const options = [
        { label: t('_common.disabled'), value: 0 },
        { label: t('config.wan_encryption_mode_1'), value: 1 },
        { label: t('config.wan_encryption_mode_2'), value: 2 },
      ];
      return ensureIncludesCurrentValue(options, ctx.currentValue);
    }
    case 'video_max_batch_size_kb': {
      const options = [
        { label: `64 KiB ${t('_common.default_parenthetical')}`, value: 64 },
        { label: '32 KiB', value: 32 },
        { label: '16 KiB', value: 16 },
      ];
      return ensureIncludesCurrentValue(options, ctx.currentValue);
    }
    case 'hevc_mode': {
      const options = [0, 1, 2, 3].map((value) => ({
        label: t(`config.hevc_mode_${value}`),
        value,
      }));
      return ensureIncludesCurrentValue(options, ctx.currentValue);
    }
    case 'av1_mode': {
      const options = [0, 1, 2, 3].map((value) => ({
        label: t(`config.av1_mode_${value}`),
        value,
      }));
      return ensureIncludesCurrentValue(options, ctx.currentValue);
    }
    case 'encoder': {
      const options: ConfigSelectOption[] = [
        { label: t('_common.autodetect'), value: '' },
        { label: 'VideoToolbox', value: 'videotoolbox' },
        { label: t('config.encoder_software'), value: 'software' },
      ];
      return ensureIncludesCurrentValue(options, ctx.currentValue);
    }
    case 'vt_coder': {
      const options = [
        { label: t('config.ffmpeg_auto'), value: 'auto' },
        { label: t('config.coder_cabac'), value: 'cabac' },
        { label: t('config.coder_cavlc'), value: 'cavlc' },
      ];
      return ensureIncludesCurrentValue(options, ctx.currentValue);
    }
    case 'vt_software': {
      const options = [
        { label: t('_common.auto'), value: 'auto' },
        { label: t('_common.disabled'), value: 'disabled' },
        { label: t('config.vt_software_allowed'), value: 'allowed' },
        { label: t('config.vt_software_forced'), value: 'forced' },
      ];
      return ensureIncludesCurrentValue(options, ctx.currentValue);
    }
    case 'sw_preset': {
      const options = [
        { label: t('config.sw_preset_ultrafast'), value: 'ultrafast' },
        { label: t('config.sw_preset_superfast'), value: 'superfast' },
        { label: t('config.sw_preset_veryfast'), value: 'veryfast' },
        { label: t('config.sw_preset_faster'), value: 'faster' },
        { label: t('config.sw_preset_fast'), value: 'fast' },
        { label: t('config.sw_preset_medium'), value: 'medium' },
        { label: t('config.sw_preset_slow'), value: 'slow' },
        { label: t('config.sw_preset_slower'), value: 'slower' },
        { label: t('config.sw_preset_veryslow'), value: 'veryslow' },
      ];
      return ensureIncludesCurrentValue(options, ctx.currentValue);
    }
    case 'sw_tune': {
      const options = [
        { label: t('config.sw_tune_film'), value: 'film' },
        { label: t('config.sw_tune_animation'), value: 'animation' },
        { label: t('config.sw_tune_grain'), value: 'grain' },
        { label: t('config.sw_tune_stillimage'), value: 'stillimage' },
        { label: t('config.sw_tune_fastdecode'), value: 'fastdecode' },
        { label: t('config.sw_tune_zerolatency'), value: 'zerolatency' },
      ];
      return ensureIncludesCurrentValue(options, ctx.currentValue);
    }
    case 'virtual_display_mode': {
      const options = [
        { label: t('config.virtual_display_mode_disabled'), value: 'disabled' },
        { label: t('config.virtual_display_mode_per_client'), value: 'per_client' },
        { label: t('config.virtual_display_mode_shared'), value: 'shared' },
      ];
      return ensureIncludesCurrentValue(options, ctx.currentValue);
    }
    case 'virtual_display_layout': {
      const options = [
        { label: t('config.virtual_display_layout_exclusive'), value: 'exclusive' },
        { label: t('config.virtual_display_layout_extended'), value: 'extended' },
        { label: t('config.virtual_display_layout_extended_primary'), value: 'extended_primary' },
        { label: t('config.virtual_display_layout_extended_isolated'), value: 'extended_isolated' },
        {
          label: t('config.virtual_display_layout_extended_primary_isolated'),
          value: 'extended_primary_isolated',
        },
      ];
      return ensureIncludesCurrentValue(options, ctx.currentValue);
    }
    case 'dd_virtual_display_scale': {
      const options: ConfigSelectOption[] = [
        { label: t('config.virtual_display_scale_recommended'), value: -1 },
        { label: t('config.virtual_display_scale_auto'), value: 0 },
        ...[100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500].map((value) => ({
          label: `${value}%`,
          value,
        })),
      ];
      return ensureIncludesCurrentValue(options, ctx.currentValue);
    }
    default:
      return [];
  }
}

export function buildConfigOptionsText(options: ConfigSelectOption[]): string {
  if (options.length === 0) return '';
  return options
    .map((option) => `${option.label || ''} ${String(option.value ?? '')}`.trim())
    .filter(Boolean)
    .join(' | ');
}
