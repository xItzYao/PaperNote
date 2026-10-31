# PaperNote

[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-支持這個%20App-FFDD00?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/happytw)

一款給 iPad 用的手寫筆記 App，靈感來自 GoodNotes，補上了我自己做筆記時最需要、但 GoodNotes 不夠好用的功能。

> 本專案與 GoodNotes 沒有任何關係。

## 主要功能

**書寫**
- Apple Pencil 書寫（PencilKit），筆、螢光筆分開管理，可以自訂常用顏色的數量與順序
- 筆有細、中、粗（可自訂 pt）與虛線；螢光筆畫得接近直線時自動拉直
- 畫線時筆尖停住約 0.5 秒會變直線，繼續移動可以調整終點；圓、三角形、四邊形自動修正，還沒放開前可以拖曳調整長寬
- 螢光筆畫在 PDF 文字上會自動對齊、放在文字底下，不會把字蓋暗
- Apple Pencil 筆身點兩下切換橡皮擦，筆尖旁會出現調色盤圖示，點一下打開調色盤（Pencil Pro 捏一下直接打開）：按住「筆／螢光筆」展開顏色，滑過去放開就選好
- 橡皮擦也能擦掉螢光標示
- 手掌防誤觸，可以設定右手或左手；關閉「用手指書寫」時，手指只會捲動頁面

**PDF**
- 匯入 PDF，選取文字後用系統翻譯（自動偵測語言）、拷貝、查詢、螢光標示
- 掃描檔沒有文字層時，自動用 iPad 內建的文字辨識
- 任一頁可以往上下左右擴展空白畫布（拖曳四周 8 個控制點），原本內容不動

**截圖與貼圖**
- 獨立的截圖工具（矩形／自由形狀），可以釘選在畫面上、拷貝、翻譯圖中文字
- 釘選的圖片像 Snipaste 一樣浮在最上層，可以設定跨分頁顯示或只在某本筆記本顯示

**表格**
- 插入表格或手繪新表格；在既有表格上畫線可以切開儲存格、加斜線
- 合併／分割儲存格（自訂 N 欄 × M 列）、底色、格線樣式、平均分配欄寬列高
- 表格、圖片可以鎖定位置；橡皮擦不會擦到表格

**電路圖（電機系用）**
- 電阻、電容、電感、電壓源、電流源、接地、VDD、NMOS、PMOS、各種邏輯閘（輸入數量可調）
- 照著想要的路線畫導線，自動排成直角並吸附接腳；可以從導線中間接出去
- 三條以上接在一起自動打點，沒接在一起的交叉畫成跨線半圓
- 元件可以旋轉、水平／垂直翻轉；導線可以拖曳頭尾、轉角、整段調整；一律對齊格點

**整理**
- 資料夾管理：重新命名、複製、移動、刪除、多選、拖曳進資料夾
- 垃圾桶：刪除的筆記本、資料夾、頁面保留 30 天，可以還原
- 大圖／詳細資料兩種檢視，可依名稱、修改日期、建立日期排序
- 多分頁同時開啟，分頁可以組成群組（拖曳分頁到另一個分頁上就會組成群組）
- 我的最愛頁面＋備註，可以在資料庫搜尋所有備註
- 自訂套索：可以圈選筆跡、表格、圖片、文字框、螢光標示一起移動、拷貝、刪除

**備份**
- Google Drive 自動備份到「PaperNoteBackup」資料夾（每 10 分鐘＋關閉筆記本後），保留可編輯的原始檔
- 筆記也都在 iPad「檔案」App 的「我的 iPad → PaperNote」裡，可以自己備份

## 系統需求

- iPad，iPadOS 18 以上
- 一台 Windows 或 Mac 電腦（用來安裝）
- 一個 Apple ID（免費的就可以）

## 安裝教學（Sideloadly）

