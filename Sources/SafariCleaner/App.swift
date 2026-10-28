import AppKit
import SwiftUI

@main
struct SafariCleanerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("Safari Cleaner", systemImage: "safari") {
            Group {
                Button("Очистить кэш") { model.cleanCache() }
                Button("Очистить cookies…") { model.cleanCookies() }
                Button("Очистить историю…") { model.cleanHistory() }
            }
            .disabled(model.isBusy)
            Divider()
            Toggle("Тестовый режим (ничего не удалять)", isOn: $model.testMode)
            Divider()
            Button("Проверить доступ к диску") { model.showAccessStatus() }
            Button("Выйти") { NSApp.terminate(nil) }
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    /// On at every launch: deleting must always be a deliberate choice.
    @Published var testMode = true
    @Published private(set) var isBusy = false
    private var reportWindow: NSWindow?
    private var testNote: String {
        testMode ? "\n\nТестовый режим: ничего не будет удалено, вы увидите только отчёт." : ""
    }
    private static let fullDiskAccessSettings =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    func cleanCache() {
        guard ensureAccess() else { return }
        perform(needsHistoryServiceClosed: false) { _ in CacheCleaner.scan() }
    }

    func cleanCookies() {
        guard ensureAccess() else { return }
        guard confirm("Очистить cookies и данные сайтов?",
                      "Вы выйдете из аккаунтов на сайтах. Продолжить?" + testNote,
                      button: "Продолжить") else { return }
        perform(needsHistoryServiceClosed: false) { _ in CookiesCleaner.scan() }
    }

    func cleanHistory() {
        guard ensureAccess(), let period = choosePeriod() else { return }
        guard confirm("Удалить историю за \(period.title)?",
                      "Будут удалены посещения за этот период, страницы, у которых не останется посещений, "
                      + "и все значки сайтов (Favicon Cache).\n\n"
                      + "История синхронизируется через iCloud: на iPhone и iPad она останется "
                      + "и может вернуться на этот Mac." + testNote,
                      button: testMode ? "Продолжить" : "Удалить") else { return }
        perform(needsHistoryServiceClosed: true) { HistoryCleaner.run(period: period, testMode: $0) }
    }

    func showAccessStatus() {
        if SafariPaths.hasFullDiskAccess() {
            alert("Доступ есть", "У приложения есть «Полный доступ к диску», папки Safari видны.").runModal()
        } else {
            _ = ensureAccess()
        }
    }

    // MARK: - Running a cleaner

    /// `work` gets the test-mode flag; outside test mode Safari is closed first and `Deleter` removes what was found.
    private func perform(needsHistoryServiceClosed: Bool, _ work: @escaping @Sendable (Bool) -> Report) {
        let testMode = self.testMode
        isBusy = true
        Task {
            defer { isBusy = false }
            if !testMode {
                guard await closeSafari(needsHistoryServiceClosed: needsHistoryServiceClosed) else { return }
            }
            var report = await Task.detached {
                var report = work(testMode)
                report.testMode = testMode
                if !testMode { Deleter.apply(to: &report) }
                return report
            }.value
            if testMode && SafariProcess.isRunning {
                report.notes.insert("Safari сейчас открыт. При настоящей очистке приложение предложит закрыть его. "
                                    + "Для тестового режима закрывать не нужно.", at: 0)
            }
            show(report)
        }
    }

    private func closeSafari(needsHistoryServiceClosed: Bool) async -> Bool {
        if SafariProcess.isRunning {
            guard confirm("Safari открыт",
                          "Перед очисткой Safari нужно закрыть. Он закроется так же, как по ⌘Q.\n\n"
                          + "Если после повторного открытия окна не вернутся, восстановите их через меню Safari "
                          + "«История → Открыть все окна из последнего сеанса».",
                          button: "Закрыть Safari и продолжить") else { return false }
            SafariProcess.quit()
        }
        if await SafariProcess.waitUntilClosed(includingHistoryService: needsHistoryServiceClosed) { return true }
        let text = SafariProcess.isRunning
            ? "Safari не закрылся. Возможно, он задал вопрос (например, о несохранённой форме). "
              + "Ответьте на него или закройте Safari вручную и нажмите кнопку ещё раз."
            : "Safari закрылся, но его служба истории ещё работает и держит файл истории открытым. "
              + "Подождите минуту и нажмите кнопку ещё раз."
        alert("Очистка отменена, ничего не удалено", text).runModal()
        return false
    }

    // MARK: - Dialogs

    private func ensureAccess() -> Bool {
        guard !SafariPaths.hasFullDiskAccess() else { return true }
        let a = alert("Нужен «Полный доступ к диску»",
                      "macOS закрывает папки Safari от всех программ.\n\n"
                      + "Откройте Системные настройки → Конфиденциальность и безопасность → Полный доступ к диску "
                      + "и включите SafariCleaner. Если после этого доступа всё ещё нет, перезапустите приложение.")
        a.addButton(withTitle: "Открыть настройки")
        a.addButton(withTitle: "Отмена")
        if a.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(Self.fullDiskAccessSettings)
        }
        return false
    }

    private func choosePeriod() -> HistoryPeriod? {
        let a = alert("Очистить историю", "За какой период?")
        let periods: [HistoryPeriod] = [.lastHour, .today, .allTime]
        for p in periods { a.addButton(withTitle: p.title.prefix(1).uppercased() + p.title.dropFirst()) }
        a.addButton(withTitle: "Отмена")
        let index = a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return periods.indices.contains(index) ? periods[index] : nil
    }

    private func confirm(_ title: String, _ text: String, button: String) -> Bool {
        let a = alert(title, text)
        a.addButton(withTitle: button)
        a.addButton(withTitle: "Отмена")
        return a.runModal() == .alertFirstButtonReturn
    }

    /// Dialogs float above every other app's windows and take focus right away.
    private func alert(_ title: String, _ text: String) -> NSAlert {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.window.level = .floating
        NSApp.activate()
        return a
    }

    // MARK: - Reports

    private func show(_ report: Report) {
        reportWindow?.close()
        let window = NSWindow(contentViewController: NSHostingController(
            rootView: ReportView(report: report) { [weak self] in self?.reportWindow?.close() }))
        window.title = "Safari Cleaner"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        reportWindow = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}
