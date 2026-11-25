import AppKit
import SwiftUI

// MARK: - 2. 디스플레이 (Displays Settings Pane)

struct DisplaySettingsPane: View {
  @ObservedObject var store: HostStore
  @ViewState private var showAdvancedSheet = false
  private var l10n: L10n { store.l10n }

  private static let scaleChoices: [Int] = [100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500]

  var body: some View {
    Form {
      Section {
        Picker(
          selection: Binding(
            get: { store.settings.virtualDisplayMode },
            set: { v in
              store.settings.virtualDisplayMode = v
              store.patchSettings(["virtual_display_mode": v])
            }
          )
        ) {
          Text(l10n.pick("클라이언트별 전용 모니터", "Per-Client Virtual Display")).tag("per_client")
          Text(l10n.pick("공유 가상 모니터", "Shared Virtual Display")).tag("shared")
          Text(l10n.pick("물리 모니터 직접 캡처", "Physical Display")).tag("disabled")
        } label: {
          SettingsRowLabel(
            title: l10n.pick("디스플레이 방식", "Display Mode"),
            subtitle: l10n.pick("클라이언트 해상도와 주사율에 맞춘 독립 가상 화면을 생성합니다.", "Create native CGVirtualDisplay screens matching client resolution and refresh rate.")
          )
        }

        Picker(
          l10n.pick("레티나(HiDPI) 배율", "Retina HiDPI Scale"),
          selection: Binding(
            get: { store.settings.virtualDisplayScale },
            set: { v in
              store.settings.virtualDisplayScale = v
              store.patchSettings(["dd_virtual_display_scale": v])
            }
          )
        ) {
          Text(l10n.pick("자동 (권장)", "Automatic (Recommended)")).tag(-1)
          Text(l10n.pick("기존 배율 유지", "Preserve Current")).tag(0)
          ForEach(Self.scaleChoices, id: \.self) { pct in
            Text(pct == 200 ? "200% (2x Retina)" : "\(pct)%").tag(pct)
          }
          if store.settings.virtualDisplayScale != -1
            && store.settings.virtualDisplayScale != 0
            && !Self.scaleChoices.contains(store.settings.virtualDisplayScale)
          {
            Text("\(store.settings.virtualDisplayScale)%").tag(store.settings.virtualDisplayScale)
          }
        }

        Picker(
          l10n.pick("HDR 요청 처리", "HDR Request Policy"),
          selection: Binding(
            get: { store.settings.hdrRequestOverride },
            set: { v in
              store.settings.hdrRequestOverride = v
              store.patchSettings(["dd_hdr_request_override": v])
            }
          )
        ) {
          Text(l10n.pick("자동 (클라이언트 요청 따름)", "Automatic (Follow Client)")).tag("auto")
          Text(l10n.pick("항상 HDR 활성화 강제", "Force HDR On")).tag("force_on")
          Text(l10n.pick("항상 SDR 유지 (HDR 끔)", "Force HDR Off (SDR)")).tag("force_off")
        }

        Toggle(
          isOn: Binding(
            get: { store.settings.keepDisplayWhilePaused },
            set: { v in
              store.settings.keepDisplayWhilePaused = v
              store.patchSettings(["virtual_display_keep_while_paused": v])
            }
          )
        ) {
          SettingsRowLabel(
            title: l10n.pick("일시정지 중 가상 모니터 유지", "Keep Virtual Display While Paused"),
            subtitle: l10n.pick("스트림이 잠시 중단되어도 열려 있는 창 배치를 그대로 보존합니다.", "Preserve window positions while a client temporarily pauses.")
          )
        }

        Toggle(
          isOn: Binding(
            get: { store.settings.lidCloseEndsStreams },
            set: { v in
              store.settings.lidCloseEndsStreams = v
              store.patchSettings(["lid_close_ends_streams": v])
            }
          )
        ) {
          SettingsRowLabel(
            title: l10n.pick("MacBook 덮개를 닫을 때 스트림 종료", "End Stream When Lid Closes"),
            subtitle: l10n.pick("비활성화하면 깨어 있는 MacBook의 덮개를 닫은 상태에서도 스트리밍을 유지합니다.", "Turn off to continue streaming in clamshell mode while your Mac stays awake.")
          )
        }
      }

      Section(l10n.pick("고급 옵션", "Advanced")) {
        LabeledContent {
          Button(l10n.pick("고급...", "Advanced...")) {
            showAdvancedSheet = true
          }
        } label: {
          SettingsRowLabel(
            title: l10n.pick("모니터 배치 · 타겟 출력 및 원격 모니터", "Arrangement, Target Output & Remote Monitor"),
            subtitle: l10n.pick("배치 정책, 일시정지 해제 시간, 캡처 모니터 ID, 대체 해상도 및 원격 모니터 동작을 설정합니다.", "Configure layout policy, paused timeout, target display ID, fallback mode, and Remote Monitor options.")
          )
        }
      }
    }
    .vibepolloSettingsForm()
    .sheet(isPresented: $showAdvancedSheet) {
      DisplayAdvancedSheet(store: store)
    }
  }
}

