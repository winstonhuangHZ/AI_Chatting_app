import Foundation
import SwiftUI

// MARK: - 界面语言
//
// 应用界面语言支持联合国六种官方语言：
//   阿拉伯语 (ar)、中文 (zh-Hans)、英语 (en)、法语 (fr)、俄语 (ru)、西班牙语 (es)
//
// 实现方式：纯 Swift 字典翻译表（不依赖 Xcode .xcstrings / .lproj 资源包，
// 因为本项目通过 swiftc / SPM 直接编译，资源捆绑不可靠）。

/// 应用支持的界面语言（联合国官方语言）。
enum AppLanguage: String, CaseIterable, Identifiable {

    case arabic = "ar"
    case chineseSimplified = "zh-Hans"
    case english = "en"
    case french = "fr"
    case russian = "ru"
    case spanish = "es"

    /// `Identifiable` conformance（直接把 rawValue 当作稳定 id）。
    var id: String { rawValue }

    /// 每种语言用「自身语言 + 英文备注」显示，方便用户识别。
    var localizedName: String {
        switch self {
        case .arabic:          return "العربية · Arabic"
        case .chineseSimplified: return "简体中文 · Chinese (Simplified)"
        case .english:         return "English"
        case .french:          return "Français · French"
        case .russian:         return "Русский · Russian"
        case .spanish:         return "Español · Spanish"
        }
    }

    /// 该语言对应的翻译表（key → 译文）。
    var translations: [String: String] {
        switch self {
        case .english:   return Self.tableEn
        case .chineseSimplified: return Self.tableZhHans
        case .french:    return Self.tableFr
        case .spanish:   return Self.tableEs
        case .russian:   return Self.tableRu
        case .arabic:    return Self.tableAr
        }
    }

    // MARK: - 英文（基准）

