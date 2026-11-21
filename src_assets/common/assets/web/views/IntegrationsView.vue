<script setup lang="ts">
import { providerSupported } from '@/utils/providerCapabilities';
import GameLibrarySetup from '@/components/GameLibrarySetup.vue';
import { computed, nextTick, onMounted, ref, watch } from 'vue';
import { useRoute } from 'vue-router';
import { useI18n } from 'vue-i18n';

import { ApiError, apiGet, apiPatch, apiPost } from '@/api/client';
import {
  AppButton,
  InlineAlert,
  LoadingSkeleton,
  PageHeader,
  SettingRow,
  StatusBadge,
  UiIcon,
  type StatusTone,
} from '@/components/ui';
import { useSystemStore } from '@/stores/system';

interface SteamStatus {
  enabled?: boolean;
  forced?: boolean;
  available?: boolean;
  game_count?: number;
  importable_game_count?: number;
  excluded_game_count?: number;
  tool_game_count?: number;
  auto_sync?: boolean;
  sync_all_installed?: boolean;
  recent_games?: number;
  recent_max_age_days?: number;
  autosync_remove_uninstalled?: boolean;
  remove_uninstalled?: boolean;
  include_tools?: boolean;
  exclude_games?: Array<{ id?: string; name?: string }> | string[] | number;
}

interface SteamGame {
  appid: number | string;
  steam_id?: string;
  name?: string;
  install_dir?: string;
  excluded?: boolean;
  filtered?: boolean;
  app_type?: string;
  installed?: boolean;
  last_played?: number;
  playtime_minutes?: number;
}

interface MutationResult {
  status?: boolean;
  error?: string;
}

type SteamGameFilter = 'all' | 'included' | 'excluded';

interface IntegrationSummary {
  id: 'steam';
  name: string;
  description: string;
  status: string;
  tone: StatusTone;
  details: string[];
}

const { t } = useI18n();
const system = useSystemStore();
const steam = ref<SteamStatus | null>(null);
const steamGames = ref<SteamGame[]>([]);
const steamGamesLoading = ref(false);
const steamGamesError = ref('');
const steamGameSearch = ref('');
const steamGameFilter = ref<SteamGameFilter>('all');
const steamExclusionDraft = ref<Set<string>>(new Set());
const steamExclusionOriginal = ref<Set<string>>(new Set());
const steamExclusionsSaving = ref(false);
const loading = ref(true);
const refreshing = ref(false);
const syncing = ref(false);
const steamError = ref('');
const notice = ref('');

function message(cause: unknown, fallback: string): string {
  return cause instanceof ApiError ? fallback : cause instanceof Error ? cause.message : fallback;
}

function steamGameId(game: SteamGame): string {
  return String(game.steam_id ?? game.appid ?? '').trim();
}

function steamGameName(game: SteamGame): string {
  return (
    String(game.name ?? '').trim() ||
    t('ui.integrations.steam.unknownGame', { id: steamGameId(game) })
  );
}

function exclusionEntries(): Array<{ id: string; name: string }> {
  const entries = steam.value?.exclude_games;
  if (Array.isArray(entries)) {
    return entries
      .map((entry) => {
        if (typeof entry === 'string') return { id: entry, name: '' };
        return { id: String(entry?.id ?? '').trim(), name: String(entry?.name ?? '').trim() };
      })
      .filter((entry) => entry.id || entry.name);
  }
  return steamGames.value
    .filter((game) => game.excluded === true)
    .map((game) => ({ id: steamGameId(game), name: steamGameName(game) }));
}

function resetSteamExclusionDraft(): void {
  const ids = new Set(
    exclusionEntries()
      .map((entry) => entry.id)
      .filter(Boolean),
  );
  steamExclusionOriginal.value = new Set(ids);
  steamExclusionDraft.value = new Set(ids);
}

function gameExcluded(game: SteamGame): boolean {
  return steamExclusionDraft.value.has(steamGameId(game));
}

const steamExcludedCount = computed(() => steamExclusionDraft.value.size);
const steamExclusionsDirty = computed(() => {
  const current = steamExclusionDraft.value;
  const original = steamExclusionOriginal.value;
  return current.size !== original.size || [...current].some((id) => !original.has(id));
});

