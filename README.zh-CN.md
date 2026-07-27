<p align="center">
  <img src="assets/brand/symbol.svg" width="88" alt="Yandex Keyboard Desktop">
</p>

<h1 align="center">Yandex Keyboard Desktop</h1>

<p align="center">
  Windows 文本助手 · Текстовый помощник для Windows
</p>

<p align="center">
  <a href="#english">English</a>
  ·
  <a href="#русский">Русский</a>
  ·<a href="#简体中文">简体中文</a>
</p>

<p align="center">
  <a href="https://github.com/0niel/yandex-keyboard-desktop/releases/latest"><strong>下载 · Скачать · Download</strong></a>
  ·
  <a href="https://github.com/0niel/yandex-keyboard-desktop/releases">所有版本 · Все релизы · All releases</a>
</p>

## 🎬 Demo · 演示

https://github.com/user-attachments/assets/c2ddd419-5f81-49e3-b851-718b5502678a

## English

Yandex Keyboard Desktop improves selected text, fixes spelling and punctuation, and adds emoji directly in the active application.

### ✨ Features

- improves wording while preserving the original meaning;
- fixes spelling and punctuation;
- adds relevant emoji;
- shows a compact assistant window next to the cursor;
- provides global keyboard shortcuts and separate settings profiles;
- supports English and Russian with automatic system language detection;
- runs from the system tray and can start with Windows;
- restores clipboard contents after processing.

### 🚀 Quick start