    fileprivate static let tableEn: [String: String] = [
        "app.name": "AI Chat",

        // 主窗口 / 消息区
        "no.chat.selected": "No Chat Selected",
        "no.chat.description": "Choose a chat from the sidebar or create a new one.",
        "chat.count": "%d chat(s)",
        "msgs.count": "%d msgs",
        "msg.count": "%d msg(s)",
        "you": "You",
        "assistant": "Assistant",
        "system": "System",
        "generating": "Generating…",
        "generating.waiting": "Waiting for response…",
        "attach.image": "Attach image(s)",
        "send": "Send (Enter)",
        "usage.tokens": "Tokens: ↑%1$@ ↓%2$@",
        "price.unknown": "(price unknown for this model)",
        "relay.price": "(relay price)",
        "msg.copy": "Copy",
        "msg.delete": "Delete",
        "msg.retry": "Retry",

        // 顶栏
        "profile": "Profile",
        "model": "Model",
        "stop": "Stop",
        "new.chat": "New Chat",
        "settings": "Settings",
        "no.profile.add": "No profile — add in Settings (⌘,)",
        "no.models.fetch": "No models — fetch in Settings",
        "new.chat.help": "Start a new chat (⌘N)",
        "settings.open.help": "Open API profile settings (⌘,)",

        // 侧边栏
        "delete.chat": "Delete Chat",
        "delete.all.chats": "Delete all chats",

        // 设置 - 列表
        "api.relay.profiles": "API Relay Profiles",
        "add.profile": "Add Profile",
        "no.profiles": "No Profiles",
        "no.profiles.description": "Add an OpenAI-compatible relay server to start chatting.",
        "user.profile": "User Profile",
        "user.profile.description": "Preferences the AI noticed from your chats. They're sent with the system prompt to personalize replies.",
        "no.preferences.learned": "No preferences learned yet. Mention what you like in a chat and the AI will remember it here.",
        "active": "Active",
        "fetch.models": "Fetch Models",
        "models.count": "%d models",
        "test": "Test",
        "edit": "Edit",
        "delete": "Delete",

        // 设置 - 编辑
        "add.profile.title": "Add Profile",
        "edit.profile.title": "Edit Profile",
        "profile.name": "Profile Name",
        "base.url": "Base URL",
        "api.key": "API Key",
        "generation": "Generation",
        "streaming.on": "Streaming render (token-by-token)",
        "timestamp.on": "Send timestamp (let the model know current time)",
        "generation.footer": "Render: Streaming → token-by-token; Non-streaming → show once when finished (both use SSE transport). Time-stamp: On → system prompt carries CURRENT TIME.",
        "system.prompt": "System Prompt",
        "system.prompt.hint": "System prompt is sent before each chat; told the model Markdown is rendered.",
        "system.prompt.footer": "Edit freely — e.g. set the assistant's role/persona.",
        "models": "Models",
        "selected.model": "Selected Model",
        "no.models.yet": "No models yet",
        "multimodal.hint": "🖼 = multimodal (vision) model",
        "fetch.models.button": "Fetch Models",
        "cancel": "Cancel",
        "save": "Save",
        "add": "Add",

        // 通用状态
        "unnamed.profile": "Unnamed profile",
        "no.base.url": "No base URL set",
        "no.api.key": "No API key set",
        "no.model.selected": "No model selected",
        "operation.failed": "Operation Failed",
        "success": "Success",
        "memory.added": "Memory added/updated",
        "memory.removed": "Memory removed",
        "no.active.profile": "No active API profile. Add one in Settings first.",
        "no.configs.tag": "No profile — add in Settings (⌘,)",
        "model.empty.tag": "No models — fetch in Settings",
        "language.settings": "Interface Language",
        "language.hint": "Switch the app UI language. Matches your system language by default.",
        "appearance.font": "Font Preset",
        "appearance.fontsize": "Font Size",
        "appearance.sample": "Sample text — The quick brown fox jumps over the lazy dog. 中文示例：敏捷的棕色狐狸跳过了懒狗。",
        "appearance.description": "Applies to chat messages instantly. Choose serif, sans, or mono.",
        "appearance.serif": "Serif (衬线)",
        "appearance.sans": "Sans (无衬线)",
        "appearance.mono": "Mono (等宽)",
        "appearance.size.small": "Small",
        "appearance.size.medium": "Medium",
        "appearance.size.large": "Large",
        "appearance.size.xlarge": "Extra Large",
        "backup.title": "Backup & Restore",
        "backup.description": "Export all data (chats, API profiles, user profile, appearance, language) as a ZIP. Import it on another machine to restore everything.",
        "backup.export": "Export Backup…",
        "backup.import": "Import Backup…",
        "backup.exported": "Backup exported",
        "backup.imported": "Backup imported",
        "backup.export.failed": "Export failed",
        "backup.import.failed": "Import failed",
        "backup.export.choose_format": "Choose export format",
        "backup.import.choose_format": "Choose import format",
        "backup.format.zip": "ZIP archive (readable)",
        "backup.format.sqlite": "SQLite database"
    ]

    // MARK: - 简体中文

