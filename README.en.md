# Safari Cleaner

<img src="Resources/AppIcon.svg" width="128" alt="Safari Cleaner icon">

A small macOS menu bar app that clears Safari in one click: cache, cookies with website data, history. It has a test mode that only shows what *would* be removed, and a whitelist of sites whose cookies must stay.

![Safari Cleaner menu](docs/menu.png)

*[Русская версия](README.md). The app's interface is in Russian.*

## Requirements

- macOS 14 Sonoma or later.
- A Mac with Apple Silicon (M1 or later) or Intel: the app is built for both at once.
- Xcode Command Line Tools (free, installed with one command, see below). The full Xcode is not needed.

## Installing from source

1. **Install the Command Line Tools.** Open Terminal and run:
   ```
   xcode-select --install
   ```
   An installer window appears; click "Install". If the tools are already installed, the command says so, which is fine.

2. **Download the code:**
   ```
   git clone https://github.com/danecom7/safari-cleaner.git
   cd safari-cleaner
   ```

3. **Build the app:**
   ```
   ./build.sh
   ```
   The build takes 1–2 minutes. The result is `build/SafariCleaner.app`.

4. **Move it to Applications:**
   ```
   cp -R build/SafariCleaner.app /Applications/
   ```
   Or drag `SafariCleaner.app` from the `build` folder to Applications in Finder.

5. **Launch** Safari Cleaner from Applications. The app has no window: a compass icon appears on the right side of the menu bar.

### About signing

If your keychain has an "Apple Development" certificate (you have one if you have signed in to Xcode with your Apple ID), `build.sh` signs the app with it. Then "Full Disk Access" survives rebuilds.

If there is no certificate (most people don't have one), the app is signed locally (ad-hoc). It works exactly the same, but after **every rebuild** macOS treats it as a new app, and "Full Disk Access" has to be switched on again. To pick a specific certificate: `SIGN_IDENTITY="..." ./build.sh`.

## First launch: "Full Disk Access"

macOS hides Safari's folders from all apps, so without this permission the app sees nothing. Do this once:

1. Open **System Settings → Privacy & Security → Full Disk Access**.
2. Click "+" at the bottom of the list and choose **SafariCleaner** in Applications. If the app is already in the list, just turn its switch on.
3. Restart Safari Cleaner: menu bar icon → "Выйти" (Quit), then open it again.

To check: icon → "Проверить доступ к диску" (Check disk access). If access is missing, the app offers to open the right settings pane.

## How to use

### Menu items

| Menu item | Meaning |
|---|---|
| Очистить кэш | Clear cache |
| Очистить cookies… | Clear cookies… |
| Очистить историю… | Clear history… |
| Белый список cookies | Cookie whitelist |
| Тестовый режим (ничего не удалять) | Test mode (delete nothing) |
| Проверить доступ к диску | Check disk access |
| Выйти | Quit |

### Test mode

At **every** launch the app starts in test mode: "Тестовый режим (ничего не удалять)" is checked in the menu. In this mode every button only shows a report: what would be removed and how much space would be freed. Nothing is deleted, and Safari doesn't need to be closed.

To delete for real, uncheck test mode and press the button again. Before a real cleanup the app asks to quit Safari (the same way as ⌘Q). If Safari doesn't quit, the cleanup is cancelled and nothing is deleted.

Tip: look at the report in test mode first, then delete.

### Cookie whitelist

To stay signed in to important sites, add them to the whitelist: menu → "Белый список cookies" (Cookie whitelist) → "Добавить сайт…" (Add site…).

- A site is stored by domain: `google.com` keeps cookies and data of `google.com`, `mail.google.com`, `accounts.google.com` and other subdomains.
- You can paste a full address too, e.g. `https://www.google.com/mail`: the app takes `google.com` from it.
- To remove a site: the same menu → choose the site → "Удалить из белого списка" (Remove from whitelist).

The list is stored on your Mac in `~/Library/Application Support/SafariCleaner/whitelist.json` and is never sent anywhere.

If the whitelist has sites, the cookie file is not deleted as a whole but rebuilt: only cookies of whitelisted sites remain in it. Before changing anything, the app checks that it can rebuild an exact, byte-for-byte copy of the original from the parsed file. If it can't, cookies are left untouched. A backup is made before the file is replaced: on any error it is put back, on success it is deleted.

## What each button removes

| Button | What is removed | Where it lives |
|---|---|---|
| **Clear cache** | page cache, WebKit cache, previews | `~/Library/Containers/com.apple.Safari/Data/Library/Caches/com.apple.Safari/*`, `…/Caches/WebKit/NetworkCache`, the old cache in `~/Library/Caches/com.apple.Safari` |
| **Clear cookies…** | Safari cookies and website data (Local Storage, IndexedDB, WebSQL, Cache Storage), except whitelisted sites. You will be signed out of websites | `~/Library/Cookies/Cookies.binarycookies`, `…/WebKit/WebsiteData/{Default,IndexedDB,LocalStorage,WebSQL}`, `…/Caches/WebKit/CacheStorage` |
| **Clear history…** | visits for the chosen period (last hour, today, all time), pages left with no visits, website icons | `~/Library/Safari/History.db` (+ `-wal`, `-shm`), `~/Library/Safari/Favicon Cache` |

History is removed carefully, through the database itself rather than by deleting the file: first a backup is made, then records are removed, then the file is compacted and checked for integrity. On any error the backup is put back.

### What the app never touches

Bookmarks, tabs (including recently closed ones), passwords, form autofill, Safari settings, extensions, iCloud sync data (CloudKit), HSTS, other apps' cookies. A guard in the code (`SafariPaths.swift`) refuses any path outside the table above, any path through a symbolic link, and any files with these names.

## ⚠️ iCloud and history

If Safari sync is turned on in iCloud settings, history is shared between all your devices. Safari Cleaner removes history **on this Mac only**. It stays on your iPhone and iPad and **may come back** to the Mac at the next sync.

To remove history everywhere, clear it on your other devices too (on iPhone: Settings → Apps → Safari → "Clear History and Website Data"), or turn off Safari sync in iCloud.

## Uninstalling

1. Menu bar icon → "Выйти" (Quit).
2. Delete `SafariCleaner.app` from Applications (drag it to the Trash).
3. Delete the settings folder (it only holds the whitelist):
   ```
   rm -rf ~/Library/Application\ Support/SafariCleaner
   ```
4. In **System Settings → Privacy & Security → Full Disk Access** select SafariCleaner and click "−".

The app leaves nothing else on your Mac.

## For developers

- Swift and SwiftUI, built with Swift Package Manager (`Package.swift`), no Xcode project.
- Icon: the source is `Resources/AppIcon.svg`. After editing it, rebuild `Resources/AppIcon.icns` with `./make-icon.sh` (requires `brew install librsvg`).

## License

[MIT](LICENSE)