// MARK: - 3. 화질 및 인코더 (Video & Encoder Pane)

struct VideoSettingsPane: View {
  @ObservedObject var store: HostStore
  @ViewState private var showAdvancedSheet = false
  private var l10n: L10n { store.l10n }

  private static let presetBitrates: [Int] = [0, 20000, 50000, 80000, 100000, 150000, 250000, 500000]

  var body: some View {
    Form {
      Section(l10n.pick("현재 스트리밍 화질", "Current Stream")) {
        if store.dashboard.sessions.isEmpty {
          LabeledContent(l10n.pick("상태", "Status")) {
            Text(l10n.pick("스트리밍 시작 시 클라이언트 설정이 반영됩니다", "Follows client app once streaming starts"))
              .font(.system(size: 12.5))
              .foregroundStyle(.secondary)
          }
        } else {
          ForEach(store.dashboard.sessions) { s in
            LabeledContent {
              VStack(alignment: .trailing, spacing: 2) {
                Text("\(s.codec) · \(s.bitDepth)-bit \(s.hdr ? "HDR" : "SDR") · \(s.yuv444 ? "4:4:4" : "4:2:0")")
                  .font(.system(size: 12.5, weight: .medium))
                Text(currentStreamMetricsSubtitle(s))
                  .font(.system(size: 11.5).monospacedDigit())
                  .foregroundStyle(.secondary)
              }
            } label: {
              SettingsRowLabel(
                title: s.deviceName,
                subtitle: s.directUsb
                  ? l10n.pick("USB 유선 연결 중", "Connected via USB")
                  : l10n.pick("네트워크 연결 중", "Connected via Network")
              )
            }
          }
          if let pipe = store.dashboard.encoderSpec?.activePipeline, pipe.active {
            LabeledContent(l10n.pick("인코딩 경로", "Encoding Pipeline")) {
              Text(activePipelineSummary(pipe))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
            }
          }
        }
      }

      if let spec = store.dashboard.encoderSpec {
        HardwareEncoderSpecsSection(spec: spec, l10n: l10n)
      }

      Section {
        Picker(
          l10n.pick("비디오 인코더", "Video Encoder"),
          selection: Binding(
            get: { store.settings.encoder },
            set: { v in
              store.settings.encoder = v
              store.patchSettings(["encoder": v])
            }
          )
        ) {
          Text(l10n.pick("자동 (권장)", "Automatic (Recommended)")).tag("")
          Text(l10n.pick("Apple VideoToolbox (하드웨어)", "Apple VideoToolbox (Hardware)")).tag("videotoolbox")
          Text(l10n.pick("소프트웨어 (CPU 인코딩)", "Software (CPU)")).tag("software")
          if !["", "videotoolbox", "software"].contains(store.settings.encoder) {
            Text(store.settings.encoder).tag(store.settings.encoder)
          }
        }

        Picker(
          l10n.pick("최대 비트레이트 상한", "Max Bitrate Ceiling"),
          selection: Binding(
            get: { store.settings.maxBitrateKbps },
            set: { v in
              store.settings.maxBitrateKbps = v
              store.patchSettings(["max_bitrate": v])
            }
          )
        ) {
          Text(l10n.pick("제한 없음 (클라이언트 설정 따름)", "Uncapped (Follow Client)")).tag(0)
          Text("20 Mbps").tag(20000)
          Text("50 Mbps").tag(50000)
          Text("80 Mbps").tag(80000)
          Text("100 Mbps").tag(100000)
          Text("150 Mbps").tag(150000)
          Text("250 Mbps").tag(250000)
          Text("500 Mbps").tag(500000)
          if !Self.presetBitrates.contains(store.settings.maxBitrateKbps) {
            Text(l10n.pick("사용자 지정 (\(store.settings.maxBitrateKbps) kbps)", "Custom (\(store.settings.maxBitrateKbps) kbps)"))
              .tag(store.settings.maxBitrateKbps)
          }
        }

        Picker(
          l10n.pick("HEVC 허용 범위", "Allow HEVC"),
          selection: Binding(
            get: { store.settings.hevcMode },
            set: { v in
              store.settings.hevcMode = v
              store.patchSettings(["hevc_mode": v])
            }
          )
        ) {
          Text(l10n.pick("자동 (클라이언트 설정 따름)", "Automatic (Follow Client)")).tag(0)
          Text(l10n.pick("사용 안 함 (H.264로 제한)", "Disabled (H.264 Only)")).tag(1)
          Text(l10n.pick("8-bit SDR까지만 허용", "Up to 8-bit SDR")).tag(2)
          Text(l10n.pick("10-bit HDR까지 허용", "Up to 10-bit HDR")).tag(3)
        }

        Toggle(
          isOn: Binding(
            get: { store.settings.vtRealtime },
            set: { v in
              store.settings.vtRealtime = v
              store.patchSettings(["vt_realtime": v ? "enabled" : "disabled"])
            }
          )
        ) {
          SettingsRowLabel(
            title: l10n.pick("VideoToolbox 실시간 저지연 인코딩", "VideoToolbox Realtime Priority"),
            subtitle: l10n.pick("Apple Silicon 미디어 엔진의 프레임 인코딩 지연을 최소화합니다.", "Minimize frame encoding latency on Apple Silicon Media Engine.")
          )
        }
      } header: {
        Text(l10n.pick("인코더 및 코덱 허용 범위", "Encoder & Allowed Formats"))
      }

      Section(l10n.pick("고급 옵션", "Advanced")) {
        LabeledContent {
          Button(l10n.pick("고급...", "Advanced...")) {
            showAdvancedSheet = true
          }
        } label: {
          SettingsRowLabel(
            title: l10n.pick("인코더 튜닝 · 비트레이트 직접 입력 및 패킷 복구", "Encoder Tuning, Custom Bitrate & FEC"),
            subtitle: l10n.pick("세부 비트레이트(kbps), VideoToolbox 코더, SW 프리셋/QP, 유휴 FPS, FEC 및 페이싱을 설정합니다.", "Configure exact kbps bitrate, VideoToolbox coder, SW preset/QP, idle FPS, FEC, and pacing.")
          )
        }
      }
    }
    .vibepolloSettingsForm()
    .sheet(isPresented: $showAdvancedSheet) {
      VideoAdvancedSheet(store: store)
    }
  }

