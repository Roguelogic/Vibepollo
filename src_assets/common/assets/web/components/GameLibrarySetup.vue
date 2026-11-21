<script setup lang="ts">
import { providerSupported } from '@/utils/providerCapabilities';
import { computed, nextTick, reactive, ref, watch } from 'vue';

const props = defineProps<{
  open: boolean;
  platform: string;
  metadata?: unknown;
  request: (
    method: 'GET' | 'POST' | 'PATCH',
    path: string,
    body?: Record<string, unknown>,
  ) => Promise<any>;
}>();
const emit = defineEmits<{
  (event: 'update:open', value: boolean): void;
  (event: 'saved'): void;
  (event: 'configured', value: boolean): void;
}>();

const dialog = ref<HTMLDialogElement>();
const busy = ref(false);
const step = ref(1);
const configured = ref(false);

interface LibraryOptions {
  autosync_remove_uninstalled: boolean;
  sync_all_installed: boolean;
  recent_games: number;
  recent_max_age_days: number;
  include_tools: boolean;
}

const options = reactive<Record<string, LibraryOptions>>({});
function libraryOptions(id: string): LibraryOptions {
  return options[id]!;
}

const loading = ref(false);
const settingsLoaded = ref(false);
const error = ref('');
const notice = ref('');
const config = ref<Record<string, unknown>>({});
const selected = reactive<Record<string, boolean>>({
  steam: false,
});

const libraries = computed(() =>
  [
    {
      id: 'steam',
      name: 'Steam',
      benefit: 'Sync your installed Steam games on macOS with Steam artwork and direct launch support.',
      detail: 'Uses your local Steam library automatically.',
    },
  ].filter((library) => providerSupported(props.metadata, library.id)),
);

const selectedLibraries = computed(() => libraries.value.filter((library) => selected[library.id]));

function flag(value: unknown, fallback: boolean): boolean {
  if (value === undefined) return fallback;
  return (
    value === true ||
    value === 1 ||
    ['true', 'on', '1', 'yes'].includes(String(value).toLowerCase())
  );
}

async function load() {
  loading.value = true;
  settingsLoaded.value = false;
  error.value = '';
  notice.value = '';
  try {
    const settings = await props.request('GET', '/api/config');
    if (settings.status === false) throw new Error('Unable to load settings');
    config.value = settings;
    for (const library of libraries.value) {
      selected[library.id] =
        flag(settings[library.id + '_enabled'], true) &&
        flag(settings[library.id + '_auto_sync'], false);
      options[library.id] = {
        autosync_remove_uninstalled: flag(settings[library.id + '_autosync_remove_uninstalled'], true),
        sync_all_installed: flag(settings[library.id + '_sync_all_installed'], false),
        recent_games: Number(settings[library.id + '_recent_games'] ?? 10),
        recent_max_age_days: Number(settings[library.id + '_recent_max_age_days'] ?? 30),
        include_tools: flag(settings.steam_include_tools, false),
      };
    }
    configured.value = selectedLibraries.value.length > 0;
    emit('configured', configured.value);
    settingsLoaded.value = true;
  } catch {
    error.value = 'Unable to load game library settings. Close this window and try again.';
  } finally {
    loading.value = false;
  }
}

async function save() {
  busy.value = true;
  error.value = '';
  notice.value = '';
  try {
    const patch: Record<string, unknown> = {};
    for (const library of libraries.value) {
      patch[library.id + '_enabled'] = selected[library.id];
      patch[library.id + '_auto_sync'] = selected[library.id];
      if (selected[library.id]) {
        for (const [key, value] of Object.entries(libraryOptions(library.id))) {
          patch[library.id + '_' + key] = value;
        }
      }
    }
    const result = await props.request('PATCH', '/api/config', patch);
    if (result.status === false)
      throw new Error(result.error || 'Unable to save game library settings.');
    Object.assign(config.value, patch);
    notice.value = 'Game library settings saved.';
    configured.value = selectedLibraries.value.length > 0;
    emit('configured', configured.value);
    emit('saved');
    const results = await Promise.allSettled(
      selectedLibraries.value.map(async (library) => {
        const response = await props.request('POST', '/api/' + library.id + '/force_sync', {});
        if (response.status === false || response.success === false) throw new Error(library.name);
      }),
    );
    if (results.some((item) => item.status === 'rejected')) {
      notice.value +=
        ' Steam could not sync yet. Check that Steam is installed; automatic sync will retry.';
    }
    emit('saved');
  } catch (cause) {
    error.value =
      cause instanceof Error ? cause.message : 'Unable to set up game libraries. Try again.';
  } finally {
    busy.value = false;
  }
}