const filteredSteamGames = computed(() => {
  const query = steamGameSearch.value.trim().toLocaleLowerCase();
  return [...steamGames.value]
    .filter((game) => {
      if (game.installed === false) return false;
      if (game.filtered && !steamIncludeToolsEnabled()) return false;
      const excluded = gameExcluded(game);
      if (steamGameFilter.value === 'included' && excluded) return false;
      if (steamGameFilter.value === 'excluded' && !excluded) return false;
      if (!query) return true;
      return (
        steamGameName(game).toLocaleLowerCase().includes(query) || steamGameId(game).includes(query)
      );
    })
    .sort((left, right) => steamGameName(left).localeCompare(steamGameName(right)));
});

function setDraftExclusion(game: SteamGame, excluded: boolean): void {
  const id = steamGameId(game);
  if (!id) return;
  const next = new Set(steamExclusionDraft.value);
  if (excluded) next.add(id);
  else next.delete(id);
  steamExclusionDraft.value = next;
}

function setVisibleDraftExclusions(excluded: boolean): void {
  const next = new Set(steamExclusionDraft.value);
  for (const game of filteredSteamGames.value) {
    const id = steamGameId(game);
    if (!id) continue;
    if (excluded) next.add(id);
    else next.delete(id);
  }
  steamExclusionDraft.value = next;
}

function steamAutoSyncEnabled(): boolean {
  return steam.value?.auto_sync === true;
}

function steamRemoveUninstalledEnabled(): boolean {
  return (
    steam.value?.autosync_remove_uninstalled === true || steam.value?.remove_uninstalled === true
  );
}

function steamIncludeToolsEnabled(): boolean {
  return steam.value?.include_tools === true;
}

async function loadSteamGames(resetDraft = true): Promise<void> {
  steamGamesLoading.value = true;
  steamGamesError.value = '';
  try {
    const payload = await apiGet<unknown>('/api/steam/games');
    const games =
      payload && typeof payload === 'object' && !Array.isArray(payload)
        ? (payload as { games?: unknown }).games
        : payload;
    steamGames.value = (Array.isArray(games) ? games : []).filter(
      (game): game is SteamGame =>
        Boolean(game) && typeof game === 'object' && !Array.isArray(game),
    );
    if (resetDraft) resetSteamExclusionDraft();
  } catch (cause) {
    steamGames.value = [];
    steamGamesError.value = message(cause, t('ui.integrations.errors.steamGames'));
  } finally {
    steamGamesLoading.value = false;
  }
}

async function load(preserveNotice = false): Promise<void> {
  if (refreshing.value) return;
  refreshing.value = true;
  if (!preserveNotice) notice.value = '';
  steamError.value = '';

  if (!system.metadata) await system.refreshHost();

  if (providerSupported(system.metadata, 'steam')) {
    try {
      steam.value = await apiGet<SteamStatus>('/api/steam/status');
      await loadSteamGames();
    } catch (cause) {
      steamError.value = message(cause, t('ui.integrations.errors.steamStatus'));
    }
  }

  loading.value = false;
  refreshing.value = false;
}

function steamSummary(): IntegrationSummary {
  const value = steam.value;
  const name = t('ui.integrations.steam.name');
  const description = t('ui.integrations.steam.description');
  if (!value) {
    return {
      id: 'steam',
      name,
      description,
      status: t('ui.integrations.status.unavailable'),
      tone: 'danger',
      details: [steamError.value || t('ui.integrations.errors.statusLoad')],
    };
  }
  const enabled = value.enabled !== false;
  const status = !enabled
    ? t('_common.disabled')
    : !value.available
      ? t('ui.integrations.status.notDetected')
      : t('_common.enabled');
  return {
    id: 'steam',
    name,
    description,
    status,
    tone: enabled && value.available ? 'success' : enabled ? 'info' : 'neutral',
    details: [
      value.game_count !== undefined
        ? t('ui.integrations.steam.gameCount', { count: value.game_count })
        : '',
      value.importable_game_count !== undefined
        ? t('ui.integrations.steam.synchronizedCount', { count: value.importable_game_count })
        : '',
    ].filter(Boolean),
  };
}

