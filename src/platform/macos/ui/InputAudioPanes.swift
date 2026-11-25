import AppKit
import SwiftUI

// MARK: - 4. 입력 및 오디오 (Input & Audio Pane)

struct InputAudioSettingsPane: View {
  @ObservedObject var store: HostStore
  @ViewState private var showInputAdvanced = false
  @ViewState private var showAudioAdvanced = false
  private var l10n: L10n { store.l10n }

  var body: some View {
    Form {
      Section(l10n.pick("트랙패드 및 Apple Pencil", "Trackpad & Apple Pencil")) {
        Picker(
          l10n.pick("스크롤 관성 방식", "Scroll Inertia"),
          selection: Binding(
            get: { store.settings.scrollInertia },
            set: { v in
              store.settings.scrollInertia = v
              store.patchSettings(["macos_scroll_inertia": v])
            }
          )
        ) {
          Text(l10n.pick("MacBook 트랙패드 네이티브", "MacBook Trackpad")).tag("macos")
          Text(l10n.pick("iPad 모멘텀 관성", "iPad Momentum")).tag("ipados")
          Text(l10n.pick("관성 없음", "Disabled")).tag("disabled")
        }

        Picker(
          l10n.pick("Apple Pencil 동작", "Apple Pencil Mode"),
          selection: Binding(
            get: { store.settings.pencilMode },
            set: { v in
              store.settings.pencilMode = v
              store.patchSettings(["macos_pencil_mode": v])
            }
          )
        ) {
          Text(l10n.pick("클라이언트 설정 따름 (VoidLink)", "Follow Client")).tag("auto")
          Text(l10n.pick("스크롤 및 탭 (iPad 조작 방식)", "Scroll & Tap")).tag("scroll")
          Text(l10n.pick("드로잉 태블릿 (필압 펜 입력)", "Drawing Tablet")).tag("draw")
        }

        Toggle(
          isOn: Binding(
            get: { store.settings.palmRejection },
            set: { v in
              store.settings.palmRejection = v
              store.patchSettings(["macos_palm_rejection": v])
            }
          )
        ) {
          SettingsRowLabel(
            title: l10n.pick("펜 사용 중 손바닥 터치 차단", "Reject Touch While Using Pencil"),
            subtitle: l10n.pick("Apple Pencil이 호버 중이거나 그리는 동안 손바닥·손가락 터치 오작동을 자동으로 막습니다.", "Ignore stray finger and palm touches while Apple Pencil is hovering or drawing.")
          )
        }

        Toggle(
          l10n.pick("고해상도 부드러운 스크롤", "High-Resolution Scrolling"),
          isOn: Binding(
            get: { store.settings.highResScrolling },
            set: { v in
              store.settings.highResScrolling = v
              store.patchSettings(["high_resolution_scrolling": v])
            }
          )
        )

        Toggle(
          isOn: Binding(
            get: { store.settings.nativePenTouch },
            set: { v in
              store.settings.nativePenTouch = v
              store.patchSettings(["native_pen_touch": v])
            }
          )
        ) {
          SettingsRowLabel(
            title: l10n.pick("Apple Pencil 및 보조 터치 전달", "Apple Pencil & Auxiliary Touch"),
            subtitle: l10n.pick("Apple Pencil 필압 · 호버 · 배럴 롤을 전달합니다. 손가락 조작은 클라이언트 앱의 트랙패드/마우스 모드를 권장합니다.", "Forwards Apple Pencil pressure, hover, and barrel roll. Use the client app's Trackpad or Mouse mode for finger navigation.")
          )
        }
      }

      Section(l10n.pick("입력 장치", "Input Devices")) {
        Toggle(
          l10n.pick("키보드 입력 허용", "Enable Keyboard Input"),
          isOn: Binding(
            get: { store.settings.keyboard },
            set: { v in
              store.settings.keyboard = v
              store.patchSettings(["keyboard": v])
            }
          )
        )

        Toggle(
          l10n.pick("마우스 입력 허용", "Enable Mouse Input"),
          isOn: Binding(
            get: { store.settings.mouse },
            set: { v in
              store.settings.mouse = v
              store.patchSettings(["mouse": v])
            }
          )
        )
      }

      Section(l10n.pick("오디오", "Audio")) {
        Toggle(
          isOn: Binding(
            get: { store.settings.streamAudio },
            set: { v in
              store.settings.streamAudio = v
              store.patchSettings(["stream_audio": v])
            }
          )
        ) {
          SettingsRowLabel(
            title: l10n.pick("Mac 시스템 오디오 전송", "Stream System Audio"),
            subtitle: l10n.pick("스트리밍 중 클라이언트로 Mac의 오디오 출력을 함께 전달합니다.", "Capture and stream macOS system audio to connected clients.")
          )
        }

        Picker(
          l10n.pick("오디오 코덱 포맷", "Audio Codec"),
          selection: Binding(
            get: { store.settings.audioFormat },
            set: { v in
              store.settings.audioFormat = v
              store.patchSettings(["audio_format": v])
            }
          )
        ) {
          Text(l10n.pick("Opus (초저지연 기본)", "Opus (Low-Latency Default)")).tag("opus")
          Text("Dolby Digital (AC-3)").tag("ac3")
          Text("Dolby Digital Plus (E-AC-3)").tag("eac3")
        }
      }

      Section(l10n.pick("고급 옵션", "Advanced")) {
        LabeledContent {
          Button(l10n.pick("입력 고급...", "Input Options...")) {
            showInputAdvanced = true
          }
        } label: {
          SettingsRowLabel(
            title: l10n.pick("입력 세션 · 키 반복 및 키 바인딩", "Input Session, Key Repeat & Keybindings"),
            subtitle: l10n.pick("입력 전용 모드, 우측 Option 매핑, 키 반복 속도 및 커스텀 키 바인딩을 설정합니다.", "Configure input-only mode, Right Option mapping, key repeat, and custom keybindings.")
          )
        }

        LabeledContent {
          Button(l10n.pick("오디오 고급...", "Audio Options...")) {
            showAudioAdvanced = true
          }
        } label: {
          SettingsRowLabel(
            title: l10n.pick("오디오 출력 장치 및 서라운드 옵션", "Audio Routing & Surround"),
            subtitle: l10n.pick("CoreAudio 출력 싱크 장치 지정 및 Dolby 고음질 서라운드를 설정합니다.", "Configure CoreAudio sink override and high-quality Dolby surround.")
          )
        }
      }
    }
    .vibepolloSettingsForm()
    .sheet(isPresented: $showInputAdvanced) {
      InputAdvancedSheet(store: store)
    }
    .sheet(isPresented: $showAudioAdvanced) {
      AudioAdvancedSheet(store: store)
    }
  }
}