  private func currentStreamMetricsSubtitle(_ s: ActiveStreamSession) -> String {
    let liveFps = (s.actualFps ?? 0) > 0 ? (s.actualFps ?? 0) : Double(s.fps)
    let liveMbps = (s.actualBitrateKbps ?? 0) > 0
      ? ((s.actualBitrateKbps ?? 0) / 1000.0)
      : (Double(s.bitrateKbps) / 1000.0)
    return String(format: "%d×%d · %.1f fps · %.1f Mbps", s.width, s.height, liveFps, liveMbps)
  }

  private func activePipelineSummary(_ pipe: EncoderRuntimePipeline) -> String {
    var parts: [String] = []
    if !pipe.captureFormat.isEmpty {
      parts.append(pipe.zeroCopy ? "Zero-Copy (\(pipe.captureFormat))" : "\(pipe.captureFormat) → \(pipe.encoderFormat)")
    }
    if !pipe.throughputTier.isEmpty {
      parts.append("AppleAVE \(pipe.throughputTier.capitalized)")
    }
    return parts.isEmpty ? "\(pipe.codec) \(pipe.profile)" : parts.joined(separator: " · ")
  }
}

// MARK: - Hardware Encoder Spec & Session History Components

private struct HardwareEncoderSpecsSection: View {
  let spec: EncoderSpecSnapshot
  let l10n: L10n

