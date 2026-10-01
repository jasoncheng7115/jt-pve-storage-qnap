# 這個 plugin 使用的 NAS 帳號

## 必須是管理員帳號

這一點沒有替代做法，所以先說明清楚。

這個 plugin 呼叫的 CGI（`iscsi_lun_setting.cgi`、`iscsi_target_setting.cgi`、`iscsi_portal_setting.cgi`、`disk_manage.cgi`、`snapshot.cgi`）在 QTS 裡只有管理員可以使用。一般使用者，或是只在某個共用資料夾上取得授權的使用者，可以正常登入，但上面每一個呼叫都會被拒絕。

所以**必須是 `administrators` 群組裡的帳號**。

## 請不要使用 `admin`

請另外建立**第二個**管理員帳號，專門給這個用途：

* 需要時可以停用它，不會讓所有人都無法登入 NAS。
* 從 NAS 自己的記錄就能分辨哪些動作是 Proxmox VE 執行的。
* `admin` 是所有人都知道的帳號名稱，也是暴力破解最先嘗試的對象。

請在「控制台 → 權限 → 使用者」建立，並加入 `administrators` 群組。

```
使用者名稱   pve
群組         administrators
密碼         長度足夠，而且不在其他地方重複使用
```

## 兩步驟驗證：這個帳號請**停用**

這個 plugin 只用帳號與密碼登入，沒有實作兩步驟驗證。啟用了兩步驟驗證的帳號，這個 plugin 無法使用。

所以這個帳號應該有專屬的名稱與一組專屬的長密碼，而由人員使用的帳號請繼續啟用兩步驟驗證。

## 密碼存放的位置

**不在 `/etc/pve/storage.cfg` 裡**。那個檔案的權限是 `root:www-data 0640`，而且 PVE 不知道是機密的欄位，會透過 `GET /storage/<id>` 回傳給任何具有 `Datastore.Audit` 權限的使用者。只有唯讀稽核權限的人，就會拿到 NAS 的管理員憑證。

這個 plugin 把 `qnap-password`、`qnap-chap-password` 與 `qnap-mutual-chap-password` 宣告為機密欄位，所以 PVE 會把它們從設定檔移除，改交給 plugin 處理。它們會被寫入：

```
/etc/pve/priv/storage/<storeid>.qnap     只有 root 能讀取，並且會同步到每個節點
```

如果是從把密碼存在 `storage.cfg` 的舊版本升級，plugin 仍然會從那裡讀取，所以不會無法運作。plugin 會提醒一次，並附上搬移的指令：

```
pvesm set <storeid> --qnap-password <密碼>
```

## 請使用 HTTPS

`qnap-scheme` 預設是 `https`，連接埠 443。使用 `http` 時，密碼與 CHAP 密碼在**每一次**呼叫都不會加密，而 `status()` 在每個節點上每十秒就會執行一次。設成 `http` 時，plugin 會針對每個 storage 提醒一次。

QTS 出廠時使用自簽憑證，所以 `qnap-ssl-verify` 預設是停用的。如果已經在 NAS 上安裝了正式憑證，請啟用驗證：

```
pvesm set <storeid> --qnap-ssl-verify 1
```

## CHAP 是這個 plugin 的存取控制

**這個 plugin 不會在 target 上設定針對個別主機的存取清單**。它只在 target 的預設原則上設定 CHAP，不做更細的限制。如果還想把 LUN 限制給特定主機，請在 QNAP 網頁介面裡設定。

所以誰能掛上這些磁碟，是由 CHAP 決定的。請設定它：

```
pvesm set <storeid> --qnap-chap-username pve --qnap-chap-password <密碼>
```

帳號與密碼一定要一起設定。只有帳號沒有密碼時，會寫入一組**空的** CHAP 密碼，看起來已經啟用，實際上沒有任何保護。plugin 會拒絕這樣的設定。

雙向 CHAP 是讓 NAS 向節點驗證自己，可以防止節點連到假冒的 target。它需要同時啟用單向 CHAP：

```
pvesm set <storeid> \
    --qnap-chap-username pve --qnap-chap-password <密碼> \
    --qnap-mutual-chap-username nas --qnap-mutual-chap-password <另一組密碼>
```

## 密碼錯誤時只會嘗試一次

QTS 會在數次登入失敗之後封鎖來源位址。Proxmox VE 的每個節點每十秒都會輪詢每一個 storage，所以密碼錯誤時，不到一分鐘就會達到門檻。之後的症狀是連線被拒絕，看起來像 NAS 故障，而不像密碼錯誤。

所以 plugin 會記住被拒絕的憑證：只嘗試一次，記錄在 `/run/jt-pve-storage-qnap/` 底下，在 storage 的設定改變之前不再嘗試。對該 storage 執行任何一次 `pvesm set`，就會解除這個狀態。

如果看到：

```
storage 'qnap1': not retrying after the NAS did not accept the account...
```

請修正憑證，然後執行 `pvesm set qnap1 --qnap-password <密碼>`。
