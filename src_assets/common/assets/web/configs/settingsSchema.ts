import {
  advancedEncoderGroups,
  extendedDefaults,
  extendedField,
} from './extendedSettings.ts';
import { NETWORK_PORT_MAX, NETWORK_PORT_MIN } from '../utils/network.ts';

export type SettingsFieldKind =
  | 'boolean'
  | 'number'
  | 'select'
  | 'duration'
  | 'text'
  | 'textarea'
  | 'command-preparations'
  | 'server-commands';

export interface SettingsOption {
  labelKey: string;
  value: string;
}

export interface SettingsVisibility {
  key: string;
  equals?: string | boolean;
  notEquals?: string | boolean;
}

export interface SettingsField {
  key: string;
  kind: SettingsFieldKind;
  labelKey?: string;
  descriptionKey?: string;
  warningKey?: string;
  options?: SettingsOption[];
  min?: number;
  max?: number;
  step?: number;
  placeholderKey?: string;
  monospace?: boolean;
  restartRequired?: boolean;
  stacked?: boolean;
  recommended?: boolean;
  simple?: boolean;
  platform?: 'windows' | 'linux' | 'macos' | Array<'windows' | 'linux' | 'macos'>;
  visibleWhen?: SettingsVisibility;
  source?: 'gpu';
  encoderFamily?: 'videotoolbox' | 'software';
}

// Per-client / per-app runtime overrides supported on macOS.
export const clientOverrideableKeys = new Set([
  'controller',
  'motion_as_ds4',
  'touchpad_as_ds4',
  'back_button_timeout',
  'guide_button_key',
  'guide_button_controller',
  'keyboard',
  'key_repeat_delay',
  'key_repeat_frequency',
  'key_rightalt_to_key_win',
  'mouse',
  'high_resolution_scrolling',
  'native_pen_touch',
  'macos_scroll_inertia',
  'macos_pencil_mode',
  'keybindings',
  'audio_sink',
  'virtual_sink',
  'stream_audio',
  'dd_hdr_request_override',
  'dd_paused_virtual_display_timeout_secs',
  'dd_virtual_display_scale',
  'max_bitrate',
  'minimum_fps_target',
  'fec_percentage',
  'video_max_batch_size_kb',
  'qp',
  'min_threads',
  'hevc_mode',
  'av1_mode',
  'encoder',
  'vt_coder',
  'vt_software',
  'vt_realtime',
  'sw_preset',
  'sw_tune',
]);

export interface SettingsGroup {
  id: string;
  fields: SettingsField[];
  collapsed?: boolean;
  platform?: SettingsField['platform'];
  link?: string;
  linkLabelKey?: string;
  visibleWhen?: SettingsVisibility;
}

export interface SettingsCategory {
  id: string;
  groups: SettingsGroup[];
}

const option = (value: string, labelKey: string): SettingsOption => ({ value, labelKey });
const boolean = (key: string, extra: Partial<SettingsField> = {}): SettingsField => ({
  key,
  kind: 'boolean',
  ...extra,
});
const number = (key: string, extra: Partial<SettingsField> = {}): SettingsField => ({
  key,
  kind: 'number',
  ...extra,
});
const text = (key: string, extra: Partial<SettingsField> = {}): SettingsField => ({
  key,
  kind: 'text',
  ...extra,
});
const select = (
  key: string,
  options: SettingsOption[],
  extra: Partial<SettingsField> = {},
): SettingsField => ({ key, kind: 'select', options, ...extra });
const duration = (
  key: string,
  options: SettingsOption[],
  extra: Partial<SettingsField> = {},
): SettingsField => ({ key, kind: 'duration', options, ...extra });

const virtualDisplayOptions = [
  option('disabled', 'ui.settings.options.virtual_display_mode.physical'),
  option('per_client', 'ui.settings.options.virtual_display_mode.per_client'),
  option('shared', 'ui.settings.options.virtual_display_mode.shared'),
];

