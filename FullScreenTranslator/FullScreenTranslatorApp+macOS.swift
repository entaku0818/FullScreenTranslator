#if canImport(AppKit)
  import AppKit
  import Speech
  import SwiftUI
  import Translation

  // NSWindowへアクセスするためのNSViewRepresentable
  struct WindowAccessor: NSViewRepresentable {
    var text: String?
    var callback: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
      let view = NSView()
      // 次のRunLoopでwindowプロパティにアクセス
      DispatchQueue.main.async {
        self.callback(view.window)
      }
      return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
      guard let window = nsView.window else { return }
      if text?.isEmpty ?? true {
        window.orderOut(nil)
      } else {
        window.orderFront(nil)
      }
    }
  }

  struct SubtitlesView: View {
    var text: String
    var translated: String?

    var body: some View {
      VStack {
        Spacer()  // 画面上部の余白
        VStack(spacing: 8) {
          Text(text)
            .font(.system(size: 24, weight: .bold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, alignment: .center)
            .multilineTextAlignment(.center)

          if let translated {
            Text(translated)
              .font(.system(size: 48, weight: .bold))
              .foregroundColor(.white)
              .frame(maxWidth: .infinity, alignment: .center)
              .multilineTextAlignment(.center)
          }
        }
        .background(Color.black.opacity(0.6))
      }
      .ignoresSafeArea()
    }
  }

  struct ContentView: View {
    var text: String?
    var translated: String?

    var body: some View {
      ZStack {
        if let text {
          SubtitlesView(text: text, translated: translated)
        }
        WindowAccessor(text: text) { window in
          if let window = window {
            window.isOpaque = false
            window.backgroundColor = .clear
            window.styleMask = [.borderless]
            window.level = .screenSaver
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            if let screenFrame = NSScreen.main?.frame {
              window.setFrame(screenFrame, display: true)
            }
          }
        }
      }
      .ignoresSafeArea()
    }
  }

  @main
  struct FullScreenTranslatorApp: App {
    @State var alertMessage: AlertMessage?
    @State var speechRecognizer: SpeechRecognizer = .init()
    @State var localeIdentifier: String
    @State var translateLanguageCode: String
    @State var supportedLanguageCodes: [String] = []
    @State var translator: Translator = .init()
    @State var configuration: TranslationSession.Configuration?
    private let languageAvailability = LanguageAvailability()
    @State var notSupported: Bool = false

    init() {
      if let data = UserDefaults.standard.data(forKey: baseLocaleKey) {
        do {
          localeIdentifier = try JSONDecoder().decode(Locale.self, from: data).identifier
        } catch {
          print("\(Self.self) error \(error.localizedDescription)")
          localeIdentifier = Locale.current.identifier
          self.alertMessage = .init(message: error.localizedDescription)
        }
      } else {
        localeIdentifier = Locale.current.identifier
      }

      if let data = UserDefaults.standard.data(forKey: translateLanguageKey) {
        do {
          translateLanguageCode =
            try JSONDecoder().decode(Locale.Language.self, from: data).languageCode?.identifier
            ?? "en"
        } catch {
          print("\(Self.self)error \(error.localizedDescription)")
          translateLanguageCode = "en"
          self.alertMessage = .init(message: error.localizedDescription)
        }
      } else {
        translateLanguageCode = "en"
      }

      speechRecognizer = SpeechRecognizer(locale: Locale(identifier: localeIdentifier))
      speechRecognizer.requestAuthorization()
    }

    var body: some Scene {
      WindowGroup {
        ContentView(text: speechRecognizer.text, translated: translator.translated)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .translationTask(configuration) { session in
            Task {
              do {
                try await session.prepareTranslation()
                translator.setSession(session)
              } catch {
                print("translationTask.error \(error.localizedDescription)")
              }
            }
          }
          .alert("Not supported language", isPresented: $notSupported, actions: {})
          .alert(
            item: $alertMessage,
            content: { alertMessage in
              Alert(title: Text(alertMessage.message))
            })
      }
      .windowStyle(HiddenTitleBarWindowStyle())

      MenuBarExtra(
        content: {
          if speechRecognizer.isAuthorized {
            if speechRecognizer.isRecognizing {
              Button {
                do {
                  try speechRecognizer.stopRecognition()
                  speechRecognizer.text = nil
                } catch {
                  self.alertMessage = .init(message: error.localizedDescription)
                }
              } label: {
                HStack {
                  Image(systemName: "stop.circle.fill")
                  Text("Stop")
                }
              }
            } else {
              Button {
                do {
                  try speechRecognizer.startRecognition()
                } catch {
                  self.alertMessage = .init(message: error.localizedDescription)
                }
              } label: {
                HStack {
                  Image(systemName: "play.fill")
                  Text("Start")
                }
              }
            }
          } else {
            Text("Please allow permission")
          }

          Picker(
            "Base locale", selection: $localeIdentifier,
            content: {
              ForEach(
                Array(
                  SFSpeechRecognizer.supportedLocales().sorted(
                    using: KeyPathComparator(\.identifier))
                ).map(\.identifier), id: \.self
              ) { currentLocale in
                Text(currentLocale).tag(currentLocale)
              }
            }
          )

          Picker(
            "Translate language", selection: $translateLanguageCode,
            content: {
              ForEach(supportedLanguageCodes, id: \.self) { language in
                Text(language).tag(language)
              }
            }
          )

          Button {
            exit(1)
          } label: {
            Text("Quit")
          }
        },
        label: {
          HStack {
            if !speechRecognizer.isAuthorized {
              Image(systemName: "microphone.badge.xmark.fill")
            } else if speechRecognizer.isRecognizing {
              Image(systemName: "progress.indicator")
            } else {
              Image(systemName: "translate")
            }
          }
          .task {
            let availability = LanguageAvailability()
            supportedLanguageCodes = Set(
              await availability.supportedLanguages.compactMap { $0.languageCode?.identifier }
            )
            .sorted(using: KeyPathComparator(\.self))
            updateTranslateConfiguration()
          }
          .onChange(of: localeIdentifier) { oldValue, newValue in
            speechRecognizer = SpeechRecognizer(locale: Locale(identifier: newValue))
            speechRecognizer.requestAuthorization()
            save()
            updateTranslateConfiguration()
          }
          .onChange(of: translateLanguageCode) { oldValue, newValue in
            save()
            updateTranslateConfiguration()
          }
          .onChange(of: speechRecognizer.text) { oldValue, newValue in
            guard let text = newValue, !text.isEmpty else { return }
            translator.translate(text)
          }
        }
      )
    }

    private func updateTranslateConfiguration() {
      Task {
        let locale = Locale(identifier: localeIdentifier)
        let translateLanguage = Locale.Language(identifier: translateLanguageCode)
        let status = await languageAvailability.status(from: locale.language, to: translateLanguage)
        print("\(Self.self).updateTranslateConfiguration status: \(status)")
        switch status {
        case .installed, .supported:
          configuration?.invalidate()
          configuration = .init(source: locale.language, target: translateLanguage)
        case .unsupported:
          notSupported = true
        @unknown default:
          return
        }
      }
    }

    private let baseLocaleKey = "baseLocale"
    private let translateLanguageKey = "translateLanguage"

    private func save() {
      do {
        let localeData = try JSONEncoder().encode(Locale(identifier: localeIdentifier))
        UserDefaults.standard.set(localeData, forKey: baseLocaleKey)

        let translateLanguageData = try JSONEncoder().encode(
          Locale.Language(identifier: translateLanguageCode))
        UserDefaults.standard.set(translateLanguageData, forKey: translateLanguageKey)
      } catch {
        print("\(Self.self) error \(error.localizedDescription)")
      }
    }
  }
#endif