const summaries = computed(() =>
  providerSupported(system.metadata, 'steam') ? [steamSummary()] : [],
);

async function syncSteam(): Promise<void> {
  if (syncing.value) return;
  syncing.value = true;
  notice.value = '';
  try {
    const result = await apiPost<MutationResult>('/api/steam/force_sync', {});
    if (result.status === false)
      throw new Error(result.error || t('ui.integrations.errors.steamSyncRejected'));
    notice.value = t('ui.integrations.notices.steamSynced');
    await load(true);
  } catch (cause) {
    steamError.value = message(cause, t('ui.integrations.errors.steamSyncFailed'));
  } finally {
    syncing.value = false;
  }
}

async function setSteamEnabled(enabled: boolean): Promise<void> {
  if (steam.value?.forced) return;
  try {
    await apiPatch('/api/config', { steam_enabled: enabled });
    notice.value = t('ui.integrations.notices.providerUpdated');
    await load(true);
  } catch (cause) {
    steamError.value = message(cause, t('ui.integrations.errors.providerUpdateFailed'));
  }
}

async function setSteamPolicy(
  key: 'steam_auto_sync' | 'steam_sync_all_installed' | 'steam_autosync_remove_uninstalled',
  value: boolean,
): Promise<void> {
  try {
    await apiPatch('/api/config', { [key]: value });
    if (steam.value) {
      if (key === 'steam_auto_sync') steam.value.auto_sync = value;
      else if (key === 'steam_sync_all_installed') steam.value.sync_all_installed = value;
      else steam.value.autosync_remove_uninstalled = value;
    }
    notice.value = t('ui.integrations.notices.providerUpdated');
  } catch (cause) {
    steamError.value = message(cause, t('ui.integrations.errors.providerUpdateFailed'));
  }
}

async function setSteamRecentPolicy(
  key: 'steam_recent_games' | 'steam_recent_max_age_days',
  value: string,
): Promise<void> {
  const parsed = Math.max(0, Number.parseInt(value, 10) || 0);
  try {
    await apiPatch('/api/config', { [key]: parsed });
    if (steam.value) {
      if (key === 'steam_recent_games') steam.value.recent_games = parsed;
      else steam.value.recent_max_age_days = parsed;
    }
    notice.value = t('ui.integrations.notices.providerUpdated');
  } catch (cause) {
    steamError.value = message(cause, t('ui.integrations.errors.providerUpdateFailed'));
  }
}

async function setSteamIncludeTools(value: boolean): Promise<void> {
  try {
    await apiPatch('/api/config', { steam_include_tools: value });
    if (steam.value) steam.value.include_tools = value;
    notice.value = t('ui.integrations.notices.providerUpdated');
    await loadSteamGames(false);
  } catch (cause) {
    steamError.value = message(cause, t('ui.integrations.errors.providerUpdateFailed'));
  }
}

async function saveSteamExclusions(): Promise<void> {
  if (!steamExclusionsDirty.value || steamExclusionsSaving.value) return;
  steamExclusionsSaving.value = true;
  try {
    const gamesById = new Map(steamGames.value.map((game) => [steamGameId(game), game]));
    const next = [...steamExclusionDraft.value]
      .map((id) => ({ id, name: gamesById.has(id) ? steamGameName(gamesById.get(id)!) : '' }))
      .sort(
        (left, right) => left.name.localeCompare(right.name) || left.id.localeCompare(right.id),
      );
    await apiPatch('/api/config', { steam_exclude_games: next });
    if (steam.value) steam.value.exclude_games = next;
    steamExclusionOriginal.value = new Set(steamExclusionDraft.value);
    notice.value = t('ui.integrations.notices.exclusionsUpdated');
  } catch (cause) {
    steamError.value = message(cause, t('ui.integrations.errors.exclusionsUpdateFailed'));
  } finally {
    steamExclusionsSaving.value = false;
  }
}

const route = useRoute();
watch(
  () => [loading.value, route.hash],
  async () => {
    if (loading.value || !route.hash) return;
    await nextTick();
    document.getElementById(route.hash.slice(1))?.scrollIntoView({ block: 'start' });
  },
);
onMounted(() => void load());