    fileprivate static let tableZhHans: [String: String] = [
        "app.name": "AI 聊天",

        "no.chat.selected": "未选择会话",
        "no.chat.description": "从侧边栏选择一个会话，或新建一个。",
        "chat.count": "%d 个会话",
        "msgs.count": "%d 条消息",
        "msg.count": "%d 条消息",
        "you": "你",
        "assistant": "助手",
        "system": "系统",
        "generating": "生成中…",
        "generating.waiting": "等待响应…",
        "attach.image": "附加图片",
        "send": "发送 (回车)",
        "usage.tokens": "Tokens：↑%1$@ ↓%2$@",
        "price.unknown": "(该模型价格未知)",
        "relay.price": "(中转站价格)",
        "msg.copy": "复制",
        "msg.delete": "删除",
        "msg.retry": "重新生成",

        "profile": "配置",
        "model": "模型",
        "stop": "停止",
        "new.chat": "新建会话",
        "settings": "设置",
        "no.profile.add": "无配置 — 请在设置中添加 (⌘,)",
        "no.models.fetch": "无模型 — 请在设置中获取",
        "new.chat.help": "新建会话 (⌘N)",
        "settings.open.help": "打开 API 配置设置 (⌘,)",

        "delete.chat": "删除会话",
        "delete.all.chats": "删除全部会话",

        "api.relay.profiles": "API 中转站配置",
        "add.profile": "添加配置",
        "no.profiles": "暂无配置",
        "no.profiles.description": "添加一个 OpenAI 兼容的中转服务器即可开始聊天。",
        "user.profile": "用户画像",
        "user.profile.description": "AI 从聊天中学到的偏好，将随系统提示一起发送以个性化回复。",
        "no.preferences.learned": "尚未学习到偏好。在聊天中提及你的喜好，AI 会在这里记住它。",
        "active": "使用中",
        "fetch.models": "获取模型",
        "models.count": "%d 个模型",
        "test": "测试",
        "edit": "编辑",
        "delete": "删除",

        "add.profile.title": "添加配置",
        "edit.profile.title": "编辑配置",
        "profile.name": "配置名称",
        "base.url": "基础地址",
        "api.key": "API 密钥",
        "generation": "生成",
        "streaming.on": "流式渲染（逐字显示）",
        "timestamp.on": "发送时间戳（让模型感知当前时间）",
        "generation.footer": "渲染：流式 → 逐字显示；非流式 → 结束后一次性显示（两者都走 SSE 传输）。时间戳：开 → 系统提示附带 CURRENT TIME。",
        "system.prompt": "系统提示",
        "system.prompt.hint": "每次聊天前发送的系统提示；已告知模型应用会渲染 Markdown。",
        "system.prompt.footer": "可自由编辑——例如设置助手的角色/人格。",
        "models": "模型",
        "selected.model": "已选模型",
        "no.models.yet": "暂无模型",
        "multimodal.hint": "🖼 = 多模态（视觉）模型",
        "fetch.models.button": "获取模型",
        "cancel": "取消",
        "save": "保存",
        "add": "添加",

        "unnamed.profile": "未命名配置",
        "no.base.url": "未设置基础地址",
        "no.api.key": "未设置 API 密钥",
        "no.model.selected": "未选择模型",
        "operation.failed": "操作失败",
        "success": "成功",
        "memory.added": "记忆已添加/更新",
        "memory.removed": "记忆已删除",
        "no.active.profile": "没有激活的 API 配置，请先在设置中添加。",
        "no.configs.tag": "无配置 — 请在设置中添加 (⌘,)",
        "model.empty.tag": "无模型 — 请在设置中获取",
        "language.settings": "界面语言",
        "language.hint": "切换应用界面语言，默认跟随系统语言。",
        "appearance.font": "字体预设",
        "appearance.fontsize": "字号",
        "appearance.sample": "示例文本 — 敏捷的棕色狐狸跳过了懒狗。The quick brown fox jumps over the lazy dog.",
        "appearance.description": "即时应用到聊天消息。可选择衬线、无衬线或等宽。",
        "appearance.serif": "衬线 (Serif)",
        "appearance.sans": "无衬线 (Sans)",
        "appearance.mono": "等宽 (Mono)",
        "appearance.size.small": "小",
        "appearance.size.medium": "中",
        "appearance.size.large": "大",
        "appearance.size.xlarge": "特大",
        "backup.export.choose_format": "选择导出格式",
        "backup.import.choose_format": "选择导入格式",
        "backup.format.zip": "ZIP 压缩包（可读）",
        "backup.format.sqlite": "SQLite 数据库"
    ]

    // MARK: - 法语