PaperNote 沒有上架 App Store，需要用 [Sideloadly](https://sideloadly.io) 自行安裝。

### 1. 下載 App

到本專案的 [Releases](../../releases) 頁面，下載最新版的 `PaperNote.ipa`。

### 2. 準備電腦

1. 安裝 [Sideloadly](https://sideloadly.io)。
2. **Windows** 還需要安裝 Apple 官網版的 **iTunes** 和 **iCloud**（Sideloadly 下載頁有連結）。
   **不要用 Microsoft Store 的版本**；如果已經裝了，請先解除安裝。
3. 用傳輸線把 iPad 接上電腦，iPad 解鎖後按「**信任這部電腦**」。

### 3. 安裝

1. 打開 Sideloadly，把 `PaperNote.ipa` 拖到左上角的 IPA 圖示。
2. 「iDevice」選你的 iPad。
3. 「Apple account」輸入你的 Apple ID（建議可以另外申請一個 Apple ID 專門用來安裝）。
4. 按 **Start**，輸入 Apple ID 密碼（有雙重認證的話輸入驗證碼），等出現 **Done**。

### 4. iPad 設定（只有第一次需要）

1. **設定 → 隱私權與安全性 → 開發者模式** → 打開，iPad 會重新開機，重開後選「開啟」。
2. **設定 → 一般 → VPN 與裝置管理** → 點你的 Apple ID → **信任**。
3. 回到主畫面打開 PaperNote。

### 注意事項

- 免費 Apple ID 安裝的 App **每 7 天要用 Sideloadly 重新安裝一次**，否則會打不開（資料不會消失）。
- **更新或重新安裝時，直接安裝覆蓋即可，不要先刪除 App**，刪除 App 會連筆記一起刪除。
- 每次都用同一個 Apple ID、不要更改 Bundle ID，才會沿用原本的筆記。

## Google Drive 備份（選用）

1. 在 App 的資料庫右上角「⋯」→「**雲端備份**」。
2. 按「**連結 Google Drive**」，選擇你的 Google 帳號 →「**允許**」。
   如果出現「Google 尚未驗證這個應用程式」，點「進階 → 前往 PaperNote」即可。
3. 完成。App 會在你的 Google Drive 建立「PaperNoteBackup」資料夾，每 10 分鐘以及關閉筆記本後自動備份；
   換新 iPad 時，在同一頁按「從 Google Drive 還原」即可。

App 只使用 `drive.file` 權限，**只能存取它自己建立的檔案**，看不到你雲端硬碟裡的其他東西；
備份直接在你的 iPad 和你的 Google Drive 之間傳輸，不經過任何第三方伺服器。詳見[隱私權政策](PRIVACY.md)。

## 自己編譯

不需要 Mac 也能編譯：

1. Fork 這個 repo。
2. 推送到 `main` 分支後，GitHub Actions（macOS runner）會自動用 XcodeGen 產生專案並編譯。
3. 在 Actions 頁面的執行結果下載 `PaperNote-ipa`，用 Sideloadly 安裝。

有 Mac 的話：

```bash
brew install xcodegen
xcodegen generate
open PaperNote.xcodeproj
```

## 隱私

- 所有筆記都存在 iPad 本機，不會上傳到任何伺服器。
- 只有在你自己連結 Google Drive 後，才會把筆記檔上傳到**你自己的** Google Drive。
- 完整說明請見[隱私權政策](PRIVACY.md)。

## 授權

本專案以 [GNU General Public License v3.0](LICENSE)（GPL-3.0）授權。

- 你可以自由使用、修改、再散布這份程式碼。
- 如果你發布修改過的版本，也必須以 GPL-3.0 公開原始碼，並保留原本的版權與授權聲明。
- 本軟體不提供任何保證，詳見 [LICENSE](LICENSE)。

歡迎回報問題或送 Pull Request 一起改進。

## 支持

如果這個 App 對你有幫助，歡迎[請我喝杯咖啡](https://buymeacoffee.com/happytw) ☕