const librarySetupOpen = ref(false);
function libraryRequest(
  method: 'GET' | 'POST' | 'PATCH',
  path: string,
  body?: Record<string, unknown>,
): Promise<any> {
  return method === 'GET'
    ? apiGet(path)
    : method === 'PATCH'
      ? apiPatch(path, body ?? {})
      : apiPost(path, body ?? {});
}
</script>

<template>
  <div class="page page--narrow integrations-page">
    <GameLibrarySetup
      v-model:open="librarySetupOpen"
      :platform="system.metadata?.platform || 'macos'"
      :metadata="system.metadata"
      :request="libraryRequest"
      @saved="load()"
    />
    <PageHeader :title="t('ui.integrations.title')" :description="t('ui.integrations.description')">
      <template #actions>
        <AppButton
          icon="integrations"
          label="Setup Game Library Integration"
          @click="librarySetupOpen = true"
        />
        <AppButton
          icon="refresh"
          :label="t('ui.integrations.actions.refreshStatus')"
          variant="secondary"
          :busy="refreshing"
          :busy-label="t('ui.integrations.refreshing')"
          @click="load()"
        />
      </template>
    </PageHeader>

    <InlineAlert
      v-if="notice"
      tone="success"
      :title="t('ui.integrations.updated')"
      announce="polite"
    >
      {{ notice }}
    </InlineAlert>
    <InlineAlert v-if="steamError" tone="warning" :title="t('ui.integrations.checksFailed')">
      {{ steamError }}
    </InlineAlert>

    <div v-if="loading" class="integration-list" :aria-label="t('ui.integrations.loadingStatus')">
      <LoadingSkeleton variant="block" height="140px" />
    </div>

    <section
      v-else
      class="integration-list"
      :aria-label="t('ui.integrations.installedIntegrations')"
    >
      <article
        v-for="summary in summaries"
        :key="summary.id"
        class="integration-row integration-row--steam"
        :aria-labelledby="`integration-${summary.id}`"
      >
        <span class="integration-row__icon" aria-hidden="true">
          <UiIcon name="gamepad" :size="20" />
        </span>
        <div class="integration-row__main">
          <div class="integration-row__title">
            <h2 :id="`integration-${summary.id}`">{{ summary.name }}</h2>
            <StatusBadge :label="summary.status" :tone="summary.tone" compact />
          </div>
          <ul v-if="summary.details.length" class="integration-details">
            <li v-for="detail in summary.details" :key="detail">{{ detail }}</li>
          </ul>
          <p class="integration-row__description">{{ summary.description }}</p>

          <section class="integration-settings" aria-labelledby="steam-policy-heading">
            <div class="integration-settings__heading">
              <div>
                <h3 id="steam-policy-heading">{{ t('ui.integrations.steam.policyTitle') }}</h3>
                <small>{{ t('ui.integrations.steam.policyDescription') }}</small>
              </div>
            </div>

            <div class="integration-settings__rows">
              <SettingRow
                class="steam-setting-row"
                :label="t('ui.integrations.steam.autoSync')"
                :description="t('ui.integrations.steam.autoSyncDescription')"
                control-id="steam-auto-sync"
              >
                <label class="vs-switch">
                  <input
                    id="steam-auto-sync"
                    type="checkbox"
                    :checked="steamAutoSyncEnabled()"
                    @change="
                      setSteamPolicy('steam_auto_sync', ($event.target as HTMLInputElement).checked)
                    "
                  />
                  <span class="vs-switch__track" aria-hidden="true" />
                  <span class="vs-sr-only">{{ t('ui.integrations.steam.autoSync') }}</span>
                </label>
              </SettingRow>
              <SettingRow
                class="steam-setting-row"
                :label="t('ui.integrations.steam.removeUninstalled')"
                :description="t('ui.integrations.steam.removeUninstalledDescription')"
                control-id="steam-remove-uninstalled"
              >
                <label class="vs-switch">
                  <input
                    id="steam-remove-uninstalled"
                    type="checkbox"
                    :checked="steamRemoveUninstalledEnabled()"
                    :disabled="steam?.sync_all_installed === false"
                    @change="
                      setSteamPolicy(
                        'steam_autosync_remove_uninstalled',
                        ($event.target as HTMLInputElement).checked,
                      )
                    "
                  />
                  <span class="vs-switch__track" aria-hidden="true" />
                  <span class="vs-sr-only">{{ t('ui.integrations.steam.removeUninstalled') }}</span>
                </label>
              </SettingRow>
              <SettingRow
                class="steam-setting-row"
                :label="t('ui.integrations.steam.syncAllInstalled')"
                :description="t('ui.integrations.steam.syncAllInstalledDescription')"
                control-id="steam-sync-all-installed"
              >
                <label class="vs-switch">
                  <input
                    id="steam-sync-all-installed"
                    type="checkbox"
                    :checked="steam?.sync_all_installed !== false"
                    @change="
                      setSteamPolicy(
                        'steam_sync_all_installed',
                        ($event.target as HTMLInputElement).checked,
                      )
                    "
                  />
                  <span class="vs-switch__track" aria-hidden="true" />
                  <span class="vs-sr-only">{{ t('ui.integrations.steam.syncAllInstalled') }}</span>
                </label>
              </SettingRow>
              <SettingRow
                :label="t('ui.integrations.steam.recentGames')"
                :description="t('ui.integrations.steam.recentGamesDescription')"
                control-id="steam-recent-games"
              >
                <div class="integration-number">
                  <input
                    id="steam-recent-games"
                    class="integration-control"
                    type="number"
                    min="0"
                    :value="steam?.recent_games ?? 10"
                    :disabled="steam?.sync_all_installed !== false"
                    @change="
                      setSteamRecentPolicy(
                        'steam_recent_games',
                        ($event.target as HTMLInputElement).value,
                      )
                    "
                  />
                  <span>{{ t('ui.integrations.steam.gamesUnit') }}</span>
                </div>
              </SettingRow>
              <SettingRow
                :label="t('ui.integrations.steam.recentMaxAge')"
                :description="t('ui.integrations.steam.recentMaxAgeDescription')"
                control-id="steam-recent-max-age"
              >
                <div class="integration-number">
                  <input
                    id="steam-recent-max-age"
                    class="integration-control"
                    type="number"
                    min="0"
                    :value="steam?.recent_max_age_days ?? 30"
                    :disabled="steam?.sync_all_installed !== false"
                    @change="
                      setSteamRecentPolicy(
                        'steam_recent_max_age_days',
                        ($event.target as HTMLInputElement).value,
                      )
                    "
                  />
                  <span>{{ t('ui.integrations.steam.daysUnit') }}</span>
                </div>
              </SettingRow>
              <details class="integration-advanced">
                <summary>{{ t('ui.integrations.steam.advancedSettings') }}</summary>
                <SettingRow
                  class="steam-setting-row"
                  :label="t('ui.integrations.steam.includeTools')"
                  :description="t('ui.integrations.steam.includeToolsDescription')"
                  control-id="steam-include-tools"
                >
                  <label class="vs-switch">
                    <input
                      id="steam-include-tools"
                      type="checkbox"
                      :checked="steamIncludeToolsEnabled()"
                      @change="setSteamIncludeTools(($event.target as HTMLInputElement).checked)"
                    />
                    <span class="vs-switch__track" aria-hidden="true" />
                    <span class="vs-sr-only">{{ t('ui.integrations.steam.includeTools') }}</span>
                  </label>
                </SettingRow>
              </details>
            </div>

            <details class="integration-advanced integration-advanced--manager">
              <summary>{{ t('ui.integrations.steam.manageGames') }}</summary>
              <div class="game-manager" aria-labelledby="steam-exclusions-heading">
                <div class="game-manager__heading">
                  <div>
                    <h4 id="steam-exclusions-heading">
                      {{ t('ui.integrations.steam.exclusionsTitle') }}
                    </h4>
                    <small>{{ t('ui.integrations.steam.exclusionsDescription') }}</small>
                  </div>
                  <StatusBadge
                    :label="t('ui.integrations.steam.excludedCount', { count: steamExcludedCount })"
                    :tone="steamExclusionsDirty ? 'warning' : 'neutral'"
                    compact
                  />
                </div>
                <div class="game-manager__toolbar">
                  <label class="game-manager__search">
                    <span class="vs-sr-only">{{ t('ui.integrations.steam.searchGames') }}</span>
                    <UiIcon name="search" :size="16" aria-hidden="true" />
                    <input
                      v-model="steamGameSearch"
                      type="search"
                      :placeholder="t('ui.integrations.steam.searchGames')"
                    />
                  </label>
                  <label class="game-manager__filter">
                    <span class="vs-sr-only">{{ t('ui.integrations.steam.filterGames') }}</span>
                    <select v-model="steamGameFilter">
                      <option value="all">{{ t('ui.integrations.steam.filters.all') }}</option>
                      <option value="included">
                        {{ t('ui.integrations.steam.filters.included') }}
                      </option>
                      <option value="excluded">
                        {{ t('ui.integrations.steam.filters.excluded') }}
                      </option>
                    </select>
                  </label>
                </div>
                <div class="game-manager__bulk">
                  <span>{{
                    t('ui.integrations.steam.resultCount', { count: filteredSteamGames.length })
                  }}</span>
                  <div>
                    <AppButton
                      :label="t('ui.integrations.steam.includeResults')"
                      variant="tertiary"
                      size="compact"
                      :disabled="!filteredSteamGames.length"
                      @click="setVisibleDraftExclusions(false)"
                    />
                    <AppButton
                      :label="t('ui.integrations.steam.excludeResults')"
                      variant="tertiary"
                      size="compact"
                      :disabled="!filteredSteamGames.length"
                      @click="setVisibleDraftExclusions(true)"
                    />
                  </div>
                </div>
                <p v-if="steamGamesLoading" class="game-manager__notice">
                  {{ t('ui.integrations.steam.loadingGames') }}
                </p>
                <p
                  v-else-if="steamGamesError"
                  class="game-manager__notice game-manager__notice--error"
                >
                  {{ steamGamesError }}
                </p>
                <p v-else-if="!steamGames.length" class="game-manager__notice">
                  {{ t('ui.integrations.steam.noGames') }}
                </p>
                <p v-else-if="!filteredSteamGames.length" class="game-manager__notice">
                  {{ t('ui.integrations.steam.noMatchingGames') }}
                </p>
                <div v-else class="game-manager__list">
                  <div
                    v-for="game in filteredSteamGames"
                    :key="steamGameId(game)"
                    class="game-manager__game"
                  >
                    <span class="game-manager__game-icon" aria-hidden="true"
                      ><UiIcon name="gamepad" :size="16"
                    /></span>
                    <span class="game-manager__game-copy">
                      <strong>{{ steamGameName(game) }}</strong>
                      <small>
                        {{ t('ui.integrations.steam.appId', { id: steamGameId(game) }) }}
                        <template v-if="game.filtered">
                          · {{ t('ui.integrations.steam.filteredTool') }}</template
                        >
                      </small>
                    </span>
                    <StatusBadge
                      :label="
                        gameExcluded(game)
                          ? t('ui.integrations.steam.excluded')
                          : t('ui.integrations.steam.included')
                      "
                      :tone="gameExcluded(game) ? 'neutral' : 'success'"
                      compact
                    />
                    <AppButton
                      :label="
                        gameExcluded(game)
                          ? t('ui.integrations.steam.include')
                          : t('ui.integrations.steam.exclude')
                      "
                      variant="tertiary"
                      size="compact"
                      @click="setDraftExclusion(game, !gameExcluded(game))"
                    />
                  </div>
                </div>
                <div class="game-manager__footer">
                  <span v-if="steamExclusionsDirty">{{ t('ui.integrations.unsavedChanges') }}</span>
                  <span v-else>{{ t('ui.integrations.saved') }}</span>
                  <div>
                    <AppButton
                      :label="t('_common.cancel')"
                      variant="tertiary"
                      size="compact"
                      :disabled="!steamExclusionsDirty"
                      @click="resetSteamExclusionDraft"
                    />
                    <AppButton
                      :label="t('_common.apply')"
                      variant="primary"
                      size="compact"
                      :busy="steamExclusionsSaving"
                      :busy-label="t('ui.integrations.applying')"
                      :disabled="!steamExclusionsDirty"
                      @click="saveSteamExclusions"
                    />
                  </div>
                </div>
              </div>
            </details>
          </section>
        </div>

        <div class="integration-row__actions">
          <AppButton
            v-if="!steam?.forced"
            :label="
              steam?.enabled === false
                ? t('ui.integrations.actions.enable')
                : t('ui.integrations.actions.disable')
            "
            variant="tertiary"
            size="compact"
            @click="setSteamEnabled(steam?.enabled === false)"
          />
          <AppButton
            icon="refresh"
            :label="t('ui.integrations.actions.rescan')"
            variant="secondary"
            size="compact"
            :busy="syncing"
            :busy-label="t('ui.integrations.syncing')"
            :disabled="steam?.enabled === false"
            @click="syncSteam"
          />
        </div>
      </article>
    </section>
  </div>