    fileprivate static let tableFr: [String: String] = [
        "app.name": "IA Chat",

        "no.chat.selected": "Aucune discussion sélectionnée",
        "no.chat.description": "Choisissez une discussion dans la barre latérale ou créez-en une nouvelle.",
        "chat.count": "%d discussion(s)",
        "msgs.count": "%d msg(s)",
        "msg.count": "%d msg(s)",
        "you": "Vous",
        "assistant": "Assistant",
        "system": "Système",
        "generating": "Génération…",
        "attach.image": "Joindre des images",
        "send": "Envoyer (Entrée)",
        "usage.tokens": "Tokens : ↑%1$@ ↓%2$@",
        "price.unknown": "(prix inconnu pour ce modèle)",
        "relay.price": "(prix du relais)",

        "profile": "Profil",
        "model": "Modèle",
        "stop": "Arrêter",
        "new.chat": "Nouvelle discussion",
        "settings": "Réglages",
        "no.profile.add": "Aucun profil — ajoutez-en un dans les réglages (⌘,)",
        "no.models.fetch": "Aucun modèle — récupérez-en dans les réglages",
        "new.chat.help": "Démarrer une nouvelle discussion (⌘N)",
        "settings.open.help": "Ouvrir les réglages des profils API (⌘,)",

        "delete.chat": "Supprimer la discussion",
        "delete.all.chats": "Supprimer toutes les discussions",

        "api.relay.profiles": "Profils de relais API",
        "add.profile": "Ajouter un profil",
        "no.profiles": "Aucun profil",
        "no.profiles.description": "Ajoutez un serveur relais compatible OpenAI pour commencer à discuter.",
        "user.profile": "Profil utilisateur",
        "user.profile.description": "Préférences remarquées par l'IA. Elles sont envoyées avec le prompt système pour personnaliser les réponses.",
        "no.preferences.learned": "Aucune préférence apprise. Mentionnez ce que vous aimez dans une discussion et l'IA s'en souviendra ici.",
        "active": "Actif",
        "fetch.models": "Récupérer les modèles",
        "models.count": "%d modèle(s)",
        "test": "Tester",
        "edit": "Modifier",
        "delete": "Supprimer",

        "add.profile.title": "Ajouter un profil",
        "edit.profile.title": "Modifier le profil",
        "profile.name": "Nom du profil",
        "base.url": "URL de base",
        "api.key": "Clé API",
        "generation": "Génération",
        "streaming.on": "Streaming (sortie au fil de l'eau)",
        "timestamp.on": "Envoyer l'horodatage (faire connaître l'heure au modèle)",
        "generation.footer": "Streaming : activé → mot à mot. Horodatage : activé → CURRENT TIME dans le prompt système.",
        "system.prompt": "Prompt système",
        "system.prompt.hint": "Envoyé avant chaque discussion ; informe le modèle que le Markdown est rendu.",
        "system.prompt.footer": "Modifiable librement — p. ex. définir le rôle/persona de l'assistant.",
        "models": "Modèles",
        "selected.model": "Modèle sélectionné",
        "no.models.yet": "Aucun modèle",
        "multimodal.hint": "🖼 = modèle multimodal (vision)",
        "fetch.models.button": "Récupérer les modèles",
        "cancel": "Annuler",
        "save": "Enregistrer",
        "add": "Ajouter",

        "unnamed.profile": "Profil sans nom",
        "no.base.url": "URL de base non définie",
        "no.api.key": "Clé API non définie",
        "no.model.selected": "Aucun modèle sélectionné",
        "operation.failed": "Échec de l'opération",
        "success": "Succès",
        "memory.added": "Mémoire ajoutée/mise à jour",
        "memory.removed": "Mémoire supprimée",
        "no.active.profile": "Aucun profil API actif. Ajoutez-en un dans les réglages d'abord.",
        "no.configs.tag": "Aucun profil — ajoutez-en dans les réglages (⌘,)",
        "model.empty.tag": "Aucun modèle — récupérez-en dans les réglages",
        "language.settings": "Langue de l'interface",
        "language.hint": "Change la langue de l'interface. Suit la langue du système par défaut.",
        "appearance.font": "Police",
        "appearance.fontsize": "Taille",
        "appearance.sample": "Exemple — Le renard brun rapide saute par-dessus le chien paresseux.",
        "appearance.description": "S'applique instantanément aux messages. Choisissez serif, sans ou mono.",
        "appearance.serif": "Serif",
        "appearance.sans": "Sans",
        "appearance.mono": "Mono",
        "appearance.size.small": "Petite",
        "appearance.size.medium": "Moyenne",
        "appearance.size.large": "Grande",
        "appearance.size.xlarge": "Extra large"
    ]

    // MARK: - 西班牙语

