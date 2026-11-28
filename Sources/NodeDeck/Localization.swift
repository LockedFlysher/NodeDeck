import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case zhHans = "zh-Hans"
    case en

    var id: String { rawValue }

    @MainActor
    var menuTitle: String {
        switch self {
        case .system:
            return AppLocalization.shared.isChinese ? "跟随系统 (System)" : "System Default"
        case .zhHans:
            return "简体中文"
        case .en:
            return "English"
        }
    }
}

@MainActor
final class AppLocalization: ObservableObject {
    static let shared = AppLocalization()
    private static let storageKey = "nodedeck.language"

    @Published var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Self.storageKey)
        }
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.storageKey) ?? AppLanguage.system.rawValue
        self.language = AppLanguage(rawValue: saved) ?? .system
    }

    var isChinese: Bool {
        switch language {
        case .zhHans:
            return true
        case .en:
            return false
        case .system:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
            return preferred.hasPrefix("zh")
        }
    }

    func t(_ zh: String, _ en: String) -> String {
        isChinese ? zh : en
    }

    func toggleChineseEnglish() {
        language = isChinese ? .en : .zhHans
    }
}

@MainActor
func L(_ zh: String, _ en: String) -> String {
    AppLocalization.shared.t(zh, en)
}

extension SidebarFilter {
    @MainActor
    var localizedTitle: String {
        switch self {
        case .all: return L("全部", "All")
        case .online: return L("在线", "Online")
        case .mounted: return L("已挂载", "Mounted")
        case .gpu: return L("GPU", "GPU")
        }
    }
}
