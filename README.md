<p align="center">
  <img src="assets/brand/symbol.svg" width="88" alt="Yandex Keyboard Desktop">
</p>

<h1 align="center">Yandex Keyboard Desktop</h1>

<p align="center">
  Text assistant for Windows · Текстовый помощник для Windows
</p>

<p align="center">
  <a href="#english">English</a>
  ·
  <a href="#русский">Русский</a>
</p>

<p align="center">
  <a href="https://github.com/0niel/yandex-keyboard-desktop/releases/latest"><strong>Download · Скачать</strong></a>
  ·
  <a href="https://github.com/0niel/yandex-keyboard-desktop/releases">All releases · Все релизы</a>
</p>

## 🎬 Demo · Демонстрация

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

## 📄 License · Лицензия

Distributed under the [MIT License](LICENSE) · Проект распространяется по лицензии [MIT](LICENSE).