    fileprivate static let tableEs: [String: String] = [
        "app.name": "IA Chat",

        "no.chat.selected": "Sin conversación seleccionada",
        "no.chat.description": "Elija una conversación en la barra lateral o cree una nueva.",
        "chat.count": "%d conversación(es)",
        "msgs.count": "%d msgs",
        "msg.count": "%d msg(s)",
        "you": "Tú",
        "assistant": "Asistente",
        "system": "Sistema",
        "generating": "Generando…",
        "attach.image": "Adjuntar imagen(es)",
        "send": "Enviar (Intro)",
        "usage.tokens": "Tokens: ↑%1$@ ↓%2$@",
        "price.unknown": "(precio desconocido para este modelo)",
        "relay.price": "(precio del relay)",

        "profile": "Perfil",
        "model": "Modelo",
        "stop": "Detener",
        "new.chat": "Nueva conversación",
        "settings": "Ajustes",
        "no.profile.add": "Sin perfil — añada uno en Ajustes (⌘,)",
        "no.models.fetch": "Sin modelos — obtenga en Ajustes",
        "new.chat.help": "Iniciar nueva conversación (⌘N)",
        "settings.open.help": "Abrir ajustes de perfiles API (⌘,)",

        "delete.chat": "Eliminar conversación",
        "delete.all.chats": "Eliminar todas las conversaciones",

        "api.relay.profiles": "Perfiles de relay API",
        "add.profile": "Añadir perfil",
        "no.profiles": "Sin perfiles",
        "no.profiles.description": "Añada un servidor relay compatible con OpenAI para empezar a chatear.",
        "user.profile": "Perfil de usuario",
        "user.profile.description": "Preferencias que la IA notó en sus chats. Se envían con el prompt del sistema para personalizar respuestas.",
        "no.preferences.learned": "Aún no se aprendieron preferencias. Mencione lo que le gusta en un chat y la IA lo recordará aquí.",
        "active": "Activo",
        "fetch.models": "Obtener modelos",
        "models.count": "%d modelo(s)",
        "test": "Probar",
        "edit": "Editar",
        "delete": "Eliminar",

        "add.profile.title": "Añadir perfil",
        "edit.profile.title": "Editar perfil",
        "profile.name": "Nombre del perfil",
        "base.url": "URL base",
        "api.key": "Clave API",
        "generation": "Generación",
        "streaming.on": "Streaming (salida en directo)",
        "timestamp.on": "Enviar marca de hora (que el modelo sepa la hora actual)",
        "generation.footer": "Streaming: activado → palabra por palabra. Marca de hora: activada → CURRENT TIME en el prompt del sistema.",
        "system.prompt": "Prompt del sistema",
        "system.prompt.hint": "Se envía antes de cada chat; informa al modelo de que Markdown se renderiza.",
        "system.prompt.footer": "Edite libremente — p. ej. defina el rol/persona del asistente.",
        "models": "Modelos",
        "selected.model": "Modelo seleccionado",
        "no.models.yet": "Aún sin modelos",
        "multimodal.hint": "🖼 = modelo multimodal (visión)",
        "fetch.models.button": "Obtener modelos",
        "cancel": "Cancelar",
        "save": "Guardar",
        "add": "Añadir",

        "unnamed.profile": "Perfil sin nombre",
        "no.base.url": "URL base no definida",
        "no.api.key": "Clave API no definida",
        "no.model.selected": "Ningún modelo seleccionado",
        "operation.failed": "Error de operación",
        "success": "Éxito",
        "memory.added": "Memoria añadida/actualizada",
        "memory.removed": "Memoria eliminada",
        "no.active.profile": "Sin perfil API activo. Añada uno en Ajustes primero.",
        "no.configs.tag": "Sin perfil — añada en Ajustes (⌘,)",
        "model.empty.tag": "Sin modelos — obtenga en Ajustes",
        "language.settings": "Idioma de la interfaz",
        "language.hint": "Cambia el idioma de la interfaz. Sigue el idioma del sistema por defecto.",
        "appearance.font": "Tipo de letra",
        "appearance.fontsize": "Tamaño",
        "appearance.sample": "Ejemplo — El rápido zorro marrón salta sobre el perro perezoso.",
        "appearance.description": "Se aplica al instante a los mensajes. Elija serif, sans o mono.",
        "appearance.serif": "Serif",
        "appearance.sans": "Sans",
        "appearance.mono": "Mono",
        "appearance.size.small": "Pequeño",
        "appearance.size.medium": "Medio",
        "appearance.size.large": "Grande",
        "appearance.size.xlarge": "Extra grande"
    ]