function close() {
  if (!busy.value) emit('update:open', false);
}

watch(
  () => props.open,
  async (open) => {
    await nextTick();
    if (open) {
      step.value = 1;
      if (!dialog.value?.open) dialog.value?.showModal();
      void load();
    } else dialog.value?.close();
  },
  { immediate: true },
);

watch(
  () => props.platform,
  (platform) => {
    if (platform && !props.open) void load();
  },
  { immediate: true },
);
</script>

<template>
  <dialog
    ref="dialog"
    class="game-library-setup"
    aria-labelledby="game-library-setup-title"
    @cancel.prevent="close"
  >
    <form @submit.prevent="step === 1 ? (step = 2) : save()">
      <header>
        <span class="game-library-setup__eyebrow">YOUR GAMES, READY TO STREAM</span>
        <h2 id="game-library-setup-title">
          {{ configured ? 'Library manager settings' : 'Setup Game Library Integration' }}
        </h2>
        <p>
          Step {{ step }} of 2:
          {{ step === 1 ? 'Choose your library' : 'Configure sync settings' }}. You can change
          these settings any time.
        </p>
      </header>
      <p v-if="loading" role="status">Loading your library…</p>
      <fieldset v-if="step === 1" :disabled="loading || busy || !settingsLoaded">
        <legend class="game-library-setup__legend">Libraries to sync automatically</legend>
        <label
          v-for="library in libraries"
          :key="library.id"
          class="game-library-setup__card"
          :class="{ 'game-library-setup__card--selected': selected[library.id] }"
        >
          <input v-model="selected[library.id]" type="checkbox" :aria-label="library.name" />
          <span>
            <strong>{{ library.name }}</strong>
            <span>{{ library.benefit }}</span>
            <span class="game-library-setup__detail">{{ library.detail }}</span>
          </span>
        </label>
      </fieldset>
      <fieldset v-else :disabled="loading || busy || !settingsLoaded">
        <legend class="game-library-setup__legend">Library sync settings</legend>
        <p v-if="!selectedLibraries.length">Automatic sync is off.</p>
        <section
          v-for="library in selectedLibraries"
          :key="library.id"
          class="game-library-setup__settings"
        >
          <h3>{{ library.name }}</h3>
          <label>
            <input v-model="libraryOptions(library.id).sync_all_installed" type="checkbox" />
            Sync all installed games
          </label>
          <template v-if="!libraryOptions(library.id).sync_all_installed">
            <label>
              Recent games
              <input
                v-model.number="libraryOptions(library.id).recent_games"
                type="number"
                min="0"
                step="1"
                required
              />
            </label>
            <label>
              Maximum age in days (0 = no limit)
              <input
                v-model.number="libraryOptions(library.id).recent_max_age_days"
                type="number"
                min="0"
                step="1"
                required
              />
            </label>
          </template>
          <label>
            <input
              v-model="libraryOptions(library.id).autosync_remove_uninstalled"
              type="checkbox"
            />
            Remove uninstalled games from automatic sync
          </label>
          <label>
            <input v-model="libraryOptions('steam').include_tools" type="checkbox" />
            Include Steam tools
          </label>
        </section>
      </fieldset>
      <p v-if="error" role="alert" class="game-library-setup__error">{{ error }}</p>
      <p v-if="notice" role="status">{{ notice }}</p>
      <footer>
        <button v-if="step === 2" type="button" :disabled="busy" @click="step = 1">Back</button>
        <button type="button" :disabled="busy" @click="close">
          {{ notice ? 'Done' : 'Cancel' }}
        </button>
        <button
          type="submit"
          class="game-library-setup__save"
          :disabled="loading || busy || !settingsLoaded"
        >
          {{
            busy ? 'Saving and syncing…' : step === 1 ? 'Next: Library settings' : 'Save settings'
          }}
        </button>
      </footer>
    </form>
  </dialog>