</template>

<style scoped>
.integrations-page {
  display: grid;
  gap: var(--vs-space-20);
}

.integration-list {
  display: grid;
  overflow: hidden;
  border: var(--vs-border-width) solid var(--vs-color-border-subtle);
  border-radius: var(--vs-radius-card);
  background: var(--vs-color-bg-surface);
}

.integration-row {
  display: grid;
  min-height: 7rem;
  grid-template-columns: auto minmax(0, 1fr) auto;
  align-items: start;
  gap: var(--vs-space-16);
  padding: var(--vs-space-16) var(--vs-space-20);
}

.integration-row__icon {
  display: grid;
  width: 2.25rem;
  height: 2.25rem;
  place-items: center;
  border-radius: var(--vs-radius-control);
  background: var(--vs-color-bg-subtle);
  color: var(--vs-color-text-secondary);
}

.integration-row__main {
  display: grid;
  min-width: 0;
  gap: var(--vs-space-4);
}

.integration-row__title {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: var(--vs-space-8);
}

.integration-row h2 {
  font-size: var(--vs-type-size-section);
  line-height: var(--vs-type-line-height-section);
}

.integration-row p,
.integration-details {
  color: var(--vs-color-text-secondary);
  font-size: var(--vs-type-size-metadata);
  line-height: var(--vs-type-line-height-metadata);
}