    // MARK: - 俄语

    fileprivate static let tableRu: [String: String] = [
        "app.name": "ИИ-чат",

        "no.chat.selected": "Чат не выбран",
        "no.chat.description": "Выберите чат на боковой панели или создайте новый.",
        "chat.count": "%d чат(ов)",
        "msgs.count": "%d сообщ.",
        "msg.count": "%d сообщ.",
        "you": "Вы",
        "assistant": "Ассистент",
        "system": "Система",
        "generating": "Генерация…",
        "attach.image": "Прикрепить изображения",
        "send": "Отправить (Enter)",
        "usage.tokens": "Токены: ↑%1$@ ↓%2$@",
        "price.unknown": "(цена для этой модели неизвестна)",
        "relay.price": "(цена релея)",

        "profile": "Профиль",
        "model": "Модель",
        "stop": "Стоп",
        "new.chat": "Новый чат",
        "settings": "Настройки",
        "no.profile.add": "Нет профиля — добавьте в настройках (⌘,)",
        "no.models.fetch": "Нет моделей — получите в настройках",
        "new.chat.help": "Начать новый чат (⌘N)",
        "settings.open.help": "Открыть настройки профилей API (⌘,)",

        "delete.chat": "Удалить чат",
        "delete.all.chats": "Удалить все чаты",

        "api.relay.profiles": "Профили релеев API",
        "add.profile": "Добавить профиль",
        "no.profiles": "Нет профилей",
        "no.profiles.description": "Добавьте OpenAI-совместимый сервер-релей, чтобы начать общение.",
        "user.profile": "Профиль пользователя",
        "user.profile.description": "Предпочтения, замеченные ИИ в чатах. Они отправляются с системным промптом для персонализации ответов.",
        "no.preferences.learned": "Предпочтения ещё не изучены. Упомяните, что вам нравится, и ИИ запомнит это здесь.",
        "active": "Активен",
        "fetch.models": "Получить модели",
        "models.count": "%d модел(ей)",
        "test": "Тест",
        "edit": "Изменить",
        "delete": "Удалить",

        "add.profile.title": "Добавить профиль",
        "edit.profile.title": "Изменить профиль",
        "profile.name": "Имя профиля",
        "base.url": "Базовый URL",
        "api.key": "Ключ API",
        "generation": "Генерация",
        "streaming.on": "Стриминг (потоковый вывод)",
        "timestamp.on": "Отправлять метку времени (сообщить модели текущее время)",
        "generation.footer": "Стриминг: вкл → по токенам. Метка времени: вкл → CURRENT TIME в системном промпте.",
        "system.prompt": "Системный промпт",
        "system.prompt.hint": "Отправляется перед каждым чатом; сообщает модели, что Markdown рендерится.",
        "system.prompt.footer": "Можно редактировать — например, задать роль/персону ассистента.",
        "models": "Модели",
        "selected.model": "Выбранная модель",
        "no.models.yet": "Моделей пока нет",
        "multimodal.hint": "🖼 = мультимодальная (зрительная) модель",
        "fetch.models.button": "Получить модели",
        "cancel": "Отмена",
        "save": "Сохранить",
        "add": "Добавить",

        "unnamed.profile": "Безымянный профиль",
        "no.base.url": "Базовый URL не задан",
        "no.api.key": "Ключ API не задан",
        "no.model.selected": "Модель не выбрана",
        "operation.failed": "Ошибка операции",
        "success": "Успех",
        "memory.added": "Память добавлена/обновлена",
        "memory.removed": "Память удалена",
        "no.active.profile": "Нет активного профиля API. Сначала добавьте его в настройках.",
        "no.configs.tag": "Нет профиля — добавьте в настройках (⌘,)",
        "model.empty.tag": "Нет моделей — получите в настройках",
        "language.settings": "Язык интерфейса",
        "language.hint": "Переключить язык интерфейса. По умолчанию соответствует языку системы.",
        "appearance.font": "Шрифт",
        "appearance.fontsize": "Размер",
        "appearance.sample": "Пример — Быстрая коричневая лиса прыгает через ленивую собаку.",
        "appearance.description": "Применяется к сообщениям мгновенно. Выберите serif, sans или mono.",
        "appearance.serif": "Serif",
        "appearance.sans": "Sans",
        "appearance.mono": "Mono",
        "appearance.size.small": "Мелкий",
        "appearance.size.medium": "Средний",
        "appearance.size.large": "Крупный",
        "appearance.size.xlarge": "Очень крупный"
    ]