</template>

<style scoped>
.game-library-setup__settings {
  display: grid;
  gap: 12px;
  padding: 16px;
  border: 1px solid #526078;
  border-radius: 12px;
}
.game-library-setup__settings h3 {
  margin: 0;
  color: #edf3fc;
}
.game-library-setup__settings label {
  display: flex;
  align-items: center;
  gap: 10px;
}
.game-library-setup__settings input[type='number'] {
  width: 90px;
  margin-left: auto;
  padding: 6px;
  border: 1px solid #71839e;
  border-radius: 6px;
  background: #203653;
  color: #edf3fc;
}
.game-library-setup {
  box-sizing: border-box;
  width: min(680px, calc(100vw - 32px));
  max-height: calc(100dvh - 32px);
  margin: auto;
  padding: 28px;
  overflow: auto;
  border: 1px solid #435169;
  border-radius: 20px;
  background: #152033;
  color: #edf3fc;
  box-shadow: 0 24px 90px #0008;
  font-family: inherit;
}
.game-library-setup::backdrop {
  background: #060e1cc2;
  backdrop-filter: blur(5px);
}
.game-library-setup header {
  margin-bottom: 22px;
}
.game-library-setup h2 {
  margin: 8px 0;
  color: #edf3fc;
  font-size: 26px;
  line-height: 1.2;
  font-weight: 650;
}
.game-library-setup p {
  line-height: 1.5;
}
.game-library-setup__eyebrow {
  color: #92c6ff;
  font-size: 11px;
  letter-spacing: 0.12em;
}
.game-library-setup fieldset {
  border: 0;
  padding: 0;
  margin: 0;
  display: grid;
  gap: 12px;
}
.game-library-setup__legend {
  margin-bottom: 10px;
  font-size: 14px;
}
.game-library-setup__card {
  display: flex;
  gap: 14px;
  padding: 16px;
  border: 1px solid #526078;
  border-radius: 12px;
  cursor: pointer;
}
.game-library-setup__card--selected {
  border-color: #8cc4ff;
  background: #203653;
}
.game-library-setup__card input {
  width: 18px;
  height: 18px;
  flex-shrink: 0;
  margin-top: 3px;
  accent-color: #8cc4ff;
}
.game-library-setup__card span span {
  display: block;
  margin-top: 7px;
  line-height: 1.4;
  font-size: 14px;
}
.game-library-setup__card strong {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  align-items: center;
  font-size: 18px;
}
.game-library-setup__detail {
  color: #bdcbdd;
  font-size: 13px;
}
.game-library-setup fieldset + p {
  margin-top: 14px;
}
.game-library-setup__error {
  color: #ffb7b7;
}
.game-library-setup footer {
  display: flex;
  flex-wrap: wrap;
  justify-content: flex-end;
  gap: 10px;
  margin-top: 22px;
}
.game-library-setup button {
  padding: 10px 16px;
  border: 1px solid #71839e;
  border-radius: 8px;
  background: transparent;
  color: inherit;
  cursor: pointer;
  font: inherit;
}
.game-library-setup .game-library-setup__save {
  background: #98cdff;
  border-color: #98cdff;
  color: #102137;
  font-weight: 600;
}
.game-library-setup :focus-visible {
  outline: 3px solid #c7e3ff;
  outline-offset: 3px;
}
.game-library-setup button:disabled {
  opacity: 0.5;
  cursor: wait;
}
@media (max-width: 480px) {
  .game-library-setup {
    padding: 18px;
  }
  .game-library-setup h2 {
    font-size: 22px;
  }
}
</style>