1. Download the ZIP archive from the [latest release](https://github.com/0niel/yandex-keyboard-desktop/releases/latest).
2. Extract it to any convenient folder.
3. Run `yandex_keyboard_desktop.exe`.
4. Select text in any application and press the required keyboard shortcut.

Releases are published for Windows x64 as portable archives, with no installer or MSIX. The application is currently unsigned, so Windows SmartScreen may display a warning on first launch.

### ⌨️ Keyboard shortcuts

| Action | Default |
  | --- | --- |
| Show the assistant | `Ctrl+Alt+Space` |
| Improve selected text | `Ctrl+Alt+R` |
| Fix errors in selected text | `Ctrl+Alt+F` |
| Emojify selected text | `Ctrl+Alt+E` |

All shortcuts can be changed in the application settings.

### 🔒 Data and privacy

Selected text is sent to the processing service only when the user starts an action. Local history and diagnostics are disabled by default. When enabled, they do not store the original or processed text, clipboard contents, window titles, or URLs.

### 🛠 Development

Building the application requires Flutter 3.44.2 and a configured Windows desktop toolchain.

```powershell
git clone https://github.com/0niel/yandex-keyboard-desktop.git
cd yandex-keyboard-desktop
flutter pub get --enforce-lockfile
flutter run -d windows
```

Release build:

```powershell
flutter build windows --release
```

GitHub Actions checks formatting, static analysis, tests, and the Windows build before publishing a portable archive with a SHA-256 checksum. The version is derived from the UTC commit date and the total commit count.

## Русский

Yandex Keyboard Desktop улучшает выделенный текст, исправляет ошибки и добавляет эмодзи прямо в активном приложении.

### ✨ Возможности

- улучшение формулировок без изменения смысла;
- исправление орфографии и пунктуации;
- добавление уместных эмодзи;
- небольшое окно ассистента рядом с курсором;
- глобальные сочетания клавиш и отдельные профили настроек;
- интерфейс на русском и английском языках с автоматическим выбором языка системы;
- работа из системного трея и запуск вместе с Windows;
- восстановление содержимого буфера обмена после обработки.

### 🚀 Быстрый старт

1. Скачайте ZIP-архив из [последнего релиза](https://github.com/0niel/yandex-keyboard-desktop/releases/latest).
2. Распакуйте архив в удобную папку.
3. Запустите `yandex_keyboard_desktop.exe`.
4. Выделите текст в любом приложении и нажмите нужное сочетание клавиш.

Релизы публикуются для Windows x64 в portable-формате — без установщика и MSIX. Приложение пока не подписано сертификатом, поэтому при первом запуске Windows SmartScreen может показать предупреждение.

### ⌨️ Горячие клавиши

| Действие | По умолчанию |
| --- | --- |
| Показать ассистента | `Ctrl+Alt+Space` |
| Улучшить выделенный текст | `Ctrl+Alt+R` |
| Исправить ошибки | `Ctrl+Alt+F` |
| Добавить эмодзи | `Ctrl+Alt+E` |

Все сочетания можно изменить в настройках приложения.

### 🔒 Данные и конфиденциальность

Выделенный текст отправляется в сервис обработки только после запуска действия пользователем. Локальная история и диагностика по умолчанию отключены. При включении они не сохраняют исходный или обработанный текст, содержимое буфера обмена, заголовки окон и URL.

### 🛠 Разработка

Для сборки нужны Flutter 3.44.2 и настроенный Windows desktop toolchain.

```powershell
git clone https://github.com/0niel/yandex-keyboard-desktop.git
cd yandex-keyboard-desktop
flutter pub get --enforce-lockfile
flutter run -d windows
```

Релизная сборка:

```powershell
flutter build windows --release
```

GitHub Actions проверяет форматирование, статический анализ, тесты и Windows-сборку, после чего публикует portable-архив с контрольной суммой SHA-256. Версия формируется из даты коммита по UTC и общего количества коммитов.

## 简体中文

Yandex Keyboard Desktop 可以在当前活动应用程序中直接优化所选文本、修正拼写和标点，并添加表情符号。

### ✨ 功能特点

- 在保留原意的前提下优化措辞；
- 修正拼写和标点错误；
- 添加相关的表情符号；
- 在光标旁显示简洁的助手窗口；
- 提供全局快捷键和独立的设置配置文件；
- 支持英语和俄语，并能自动检测系统语言；
- 运行在系统托盘中，并支持随 Windows 启动；
- 处理完成后还原剪贴板内容。

### 🚀 快速上手

1. 从 [最新版本](https://github.com/0niel/yandex-keyboard-desktop/releases/latest) 下载 ZIP 压缩包。
2. 将其解压到任何方便的文件夹中。
3. 运行 `yandex_keyboard_desktop.exe`。
4. 在任何应用程序中选中一段文本，然后按下相应的快捷键。

发布版本为 Windows x64 的便携版（Portable），不含安装程序或 MSIX。目前该应用程序未签名，因此首次启动时 Windows SmartScreen 可能会显示警告。

### ⌨️ 快捷键

| 操作 | 默认快捷键 |
| --- | --- |
| 显示助手 | `Ctrl+Alt+Space` |
| 优化所选文本 | `Ctrl+Alt+R` |
| 修正所选文本错误 | `Ctrl+Alt+F` |
| 为所选文本添加表情 | `Ctrl+Alt+E` |

所有快捷键均可在应用程序设置中更改。

### 🔒 数据与隐私

仅在用户启动操作时，所选文本才会被发送到处理服务。本地历史记录和诊断功能默认关闭。即使开启，它们也不会存储原始文本或处理后的文本、剪贴板内容、窗口标题或 URL。

### 🛠 开发

构建应用程序需要 Flutter 3.44.2 和配置好的 Windows 桌面工具链。

```powershell
git clone https://github.com/0niel/yandex-keyboard-desktop.git
cd yandex-keyboard-desktop
flutter pub get --enforce-lockfile
flutter run -d windows
```

发布构建：

```powershell
flutter build windows --release
```

GitHub Actions 在发布带有 SHA-256 校验和的便携版压缩包之前，会检查格式、进行静态分析、运行测试并构建 Windows 版本。版本号由 UTC 提交日期和总提交次数决定。

## 📄 License · Лицензия · 许可证

Distributed under the [MIT License](LICENSE) · Проект распространяется по лицензии [MIT](LICENSE) · 基于 [MIT 许可证](LICENSE) 分发。