    // MARK: - 阿拉伯语

    fileprivate static let tableAr: [String: String] = [
        "app.name": "الدردشة الذكية",

        "no.chat.selected": "لم يتم تحديد محادثة",
        "no.chat.description": "اختر محادثة من الشريط الجانبي أو أنشئ محادثة جديدة.",
        "chat.count": "%d محادثة",
        "msgs.count": "%d رسالة",
        "msg.count": "%d رسالة",
        "you": "أنت",
        "assistant": "المساعد",
        "system": "النظام",
        "generating": "جارٍ التوليد…",
        "attach.image": "إرفاق صورة",
        "send": "إرسال (Enter)",
        "usage.tokens": "الرموز: ↑%1$@ ↓%2$@",
        "price.unknown": "(سعر هذا النموذج غير معروف)",
        "relay.price": "(سعر الوسيط)",

        "profile": "الملف",
        "model": "النموذج",
        "stop": "إيقاف",
        "new.chat": "محادثة جديدة",
        "settings": "الإعدادات",
        "no.profile.add": "لا يوجد ملف — أضفه في الإعدادات (⌘,)",
        "no.models.fetch": "لا توجد نماذج — اجلبها من الإعدادات",
        "new.chat.help": "بدء محادثة جديدة (⌘N)",
        "settings.open.help": "فتح إعدادات ملفات API (⌘,)",

        "delete.chat": "حذف المحادثة",
        "delete.all.chats": "حذف كل المحادثات",

        "api.relay.profiles": "ملفات وسائط API",
        "add.profile": "إضافة ملف",
        "no.profiles": "لا توجد ملفات",
        "no.profiles.description": "أضف خادم وسيط متوافقًا مع OpenAI لبدء الدردشة.",
        "user.profile": "ملف المستخدم",
        "user.profile.description": "تفضيلات لاحظها الذكاء الاصطناعي في محادثاتك. تُرسل مع موجه النظام لتخصيص الردود.",
        "no.preferences.learned": "لم تُتعلم تفضيلات بعد. اذكر ما يعجبك في محادثة وسيتذكرها الذكاء الاصطناعي هنا.",
        "active": "نشط",
        "fetch.models": "جلب النماذج",
        "models.count": "%d نموذج",
        "test": "اختبار",
        "edit": "تعديل",
        "delete": "حذف",

        "add.profile.title": "إضافة ملف",
        "edit.profile.title": "تعديل الملف",
        "profile.name": "اسم الملف",
        "base.url": "عنوان URL الأساسي",
        "api.key": "مفتاح API",
        "generation": "التوليد",
        "streaming.on": "البث (إخراج متدفق)",
        "timestamp.on": "إرسال الطابع الزمني (إعلام النموذج بالوقت الحالي)",
        "generation.footer": "البث: تشغيل → كلمة بكلمة. الطابع الزمني: تشغيل → CURRENT TIME في موجه النظام.",
        "system.prompt": "موجه النظام",
        "system.prompt.hint": "يُرسل قبل كل محادثة؛ يُعلم النموذج أن Markdown يُعرض.",
        "system.prompt.footer": "حرر بحرية — مثلًا اضبط دور/شخصية المساعد.",
        "models": "النماذج",
        "selected.model": "النموذج المحدد",
        "no.models.yet": "لا توجد نماذج بعد",
        "multimodal.hint": "🖼 = نموذج متعدد الوسائط (رؤية)",
        "fetch.models.button": "جلب النماذج",
        "cancel": "إلغاء",
        "save": "حفظ",
        "add": "إضافة",

        "unnamed.profile": "ملف بدون اسم",
        "no.base.url": "عنوان URL الأساسي غير مضبوط",
        "no.api.key": "مفتاح API غير مضبوط",
        "no.model.selected": "لم يُحدد نموذج",
        "operation.failed": "فشلت العملية",
        "success": "نجاح",
        "memory.added": "تمت إضافة/تحديث الذاكرة",
        "memory.removed": "تم حذف الذاكرة",
        "no.active.profile": "لا يوجد ملف API نشط. أضف واحدًا في الإعدادات أولًا.",
        "no.configs.tag": "لا يوجد ملف — أضفه في الإعدادات (⌘,)",
        "model.empty.tag": "لا توجد نماذج — اجلبها من الإعدادات",
        "language.settings": "لغة الواجهة",
        "language.hint": "بدّل لغة واجهة التطبيق. يتبع لغة النظام افتراضيًا.",
        "appearance.font": "الخط",
        "appearance.fontsize": "الحجم",
        "appearance.sample": "مثال — الثعلب البني السريع يقفز فوق الكلب الكسول.",
        "appearance.description": "يُطبق على الرسائل فورًا. اختر serif أو sans أو mono.",
        "appearance.serif": "Serif",
        "appearance.sans": "Sans",
        "appearance.mono": "Mono",
        "appearance.size.small": "صغير",
        "appearance.size.medium": "متوسط",
        "appearance.size.large": "كبير",
        "appearance.size.xlarge": "كبير جدًا"
    ]
}

