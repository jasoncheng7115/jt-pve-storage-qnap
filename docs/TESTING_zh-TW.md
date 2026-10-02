# 已驗證與未驗證的項目

把資料放到這個 storage 之前，請先讀這一頁。

**目前只在一台 QNAP NAS 上測過**。那台 NAS 的韌體是 QuTS hero h6.0.1，結果是無法使用。它所針對的韌體則還沒有實機驗證過任何一項。0.x 系列的每一個版本都是預覽版，這一頁說明目前的實際狀況。相關專案（`jt-pve-storage-synology`、`-netapp`、`-purestorage`、`-dellemc`）是靠實際量測儲存設備、把實際行為記錄下來才穩定的，這個專案才剛開始這個過程。

## 具體來說

所有與 NAS 溝通的部分（登入驗證、iSCSI target 與 LUN、儲存集區、LUN 快照）都只依照 QTS 5.1 的 API 文件撰寫，還沒有任何一台受支援韌體的 NAS 回應過其中任何一個呼叫。

行為已知的地方，plugin 就照著做。行為未知的地方，程式碼刻意從嚴處理：寧可拒絕也不假設，所以猜錯時看到的是一句說明原因的訊息，而不是 NAS 回傳的一個負數。

這個 plugin 已經對模擬的 NAS 跑過完整的操作流程，模擬的 QTS 與 QuTS hero 各一次。這能檢查 plugin 是否符合本專案對 NAS 回應方式的理解，但無法檢查這份理解本身是否正確。

從相關專案移植過來的部分（multipath 處理、iSCSI node 管理、有時間上限的外部指令執行、WWID 追蹤）**已經**量測過，只是在別的儲存設備上。這些部分防範的是節點與核心的行為，不會因為儲存設備的廠牌而改變。

---

## 實機已經回答的部分

只有一次，使用 0.6.0 版，對象是一台 QuTS hero h6.0.1 的 NAS：

| | 結果 |
|---|---|
| 以 POST 送出的登入 | 接受 |
| `storage_v2` 與 `is_zfs` | 兩者都回報 `1` |
| `pve-qnap-api-probe` | 讀得到 portal、儲存集區、LUN 與 target |
| `pvesm add` 時建立 storage 的 iSCSI target | **被 NAS 拒絕** |
| 建立 LUN | **被 NAS 拒絕** |

所以 QuTS hero h6.0 以上不支援，從 0.6.1 開始，新增 storage 時 plugin 會直接拒絕。見 [SUPPORTED-QNAP-OS_zh-TW.md](SUPPORTED-QNAP-OS_zh-TW.md)。

這次執行沒有解決下面任何一個項目。沒有建立任何 LUN，所以沒有看到裝置、WWID 或 vendor 字串，而且那個韌體不在這個 plugin 的支援範圍內。

---

## 待驗證項目，依應該處理的順序

### 關鍵：答案與預期不同時必須修改設計

1. **`LUNNAA` 是否等於 `/sys/block/<sd>/device/wwid`**？plugin 靠比對這兩者來辨識每一個裝置。`LUNNAA` 是 32 個十六進位字元，核心回報的是 `naa.<相同字元>`。如果兩者不一致，這個 plugin 的所有功能都無法運作。確認方式：建立一個 LUN 並掛上，把 `pve-qnap-api-probe` 的輸出與 `cat /sys/block/sdX/device/wwid` 對照。

2. **QNAP LUN 回報的 SCSI vendor 與 product 是什麼**？multipath 設定檔比對的是 vendor `QNAP` 加上所有 product。如果 vendor 字串不同，這段設定不會生效，LUN 會改用 multipath 的通用預設值。通用預設值包含 `no_path_retry queue`，失去所有路徑時會變成無法終止的停滯。確認方式：`cat /sys/block/sdX/device/vendor`。