const virtualLayoutOptions = [
  option('exclusive', 'ui.settings.options.virtual_display_layout.exclusive'),
  option('extended', 'ui.settings.options.virtual_display_layout.extended'),
  option('extended_primary', 'ui.settings.options.virtual_display_layout.extended_primary'),
  option('extended_isolated', 'ui.settings.options.virtual_display_layout.extended_isolated'),
  option(
    'extended_primary_isolated',
    'ui.settings.options.virtual_display_layout.extended_primary_isolated',
  ),
];

const virtualScaleOptions = [
  option('-1', 'ui.settings.options.virtual_scale.recommended'),
  option('0', 'ui.settings.options.virtual_scale.preserve'),
  ...[100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500].map((scale) =>
    option(String(scale), 'ui.settings.options.virtual_scale.percent'),
  ),
];

const hdrRequestOptions = [
  option('auto', 'ui.settings.options.hdr_request.auto'),
  option('force_on', 'ui.settings.options.hdr_request.force_on'),
  option('force_off', 'ui.settings.options.hdr_request.force_off'),
];

const pausedDisplayTimeoutOptions = [
  option('0', 'ui.settings.options.paused_display_timeout.until_game_closes'),
  option('1800', 'ui.settings.options.paused_display_timeout.thirty_minutes'),
  option('3600', 'ui.settings.options.paused_display_timeout.one_hour'),
  option('7200', 'ui.settings.options.paused_display_timeout.two_hours'),
  option('14400', 'ui.settings.options.paused_display_timeout.four_hours'),
];

export function captureOptionsForPlatform(_platform: string): SettingsOption[] {
  return [option('', '_common.auto')];
}

export function gamepadOptionsForPlatform(_platform: string): SettingsOption[] {
  return [option('auto', '_common.auto')];
}

export function frameGenerationOptionsForPlatform(_platform: string): SettingsOption[] {
  return [option('disabled', 'ui.settings.options.frame_generation.off')];
}

const virtualDisplayFields = (): SettingsField[] => [
  select('virtual_display_mode', virtualDisplayOptions, {
    labelKey: 'ui.settings.fields.virtual_display_mode.label',
    descriptionKey: 'ui.settings.fields.virtual_display_mode.description',
    recommended: true,
  }),
  select('virtual_display_layout', virtualLayoutOptions, {
    labelKey: 'ui.settings.fields.virtual_display_layout.label',
    descriptionKey: 'ui.settings.fields.virtual_display_layout.description',
    visibleWhen: { key: 'virtual_display_mode', notEquals: 'disabled' },
  }),
  select('dd_virtual_display_scale', virtualScaleOptions, {
    labelKey: 'ui.settings.fields.dd_virtual_display_scale.label',
    descriptionKey: 'ui.settings.fields.dd_virtual_display_scale.description',
    visibleWhen: { key: 'virtual_display_mode', notEquals: 'disabled' },
  }),
  boolean('virtual_display_keep_while_paused', {
    visibleWhen: { key: 'virtual_display_mode', notEquals: 'disabled' },
  }),
  duration('dd_paused_virtual_display_timeout_secs', pausedDisplayTimeoutOptions, {
    labelKey: 'ui.settings.fields.dd_paused_virtual_display_timeout_secs.label',
    descriptionKey: 'ui.settings.fields.dd_paused_virtual_display_timeout_secs.description',
    warningKey: 'ui.settings.fields.dd_paused_virtual_display_timeout_secs.warning',
    visibleWhen: {
      key: 'virtual_display_keep_while_paused',
      equals: true,
    },
  }),
  select('dd_hdr_request_override', hdrRequestOptions),
];

const remoteMonitorFields = (): SettingsField[] => [
  boolean('remote_monitor_confirm_app_replacement', {
    labelKey: 'ui.settings.fields.remote_monitor_confirm_app_replacement.label',
    descriptionKey: 'ui.settings.fields.remote_monitor_confirm_app_replacement.description',
  }),
];