// MARK: - 本地化管理器

/// 界面本地化管理器：持有当前语言并负责查询翻译。
///
/// - 界面通过 `@EnvironmentObject` 观察，切换语言即时刷新。
/// - ViewModel / Service 可直接调用全局 `L("key")`。
final class LocalizationManager: ObservableObject {

    /// 全局共享实例（AppMain 会注入到 environment）。
    static let shared = LocalizationManager()

    /// `UserDefaults` 存储键。
    private static let languageKey = "appLanguage"

    /// 当前界面语言。
    @Published var current: AppLanguage {
        didSet {
            UserDefaults.standard.set(current.rawValue, forKey: Self.languageKey)
            UserDefaults.standard.synchronize()
        }
    }

    /// 持久化已保存的语言（默认跟随系统：中文则 zh-Hans，否则英文）。
    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.languageKey)
        if let stored, let lang = AppLanguage(rawValue: stored) {
            current = lang
        } else {
            // 跟随系统语言：App 支持集内最接近系统的语言。
            let systemLang = Locale.preferredLanguages.first ?? "en"
            if systemLang.hasPrefix("zh") {
                current = .chineseSimplified
            } else if systemLang.hasPrefix("ar") {
                current = .arabic
            } else if systemLang.hasPrefix("fr") {
                current = .french
            } else if systemLang.hasPrefix("ru") {
                current = .russian
            } else if systemLang.hasPrefix("es") {
                current = .spanish
            } else {
                current = .english
            }
        }
    }

    /// 查询当前语言的翻译；缺失的 key 回退到英文。
    func tr(_ key: String) -> String {
        translations[key] ?? Self.englishFallback[key] ?? key
    }

    /// 带格式化参数的查询（`%d` / `%@`）。
    func tr(_ key: String, _ args: CVarArg...) -> String {
        String(format: tr(key), locale: Locale(identifier: current.rawValue), arguments: args)
    }

    /// 当前语言的翻译表（英文兜底）。
    private var translations: [String: String] {
        var table = AppLanguage.tableEn
        table.merge(current.translations) { _, localized in localized }
        return table
    }

    private static let englishFallback = AppLanguage.tableEn
}

// MARK: - 便捷全局函数

/// 界面文本快捷方式（任何层都可用）。
func L(_ key: String) -> String {
    LocalizationManager.shared.tr(key)
}

/// 带参数的界面文本快捷方式。
func L(_ key: String, _ args: CVarArg...) -> String {
    LocalizationManager.shared.tr(key, args)
}