// MARK: - 4B. 입력 및 오디오 고급 옵션 시트 (Input & Audio Advanced Sheets)

struct InputAdvancedSheet: View {
  @ObservedObject var store: HostStore
  @Environment(\.dismiss) private var dismiss
  private var l10n: L10n { store.l10n }

  @ViewState private var repeatDelayDraft: Int = 500
  @ViewState private var repeatFreqDraft: Double = 24.9
  @ViewState private var keybindingsDraft: String = ""

  var body: some View {
    NavigationStack {
      Form {
        Section(l10n.pick("입력 세션", "Input Session")) {
          Toggle(
            l10n.pick("입력 전용(Input-Only) 스트림 모드 허용", "Enable Input-Only Mode"),
            isOn: Binding(
              get: { store.settings.enableInputOnlyMode },
              set: { v in
                store.settings.enableInputOnlyMode = v
                store.patchSettings(["enable_input_only_mode": v])
              }
            )
          )
        }

        Section(l10n.pick("키보드 반복 및 키 매핑", "Keyboard Repeat & Key Mapping")) {
          Toggle(
            l10n.pick("우측 Option(Alt) 키를 Command 키로 매핑", "Map Right Option to Command"),
            isOn: Binding(
              get: { store.settings.keyRightAltToKeyWin },
              set: { v in
                store.settings.keyRightAltToKeyWin = v
                store.patchSettings(["key_rightalt_to_key_win": v])
              }
            )
          )

          LabeledContent(l10n.pick("키 반복 시작 지연 (ms)", "Key Repeat Delay (ms)")) {
            TextField("", value: $repeatDelayDraft, format: .number.grouping(.never))
              .labelsHidden()
              .font(.system(size: 12, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 90)
              .onSubmit(commitFields)
          }

          LabeledContent(l10n.pick("키 반복 속도 (회/초)", "Key Repeat Frequency (Hz)")) {
            TextField("", value: $repeatFreqDraft, format: .number.grouping(.never))
              .labelsHidden()
              .font(.system(size: 12, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 90)
              .onSubmit(commitFields)
          }

          LabeledContent(l10n.pick("커스텀 키 바인딩 목록", "Custom Keybindings")) {
            TextField("", text: $keybindingsDraft, prompt: Text("[0x10, 0xA0, ...]"))
              .labelsHidden()
              .font(.system(size: 12, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 200)
              .onSubmit(commitFields)
          }
        }
      }
      .vibepolloSheetForm()
      .navigationTitle(l10n.pick("입력 고급 옵션", "Advanced Input Options"))
      .toolbarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(l10n.pick("완료", "Done")) {
            NSApp.keyWindow?.makeFirstResponder(nil)
            commitFields()
            dismiss()
          }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
        }
      }
    }
    .frame(width: 480, height: 340)
    .onAppear {
      repeatDelayDraft = store.settings.keyRepeatDelay
      repeatFreqDraft = store.settings.keyRepeatFrequency
      keybindingsDraft = store.settings.keybindings
    }
    .onDisappear {
      commitFields()
    }
  }

  private func commitFields() {
    var patch: [String: Any] = [:]
    let rd = max(0, repeatDelayDraft)
    if rd != store.settings.keyRepeatDelay {
      store.settings.keyRepeatDelay = rd
      patch["key_repeat_delay"] = rd
    }
    let rf = max(0.1, repeatFreqDraft)
    if abs(rf - store.settings.keyRepeatFrequency) > 0.01 {
      store.settings.keyRepeatFrequency = rf
      patch["key_repeat_frequency"] = rf
    }
    let kb = keybindingsDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    if kb != store.settings.keybindings {
      store.settings.keybindings = kb
      patch["keybindings"] = kb
    }
    if !patch.isEmpty {
      store.patchSettings(patch)
    }
  }
}

struct AudioAdvancedSheet: View {
  @ObservedObject var store: HostStore
  @Environment(\.dismiss) private var dismiss
  private var l10n: L10n { store.l10n }