export const settingsCategories: SettingsCategory[] = [
  {
    id: 'everyday',
    groups: [
      {
        id: 'everyday_display',
        link: '/settings?category=display',
        linkLabelKey: 'ui.settings.links.displays',
        fields: virtualDisplayFields(),
      },
      {
        id: 'everyday_encoding',
        collapsed: false,
        link: '/settings?category=video',
        linkLabelKey: 'ui.settings.links.video',
        fields: [
          select('encoder', [option('', '_common.auto')], {
            labelKey: 'ui.settings.fields.encoder.label',
            descriptionKey: 'ui.settings.fields.encoder.description',
            recommended: true,
          }),
          extendedField('vt_realtime', { encoderFamily: 'videotoolbox' }),
          extendedField('vt_software', { encoderFamily: 'videotoolbox' }),
          number('fec_percentage', {
            min: 0,
            max: 255,
            step: 1,
            labelKey: 'ui.settings.fields.fec_percentage.label',
            descriptionKey: 'ui.settings.fields.fec_percentage.description',
          }),
        ],
      },
      {
        id: 'everyday_remote_monitor',
        collapsed: true,
        link: '/settings?category=display',
        linkLabelKey: 'ui.settings.links.remote_monitor',
        fields: remoteMonitorFields(),
      },
      {
        id: 'everyday_automation',
        collapsed: true,
        link: '/settings?category=host',
        linkLabelKey: 'ui.settings.links.automation',
        fields: [{ key: 'global_prep_cmd', kind: 'command-preparations', stacked: true }],
      },
    ],
  },
  {
    id: 'display',
    groups: [
      {
        id: 'display_virtual',
        fields: virtualDisplayFields(),
      },
      {
        id: 'display_target',
        fields: [
          text('output_name', { monospace: true, stacked: true }),
          text('fallback_mode'),
        ],
      },
      {
        id: 'display_remote_monitor',
        fields: remoteMonitorFields(),
      },
    ],
  },
  {
    id: 'input',
    groups: [
      {
        id: 'input_devices',
        fields: [
          boolean('keyboard'),
          boolean('mouse'),
          boolean('controller'),
          boolean('enable_input_only_mode'),
          boolean('forward_rumble'),
          boolean('legacy_ordering'),
          boolean('motion_as_ds4'),
          boolean('touchpad_as_ds4'),
          boolean('high_resolution_scrolling'),
          select('macos_scroll_inertia', [
            option('macos', 'config.macos_scroll_inertia_macos'),
            option('ipados', 'config.macos_scroll_inertia_ipados'),
            option('disabled', 'config.macos_scroll_inertia_disabled'),
          ]),
          select('macos_pencil_mode', [
            option('scroll', 'config.macos_pencil_mode_scroll'),
            option('draw', 'config.macos_pencil_mode_draw'),
          ]),
          boolean('native_pen_touch'),
        ],
      },
      {
        id: 'input_repeat',
        fields: [
          extendedField('back_button_timeout'),
          extendedField('guide_button_key'),
          extendedField('guide_button_controller'),
          extendedField('key_rightalt_to_key_win'),
          { key: 'keybindings', kind: 'textarea', stacked: true },
          number('key_repeat_delay', { min: 0, step: 1 }),
          number('key_repeat_frequency', { min: 0.1, step: 0.1 }),
        ],
      },
    ],
  },
  {
    id: 'audio',
    groups: [
      {
        id: 'audio_routing',
        fields: [
          boolean('stream_audio'),
          boolean('keep_sink_default'),
          boolean('auto_capture_sink'),
          select('audio_format', [
            option('opus', 'config.audio_format_opus'),
            option('ac3', 'config.audio_format_ac3'),
            option('eac3', 'config.audio_format_eac3'),
          ]),
          boolean('high_quality_audio', {
            visibleWhen: { key: 'audio_format', notEquals: 'opus' },
          }),
          text('audio_sink', { monospace: true, stacked: true }),
          text('virtual_sink', { monospace: true, stacked: true }),
        ],
      },
    ],
  },
  {
    id: 'video',
    groups: [
      {
        id: 'video_encoder',
        fields: [
          select('encoder', [option('', '_common.auto')]),
          boolean('ignore_encoder_probe_failure'),
        ],
      },
      {
        id: 'video_codecs',
        fields: [
          select('hevc_mode', [
            option('0', '_common.auto'),
            option('1', '_common.disabled'),
            option('2', 'ui.settings.options.codec.eight_bit'),
            option('3', 'ui.settings.options.codec.hdr_ten_bit'),
          ]),
          select('av1_mode', [
            option('0', '_common.auto'),
            option('1', '_common.disabled'),
            option('2', 'ui.settings.options.codec.eight_bit'),
            option('3', 'ui.settings.options.codec.hdr_ten_bit'),
          ]),
        ],
      },
      {
        id: 'video_quality',
        fields: [
          number('max_bitrate', { min: 0, step: 1 }),
          number('minimum_fps_target', { min: 0, max: 1000, step: 0.1 }),
          extendedField('min_threads', { min: 1, step: 1 }),
          number('qp', { min: 0, max: 51, step: 1 }),
          number('fec_percentage', { min: 0, max: 255, step: 1 }),
          number('video_max_batch_size_kb', { min: 1, step: 1 }),
        ],
      },
      ...advancedEncoderGroups,
    ],
  },
  {
    id: 'network',
    groups: [
      {
        id: 'network_access',
        fields: [
          select('origin_web_ui_allowed', [
            option('pc', 'ui.settings.options.origin.pc'),
            option('lan', 'ui.settings.options.origin.lan'),
            option('wan', 'ui.settings.options.origin.wan'),
          ]),
          boolean('upnp', { restartRequired: true }),
          boolean('enable_discovery'),
          select(
            'address_family',
            [
              option('ipv4', 'ui.settings.options.address_family.ipv4'),
              option('both', 'ui.settings.options.address_family.both'),
            ],
            { restartRequired: true },
          ),
          number('port', {
            min: NETWORK_PORT_MIN,
            max: NETWORK_PORT_MAX,
            step: 1,
            restartRequired: true,
            descriptionKey: 'ui.settings.fields.port.description',
            stacked: true,
          }),
          text('bind_address', { monospace: true, stacked: true }),
          text('external_ip', { monospace: true, stacked: true }),
          number('ping_timeout', { min: 0, step: 1 }),
          number('control_peer_timeout', { min: 0, max: 86399999, step: 1 }),
        ],
      },
      {
        id: 'network_security',
        fields: [
          boolean('enable_pairing'),
          select('lan_encryption_mode', [
            option('0', '_common.disabled'),
            option('1', 'ui.settings.options.encryption.optional'),
            option('2', 'ui.settings.options.encryption.required'),
          ]),
          select('wan_encryption_mode', [
            option('0', '_common.disabled'),
            option('1', 'ui.settings.options.encryption.optional'),
            option('2', 'ui.settings.options.encryption.required'),
          ]),
          extendedField('session_token_ttl_seconds'),
          extendedField('remember_me_refresh_token_ttl_seconds'),
          text('csrf_allowed_origins', { stacked: true }),
        ],
      },
    ],
  },
  {
    id: 'host',
    groups: [
      {
        id: 'app_focus',
        fields: [
          number('app_focus_attempts', { min: 0, max: 100, step: 1 }),
          number('app_focus_timeout_secs', { min: 0, max: 300, step: 1 }),
          boolean('app_focus_exit_on_first'),
        ],
      },
      {
        id: 'everyday_automation',
        collapsed: true,
        fields: [
          { key: 'global_prep_cmd', kind: 'command-preparations', stacked: true },
          {
            key: 'global_state_cmd',
            kind: 'command-preparations',
            labelKey: 'config.global_state_cmd',
            descriptionKey: 'config.global_state_cmd_desc',
            stacked: true,
          },
          {
            key: 'server_cmd',
            kind: 'server-commands',
            labelKey: 'config.server_cmd',
            descriptionKey: 'config.server_cmd_desc',
            stacked: true,
          },
        ],
      },
      {
        id: 'host_identity',
        fields: [
          extendedField('locale'),
          extendedField('update_check_interval'),
          text('sunshine_name', { placeholderKey: 'ui.settings.placeholders.host_name' }),
          boolean('system_tray'),
          boolean('lid_close_ends_streams'),
          boolean('hide_tray_controls'),
          boolean('envvar_compatibility_mode'),
          boolean('notify_pre_releases'),
          select('min_log_level', [
            option('0', 'ui.settings.options.log_level.verbose'),
            option('1', 'ui.settings.options.log_level.debug'),
            option('2', 'ui.settings.options.log_level.info'),
            option('3', 'ui.settings.options.log_level.warning'),
            option('4', 'ui.settings.options.log_level.error'),
            option('5', 'ui.settings.options.log_level.fatal'),
            option('6', 'ui.settings.options.log_level.none'),
          ]),
        ],
      },
      {
        id: 'host_history',
        fields: [
          ...Object.keys(extendedDefaults)
            .filter(
              (key) =>
                key.startsWith('realtime_stats_') &&
                !['realtime_stats_enabled', 'realtime_stats_poll_interval_ms'].includes(key),
            )
            .map((key) =>
              extendedField(key, { visibleWhen: { key: 'realtime_stats_enabled', equals: true } }),
            ),
          boolean('session_history_enabled'),
          number('session_history_ttl_days', {
            min: 0,
            step: 1,
            visibleWhen: { key: 'session_history_enabled', equals: true },
          }),
          number('session_history_db_size_limit_mb', {
            min: 0,
            step: 1,
            visibleWhen: { key: 'session_history_enabled', equals: true },
          }),
          boolean('hardware_metrics'),
          number('hardware_metrics_interval', {
            min: 500,
            max: 10000,
            step: 100,
            visibleWhen: { key: 'hardware_metrics', equals: true },
          }),
          boolean('realtime_stats_enabled'),
          number('realtime_stats_poll_interval_ms', {
            min: 250,
            max: 60000,
            step: 50,
            visibleWhen: { key: 'realtime_stats_enabled', equals: true },
          }),
        ],
      },
    ],
  },
  {
    id: 'files',
    groups: [
      {
        id: 'file_paths',
        fields: [
          extendedField('credentials_file', { monospace: true, stacked: true }),
          text('vibeshine_file_state', { monospace: true, stacked: true }),
          extendedField('file_state', { monospace: true, stacked: true }),
          text('file_apps', { monospace: true, stacked: true }),
          text('log_path', { monospace: true, stacked: true }),
          text('pkey', { monospace: true, restartRequired: true, stacked: true }),
          text('cert', { monospace: true, restartRequired: true, stacked: true }),
        ],
      },
    ],
  },
];