.integration-details {
  display: flex;
  min-width: 0;
  flex-wrap: wrap;
  gap: var(--vs-space-4) var(--vs-space-16);
  padding: 0;
  margin-top: 0;
  list-style: none;
}

.integration-details li {
  overflow-wrap: anywhere;
}

.integration-settings {
  display: grid;
  max-width: 52rem;
  gap: var(--vs-space-8);
  padding-top: var(--vs-space-8);
}

.integration-settings__heading,
.game-manager__heading,
.game-manager__footer {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: var(--vs-space-12);
}

.integration-settings h3,
.integration-settings h4 {
  font-size: var(--vs-type-size-label);
}

.integration-settings small,
.game-manager small {
  color: var(--vs-color-text-secondary);
  font-size: var(--vs-type-size-metadata);
}

.integration-settings__rows :deep(.vs-setting-row) {
  min-block-size: 0;
  grid-template-columns: minmax(0, 1fr) auto;
  gap: var(--vs-space-16);
  padding: var(--vs-space-8) 0;
}

.integration-settings__rows :deep(.vs-setting-row + .vs-setting-row) {
  border-top: 0;
}

.integration-settings__rows :deep(.vs-setting-row__control) {
  min-inline-size: auto;
}

.integration-settings__rows :deep(.vs-setting-row__copy) {
  gap: var(--vs-space-2);
}

