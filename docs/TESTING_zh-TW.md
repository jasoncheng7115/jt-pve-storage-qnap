# 已驗證與未驗證的項目

把資料放上這個儲存之前，請先讀這一頁。

**這個外掛還沒有在任何 QNAP NAS 上執行過。** 0.x 系列的每一個版本都是預覽版，而這一頁就是對這件事誠實的交代。這個家族的其他專案（`jt-pve-storage-synology`、`-netapp`、`-purestorage`、`-dellemc`）是靠實際量測陣列、把它真正的行為寫下來才穩定的；這個專案才剛開始那個過程。

## 具體來說是什麼意思

所有與陣列溝通的部分，都只依 QTS 5.1 的 API 文件撰寫 —— 涵蓋登入驗證、iSCSI 目標與 LUN、儲存池，以及 LUN 快照 —— 還沒有任何一台 NAS 回應過其中任何一個呼叫。

行為已知的地方，外掛就照著做。行為未知的地方，程式碼刻意選擇嚴格 —— 寧可拒絕也不假設，讓猜錯時看到的是一句說明原因的訊息，而不是 NAS 回來的一個負數。

從其他專案移植過來的部分 —— multipath 處理、iSCSI node 管理、有界限的外部指令執行、WWID 追蹤 —— **是**經過實測的，只是在別的陣列上。它們防的是節點與核心的行為，那不會因為儲存廠牌而改變。

---

## 待驗證項目，依應該處理的順序

### 阻斷性 —— 答案不同就要改設計

1. **`LUNNAA` 是否等於 `/sys/block/<sd>/device/wwid`？**
   外掛靠比對這兩者來辨識每一個裝置。`LUNNAA` 是 32 個十六進位字元，核心回報的是 `naa.<相同字元>`；如果兩者對不起來，這個外掛沒有一件事會正常運作。
   *怎麼確認：* 建立一個 LUN、掛上去，把 `pve-qnap-api-probe` 的輸出與 `cat /sys/block/sdX/device/wwid` 對照。

2. **QNAP LUN 回報的 SCSI vendor 與 product 是什麼？**
   multipath 設定檔比對的是 vendor `QNAP` 加上所有 product。如果 vendor 字串不同，這段設定就不會生效，LUN 會落回 multipath 的通用預設值 —— 那包含 `no_path_retry queue`，也就是失去所有路徑時會變成殺不掉的當機。
   *怎麼確認：* `cat /sys/block/sdX/device/vendor`。

3. **`edit_lun` 能不能對「已掛載且使用中」的 LUN 擴容？**
   `volume_resize` 依賴這件事。`edit_lun` 有 `LUNCapacity` 這個參數；需不需要先取消對應、能不能容忍運行中的客體，都還不知道。

4. **`add_lun` 的 `LUNCapacity` 接不接受小數？**
   外掛把每個容量都進位到整數 GiB，因為目前只知道整數可行。如果小數可行，這個進位可以更細 —— 但無條件進位永遠不會錯，只是浪費，所以這是改進而不是修正。

### 重要 —— 決定某個操作安不安全

5. **`recover_snapshot` 帶 `by_lun=1` 時，比被還原的那個更新的快照會保留嗎？**
   目前 `volume_rollback_is_possible` 允許還原。如果 QTS 會把更新的快照丟掉，PVE 就會默默刪掉管理者還看得到的快照，那麼其他專案帶的那道拒絕就必須加進來。

6. **LUN 的 NAA 在還原之後會不變嗎？**
   外掛有檢查，一旦改變就大聲拒絕，因為那代表裝置身分在每個節點底下都移動了。這個家族的任何陣列上都還沒見過這種事。

7. **`authLogin.cgi` 收不收 POST？**
   這個外掛的每一個呼叫都是 POST，這樣憑證就不會出現在 URL 裡。不帶機密的呼叫在韌體忽略 POST 內容時會自動退回 GET；**登入不會**，所以只讀查詢字串的韌體完全無法使用。這是第一次上機失敗最可能的原因。

8. **併發。**
   `get_return` 的 key 是 CGI 名稱而不是 job，所以同時進行的複製與還原無法區分。外掛用 PVE 的叢集儲存鎖把兩者序列化。值得確認的是：NAS 上有沒有別的東西 —— 排程快照工作、網頁介面 —— 也共用那個管道。`get_return` 的 `cginame` 該送什麼也還沒實測：外掛送的是 `snapshot.cgi`，如果 QTS 要的是別的寫法，複製或還原就永遠拿不到結果。