export const settingsDefaults: Record<string, unknown> = {
  ...extendedDefaults,
  virtual_display_mode: 'per_client',
  virtual_display_layout: 'exclusive',
  virtual_display_keep_while_paused: true,
  remote_monitor_confirm_app_replacement: true,
  dd_virtual_display_scale: 0,
  dd_hdr_request_override: 'auto',
  dd_paused_virtual_display_timeout_secs: 7200,
  stream_audio: true,
  controller: true,
  origin_web_ui_allowed: 'lan',
  upnp: false,
  output_name: '',
  fallback_mode: '1920x1080x60',
  keyboard: true,
  mouse: true,
  motion_as_ds4: true,
  touchpad_as_ds4: true,
  high_resolution_scrolling: true,
  macos_scroll_inertia: 'macos',
  macos_pencil_mode: 'scroll',
  native_pen_touch: true,
  key_repeat_delay: 500,
  key_repeat_frequency: 24.9,
  audio_format: 'opus',
  high_quality_audio: false,
  audio_sink: '',
  virtual_sink: '',
  encoder: '',
  enable_pairing: true,
  enable_discovery: true,
  hide_tray_controls: false,
  enable_input_only_mode: false,
  forward_rumble: true,
  keep_sink_default: true,
  auto_capture_sink: true,
  envvar_compatibility_mode: false,
  legacy_ordering: false,
  ignore_encoder_probe_failure: false,
  hevc_mode: 0,
  av1_mode: 0,
  max_bitrate: 0,
  minimum_fps_target: 20,
  qp: 28,
  fec_percentage: 20,
  video_max_batch_size_kb: 64,
  address_family: 'ipv4',
  port: 47989,
  bind_address: '',
  external_ip: '',
  ping_timeout: 10000,
  control_peer_timeout: 0,
  lan_encryption_mode: 0,
  wan_encryption_mode: 1,
  csrf_allowed_origins: '',
  system_tray: true,
  lid_close_ends_streams: true,
  notify_pre_releases: true,
  min_log_level: 2,
  global_prep_cmd: [],
  session_history_enabled: true,
  session_history_ttl_days: 0,
  session_history_db_size_limit_mb: 0,
  hardware_metrics: false,
  hardware_metrics_interval: 1000,
  realtime_stats_enabled: true,
  realtime_stats_poll_interval_ms: 2000,
};