.integration-settings__rows :deep(.vs-setting-row__description) {
  max-inline-size: 42rem;
}

.integration-advanced {
  margin-top: var(--vs-space-4);
}

.integration-advanced summary {
  padding: var(--vs-space-6) 0;
  color: var(--vs-color-text-secondary);
  cursor: pointer;
  font-size: var(--vs-type-size-metadata);
  font-weight: 600;
}

.integration-advanced--manager {
  overflow: hidden;
  border: var(--vs-border-width) solid var(--vs-color-border-subtle);
  border-radius: var(--vs-radius-control);
  background: var(--vs-color-bg-subtle);
  padding-inline: var(--vs-space-12);
}

.integration-advanced--manager > .game-manager {
  border-inline: 0;
  border-bottom: 0;
  border-radius: 0;
  background: var(--vs-color-bg-surface);
  margin-inline: calc(-1 * var(--vs-space-12));
}

.integration-control,
.game-manager input,
.game-manager select {
  min-height: 2.25rem;
  border: var(--vs-border-width) solid var(--vs-color-border-subtle);
  border-radius: var(--vs-radius-control);
  background: var(--vs-color-bg-surface);
  color: var(--vs-color-text-primary);
  padding: var(--vs-space-4) var(--vs-space-8);
}

.integration-number {
  display: flex;
  align-items: center;
  gap: var(--vs-space-8);
}

