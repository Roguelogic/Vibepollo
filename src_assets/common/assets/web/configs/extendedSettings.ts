import { getConfigFieldDefinition } from './configFieldSchema.ts';
import type { SettingsField, SettingsGroup } from './settingsSchema.ts';

// Defaults and wire values for the standalone macOS host configuration.
export const extendedDefaults: Record<string, unknown> = {
  vt_coder: 'auto',
  vt_software: 'auto',
  vt_realtime: 'enabled',
  sw_preset: 'superfast',
  sw_tune: 'zerolatency',
  min_threads: 2,
  locale: 'en',
  update_check_interval: 86400,
  session_token_ttl_seconds: 86400,
  remember_me_refresh_token_ttl_seconds: 604800,
  back_button_timeout: -1,
  guide_button_key: 0,
  guide_button_controller: 0,
  key_rightalt_to_key_win: 'disabled',
  credentials_file: '',
  file_state: '',
  realtime_stats_enabled: true,
  realtime_stats_poll_interval_ms: 2000,
  realtime_stats_history_retention_seconds: 300,
  realtime_stats_max_history_points: 300,
  realtime_stats_pause_when_hidden: true,
  realtime_stats_show_active_sessions: true,
  realtime_stats_show_host_stats: true,
  realtime_stats_show_host_charts: true,
  realtime_stats_show_session_history: true,
  app_focus_attempts: 3,
  app_focus_timeout_secs: 15,
  app_focus_exit_on_first: false,
};

export function extendedField(key: string, extra: Partial<SettingsField> = {}): SettingsField {
  const definition = getConfigFieldDefinition(key, {
    t: (k) => k,
    platform: 'macos',
    defaultValue: extendedDefaults[key],
  });
  const kind =
    definition.kind === 'checkbox' || definition.kind === 'switch'
      ? 'boolean'
      : definition.kind === 'number' || definition.kind === 'slider'
        ? 'number'
        : definition.kind === 'select'
          ? 'select'
          : 'text';
  return {
    key,
    kind,
    min: definition.min,
    max: definition.max,
    step: definition.step,
    options: definition.options?.map((option) => ({
      value: String(option.value),
      labelKey: option.label,
    })),
    ...extra,
  };
}

const encoderFamilies = {
  vt: 'videotoolbox',
  sw: 'software',
} as const;

export const advancedEncoderGroups: SettingsGroup[] = Object.entries(encoderFamilies).map(
  ([prefix, encoderFamily]) => ({
    id: `encoder_${prefix}`,
    collapsed: prefix !== 'vt',
    fields: Object.keys(extendedDefaults)
      .filter((key) => key.startsWith(`${prefix}_`))
      .map((key) =>
        extendedField(key, {
          encoderFamily,
        }),
      ),
  }),
);