  private var backendSummary: String {
    let base: String
    if spec.backend == "videotoolbox" {
      base = "Apple VideoToolbox"
    } else if spec.backend == "software" {
      base = l10n.pick("소프트웨어 (CPU)", "Software (CPU)")
    } else {
      base = spec.backend
    }
    if spec.hevcMaxMpxPerSec > 0 {
      return String(format: "%@ · HEVC %.0f Mpx/s", base, spec.hevcMaxMpxPerSec)
    }
    return base
  }

  private var supportedCodecsSummary: String {
    var items: [String] = []
    if spec.h264 { items.append("H.264") }
    if spec.hevc10BitHdr {
      items.append("HEVC 10-bit")
    } else if spec.hevc8Bit {
      items.append("HEVC")
    }
    if spec.hevc444_10Bit || spec.hevc444_8Bit {
      items.append("4:4:4")
    }
    if spec.av1Hw {
      items.append("AV1")
    }
    return items.isEmpty ? "—" : items.joined(separator: " · ")
  }

  var body: some View {
    Section(l10n.pick("하드웨어 인코더", "Hardware Encoder")) {
      LabeledContent(l10n.pick("인코더", "Encoder")) {
        Text(backendSummary)
          .font(.system(size: 12.5).monospacedDigit())
          .foregroundStyle(.secondary)
      }

      LabeledContent(l10n.pick("지원 코덱", "Supported Codecs")) {
        Text(supportedCodecsSummary)
          .font(.system(size: 12.5))
          .foregroundStyle(.secondary)
      }
    }
  }
}

// MARK: - 2B. 디스플레이 고급 옵션 시트 (Display Advanced Sheet)

struct DisplayAdvancedSheet: View {
  @ObservedObject var store: HostStore
  @Environment(\.dismiss) private var dismiss
  private var l10n: L10n { store.l10n }

  @ViewState private var outputNameDraft: String = ""
  @ViewState private var fallbackModeDraft: String = ""

