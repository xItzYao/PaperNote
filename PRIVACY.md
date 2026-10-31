# PaperNote 隱私權政策 / Privacy Policy

最後更新：2026 年 10 月 31 日

## 中文

PaperNote 是一款 iPad 手寫筆記 App。我們非常重視你的隱私，以下說明 App 如何處理你的資料。

### 我們不收集任何資料
- PaperNote **沒有伺服器**，不會把你的筆記、使用紀錄或任何個人資訊傳送給開發者或第三方。
- App 內**沒有廣告、沒有分析或追蹤工具**。
- 你的筆記（筆跡、PDF、圖片、表格、備註）都只儲存在你自己的 iPad 上。

### 照片、翻譯與文字辨識
- **照片**：只有在你使用「插入圖片」或「存到照片」時，App 才會請求照片權限。照片只在 iPad 上讀取或儲存，不會上傳。
- **翻譯**：使用 Apple 系統內建的翻譯功能。翻譯語言包由 Apple 提供，翻譯在你的裝置上進行，App 不會把文字傳給開發者或其他第三方。
- **文字辨識**：掃描檔的文字辨識使用 Apple 的 Vision，在 iPad 上完成，不會上傳。

### Google Drive 備份（選用）
只有在你主動於 App 內按下「連結 Google Drive」並同意授權後，App 才會使用 Google Drive：

- App 只要求 `https://www.googleapis.com/auth/drive.file` 權限，**只能存取 App 自己建立的檔案**，看不到你 Google Drive 裡的其他任何檔案。
- App 會在你的 Google Drive 建立「PaperNoteBackup」資料夾，把你的筆記檔案備份到裡面，並在你要求還原時從中讀取。
- 備份資料直接在你的 iPad 與你自己的 Google Drive 之間傳輸，**不經過開發者的任何伺服器**，開發者也無法存取。
- 登入憑證（refresh token）只儲存在你 iPad 的鑰匙圈（Keychain）中。
- PaperNote 對 Google API 取得資料的使用與傳輸，遵守 [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy)，包含其中的 Limited Use 規定：資料只用於提供備份與還原功能，不會用於廣告、不會出售，也不會轉移給任何第三方。

### TestFlight 測試版
如果你透過 TestFlight 安裝測試版，Apple 會依 [TestFlight 的隱私權規範](https://www.apple.com/legal/privacy/data/zh-tw/testflight/) 提供開發者當機報告，以及你主動送出的截圖與意見回饋，用來修正問題。開發者不會把這些資料用在其他用途。

### 如何刪除資料或撤銷授權
- 在 App 的「雲端備份」頁按「中斷連結」，會刪除 iPad 上的登入憑證。
- 到 [Google 帳戶的第三方存取權限](https://myaccount.google.com/permissions) 移除 PaperNote，即可撤銷授權。
- 刪除 Google Drive 中的「PaperNoteBackup」資料夾即可刪除所有備份；刪除 App 即可刪除 iPad 上的所有資料。

### 聯絡方式
如有任何問題，請在 [GitHub Issues](https://github.com/xItzYao/PaperNote/issues) 提出。

---

## English

PaperNote is a handwriting note-taking app for iPad.

- **We do not collect any data.** PaperNote has no servers, no ads, and no analytics or tracking. Your notes are stored only on your own iPad.
- **Photos, translation and text recognition.** The app asks for photo access only when you insert a picture or save a screenshot; photos are read and saved on your iPad and never uploaded. Translation uses Apple's built-in translation on your device, and text recognition for scanned pages uses Apple's Vision on your iPad.
- **Google Drive backup (optional).** Only after you choose "Connect Google Drive" and grant permission, the app uses the `https://www.googleapis.com/auth/drive.file` scope, which only allows access to files the app itself creates. The app creates a "PaperNoteBackup" folder in your Google Drive to back up and restore your notes. Data is transferred directly between your iPad and your own Google Drive and never passes through any server operated by the developer. The sign-in credential is stored only in your iPad's Keychain.
- PaperNote's use and transfer of information received from Google APIs adheres to the [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy), including the Limited Use requirements. Data is used only to provide backup and restore, is never used for advertising, never sold, and never transferred to third parties.
- **TestFlight beta.** If you install a beta through TestFlight, Apple shares crash reports and any screenshots or feedback you choose to send with the developer, under [Apple's TestFlight privacy terms](https://www.apple.com/legal/privacy/data/en/testflight/). They are used only to fix problems.
- **Revoking access / deleting data.** Tap "Disconnect" on the Cloud Backup screen, remove PaperNote from your [Google Account third-party access](https://myaccount.google.com/permissions), delete the "PaperNoteBackup" folder from your Google Drive, and delete the app to remove all local data.
- **Contact:** please open an issue on [GitHub](https://github.com/xItzYao/PaperNote/issues).