.integration-number input {
  width: 8rem;
}

.integration-number span {
  color: var(--vs-color-text-tertiary);
  font-size: var(--vs-type-size-metadata);
  font-weight: 600;
}

.game-manager {
  display: grid;
  gap: 0;
  margin-top: var(--vs-space-4);
}

.game-manager__heading {
  padding: var(--vs-space-12);
}

.game-manager__toolbar {
  display: grid;
  grid-template-columns: minmax(12rem, 1fr) auto;
  gap: var(--vs-space-8);
  padding: var(--vs-space-12);
  border-top: var(--vs-border-width) solid var(--vs-color-border-subtle);
}

.game-manager__search {
  display: flex;
  align-items: center;
  gap: var(--vs-space-8);
  min-height: 2.25rem;
  padding-inline-start: var(--vs-space-8);
  border: var(--vs-border-width) solid var(--vs-color-border-subtle);
  border-radius: var(--vs-radius-control);
  color: var(--vs-color-text-tertiary);
}

.game-manager__search input {
  width: 100%;
  min-height: 2rem;
  padding-inline-start: 0;
  border: 0;
  outline: 0;
}

.game-manager__bulk {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: var(--vs-space-8);
  padding: var(--vs-space-4) var(--vs-space-12) var(--vs-space-8);
  color: var(--vs-color-text-secondary);
  font-size: var(--vs-type-size-metadata);
}

.game-manager__bulk > div,
.game-manager__footer > div,
.integration-row__actions {
  display: flex;
  flex-wrap: wrap;
  gap: var(--vs-space-4);
}

.game-manager__list {
  display: grid;
  overflow-y: auto;
  max-height: 23rem;
  border-top: var(--vs-border-width) solid var(--vs-color-border-subtle);
}

.game-manager__game {
  display: grid;
  grid-template-columns: auto minmax(0, 1fr) auto auto;
  align-items: center;
  gap: var(--vs-space-8);
  min-height: 3.5rem;
  padding: var(--vs-space-8) var(--vs-space-12);
}

.game-manager__game + .game-manager__game {
  border-top: var(--vs-border-width) solid var(--vs-color-border-subtle);
}

.game-manager__game-icon {
  display: grid;
  width: 2rem;
  height: 2rem;
  place-items: center;
  border-radius: var(--vs-radius-control);
  background: var(--vs-color-bg-subtle);
  color: var(--vs-color-text-secondary);
}

.game-manager__game-copy {
  display: grid;
  min-width: 0;
  gap: var(--vs-space-2);
}

.game-manager__game-copy strong,
.game-manager__game-copy small {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.game-manager__notice {
  padding: var(--vs-space-16);
  border-top: var(--vs-border-width) solid var(--vs-color-border-subtle);
  color: var(--vs-color-text-secondary);
  font-size: var(--vs-type-size-metadata);
}

.game-manager__notice--error {
  color: var(--vs-color-status-danger);
}

.game-manager__footer {
  align-items: center;
  padding: var(--vs-space-12);
  border-top: var(--vs-border-width) solid var(--vs-color-border-subtle);
}

@media (max-width: 47.999rem) {
  .integration-row {
    grid-template-columns: minmax(0, 1fr);
  }
}
</style>