3. **`edit_lun` 能不能對已對應且使用中的 LUN 擴充容量**？`volume_resize` 依賴這件事。`edit_lun` 有 `LUNCapacity` 這個參數，但需不需要先取消對應、能不能在 guest 執行中進行，都還不知道。

4. **`add_lun` 的 `LUNCapacity` 是否接受小數**？plugin 把每個容量都進位到整數 GiB，因為目前只知道整數可行。如果小數可行，進位的單位可以更細。無條件進位不會出錯，只是多佔空間，所以這是改進而不是修正。

### 重要：決定某個操作是否安全

5. **`recover_snapshot` 帶 `by_lun=1` 時，比倒回目標更新的快照會保留嗎**？目前 `volume_rollback_is_possible` 允許倒回。如果 QTS 會捨棄較新的快照，PVE 就會在沒有任何提示的情況下，刪除管理者還看得到的快照。這時必須加上相關專案已有的拒絕機制。

6. **倒回之後，LUN 的 NAA 會維持不變嗎**？plugin 會檢查，一旦改變就明確拒絕，因為那代表每個節點上的裝置識別都變了。相關專案的任何儲存設備上都還沒有發生過這種情況。

7. **`authLogin.cgi` 是否接受 POST**？這個 plugin 的每一個呼叫都是 POST，憑證不會出現在 URL 裡。如果剛取得的工作階段在另一支 CGI 仍然不被承認，plugin 會判斷韌體沒有讀取 POST 內容，改用 GET 重送那一個呼叫，但只限不含密碼的呼叫。**登入絕不會用 GET 送出**，所以只讀取查詢字串的韌體完全無法使用。這是第一次上機最可能失敗的原因。在 QuTS hero h6.0.1 上，以 POST 送出的登入是被接受的。那個韌體不支援，所以對受支援的韌體來說，這個問題仍然沒有答案。

8. **同時執行**。`get_return` 是以 CGI 名稱而不是以工作為依據，所以同時進行的複製與倒回無法區分。因此 plugin 在同一台 NAS 上一次只執行一個，範圍是整個叢集：第一個還在執行時，第二個會被拒絕。需要確認 NAS 上有沒有別的來源（排程快照、網頁介面）也使用同一個管道。`get_return` 的 `cginame` 應該送什麼也還沒有實測：plugin 送的是 `snapshot.cgi`，如果 QTS 要的是別的寫法，複製或倒回就永遠拿不到結果。

9. **工作階段的有效時間**。`sid` 能維持多久還不知道。呼叫回報 `authPassed 0` 時，plugin 會重新登入一次。

10. **QTS 的網路存取保護**。plugin 會記住被拒絕的憑證，因為密碼錯誤加上每十秒一次的輪詢，會讓節點被 NAS 封鎖。門檻與封鎖時間是每台 NAS 各自的設定。有了這個機制，plugin 無論如何都只會失敗一次。

11. **登出是否真的結束工作階段**？plugin 每個操作各自登入，完成後登出，而每個節點每十秒輪詢一次。登出時 plugin 會送 `sid` 以及明確的 `logout=1`。如果 QTS 回應了登出卻沒有結束工作階段，每個節點每分鐘會留下六個。確認方式：把 storage 設定好放置十分鐘，到 NAS 上查看 plugin 帳號的連線數。答案必須來自 NAS，不能只看登出的回應。

12. **單一 target 能對應幾個 LUN？LUN 與 target 是否共用同一個上限**？預設的 `qnap-target-mode=shared` 會把這個 storage 的每顆磁碟都對應到同一個 target，所以那個 target 的上限就是這個 storage 的上限。NAS 會回報 LUN 總數與 target 總數的上限，但沒有「每個 target 幾個 LUN」的上限。Synology 的相關專案實測過單一 target 對應 200 個 LUN 沒有問題，但那不能代表 QTS。如果 QTS 的上限比較低，可以改用 `qnap-target-mode=per-volume`，代價是改受 target 總數的上限限制。QNAP 的使用手冊另外寫了 LUN 與 target **合計** 255，而 plugin 是分開檢查這兩個上限的，見 [LIMITS_zh-TW.md](LIMITS_zh-TW.md)。確認方式：對同一個 target 持續對應 LUN，直到 NAS 拒絕，記下當時的數量與 NAS 的回應。

