# jt-pve-storage-qnap

**讓 Proxmox VE 透過 iSCSI，直接把 QNAP NAS 當成虛擬機的儲存後端。**

每一顆 Proxmox VE 虛擬機磁碟，直接對應 NAS 上的一個 thin LUN。因此虛擬機的建立、刪除、擴充、複製、快照與倒回，用的都是 NAS 自己的 LUN 功能，不需要先建立一個大型共用 LUN，再交給 PVE 用 LVM 切割。在「儲存與快照總管」裡看到一顆磁碟，就知道它屬於哪一台虛擬機。

**沒有額外的 LVM 儲存層，也不需要手動管理 LUN。**

QTS · QuTS hero · 共用儲存 · 線上遷移 · 快照 / 倒回 · 複製 · 多重路徑。註冊的 storage 類型為 **`qnapsan`**。

[English](README.md) · [繁體中文](README_zh-TW.md) · **[文件網站](https://jasoncheng7115.github.io/jt-pve-storage-qnap/?lang=zh)**

---

## ⚠️ 目前只在一台 QNAP NAS 上測過

**目前只在一台 QNAP NAS 上測過。**

那台 NAS 的韌體是 QuTS hero h6.0.1，結果是無法使用：**不支援 QuTS hero h6.0 以上**，新增 storage 時會直接拒絕。它所針對的韌體（QTS 5.1 與 QuTS hero h5.1）還沒有在實機上執行過。

它完全是依照 API 文件寫成的。它可以編譯，通過 247 個單元測試，也對模擬的 NAS 跑過完整的操作流程。**這些都不能證明它在你的 NAS 上能正常運作。**

| | |
|---|---|
| **請不要** | 放正式資料、指向存有任何資料的 NAS、或以它為基礎規劃叢集 |
| **請這樣做** | 用一台備用 NAS、或一個可以捨棄的儲存集區來測試，然後回報結果 |

有三個問題必須先在實機上得到答案。任何一題的答案與預期不同，要改的都是設計，不是修一個 bug：

1. NAS 回報的 `LUNNAA` 是否等於核心的 `/sys/block/<sd>/device/wwid`？每一個裝置都是靠比對這兩者辨識的。
2. QNAP LUN 回報的 SCSI vendor 字串是什麼？
3. `authLogin.cgi` 是否接受 POST？這個 plugin 的每一個呼叫都是 POST。

[docs/TESTING_zh-TW.md](docs/TESTING_zh-TW.md) 依照應該處理的順序列出全部十七項待驗證事項，並附上第一次上機的指令。

0.x 全部都是預覽版本。有實測結果可以取代這段警語時，才會把它拿掉。

---

## 支援的 Proxmox VE 操作

已實作並通過單元測試，虛擬機與容器都一樣。實機測試目前只有一台 NAS。

容器的磁碟和虛擬機的磁碟是同一種東西：一個 thin LUN、一個 multipath 裝置。差別在上層。Proxmox VE 會在容器的 LUN 上建立檔案系統並掛接在主機上，而虛擬機的磁碟是整顆交給 guest。所以下表只有兩列不同。

| 操作 | 虛擬機 | 容器 |
|---|---|---|
| 配置、刪除、列表 | 支援 | 支援¹ |
| 精簡配置 | 支援 | 支援 |
| 擴充容量 | 支援 | 支援 |
| 快照、刪除快照、倒回 | 支援 | 支援² |
| 範本 | 支援 | 支援 |
| 連結複製、從快照複製 | 僅 QuTS hero⁵ | 僅 QuTS hero⁵ |
| 完整複製、`pvesm export`/`import`、搬移到其他 storage | 支援 | 支援 |
| 節點間遷移 | 支援 | 支援 |
| **線上**遷移（guest 不停機）| 支援 | 不適用³ |
| 跨多個 NAS 資料連接埠的多重路徑 | 支援 | 支援 |
| CHAP、雙向 CHAP | 支援 | 支援 |
| 縮小磁碟 | **明確拒絕** | **明確拒絕** |
| 直接把快照當成裝置讀取 | 無法做到⁴ | 無法做到⁴ |

¹ 容器需要在 storage 的內容類型裡包含 `rootdir`：`--content images,rootdir`。

² plugin 的 `volume_snapshot_needs_fsfreeze` 回答「是」，所以 PVE 會在 NAS 建立快照之前，先凍結執行中容器的掛接點。容器的根目錄是掛接在主機上的，這一點和虛擬機的磁碟不同。

³ Proxmox VE 在任何 storage 上都不支援執行中容器的線上遷移。容器遷移需要重新啟動，而在這個 storage 上，重新啟動時不需要搬動任何資料。

⁴ 請倒回到該快照，或在 QuTS hero 上把它複製成一顆獨立的磁碟。plugin 會在一開始就表明不支援，不會做到一半才失敗。

⁵ 在 QTS 上，plugin 不提供連結複製，也不提供從快照複製，Proxmox VE 會在開始之前就拒絕。範本請使用完整複製。原因見下方第三點。

## 影響使用方式的三件事

### 一、磁碟以整數 GiB 配置

LUN 的容量是整數 GiB，沒有更細的單位。所以每個容量都會**無條件進位**，而 `volume_size_info` 回報的是 NAS 上實際的大小，不是 Proxmox VE 要求的大小。要求 10.5 GB 會得到 11 GiB，虛擬機設定裡寫的也是 11 GiB。

調整容量時會明確告知：

```
storage 'qnap1': QTS allocates in whole GiB, so 'pve-qnap1-vm-100-disk-0' is
now 12884901888 bytes rather than the 11811160064 requested.
```

### 二、存取控制靠 CHAP

這個 plugin 不會在 target 上設定針對個別主機的存取清單。它只在 target 的預設原則上設定 CHAP，不做更細的限制。要把 LUN 限制給特定主機，請自行在 QNAP 網頁介面裡設定。

所以除非這台 NAS 位於儲存專用的網路，否則請設定 CHAP。新增 storage 時如果沒有設定，plugin 會提出警告。只給 CHAP 帳號卻沒有密碼時，plugin 會直接拒絕，不會寫入空密碼。

### 三、連結複製只在 QuTS hero 提供，QTS 請使用完整複製

這個 plugin 的每一次複製，都是在 NAS 上從快照建立的。

* **QuTS hero（ZFS）**：複製出來的磁碟與快照共用區塊。Proxmox VE 的連結複製會立即完成，而且不佔用額外空間。
* **QTS（LVM）**：plugin **不提供連結複製，也不提供從快照複製**。在 QTS 上複製會把整顆磁碟複製一份，而 Proxmox VE 會中止超過 60 秒的儲存端複製。範本請使用完整複製（`qm clone <vmid> <newid> --full 1`），那是由 Proxmox VE 自己複製資料。快照與倒回在 QTS 上可以使用，倒回需要的時間取決於 NAS 把磁碟寫回去要多久。

如果正在選購硬體，而且預期會大量從範本部署，這一點是決定性的差異。

## 系統需求

| | |
|---|---|
| Proxmox VE | 9.x，**叢集中的每個節點都要安裝**。8.x 預期可以運作，但從未測試過 |
| QNAP 韌體 | QTS 4.5.1 以上，或 QuTS hero h5.x。**不支援 QuTS hero h6.0 以上**。見 [docs/SUPPORTED-QNAP-OS_zh-TW.md](docs/SUPPORTED-QNAP-OS_zh-TW.md) |
| NAS 上 | iSCSI target 服務必須**啟用**，並且要有儲存集區 |
| 帳號 | **管理員**，且未啟用兩步驟驗證。見 [docs/QNAP-ACCOUNT_zh-TW.md](docs/QNAP-ACCOUNT_zh-TW.md) |
| 每個節點 | `open-iscsi`、`multipath-tools` |

如果韌體回報的是舊版 Storage Manager，而不是 Storage Manager V2，plugin 會在 `pvesm add` 時**直接拒絕**，並在訊息中寫出韌體版本。不會先新增成功，之後才列不出任何東西。

## LUN 數量上限

一顆虛擬機磁碟就是一個 LUN，而每台 NAS 能有的 LUN 數量有上限。QNAP 在產品頁公布的是 **QTS 128、QuTS hero 256**，在使用手冊公布的是 **LUN 與 target 合計 255**。兩顆硬碟的機型和十二顆硬碟的機型，數字都一樣。一台有系統磁碟與資料磁碟的虛擬機會用掉兩個，所以在 QTS 上，一台 NAS 大約可以規劃 64 台這樣的虛擬機。

plugin 會向 NAS 讀取上限，不自行假設。接近上限時提出警告，到達上限時拒絕配置，並且說明增加空間沒有幫助：

```
storage 'qnap1': the NAS already holds 256 LUNs, which is this model's maximum
(256). Free space is not the problem and adding capacity will not help. Delete
LUNs, or use a second NAS. The count includes LUNs this storage does not own,
such as Virtual Machine Manager disks.
```

`pve-qnap-api-probe` 會印出這個數字，規劃叢集之前請先確認。[docs/LIMITS_zh-TW.md](docs/LIMITS_zh-TW.md) 列出每一個公布的數字與來源，包含每個 LUN 的快照數量，以及 `per-volume` target 模式的代價。

## 安裝

叢集中的每個節點都要執行。

```bash
# 每個節點：PVE 不會預先安裝的兩個套件
apt update
apt install -y open-iscsi multipath-tools

cd /tmp
# 檔名不含版本：這個網址永遠是最新版
wget -O jt-pve-storage-qnap_all.deb \
  https://github.com/jasoncheng7115/jt-pve-storage-qnap/releases/latest/download/jt-pve-storage-qnap_all.deb
apt install -y ./jt-pve-storage-qnap_all.deb
systemctl restart pvedaemon pveproxy pvestatd

dpkg -l jt-pve-storage-qnap | awk '/^ii/{print $3}'    # 確認安裝的版本
```

**請保留 `-O`**。少了它，`wget` 不會覆寫已經存在的檔案，而是存成另一個檔名。接著 `apt` 安裝的就是上次留在 `/tmp` 的**舊檔**。

請用 `apt install ./檔案.deb`，不要用 `dpkg -i`。後者不會處理相依套件，在沒有 `multipath-tools` 的節點上會留下一個尚未設定完成的套件。

**叢集中的每個節點都要安裝，包含用來開啟網頁介面的那一台**，而且版本要一致。storage 的操作是在擁有該 guest 的節點上執行的。沒有安裝 plugin 的節點不會回報錯誤，而是讓這個 storage 從網頁介面上消失。

## 探索工具

請在做任何事之前先執行它。它是**唯讀**的：不會建立也不會刪除任何東西，結束時會自行登出。

```bash
pve-qnap-api-probe --host <nas> --user admin --insecure --node
```

它會印出機型、韌體、是 QTS 還是 QuTS hero、LUN 與 target 的數量上限、各儲存集區與剩餘空間，以及這個節點安裝了哪些工具。

## 在 Proxmox VE 新增 qnapsan storage

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

之後的用法和其他 storage 相同：`qm create --scsi0 qnap1:32`、快照、倒回、範本、複製、線上遷移。

新增 storage 時，如果 NAS 上已經有這個 storage 前綴的 LUN，plugin 會提出警告。如果這個 storage 之前在這裡新增過，那些就是它自己的磁碟。如果是另一個 Proxmox VE 叢集在同一台 NAS 上用了相同的 storage 名稱，兩邊的磁碟名稱會完全重疊。遇到這種情況，請移除這個 storage，改用另一個名稱新增。

## 清理工具

共用的磁碟在某個節點上不再需要時，Proxmox VE 不會通知該節點。所以虛擬機遷離之後，來源節點會留著一個已經用不到的 multipath map。如果那台虛擬機之後在別的節點被刪除，留下的就是一個指向已不存在 LUN 的 map。被強制重新開機的節點，也會以同樣的方式留下追蹤紀錄。

```bash
pve-qnap-reap --all             # 只回報
pve-qnap-reap --all --remove    # 實際清除
```

**節點當機之後請執行一次。移除 storage 之前，請在每個節點上各執行一次**。它不會動到正在使用中的裝置，無法確認狀態時會拒絕動作，不會猜測。

## 設定選項

| 選項 | 預設值 | |
|---|---|---|
| `qnap-portal` | 無 | 管理位址。可用逗號分隔多個，依序嘗試 |
| `qnap-port` | `443` | QTS 的 HTTP 管理連接埠通常是 8080 |
| `qnap-scheme` | `https` | 使用 `http` 時，密碼在網路上不會加密 |
| `qnap-username` | 無 | 必須是管理員 |
| `qnap-password` | 無 | 存放於 `/etc/pve/priv`，不會寫入 `storage.cfg` |
| `qnap-pool` | 無 | 「儲存與快照總管」顯示的儲存集區編號 |
| `qnap-target-mode` | `shared` | 或 `per-volume`，每顆磁碟各佔用一個 target |
| `qnap-chap-username` / `-password` | 無 | 這個 plugin 所依賴的存取控制 |
| `qnap-mutual-chap-username` / `-password` | 無 | 讓 NAS 向節點驗證自己 |
| `qnap-ssl-verify` | `0` | QTS 出廠時使用自簽憑證 |
| `qnap-data-portals` | 管理位址 | iSCSI 資料位址，以逗號分隔 |
| `qnap-min-free` | `10` | 儲存集區剩餘空間低於這個 GiB 數時拒絕配置 |
| `qnap-no-path-retry` | `18` | multipath 用。一定是數字，不使用 `queue` |
| `qnap-sector-size` | `512` | 或 `4096`。部分 guest 作業系統無法從 4Kn 開機 |
| `qnap-thin` | `1` | 完整配置的 LUN 在建立時就會保留全部容量 |
| `qnap-status-timeout` | `5` | 秒，狀態檢查用 |

## 文件

| | |
|---|---|
| [docs/TESTING_zh-TW.md](docs/TESTING_zh-TW.md) | 已驗證與未驗證的項目，以及第一次上機的步驟。**採用之前請先讀這份** |
| [docs/LIMITS_zh-TW.md](docs/LIMITS_zh-TW.md) | 公布的 LUN、target 與快照數量上限，每個數字都附官方出處 |
| [docs/SUPPORTED-QNAP-OS_zh-TW.md](docs/SUPPORTED-QNAP-OS_zh-TW.md) | 支援哪些韌體，以及 QTS 與 QuTS hero 的差異 |
| [docs/QNAP-ACCOUNT_zh-TW.md](docs/QNAP-ACCOUNT_zh-TW.md) | NAS 帳號、密碼存放位置與 CHAP |
| [CHANGELOG_zh-TW.md](CHANGELOG_zh-TW.md) | 每個版本新增、修正與尚未驗證的項目 |

## 故障處理

這個 plugin 可能出現的失敗狀況、各自代表的意義與處理方式，都列在文件網站的[故障處理](https://jasoncheng7115.github.io/jt-pve-storage-qnap/?lang=zh#trouble)。

回報時請附上 `pve-qnap-api-probe --node` 的輸出、機型、韌體版本，以及是 QTS 還是 QuTS hero。

## 參與貢獻

這個專案最需要的是實機上的回報，見 [docs/TESTING_zh-TW.md](docs/TESTING_zh-TW.md)。

**這個 plugin 呼叫的 QNAP API 是固定的一組**。`t/07-api-scope.t` 列出了每一個，原始碼只要多出一個不在清單上的呼叫，測試就會失敗。需要新增呼叫的修改，請先開 issue，不要為了讓測試通過而直接把它加進清單。

## 相關專案

其他儲存設備的 Proxmox VE storage plugin，與本專案共用主機端的架構與維運規則：

- [jt-pve-storage-synology](https://github.com/jasoncheng7115/jt-pve-storage-synology)：Synology NAS
- [jt-pve-storage-dellemc](https://github.com/jasoncheng7115/jt-pve-storage-dellemc)：Dell EMC PowerStore、PowerVault ME、PowerFlex、Unity XT
- [jt-pve-storage-netapp](https://github.com/jasoncheng7115/jt-pve-storage-netapp)：NetApp ONTAP
- [jt-pve-storage-purestorage](https://github.com/jasoncheng7115/jt-pve-storage-purestorage)：Pure Storage FlashArray

## 授權

MIT，見 [LICENSE](LICENSE)。

授權範圍是這個 plugin 自己的程式碼，不包含 QNAP 的 API 文件、軟體、韌體或商標。這些都不在這個 repository 裡。

**這是獨立專案，不是由威聯通科技（QNAP Systems, Inc.）開發、認證、背書或維護**，QNAP 也不為它提供任何保證。QNAP、QTS 與 QuTS hero 為 QNAP Systems, Inc. 的商標。

## 作者

Jason Cheng (Jason Tools) &lt;jason@jason.tools&gt;
