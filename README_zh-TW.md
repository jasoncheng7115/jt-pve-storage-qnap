# jt-pve-storage-qnap

**讓 Proxmox VE 直接以 QNAP NAS（iSCSI）作為虛擬機的儲存後端。**

每一顆 Proxmox VE 虛擬機磁碟對應 NAS 上的一個精簡（thin）LUN。所以建立、移除、
擴充、複製、快照、還原，用的都是 NAS 自己的 LUN 功能，而不是在 PVE 這邊用 LVM 把
一顆大 LUN 切開 —— 在「儲存與快照總管」裡看到一顆磁碟，就知道它屬於哪一台虛擬機。

**不需要額外的 LVM 儲存層，也不用手動管理 LUN。**

QTS · QuTS hero · 共用儲存 · 線上遷移 · 快照 / 還原 · 複製 · 多重路徑。
註冊的儲存類型為 **`qnapsan`**。

[English](README.md) · [繁體中文](README_zh-TW.md) · **[文件網站](https://jasoncheng7115.github.io/jt-pve-storage-qnap/?lang=zh)**

---

## ⚠️ 尚未實機測試

**這個外掛沒有任何一部分曾經在實體 QNAP NAS 上執行過。**

它完全是依照 API 文件寫成的。它可以編譯、通過 196 個單元測試，而**這些都不能證明
它在你的 NAS 上會正常運作**。一個還沒見過它所驅動的陣列的外掛，是一個假設，不是
一個產品。

| | |
|---|---|
| **請不要** | 放正式資料、指向存有任何資料的 NAS、或圍繞它規劃叢集 |
| **請這樣做** | 用一台備用 NAS、或一個你願意失去的儲存池來跑，然後告訴我們結果 |

有三個問題必須先在實機上得到答案，而且任何一題答錯都是要改設計，不是修個 bug：

1. NAS 回報的 `LUNNAA` 是否等於核心的 `/sys/block/<sd>/device/wwid`？每一個裝置
   都是靠比對這兩者辨識的。
2. QNAP LUN 回報的 SCSI vendor 字串是什麼？
3. `authLogin.cgi` 收不收 POST？這個外掛的每一個呼叫都是 POST。

[docs/TESTING_zh-TW.md](docs/TESTING_zh-TW.md) 依照應該處理的順序列出全部十六項待驗證事項，
並附上第一次上機的指令。

0.x 全部都是預覽版本。這段警語會在有實測結果可以取代它的時候才拿掉，不會提前。

---

## 支援的 Proxmox VE 操作

已實作並通過單元測試，**但尚未在實機上跑過** —— 虛擬機與容器都一樣。

容器的磁碟和虛擬機的磁碟是同一種東西：一個 thin LUN、一個 multipath 裝置。差別在
上層 —— Proxmox VE 會在容器的 LUN 上建立檔案系統並掛在*主機上*，而虛擬機的磁碟是
整顆交給客體。這就是下表只有兩列不同的原因。

| 操作 | 虛擬機 | 容器 |
|---|---|---|
| 配置、刪除、列表 | 支援 | 支援¹ |
| 精簡配置 | 支援 | 支援 |
| 擴充容量 | 支援 | 支援 |
| 快照、刪除快照、還原 | 支援 | 支援² |
| 範本與連結複製 | 支援 | 支援 |
| 完整複製、`pvesm export`/`import`、搬移到其他儲存 | 支援 | 支援 |
| 節點間遷移 | 支援 | 支援 |
| **線上**遷移（客體不停機） | 支援 | 不適用³ |
| 跨多個 NAS 資料埠的多重路徑 | 支援 | 支援 |
| CHAP、雙向 CHAP | 支援 | 支援 |
| 縮小磁碟 | **明確拒絕** | **明確拒絕** |
| 直接把快照當裝置讀取 | 做不到⁴ | 做不到⁴ |

¹ 容器需要在儲存的內容類型裡包含 `rootdir`：`--content images,rootdir`。

² 外掛的 `volume_snapshot_needs_fsfreeze` 回答「是」，所以 PVE 會在 NAS 取快照
之前先凍結執行中容器的掛載點 —— 容器的根目錄是掛在主機上的，這點和虛擬機的磁碟
不同。

³ Proxmox VE 在任何儲存上都不支援執行中容器的線上遷移。容器遷移需要重新啟動，而
在這個儲存上，那次重啟不需要搬動任何資料。

⁴ 請還原，或把它複製成一顆獨立磁碟。外掛選擇一開始就表明不支援，而不是做到一半才
失敗。

## 決定這個外掛能做什麼的三件事

### 一、磁碟以整數 GiB 配置

LUN 的容量是整數 GiB，沒有更細的刻度。所以每個容量都會**無條件進位**，而
`volume_size_info` 回報的是 NAS 上實際的大小，不是 Proxmox VE 要求的大小。要
10.5 GB 會得到 11 GiB，虛擬機設定裡也會寫 11 GiB，因為「設定值與實際裝置不一致」
正是這個外掛最努力避免的狀況。

調整容量時會明確說出來：

```
storage 'qnap1': QTS allocates in whole GiB, so 'pve-qnap1-vm-100-disk-0' is
now 12884901888 bytes rather than the 11811160064 requested.
```

### 二、存取控制靠 CHAP

這個外掛不會在目標上設定針對個別主機的存取清單。它只在目標的預設原則上設定 CHAP，
不做更細的限制；要把 LUN 限制給特定主機，請自行在 QNAP 網頁介面裡設定。

所以除非這台 NAS 位於純儲存網路，否則請設定 CHAP。加入儲存時若沒設定，外掛會提出
警告；只給 CHAP 帳號卻沒有密碼時，外掛會直接拒絕，不會寫入空密碼。

### 三、連結複製在 QTS 上會真的複製資料，在 QuTS hero 上不會

所有複製都是從快照做出來的。

* **QuTS hero（ZFS）**：複製出來的磁碟與快照共用區塊。Proxmox VE 的連結複製是瞬間
  完成，而且不佔額外空間。
* **QTS（LVM）**：是真的複製。對 200 GB 範本做連結複製會寫入 200 GB。

外掛會偵測目前面對的是哪一種，並使用正確的形式。如果正在選型而且預期會大量從範本
部署，這一點就是決定性的差異。

## 需求

| | |
|---|---|
| Proxmox VE | 8.0 以上，**每個節點都要裝** |
| QNAP 韌體 | QTS 4.5.1 以上，或任何 QuTS hero — 見 [docs/SUPPORTED-QNAP-OS_zh-TW.md](docs/SUPPORTED-QNAP-OS_zh-TW.md) |
| NAS 上 | iSCSI 目標服務要**開啟**，並且要有儲存池 |
| 帳號 | **管理員**，且未啟用兩步驟驗證 — 見 [docs/QNAP-ACCOUNT_zh-TW.md](docs/QNAP-ACCOUNT_zh-TW.md) |
| 每個節點 | `open-iscsi`、`multipath-tools` |

若韌體回報的是舊版 Storage Manager 而非 Storage Manager V2，外掛會在
`pvesm add` 當下**直接拒絕**，並在訊息中寫出韌體版本。它不會先加成功、之後才列不出
任何東西。

## 真正的上限是 LUN 數量

一顆虛擬機磁碟就是一個 LUN，而每台 NAS 能有的 LUN 數量有上限，且因機型而異。外掛
會向 NAS 讀取這個數字而不是自己假設，接近上限時提出警告，到達上限時拒絕配置，並且
明白說出「增加空間沒有用」：

```
storage 'qnap1': the NAS already holds 256 LUNs, which is this model's maximum
(256). Free space is not the problem and adding capacity will not help — delete
LUNs, or use a second NAS. The count includes LUNs this storage does not own,
such as Virtual Machine Manager disks.
```

`pve-qnap-api-probe` 會印出這個數字。規劃叢集之前請先確認。

## 安裝

叢集的每個節點都要執行。

```bash
# 每個節點 —— PVE 不會幫你裝的兩個套件
apt update
apt install -y open-iscsi multipath-tools

cd /tmp
# 檔名不帶版本：這個網址永遠是最新版
wget -O jt-pve-storage-qnap_all.deb \
  https://github.com/jasoncheng7115/jt-pve-storage-qnap/releases/latest/download/jt-pve-storage-qnap_all.deb
apt install -y ./jt-pve-storage-qnap_all.deb
systemctl restart pvedaemon pveproxy pvestatd

dpkg -l jt-pve-storage-qnap | awk '/^ii/{print $3}'    # 確認裝到的版本
```

**`-O` 不是裝飾。** 少了它，`wget` 不會覆寫已經存在的檔案，而是另存成別的檔名 ——
接著 `apt` 裝的就是上次留在 `/tmp` 的**舊檔**。

請用 `apt install ./檔案.deb`，不要用 `dpkg -i`：後者不會處理相依套件，在沒有
`multipath-tools` 的節點上會留下一個未設定完成的套件。

**叢集的每個節點都要裝，包含你用來開網頁介面的那一台**，而且版本要一致。儲存操作
是在擁有該客體的節點上執行的；*沒裝*外掛的節點不會回報錯誤，而是讓這個儲存在網頁
介面裡消失。

如果還沒有可下載的版本，可以從這個 repository 自行打包：`make deb`。

## 探測工具

做任何事之前先跑它。它是**唯讀**的：不會建立也不會刪除任何東西，結束時會自行登出。

```bash
pve-qnap-api-probe --host <nas> --user admin --insecure --node
```

它會印出機型、韌體、是 QTS 還是 QuTS hero、LUN 與目標的數量上限、各儲存池與其剩餘
空間，以及這個節點裝了哪些工具。

## 在 Proxmox VE 加入 QNAP 儲存

```bash
pvesm add qnapsan qnap1 \
    --qnap-portal 192.0.2.10 \
    --qnap-username pve \
    --qnap-password '<密碼>' \
    --qnap-pool 1 \
    --qnap-chap-username pve \
    --qnap-chap-password '<CHAP 密碼>' \
    --qnap-ssl-verify 0 \
    --content images
```

之後就跟其他儲存一樣使用：`qm create --scsi0 qnap1:32`、快照、還原、範本、
連結複製、線上遷移。

加入儲存時，如果 NAS 上已經有這個儲存前綴的 LUN，外掛會提出警告。如果這個儲存之前
在這裡加過，那些就是它自己的磁碟。如果是*另一個* Proxmox VE 叢集在同一台 NAS 上用了
相同的儲存名稱，兩邊的磁碟名稱會完全重疊 —— 請移除這個儲存，換一個名稱再加。

## 清理工具

Proxmox VE 不會通知**來源節點**「這個共用磁碟區在這裡已經不需要了」—— 它唯一一次
呼叫 `deactivate_volumes` 是在處理本機磁碟區的路徑裡。所以被遷離的節點會留著一個
已經用不到的 multipath map；如果那台虛擬機之後又在別的節點被刪除，留下的就是一個
指向已不存在 LUN 的 map。被強制重開的節點也會以同樣的方式留下追蹤紀錄。

```bash
pve-qnap-reap --all             # 只報告
pve-qnap-reap --all --remove    # 實際清除
```

**節點當機之後要跑一次；移除儲存之前，每個節點都要跑一次。** 它絕不會動到正在使用
中的裝置，而且在無法確認狀態時會拒絕動作，不會用猜的。

## 設定選項

| 選項 | 預設值 | |
|---|---|---|
| `qnap-portal` | — | 管理位址；可用逗號分隔多個，依序嘗試 |
| `qnap-port` | `443` | QTS 的 HTTP 管理埠通常是 8080 |
| `qnap-scheme` | `https` | 用 `http` 時密碼在網路上不會加密 |
| `qnap-username` | — | 必須是管理員 |
| `qnap-password` | — | 存放於 `/etc/pve/priv`，不會寫進 `storage.cfg` |
| `qnap-pool` | — | 「儲存與快照總管」顯示的儲存池編號 |
| `qnap-target-mode` | `shared` | 或 `per-volume`，每顆磁碟各佔用一個目標 |
| `qnap-chap-username` / `-password` | — | 這個外掛所依賴的存取控制 |
| `qnap-mutual-chap-username` / `-password` | — | 讓 NAS 對節點驗證自己 |
| `qnap-ssl-verify` | `0` | QTS 出廠是自簽憑證 |
| `qnap-data-portals` | 管理位址 | iSCSI 資料位址，逗號分隔 |
| `qnap-min-free` | `10` | 儲存池剩餘空間低於這個 GiB 數就拒絕配置 |
| `qnap-no-path-retry` | `18` | multipath 用；一定是數字，絕不用 `queue` |
| `qnap-sector-size` | `512` | 或 `4096`；部分客體作業系統無法從 4Kn 開機 |
| `qnap-thin` | `1` | 厚配置的 LUN 建立時就佔滿整個容量 |
| `qnap-status-timeout` | `5` | 秒，健康檢查用 |

## 文件

| | |
|---|---|
| [docs/TESTING_zh-TW.md](docs/TESTING_zh-TW.md) | 已驗證與未驗證的項目，以及第一次上機的步驟。**相信任何東西之前先讀這份** |
| [docs/SUPPORTED-QNAP-OS_zh-TW.md](docs/SUPPORTED-QNAP-OS_zh-TW.md) | 支援哪些韌體，以及 QTS 與 QuTS hero 的差異 |
| [docs/QNAP-ACCOUNT_zh-TW.md](docs/QNAP-ACCOUNT_zh-TW.md) | NAS 帳號、密碼存放位置與 CHAP |
| [CHANGELOG_zh-TW.md](CHANGELOG_zh-TW.md) | 每個版本新增、修正與尚未驗證的項目 |

## 出問題的時候

這個外掛可能出現的失敗狀況、各自代表什麼、該怎麼處理，都在文件網站的
[出問題的時候](https://jasoncheng7115.github.io/jt-pve-storage-qnap/?lang=zh#trouble)。

回報時請附上 `pve-qnap-api-probe --node` 的輸出、機型、韌體版本，以及是 QTS 還是
QuTS hero。

## 參與貢獻

這個專案最需要的是實機上的回報 —— 見 [docs/TESTING_zh-TW.md](docs/TESTING_zh-TW.md)。

**這個外掛呼叫的 QNAP API 是固定的一組。** `t/07-api-scope.t` 列出了每一個，原始碼
只要多出一個不在清單上的呼叫，測試就會失敗。需要新增呼叫的修改，請先開 issue，不要
為了讓測試通過而直接把它加進清單。

## 相關專案

其他陣列的 Proxmox VE 儲存外掛，共用主機端這一層，以及這個專案承襲的操作規則：

- [jt-pve-storage-synology](https://github.com/jasoncheng7115/jt-pve-storage-synology) — Synology NAS
- [jt-pve-storage-dellemc](https://github.com/jasoncheng7115/jt-pve-storage-dellemc) — Dell EMC PowerStore、PowerVault ME、PowerFlex、Unity XT
- [jt-pve-storage-netapp](https://github.com/jasoncheng7115/jt-pve-storage-netapp) — NetApp ONTAP
- [jt-pve-storage-purestorage](https://github.com/jasoncheng7115/jt-pve-storage-purestorage) — Pure Storage FlashArray

## 授權

MIT，見 [LICENSE](LICENSE)。

授權範圍是這個外掛自己的程式碼，不包含 QNAP 的 API 文件、軟體、韌體或商標 —— 這些
都不在這個 repository 裡。

**這是獨立專案，不是由威聯通科技（QNAP Systems, Inc.）開發、認證、背書或維護**，
QNAP 也不為它提供任何保證。QNAP、QTS 與 QuTS hero 為 QNAP Systems, Inc. 的商標。

## 作者

Jason Cheng (Jason Tools) &lt;jason@jason.tools&gt;