13. **在 QTS 上倒回需要多久**？在 QTS 上，倒回需要的時間取決於 NAS 把磁碟寫回去要多久，各種容量實際需要多久還沒有量測過。plugin 最多等待 30 分鐘。如果 NAS 需要更久，plugin 會停止等待，並說明倒回**沒有**失敗：這時 guest 仍然是鎖定的，解除鎖定之前請先到 NAS 確認，因為在磁碟還沒寫完時啟動 guest，等於用還原到一半的磁碟開機。倒回執行期間，同一台 NAS 上的其他倒回與複製都會被拒絕。確認方式：在 QTS 上，倒回一顆已寫入 100 GB 的磁碟，記下 NAS 花了多久。

### 其他需要知道的事

14. **QTS 的 LUN 名稱允許哪些字元？最長多少**？plugin 只送出英文字母、數字、`-`、`.` 與 `_`，長度上限 64，其餘在送出之前就會拒絕。已知 `_` 是合法的，其餘是保守的推測。

15. **QTS 的快照名稱允許哪些字元**？處理方式相同。

16. **快照清單裡的 `create_time` 是 epoch 嗎**？只有在數值像是合理的 epoch 時，plugin 才會回報時間戳記，否則不回報。Proxmox VE 9 沒有任何地方會讀取這個值。

17. **`bTargetClusterEnable` 能不能讀回來**？`targetInfo` 不會回傳它，所以 plugin 在建立 target 時寫入，並在每次 `pvesm set` 時重新套用，不會在啟用磁碟的過程中寫入。如果有第二個節點無法登入某個 target，請執行 `pvesm set <storeid>` 重新套用。

---

## 第一次上機，依序執行

請在一台空的 NAS 上，或一個可以捨棄的儲存集區上進行。

```
# 1. 唯讀，不會建立任何東西。
pve-qnap-api-probe --host <nas> --user admin --insecure --node

# 2. 新增 storage。所有前置條件都在這一步檢查。
pvesm add qnapsan qnap1 \
    --qnap-portal <nas> --qnap-username admin --qnap-password <密碼> \
    --qnap-pool 1 --qnap-ssl-verify 0 \
    --qnap-chap-username pve --qnap-chap-password <CHAP 密碼> \
    --content images

# 3. 一顆磁碟。
pvesm alloc qnap1 9999 '' 1G
pvesm list qnap1

# 4. 掛上磁碟並確認裝置識別（上面的第 1 項）。
qm create 9999 --scsi0 qnap1:vm-9999-disk-0 --scsihw virtio-scsi-single
qm start 9999
multipath -ll
cat /sys/block/sdX/device/vendor   # 第 2 項

# 5. 快照、倒回，並確認資料確實回到快照時的內容。
qm snapshot 9999 s1
qm stop 9999
qm rollback 9999 s1

# 6. 擴充容量（第 3 項）。
qm resize 9999 scsi0 +1G

# 7. 範本與複製。在 QTS 上請加 --full 1：連結複製只在 QuTS hero 提供。
qm template 9999
qm clone 9999 9998

# 8. 清理，並確認 NAS 回到原本的狀態。
qm destroy 9998; qm destroy 9999
pvesm status
```

如果第 1 步成功，第 2 步卻出現登入錯誤，請先檢查第 7 項。

---

## 回報

請附上 `pve-qnap-api-probe --node` 的輸出、機型、韌體版本，以及是 QTS 還是 QuTS hero。plugin 的訊息都寫成可以直接引用的形式。如果某一句訊息不足以判斷下一步該做什麼，這件事本身就值得回報。
