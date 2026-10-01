# 變更記錄

0.x 全部都是預覽版本。**這個 plugin 還沒有在任何 QNAP NAS 上執行過**。

哪些項目已經在實機上驗證、哪些還沒有，記錄在 [docs/TESTING_zh-TW.md](docs/TESTING_zh-TW.md)。要判斷某一版能不能採用，那份文件比這一份有用。

## [0.6.0] - 2026-10-01

### 修正

- **新增帶有 CHAP 的 storage 會被拒絕**。`pvesm add` 同時帶 `qnap-chap-username` 與 `qnap-chap-password` 時，會回報「沒有 CHAP 密碼」。密碼要等所有檢查都通過之後才會寫入憑證儲存區，而建立 target 時讀取的卻是儲存區裡的值，當時還不存在。現在建立 target 時使用的是剛才輸入的密碼。沒有設定 CHAP 的 storage 不受影響。
- **韌體正常讀取 POST 內容時，plugin 仍然送出 GET**。為了因應忽略 POST 內容的韌體，plugin 有一個改用 GET 的機制，但它在任何沒有 `<result>` 的回應之後都會啟動，而有兩種正常的回應本來就沒有 `<result>`。所以這兩種回應之後都會多送一個 GET，工作階段的 `sid` 會出現在 URL 上。現在只有剛取得的工作階段仍然不被承認時才會改用 GET，而且含有密碼的呼叫絕不會改用 GET。
- **有複製磁碟依賴的快照**。在 QuTS hero 上，如果有磁碟是從某個快照複製出來的，那個快照在該磁碟存在期間無法刪除。現在被拒絕時，訊息會引用 NAS 的回應，並說明可能的原因。

### 新增

- **[docs/LIMITS_zh-TW.md](docs/LIMITS_zh-TW.md)**：QNAP 公布的 LUN、target 與快照數量上限，每個數字都附出處，並說明一台 NAS 可以放幾顆虛擬磁碟。
- **文件網站會依瀏覽器的語言顯示**。網址帶有 `?lang=zh` 或 `?lang=en` 時仍以網址為準。沒有帶的時候，瀏覽器設定為中文就顯示中文頁面。
- **模擬的 NAS**。plugin 已經對模擬的 QTS 與模擬的 QuTS hero 跑過新增 storage、配置、快照、複製、倒回、擴充、範本、連結複製、改名、刪除與移除 storage。模擬的 NAS 會拒絕預期中 NAS 應該拒絕的操作。上面兩個問題就是這樣發現的。這不能取代實機測試。
- 針對上述修正新增 11 個單元測試，合計 207 個。

### 變更

- **訊息不再使用破折號**。操作與失敗原因之間現在以冒號分隔。有依訊息文字做比對的程式需要一併調整。
- plugin 寫入的 multipath 設定檔，註解也做了同樣的修改，所以內容與 0.1.0 不同。有 `qnapsan` storage 的節點會在下一次啟用時重寫這個檔案，並重新載入 multipathd 一次。

## [0.1.0] - 2026-10-01

第一個版本。已實作並通過單元測試，**但尚未在實機上執行過**。

### 新增

- **storage 類型 `qnapsan`**。一顆虛擬機磁碟就是 QNAP NAS 上的一個 thin LUN，透過 iSCSI 連接，所以 NAS 自己的快照、複製與容量統計，作用的單位就是管理者實際管理的單位。沒有 LVM 層，也不會把一顆大型 LUN 在本機切割。
- **Proxmox VE 會向 storage 要求的每一種磁碟操作**，虛擬機與容器都支援：配置、刪除、列表、擴充、快照、刪除快照、倒回、範本、連結複製、完整複製、匯出與匯入、改名，以及節點間遷移。縮小磁碟會被明確拒絕。
- **QTS 與 QuTS hero**。plugin 會偵測連接的是哪一種。在 QuTS hero 上，連結複製與範本共用區塊，會立即完成。在 QTS 上，同一個操作會實際複製資料。回報舊版 Storage Manager 的韌體會在 `pvesm add` 時被拒絕，訊息裡會寫出版本。
- **容量無條件進位到整數 GiB**，這是 NAS 配置的單位。`volume_size_info` 回報的是 NAS 上實際的大小，不是要求的大小。調整容量之後的數字如果與要求的不同，會明確告知。
- **CHAP 與雙向 CHAP**。CHAP 是這個 plugin 所依賴的存取控制。只有帳號沒有密碼會被拒絕，不會寫入。沒有設定 CHAP 就新增 storage 會提出警告。
- **複製與倒回會在整個叢集內依序執行**，使用的是 Proxmox VE 自己的 storage 鎖，因為 NAS 上同一時間只能進行一個。
- **LUN 數量上限是向 NAS 讀取的**。一顆虛擬機磁碟就是一個 LUN，所以接近上限時 plugin 會提出警告，到達上限時拒絕配置，並說明增加空間沒有幫助。
- **憑證存放在 `/etc/pve/priv/storage/<id>.qnap`**，不會寫入 `storage.cfg`。每一個呼叫都是 POST，所以憑證不會出現在 URL 裡。登入被拒絕時只嘗試一次，在設定改變之前不再重試，所以密碼錯誤不會讓節點被 NAS 封鎖。
- **多重路徑**。為 QNAP LUN 寫入設定檔，`no_path_retry` 一定是數字，不使用 `queue`。每一個裝置在使用之前都會與核心回報的 WWID 比對，而且一次只清除一個指定的 map。
- **NAS 上已經有這個 storage 前綴的 LUN 時，`pvesm add` 會提出警告**。如果另一個 Proxmox VE 叢集在同一台 NAS 上用了相同的 storage 名稱，兩邊的磁碟名稱會完全重疊。
- **`pve-qnap-api-probe`**：唯讀工具，印出機型、韌體、是 QTS 還是 QuTS hero、LUN 與 target 的數量上限、儲存池，以及節點安裝了哪些工具。
- **`pve-qnap-reap`**：回報節點為已經用不到的 LUN 保留的 multipath map，加上 `--remove` 才會清除。預設只回報。
- **英文與繁體中文文件**：[docs/TESTING_zh-TW.md](docs/TESTING_zh-TW.md)（全部十六項待驗證事項與第一次上機的步驟）、[docs/SUPPORTED-QNAP-OS_zh-TW.md](docs/SUPPORTED-QNAP-OS_zh-TW.md)、[docs/QNAP-ACCOUNT_zh-TW.md](docs/QNAP-ACCOUNT_zh-TW.md)。
- **196 個單元測試與建置檢查**：不得有節點層級的 multipath 清除、URL 裡不得有憑證、外部指令一律經過工具路徑解析、每一個呼叫的函式都必須存在，以及 `t/07-api-scope.t`。它列出 plugin 呼叫的每一個 QNAP API，原始碼只要多出一個不在清單上的呼叫，測試就會失敗。

### 尚未驗證

- **所有與 NAS 溝通的部分**。有三個問題必須先在實機上得到答案：NAS 回報的 `LUNNAA` 是否等於核心的 WWID、QNAP LUN 回報的 SCSI vendor 字串是什麼、`authLogin.cgi` 是否接受 POST。任何一題的答案與預期不同，要改的都是設計，不是修一個 bug。
- 面向節點的部分（multipath 處理、iSCSI node 管理、有時間上限的外部指令執行、WWID 追蹤）是從相關專案移植過來的，已經在別的儲存設備上量測過。
