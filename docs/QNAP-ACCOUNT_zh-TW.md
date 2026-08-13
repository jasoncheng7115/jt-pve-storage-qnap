# 這個外掛使用的 NAS 帳號

## 必須是管理員帳號

這件事沒有變通做法，而且值得明說，不該讓管理者自己去撞。

這個外掛呼叫的 CGI —— `iscsi_lun_setting.cgi`、`iscsi_target_setting.cgi`、`iscsi_portal_setting.cgi`、`disk_manage.cgi`、`snapshot.cgi` —— 在 QTS 裡都是管理員專用。一般使用者，或是只在某個共用資料夾上被授權的使用者，登入會完全成功，然後上面每一個呼叫都被拒絕。

所以：**必須是 `administrators` 群組裡的帳號。**

## 不要用 `admin`

請另外建立**第二個**管理員帳號，專門給這件事用：

* 需要時可以停用它，而不會把所有人鎖在 NAS 外面；
* NAS 自己的記錄就能分辨哪些動作是 Proxmox VE 做的；
* `admin` 是 QTS 的暴力破解防護、以及網路上每一支掃描器都已經知道名字的那個帳號。

在「控制台 → 權限 → 使用者」建立，並加入 *administrators*。

```
使用者名稱   pve
群組         administrators
密碼         夠長，而且不重複用在別的地方
```

## 兩步驟驗證：這個帳號請**關閉**

這個外掛只用帳號與密碼登入，沒有實作兩步驟驗證。啟用了兩步驟驗證的帳號，這個外掛沒辦法使用。

這正是應該給這個帳號一個專屬名稱與一組專屬長密碼，並讓「人用」的帳號繼續保持啟用 2FA 的理由。

## 密碼放在哪裡

**不在 `/etc/pve/storage.cfg` 裡。** 那個檔案的權限是 `root:www-data 0640`，而且 PVE 會把它不知道是機密的欄位，透過 `GET /storage/<id>` 回傳給任何具有 `Datastore.Audit` 權限的使用者 —— 一個唯讀稽核者就會拿到你 NAS 的管理員憑證。

這個外掛把 `qnap-password`、`qnap-chap-password` 與 `qnap-mutual-chap-password` 宣告為 sensitive，所以 PVE 會把它們從設定檔剝除，改交給外掛的 hook 處理。它們會被寫到：

```
/etc/pve/priv/storage/<storeid>.qnap     只有 root 能讀，且會同步到每個節點
```

如果你是從把密碼存在 `storage.cfg` 的舊版本升級上來，外掛還是會從那裡讀，所以不會壞掉 —— 而且它會提醒一次，並附上搬移的指令：

```
pvesm set <storeid> --qnap-password <密碼>
```

## 請使用 HTTPS

`qnap-scheme` 預設是 `https`，連接埠 443。用 `http` 的話，密碼與任何 CHAP 密碼會在**每一次**呼叫時以明文傳輸，而 `status()` 每個節點每十秒就會跑一次。設成 `http` 時，外掛會針對每個儲存提醒一次。

QTS 出廠是自簽憑證，所以 `qnap-ssl-verify` 預設關閉 —— 一個沒有人能用的預設值，保護不了任何人。如果你已經在 NAS 上安裝了正式憑證，請打開驗證：

```
pvesm set <storeid> --qnap-ssl-verify 1
```

## CHAP 不是「可有可無」，只是看起來像

**這個外掛不會在目標上設定針對個別主機的存取清單。** 它只在目標的預設原則上設定 CHAP，不做更細的限制。如果還想把 LUN 限制給特定主機，請在 QNAP 網頁介面裡設定。

所以誰能掛載這些磁碟，是由 CHAP 決定的。請設定它：

```
pvesm set <storeid> --qnap-chap-username pve --qnap-chap-password <密碼>
```

兩個一定要一起設。只有帳號沒有密碼的話，會寫入一組**空的** CHAP 密碼 —— 一種「自稱已啟用、實際不保護任何東西」的存取控制 —— 外掛寧可拒絕也不會這樣做。

雙向 CHAP 是讓 NAS 對節點驗證自己，也就是防止節點被指向假冒目標的那一半。它需要一併啟用單向 CHAP：

```
pvesm set <storeid> \
    --qnap-chap-username pve --qnap-chap-password <密碼> \
    --qnap-mutual-chap-username nas --qnap-mutual-chap-password <另一組密碼>
```

## 密碼錯誤只會把節點鎖出去一次

QTS 會在數次登入失敗後封鎖來源位址。Proxmox VE 每十秒、每個節點都會輪詢每一個儲存，所以密碼錯誤不用一分鐘就會達到門檻 —— 而之後的症狀是連線被拒，看起來像 NAS 掛了，而不是密碼錯了。

因此外掛會把被拒絕的憑證**閂鎖**起來：只嘗試一次，記錄在 `/run/jt-pve-storage-qnap/` 底下，在儲存設定改變之前不再嘗試。任何一次對該儲存的 `pvesm set` 都會解除閂鎖。

如果你看到：

```
storage 'qnap1': not retrying after the NAS did not accept the account...
```

請修正憑證，然後執行 `pvesm set qnap1 --qnap-password <密碼>`。
