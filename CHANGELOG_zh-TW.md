# 變更記錄

0.x 全部都是預覽版本。**這個外掛還沒有在任何 QNAP NAS 上執行過。**

哪些事實已在實機上驗證、哪些沒有，記錄在 [docs/TESTING_zh-TW.md](docs/TESTING_zh-TW.md)。
要判斷某一版能不能信任，那份文件比這一份有用。

## [0.1.0] - 2026-10-01

第一個版本。已實作並通過單元測試，**但尚未在實機上跑過**。

### 新增

- **儲存類型 `qnapsan`。** 一顆虛擬機磁碟就是 QNAP NAS 上的一個精簡（thin）LUN，
  走 iSCSI，所以 NAS 自己的快照、複製與容量統計，作用的單位就是管理者心裡想的那個
  單位。沒有 LVM 層，也不會把一顆大 LUN 在本地切開。
- **Proxmox VE 會向儲存要求的每一種磁碟區操作**，虛擬機與容器都支援：配置、刪除、
  列表、擴充、快照、刪除快照、還原、範本、連結複製、完整複製、匯出與匯入、改名，
  以及節點間遷移。縮小磁碟會被明確拒絕。
- **QTS 與 QuTS hero。** 外掛會偵測面對的是哪一種。在 QuTS hero 上，連結複製與範本
  共用區塊，瞬間完成；在 QTS 上同一個操作是真的複製。回報舊版 Storage Manager 的
  韌體會在 `pvesm add` 當下被拒絕，訊息裡會寫出版本。
- **容量無條件進位到整數 GiB**，那是 NAS 配置的刻度；`volume_size_info` 回報的是
  NAS 上實際的大小，不是要求的大小。調整容量後的數字如果和要求的不同，會明講。
- **CHAP 與雙向 CHAP。** CHAP 是這個外掛所依賴的存取控制；只給帳號沒有密碼會被
  拒絕，不會寫入；沒設定 CHAP 就加入儲存會提出警告。
- **複製與還原會在整個叢集內排隊執行**，用的是 Proxmox VE 自己的儲存鎖，因為 NAS
  上同一時間只能有一個在進行。
- **LUN 數量上限是向 NAS 讀取的。** 一顆虛擬機磁碟就是一個 LUN，所以接近機型上限
  時外掛會提出警告，到達上限時拒絕配置，並明白說出增加空間沒有用。
- **憑證存放在 `/etc/pve/priv/storage/<id>.qnap`**，不會寫進 `storage.cfg`；每一個
  呼叫都是 POST，所以憑證不會出現在 URL 裡。登入被拒絕時只嘗試一次，之後在設定
  改變之前不再重試，所以密碼錯誤不會讓節點被 NAS 封鎖。
- **多重路徑。** 為 QNAP LUN 寫入設定檔，`no_path_retry` 一定是數字，絕不用
  `queue`。每一個裝置使用前都會與核心自己的 WWID 比對，而且一次只清除一個指名的
  map。
- **NAS 上已經有這個儲存前綴的 LUN 時，`pvesm add` 會提出警告** —— 否則另一個
  Proxmox VE 叢集在同一台 NAS 上用了相同的儲存名稱時，兩邊的磁碟名稱會完全重疊。
- **`pve-qnap-api-probe`**：唯讀工具，印出機型、韌體、是 QTS 還是 QuTS hero、LUN 與
  目標的數量上限、儲存池，以及節點裝了哪些工具。
- **`pve-qnap-reap`**：回報節點為已經用不到的 LUN 留著的 multipath map，加上
  `--remove` 才會清除。預設只報告。
- **英文與繁體中文文件**：[docs/TESTING_zh-TW.md](docs/TESTING_zh-TW.md)（全部
  十六項待驗證事項與第一次上機的步驟）、
  [docs/SUPPORTED-QNAP-OS_zh-TW.md](docs/SUPPORTED-QNAP-OS_zh-TW.md)、
  [docs/QNAP-ACCOUNT_zh-TW.md](docs/QNAP-ACCOUNT_zh-TW.md)。
- **196 個單元測試與建置檢查**：不得有節點層級的 multipath 清除、URL 裡不得有
  憑證、外部指令一律經過工具路徑解析、每一個呼叫的函式都必須存在，以及 `t/07-api-scope.t` —— 它列出外掛呼叫的每一個 QNAP API，原始碼只要
  多出一個不在清單上的呼叫，測試就會失敗。

### 尚未驗證

- **所有與 NAS 溝通的部分。** 有三個問題必須先在實機上得到答案：NAS 回報的
  `LUNNAA` 是否等於核心的 WWID、QNAP LUN 回報的 SCSI vendor 字串是什麼、
  `authLogin.cgi` 收不收 POST。任何一題答錯都是要改設計，不是修個 bug。
- 面向節點的那一半 —— multipath 處理、iSCSI node 管理、有界限的外部指令執行、WWID
  追蹤 —— 是從相關專案移植過來的，在別的陣列上實測過。