  @ViewState private var audioSinkDraft: String = ""

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Toggle(
            l10n.pick("Dolby 서라운드 고음질 비트레이트 (AC-3 / E-AC-3)", "High-Quality Dolby Bitrate"),
            isOn: Binding(
              get: { store.settings.highQualityAudio },
              set: { v in
                store.settings.highQualityAudio = v
                store.patchSettings(["high_quality_audio": v])
              }
            )
          )
        }

        Section(l10n.pick("CoreAudio 출력 장치 지정 (비워 두면 시스템 전체 오디오)", "CoreAudio Sink Override")) {
          LabeledContent(l10n.pick("오디오 싱크 (audio_sink)", "Audio Sink")) {
            TextField("", text: $audioSinkDraft, prompt: Text(l10n.pick("시스템 기본", "System Default")))
              .labelsHidden()
              .font(.system(size: 12, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 210)
              .onSubmit(commitFields)
          }
        }
      }
      .vibepolloSheetForm()
      .navigationTitle(l10n.pick("오디오 고급 옵션", "Advanced Audio Options"))
      .toolbarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(l10n.pick("완료", "Done")) {
            NSApp.keyWindow?.makeFirstResponder(nil)
            commitFields()
            dismiss()
          }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
        }
      }
    }
    .frame(width: 470, height: 240)
    .onAppear {
      audioSinkDraft = store.settings.audioSink
    }
    .onDisappear {
      commitFields()
    }
  }

  private func commitFields() {
    let s1 = audioSinkDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    if s1 != store.settings.audioSink {
      store.settings.audioSink = s1
      store.patchSettings(["audio_sink": s1])
    }
  }
}