  var body: some View {
    NavigationStack {
      Form {
        Section(l10n.pick("가상 모니터 배치 및 유지", "Virtual Display Policy")) {
          Picker(
            l10n.pick("모니터 배치 정책", "Layout Policy"),
            selection: Binding(
              get: { store.settings.virtualDisplayLayout },
              set: { v in
                store.settings.virtualDisplayLayout = v
                store.patchSettings(["virtual_display_layout": v])
              }
            )
          ) {
            Text(l10n.pick("단독 표시 (물리 화면 숨김, 기본)", "Exclusive (Default)")).tag("exclusive")
            Text(l10n.pick("데스크톱 확장", "Extended")).tag("extended")
            Text(l10n.pick("확장 + 주 모니터 지정", "Extended Primary")).tag("extended_primary")
            Text(l10n.pick("확장 + 커서 격리 배치", "Extended Isolated")).tag("extended_isolated")
            Text(l10n.pick("확장 + 주 모니터 및 커서 격리", "Extended Primary & Isolated")).tag("extended_primary_isolated")
          }

          Picker(
            l10n.pick("일시정지 모니터 자동 해제 시간", "Paused Display Timeout"),
            selection: Binding(
              get: { store.settings.pausedDisplayTimeoutSecs },
              set: { v in
                store.settings.pausedDisplayTimeoutSecs = v
                store.patchSettings(["dd_paused_virtual_display_timeout_secs": v])
              }
            )
          ) {
            Text(l10n.pick("앱 종료 시까지 계속 유지", "Keep Until App Closes")).tag(0)
            Text(l10n.pick("30분", "30 Minutes")).tag(1800)
            Text(l10n.pick("1시간", "1 Hour")).tag(3600)
            Text(l10n.pick("2시간 (기본)", "2 Hours (Default)")).tag(7200)
            Text(l10n.pick("4시간", "4 Hours")).tag(14400)
            if ![0, 1800, 3600, 7200, 14400].contains(store.settings.pausedDisplayTimeoutSecs) {
              Text("\(store.settings.pausedDisplayTimeoutSecs)s").tag(store.settings.pausedDisplayTimeoutSecs)
            }
          }

          Picker(
            l10n.pick("가상 모니터 최대 동시 클라이언트", "Max Virtual Display Clients"),
            selection: Binding(
              get: { store.settings.virtualDisplayMaxClients },
              set: { v in
                store.settings.virtualDisplayMaxClients = v
                store.patchSettings(["virtual_display_max_clients": v])
              }
            )
          ) {
            ForEach(1...8, id: \.self) { count in
              Text("\(count)").tag(count)
            }
            if !(1...8).contains(store.settings.virtualDisplayMaxClients) {
              Text("\(store.settings.virtualDisplayMaxClients)").tag(store.settings.virtualDisplayMaxClients)
            }
          }
        }

        Section(l10n.pick("물리 모니터 타겟 및 대체 해상도", "Target Output & Fallback Mode")) {
          LabeledContent(l10n.pick("캡처 대상 모니터 ID", "Target Display ID")) {
            TextField("", text: $outputNameDraft, prompt: Text(l10n.pick("자동 (주 모니터)", "Auto (Main Display)")))
              .labelsHidden()
              .font(.system(size: 12, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 180)
              .onSubmit(commitFieldsIfNeeded)
          }

          LabeledContent(l10n.pick("기본 대체 해상도", "Fallback Resolution")) {
            TextField("", text: $fallbackModeDraft, prompt: Text("1920x1080x60"))
              .labelsHidden()
              .font(.system(size: 12, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 180)
              .onSubmit(commitFieldsIfNeeded)
          }
        }

        Section(l10n.pick("원격 보조 모니터 (Remote Monitor)", "Remote Monitor Sessions")) {
          Toggle(
            l10n.pick("실행 중인 앱 교체 시 확인 요청", "Confirm Before Replacing Running App"),
            isOn: Binding(
              get: { store.settings.remoteMonitorConfirmAppReplacement },
              set: { v in
                store.settings.remoteMonitorConfirmAppReplacement = v
                store.patchSettings(["remote_monitor_confirm_app_replacement": v])
              }
            )
          )

          Toggle(
            l10n.pick("원격 모니터 전용 세션 오디오 음소거", "Mute Audio for Remote Monitor"),
            isOn: Binding(
              get: { store.settings.remoteMonitorMuteAudio },
              set: { v in
                store.settings.remoteMonitorMuteAudio = v
                store.patchSettings(["remote_monitor_mute_audio": v])
              }
            )
          )

          Toggle(
            l10n.pick("스트림 종료 시 원격 모니터 즉시 해제", "Release Remote Monitor When Stream Ends"),
            isOn: Binding(
              get: { store.settings.remoteMonitorDisconnectOnStreamEnd },
              set: { v in
                store.settings.remoteMonitorDisconnectOnStreamEnd = v
                store.patchSettings(["remote_monitor_disconnect_on_stream_end": v])
              }
            )
          )
        }
      }
      .vibepolloSheetForm()
      .navigationTitle(l10n.pick("고급 디스플레이 옵션", "Advanced Display Options"))
      .toolbarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(l10n.pick("완료", "Done")) {
            NSApp.keyWindow?.makeFirstResponder(nil)
            commitFieldsIfNeeded()
            dismiss()
          }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
        }
      }
    }
    .frame(width: 500, height: 440)
    .onAppear {
      outputNameDraft = store.settings.outputName
      fallbackModeDraft = store.settings.fallbackMode
    }
    .onDisappear {
      commitFieldsIfNeeded()
    }
  }

  private func commitFieldsIfNeeded() {
    var patch: [String: Any] = [:]
    let outTrim = outputNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    if outTrim != store.settings.outputName {
      store.settings.outputName = outTrim
      patch["output_name"] = outTrim
    }
    let fbTrim = fallbackModeDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    if fbTrim != store.settings.fallbackMode {
      store.settings.fallbackMode = fbTrim
      patch["fallback_mode"] = fbTrim
    }
    if !patch.isEmpty {
      store.patchSettings(patch)
    }
  }
}

// MARK: - 3B. 화질 및 인코더 고급 옵션 시트 (Video Advanced Sheet)