export const knownSettingsKeys = new Set(
  settingsCategories.flatMap((category) =>
    category.groups.flatMap((group) => group.fields.map((field) => field.key)),
  ),
);

export const restartRequiredKeys = new Set(['address_family', 'cert', 'pkey', 'port', 'upnp']);

export function matchesPlatform(
  field: { platform?: SettingsField['platform'] },
  platform: string,
): boolean {
  if (!field.platform) return true;
  const normalized = (platform || 'macos').toLowerCase().replace('darwin', 'macos');
  const supported = Array.isArray(field.platform) ? field.platform : [field.platform];
  return supported.some((value) => normalized.includes(value === 'macos' ? 'mac' : value));
}

export function encoderFamilyFor(encoder: string): SettingsField['encoderFamily'] | undefined {
  if (encoder === 'videotoolbox') return 'videotoolbox';
  if (encoder === 'software') return 'software';
  return undefined;
}

export function encoderOptionsForPlatform(_platform: string): SettingsOption[] {
  return [
    option('', 'ui.settings.options.encoder.auto'),
    option('videotoolbox', 'ui.settings.options.encoder.videotoolbox'),
    option('software', 'ui.settings.options.encoder.software'),
  ];
}

export function optionsForPlatform(field: SettingsField, platform: string): SettingsOption[] {
  if (field.key === 'encoder') return encoderOptionsForPlatform(platform);
  return field.options ?? [];
}

// Canonical definitions prefer the dedicated category over Everyday shortcuts.
export const settingsFields = new Map(
  settingsCategories.flatMap((category) =>
    category.groups.flatMap((group) => group.fields.map((field) => [field.key, field] as const)),
  ),
);

export function fieldForPlatform(field: SettingsField, _platform: string): SettingsField {
  return field;
}

export const settingsDestinations: Array<{
  labelKey: string;
  to: string;
  keys: string[];
  platform?: SettingsField['platform'];
}> = [
  {
    labelKey: 'ui.integrations.steam.name',
    to: '/integrations#integration-steam',
    keys: ['steam', 'steam_auto_sync', 'steam_exclude_games', 'steam_include_tools'],
  },
];