9. **工作階段有效期。**
   `sid` 能撐多久還不知道。外掛在呼叫回報 `authPassed 0` 時會重新登入一次。

10. **QTS 的網路存取保護。**
    憑證閂鎖之所以存在，是因為密碼錯誤配上十秒一次的輪詢會把節點鎖在 NAS 外面。門檻與封鎖時間是每台 NAS 各自的設定；有了閂鎖，外掛不論如何都只會失敗嘗試一次。

11. **登出真的會結束工作階段嗎？**
    外掛每個操作各自登入、做完就登出，而每個節點每十秒輪詢一次。登出時外掛會送 `sid` 以及明確的 `logout=1`。如果 QTS 回應了登出卻沒有真的結束工作階段，每個節點每分鐘就會漏掉六個 —— 另一個專案就是這樣把陣列的工作階段表塞滿的，而當時每一次登出都回報成功。
    *怎麼確認：* 把儲存掛著放十分鐘，到 NAS 上數外掛帳號的連線數。答案要從 NAS 來，不能看登出自己的回應。

12. **單一目標能掛幾個 LUN？**
    預設的 `qnap-target-mode=shared` 會把這個儲存的每顆磁碟都對應到同一個目標，所以那個目標的上限就是這個儲存的上限。NAS 會回報 LUN 總數與目標總數的上限，但沒有「每個目標幾個 LUN」的上限。Synology 那個專案實測過單一目標掛 200 個沒有問題，但那不能代表 QTS。如果 QTS 的上限比較低，可以改用 `qnap-target-mode=per-volume`，代價是換成受目標總數的上限限制。

### 值得知道

13. **QTS 的 LUN 名稱允許哪些字元、最長多少？**
    外掛只送出英文字母、數字、`-`、`.` 與 `_`，長度上限 64，其餘在送出前就拒絕。已知 `_` 是合法的；其餘是保守的推測。

14. **QTS 的快照名稱允許哪些字元？** 同樣的處理方式。

15. **快照清單裡的 `create_time` 是 epoch 嗎？**
    只有在數值看起來像合理的 epoch 時，外掛才會回報時間戳，否則不回報。Proxmox VE 9 沒有任何地方會讀這個值。

16. **`bTargetClusterEnable` 能不能讀回來？**
    `targetInfo` 不會回傳它，所以外掛在建立目標時寫入、並在每次 `pvesm set` 時重新套用，而不在啟用路徑上寫。如果有第二個節點無法登入某個目標，請執行 `pvesm set <storeid>` 重新套用。

---

## 第一次上機，依序執行

請在一台空的 NAS 上、或一個你願意失去的儲存池上做這件事。

```
# 1. 唯讀，不會建立任何東西。
pve-qnap-api-probe --host <nas> --user admin --insecure --node

# 2. 加入儲存。所有前置條件都在這一步檢查。
pvesm add qnapsan qnap1 \
    --qnap-portal <nas> --qnap-username admin --qnap-password <密碼> \
    --qnap-pool 1 --qnap-ssl-verify 0 \
    --qnap-chap-username pve --qnap-chap-password <CHAP 密碼> \
    --content images

# 3. 一顆磁碟。
pvesm alloc qnap1 9999 '' 1G
pvesm list qnap1

# 4. 掛上去，確認身分 —— 也就是上面的第 1 項。
qm create 9999 --scsi0 qnap1:vm-9999-disk-0 --scsihw virtio-scsi-single
qm start 9999
multipath -ll
cat /sys/block/sdX/device/vendor   # 第 2 項

# 5. 快照、還原，並確認資料真的回去了。
qm snapshot 9999 s1
qm stop 9999
qm rollback 9999 s1

# 6. 擴容 —— 第 3 項。
qm resize 9999 scsi0 +1G

# 7. 範本與連結複製。
qm template 9999
qm clone 9999 9998

# 8. 清理，並確認 NAS 回到原本的狀態。
qm destroy 9998; qm destroy 9999
pvesm status
```

如果第 1 步成功、第 2 步卻出現登入錯誤，第一個該懷疑的是第 7 項。

---

## 回報

請附上 `pve-qnap-api-probe --node` 的輸出、機型、韌體版本，以及是 QTS 還是 QuTS hero。外掛的訊息都是寫成可以直接引用的形式 —— 如果哪一句訊息不足以讓你知道下一步要做什麼，那件事本身就是一個值得回報的缺陷。