struct VideoAdvancedSheet: View {
  @ObservedObject var store: HostStore
  @Environment(\.dismiss) private var dismiss
  private var l10n: L10n { store.l10n }

  @ViewState private var bitrateDraft: Int = 0
  @ViewState private var minFpsDraft: Double = 20.0
  @ViewState private var fecDraft: Int = 20
  @ViewState private var qpDraft: Int = 28
  @ViewState private var minThreadsDraft: Int = 2

  private static let swPresets = [
    "ultrafast", "superfast", "veryfast", "faster", "fast", "medium", "slow", "slower", "veryslow",
  ]
  private static let swTunes = [
    "zerolatency", "film", "animation", "grain", "stillimage", "fastdecode",
  ]

  var body: some View {
    NavigationStack {
      Form {
        Section(l10n.pick("비트레이트 · 프레임 및 패킷 복구", "Bitrate, Frame Pacing & FEC")) {
          LabeledContent {
            TextField("", value: $bitrateDraft, format: .number.grouping(.never))
              .labelsHidden()
              .font(.system(size: 12.5, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 110)
              .onSubmit(commitNumericFields)
          } label: {
            SettingsRowLabel(
              title: l10n.pick("최대 비트레이트 상한 (kbps)", "Max Bitrate (kbps)"),
              subtitle: l10n.pick("0 입력 시 클라이언트 요청 비트레이트를 제한 없이 따릅니다.", "Set 0 to follow the client's requested bitrate without cap.")
            )
          }

          LabeledContent(l10n.pick("유휴 화면 최소 프레임 (FPS)", "Minimum Idle FPS")) {
            TextField("", value: $minFpsDraft, format: .number.grouping(.never))
              .labelsHidden()
              .font(.system(size: 12.5, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 90)
              .onSubmit(commitNumericFields)
          }

          LabeledContent(l10n.pick("패킷 손실 복구율 (FEC %)", "FEC Percentage (0–255)")) {
            TextField("", value: $fecDraft, format: .number.grouping(.never))
              .labelsHidden()
              .font(.system(size: 12.5, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 90)
              .onSubmit(commitNumericFields)
          }

          Picker(
            l10n.pick("최대 비디오 배치 크기", "Max Video Batch Size"),
            selection: Binding(
              get: { store.settings.videoMaxBatchSizeKb },
              set: { v in
                store.settings.videoMaxBatchSizeKb = v
                store.patchSettings(["video_max_batch_size_kb": v])
              }
            )
          ) {
            Text("16 KB").tag(16)
            Text("32 KB").tag(32)
            Text(l10n.pick("64 KB (기본)", "64 KB (Default)")).tag(64)
            if ![16, 32, 64].contains(store.settings.videoMaxBatchSizeKb) {
              Text("\(store.settings.videoMaxBatchSizeKb) KB").tag(store.settings.videoMaxBatchSizeKb)
            }
          }

          Toggle(
            l10n.pick("호스트 적응형 패킷 페이싱", "Host Adaptive Packet Pacing"),
            isOn: Binding(
              get: { store.settings.hostAdaptivePacing },
              set: { v in
                store.settings.hostAdaptivePacing = v
                store.patchSettings(["host_adaptive_pacing": v])
              }
            )
          )
        }

        Section("Apple VideoToolbox") {
          Picker(
            l10n.pick("H.264 엔트로피 코딩 (vt_coder)", "H.264 Entropy Coding"),
            selection: Binding(
              get: { store.settings.vtCoder },
              set: { v in
                store.settings.vtCoder = v
                store.patchSettings(["vt_coder": v])
              }
            )
          ) {
            Text(l10n.pick("자동", "Automatic")).tag("auto")
            Text("CABAC").tag("cabac")
            Text("CAVLC").tag("cavlc")
          }

          Picker(
            l10n.pick("소프트웨어 인코더 폴백 (vt_software)", "Software Fallback"),
            selection: Binding(
              get: { store.settings.vtSoftware },
              set: { v in
                store.settings.vtSoftware = v
                store.patchSettings(["vt_software": v])
              }
            )
          ) {
            Text(l10n.pick("자동", "Automatic")).tag("auto")
            Text(l10n.pick("비활성 (하드웨어 전용)", "Disabled")).tag("disabled")
            Text(l10n.pick("허용", "Allowed")).tag("allowed")
            Text(l10n.pick("소프트웨어 강제", "Forced")).tag("forced")
          }

          Toggle(
            l10n.pick("시작 시 인코더 점검 실패 무시", "Ignore Encoder Probe Failure"),
            isOn: Binding(
              get: { store.settings.ignoreEncoderProbeFailure },
              set: { v in
                store.settings.ignoreEncoderProbeFailure = v
                store.patchSettings(["ignore_encoder_probe_failure": v])
              }
            )
          )
        }

        Section(l10n.pick("소프트웨어(CPU) 인코더 세부 설정", "Software (CPU) Encoder")) {
          Picker(
            l10n.pick("인코딩 프리셋 (sw_preset)", "Preset"),
            selection: Binding(
              get: { store.settings.swPreset },
              set: { v in
                store.settings.swPreset = v
                store.patchSettings(["sw_preset": v])
              }
            )
          ) {
            ForEach(Self.swPresets, id: \.self) { p in
              Text(p).tag(p)
            }
          }

          Picker(
            l10n.pick("인코딩 튜닝 (sw_tune)", "Tune"),
            selection: Binding(
              get: { store.settings.swTune },
              set: { v in
                store.settings.swTune = v
                store.patchSettings(["sw_tune": v])
              }
            )
          ) {
            ForEach(Self.swTunes, id: \.self) { t in
              Text(t).tag(t)
            }
          }

          LabeledContent(l10n.pick("양자화 계수 QP (0–51)", "Quantizer Parameter (QP)")) {
            TextField("", value: $qpDraft, format: .number.grouping(.never))
              .labelsHidden()
              .font(.system(size: 12.5, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 80)
              .onSubmit(commitNumericFields)
          }

          LabeledContent(l10n.pick("최소 인코딩 스레드 수", "Minimum CPU Threads")) {
            TextField("", value: $minThreadsDraft, format: .number.grouping(.never))
              .labelsHidden()
              .font(.system(size: 12.5, design: .monospaced))
              .multilineTextAlignment(.trailing)
              .frame(width: 80)
              .onSubmit(commitNumericFields)
          }
        }
      }
      .vibepolloSheetForm()
      .navigationTitle(l10n.pick("고급 화질 및 인코더 옵션", "Advanced Video Options"))
      .toolbarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(l10n.pick("완료", "Done")) {
            NSApp.keyWindow?.makeFirstResponder(nil)
            commitNumericFields()
            dismiss()
          }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
        }
      }
    }
    .frame(width: 500, height: 500)
    .onAppear {
      bitrateDraft = store.settings.maxBitrateKbps
      minFpsDraft = store.settings.minimumFpsTarget
      fecDraft = store.settings.fecPercentage
      qpDraft = store.settings.qp
      minThreadsDraft = store.settings.minThreads
    }
    .onDisappear {
      commitNumericFields()
    }
  }

  private func commitNumericFields() {
    var patch: [String: Any] = [:]
    let cleanBitrate = max(0, bitrateDraft)
    if cleanBitrate != store.settings.maxBitrateKbps {
      store.settings.maxBitrateKbps = cleanBitrate
      patch["max_bitrate"] = cleanBitrate
    }
    let cleanFps = max(0.0, min(1000.0, minFpsDraft))
    if abs(cleanFps - store.settings.minimumFpsTarget) > 0.01 {
      store.settings.minimumFpsTarget = cleanFps
      patch["minimum_fps_target"] = cleanFps
    }
    let cleanFec = max(0, min(255, fecDraft))
    if cleanFec != store.settings.fecPercentage {
      store.settings.fecPercentage = cleanFec
      patch["fec_percentage"] = cleanFec
    }
    let cleanQp = max(0, min(51, qpDraft))
    if cleanQp != store.settings.qp {
      store.settings.qp = cleanQp
      patch["qp"] = cleanQp
    }
    let cleanThreads = max(1, min(64, minThreadsDraft))
    if cleanThreads != store.settings.minThreads {
      store.settings.minThreads = cleanThreads
      patch["min_threads"] = cleanThreads
    }
    if !patch.isEmpty {
      store.patchSettings(patch)
    }
  }
}
