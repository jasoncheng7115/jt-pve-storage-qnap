# QNAP 的 LUN 與 target 數量上限

[English](LIMITS.md) · [繁體中文](LIMITS_zh-TW.md) · [文件網站](https://jasoncheng7115.github.io/jt-pve-storage-qnap/?lang=zh)

**在這個 plugin 裡，一顆虛擬機磁碟就是一個 LUN**。所以 LUN 上限就是這個 storage 最多能放幾顆虛擬磁碟，而且遠在空間用完之前就會先達到。

有三件事容易被忽略，而且都與數量有關，與容量無關：

- **上限是以 NAS 計算，不是以節點計算**。三個節點的叢集共用一台 NAS，就是共用一個上限。
- **NAS 上的每一個 LUN 都計入**，包含自己在「儲存與快照總管」裡為了其他用途建立的。plugin 也把它們計入，所以能比 NAS 更早拒絕。
- **一台虛擬機通常不只使用一個**。一顆系統磁碟加一顆資料磁碟就是兩個，所以上限 128 的 NAS 大約可以放 **64 台這樣的虛擬機**。

這一頁的每個數字都引自 QNAP 公開的網頁，並附上網址。沒有任何數字是推算出來的，而且**本專案都還沒有實測過**：這個 plugin 目前只在一台 QNAP NAS 上測過。

---

## QNAP 公布的數字：三個來源的說法不同

### 一、產品頁：QTS 是 128，QuTS hero 是 256

每個機型的「軟體規格」頁，每種作業系統各有一行：

| 作業系統 | 「Maximum number of targets LUN」| 「Maximum LUN size」|
|---|---:|---:|
| QTS 5.2 | **128** | 250 TB |
| QuTS hero h6.0 | **256** | 1024 TB |

QuTS hero 那一行是產品頁針對 h6.0 列出的數字。在 QuTS hero h6.0 以上，這個 plugin 可以建立、刪除與掛載磁碟，見 [SUPPORTED-QNAP-OS_zh-TW.md](SUPPORTED-QNAP-OS_zh-TW.md)。使用手冊針對 QuTS hero h5.1.x 的數字在下面「使用手冊」那一段。

查閱過的每個機型都是這兩個數字：

| 機型 | QTS | QuTS hero | 來源 |
|---|---:|---:|---|
| TS-233（2 bay，ARM）| 128 | 未提供 | [規格](https://www.qnap.com/en/product/ts-233/specs/software) |
| TS-464（4 bay）| 128 | 256 | [規格](https://www.qnap.com/en/product/ts-464/specs/software) |
| TS-873A（8 bay，AMD）| 128 | 256 | [規格](https://www.qnap.com/en/product/ts-873a/specs/software) |
| TVS-h874（8 bay）| 128 | 256 | [規格](https://www.qnap.com/en/product/tvs-h874/specs/software) |
| TS-h1290FX（12 bay，全快閃）| 128 | 256 | [規格](https://www.qnap.com/en/product/ts-h1290fx/specs/software) |

所以**這個數字取決於作業系統，而不是機型**：兩顆硬碟的入門機型和十二顆硬碟的全快閃機型，公布的是同一個數字。兩種作業系統都能安裝的機型，改用 QuTS hero 之後上限會變成兩倍。

### 二、FAQ：相同的數字，但註明是理論值

QNAP 關於儲存上限的 FAQ，列出每種作業系統的物件數量上限：

| | QTS | QuTS hero |
|---|---:|---:|
| LUN | **128** | **256** |
| LUN 容量 | 250 TB | 1024 TB |
| 磁碟區 | 128 | 256 |
| 快照 | 1024 | 65536 |

並且註明這些都是理論上的最大值，在某些硬體機型或特定設定下可能更低。

來源：[What are the maximum storage capacities and limits for QNAP NAS operating systems?](https://www.qnap.com/en/how-to/faq/article/what-are-the-maximum-storage-capacities-and-limits-for-qnap-nas-operating-systems)

### 三、使用手冊：255，LUN 與 target 合計

各版使用手冊的「Storage limits」頁只列出一個 iSCSI 數字，而且是**合計**：

| 使用手冊 | 每台 NAS 的 iSCSI LUN 與 target |
|---|---:|
| [QTS 5.1.x](https://docs.qnap.com/operating-system/qts/5.1.x/en-us/storage-limits-0A2EB80.html) | **255（合計）** |
| [QTS 5.2.x](https://docs.qnap.com/operating-system/qts/5.2.x/en-us/storage-limits-0A2EB80.html) | **255（合計）** |
| [QuTS hero h5.1.x](https://docs.qnap.com/operating-system/quts-hero/5.1.x/en-us/storage-limits-0A2EB80.html) | **255（合計）** |

同一頁還列出每個 iSCSI 工作階段最多 8 條連線，以及每個 target、每台 NAS 的工作階段數量是由 NAS 的 CPU、記憶體與網路決定，不是固定數字。

### 實際適用的是哪一個

在 QTS 上，這幾個數字無法同時成立：產品頁與 FAQ 是 128，使用手冊是合計 255。**實際生效的是哪一個，本專案還沒有實測**。在測出結果之前，請以較小的數字規劃：

| | 規劃時採用 |
|---|---|
| QTS | **128 個 LUN**，再扣除 NAS 上已經存在的 |
| QuTS hero | **LUN 與 target 合計 255**，再扣除 NAS 上已經存在的 |

---

## 這個 plugin 會向 NAS 詢問

NAS 會回報自己的 LUN 數量上限與 target 數量上限，`pve-qnap-api-probe` 兩個都會印出來：

```bash
pve-qnap-api-probe --host <nas> --user admin --insecure
```

plugin 是讀取這兩個數字，不自行假設，而且會比 NAS **更早**拒絕，所以訊息寫的是實際原因，而不是一個錯誤代碼：

| 上限 | plugin 的做法 |
|---|---|
| LUN | 拒絕配置，剩下 16 個時開始警告。NAS 上**每一個** LUN 都計入，包含不屬於這個 storage 的 |
| target | 拒絕建立 target。只有 `qnap-target-mode=per-volume` 才會遇到。`shared` 整個 storage 只使用一個 target，這也是預設值選用它的原因 |

NAS 沒有回報數字時，plugin 會停止檢查，不會自行假設一個數字，也不會當成沒有上限。

**plugin 是分開檢查這兩個上限的**。如果 NAS 實際採用的是使用手冊寫的合計數字，NAS 會先拒絕，plugin 會把那次拒絕原樣回報。這是 [TESTING_zh-TW.md](TESTING_zh-TW.md) 的第 12 項待驗證事項。

### `shared` 是預設 target 模式的原因

`per-volume` 是每顆磁碟各使用一個 target，所以每顆磁碟會用掉一個 LUN **加上**一個 target。以合計上限 255 計算，那是 **127 顆磁碟**。`shared` 整個 storage 只使用一個 target，可以放 254 顆。`shared` 也讓每個節點的 iSCSI 工作階段數量維持在每個資料位址一個，而不是每顆磁碟一個。

---

## 每個 LUN 的快照數量

### QuTS hero

每個 LUN、每個共用資料夾、每台 NAS 都是 **65,536 個**。儲存集區至少要剩下 32 GB，才能再建立快照。

來源：[Snapshot storage limitations, QuTS hero h5.1.x](https://docs.qnap.com/operating-system/quts-hero/5.1.x/en-us/snapshot-storage-limitations-91D8C464.html)

### QTS：取決於 CPU 與安裝的記憶體

| CPU | 安裝的記憶體 | 每台 NAS | 每個磁碟區或 LUN |
|---|---|---:|---:|
| Intel、AMD、Zhaoxin | 1 GB 以上 | 32 | 16 |
| | 2 GB 以上 | 64 | 32 |
| | 4 GB 以上 | **1024** | **256** |
| Marvell、Annapurna Labs | 1 GB 以上 | 32 | 16 |
| | 2 GB 以上 | 64 | 32 |
| | 4 GB 以上 | 256 | 64 |
| Realtek | 1 GB 以上 | 32 | 16 |
| | 2 GB 以上 | 64 | 32 |

快照功能至少需要 1 GB 記憶體，而且部分舊系列完全不支援。

來源：[How many snapshots can I create on my QNAP NAS?](https://www.qnap.com/en/how-to/faq/article/how-many-snapshots-can-i-create-on-my-qnap-nas)

關於這些數字有三件事：

- **最先達到的是「每台 NAS」的數字**。QTS 加上 4 GB 以上的記憶體時，整台 NAS 共 1024 個快照，相當於 256 顆磁碟每顆 4 個，或 128 顆磁碟每顆 8 個。
- **額度是共用的**。自己在 NAS 上設定的快照排程，和 Proxmox VE 建立的快照，使用的是同一份「每個 LUN」與「每台 NAS」額度。
- **plugin 事先不知道這些上限**。它會直接建立快照，然後回報 NAS 的回應。在 QuTS hero 上，範本也會自己保留一個快照，供連結複製使用。

### 包含記憶體的快照會多使用一個 LUN

勾選「包含記憶體」時，Proxmox VE 會把記憶體寫入另一顆磁碟 `vm-<vmid>-state-<快照名稱>`。在這個 storage 上，那就是另一個 LUN，計入同一個 LUN 上限。它的大小依虛擬機的記憶體決定，並且和其他磁碟一樣進位到整數 GiB。它預設會放在這個 storage 上，因為 Proxmox VE 會優先選擇虛擬機已經有磁碟的共用 storage。可以在虛擬機上設定 `vmstatestorage`，把它放到別的地方。刪除快照時，它會一併釋放。

---

## LUN 容量

| | 最大 | 這個 plugin 建立的最小值 |
|---|---:|---:|
| QTS | 250 TB | 1 GiB |
| QuTS hero | 1024 TB | 1 GiB |

產品頁註明 QTS 的最大值需要至少 4 GB 記憶體。plugin 以整數 GiB 配置，所以最小的磁碟（EFI 磁碟、TPM 狀態、cloud-init 磁碟）都是 1 GiB。

---

## 沒有公布的，以及尚未實測的

- **沒有「每個 target 可以對應幾個 LUN」的數字**。使用 `shared` 時，這個 storage 的每顆磁碟都在同一個 target 上，所以這個數字有影響，但 QNAP 公布的資料裡沒有。
- **沒有說明哪個數字優先**：QTS 產品頁的 128，或是使用手冊的合計 255。
- **只查閱了五個機型的產品頁**。它們的數字一致，FAQ 也列出每種作業系統相同的數字，但 FAQ 同時註明個別機型可能更低。請查閱自己機型的頁面，或直接向 NAS 詢問。
- **這裡沒有任何數字是實測的**，全部都是 QNAP 公布的數字。本專案有 NAS 可以量測之後，NAS 回報的數字與實際拒絕的位置，會寫在這些數字旁邊。

---

## 官方資料

- [QTS 5.1.x User Guide：Storage limits](https://docs.qnap.com/operating-system/qts/5.1.x/en-us/storage-limits-0A2EB80.html)
- [QTS 5.2.x User Guide：Storage limits](https://docs.qnap.com/operating-system/qts/5.2.x/en-us/storage-limits-0A2EB80.html)
- [QuTS hero h5.1.x User Guide：Storage limits](https://docs.qnap.com/operating-system/quts-hero/5.1.x/en-us/storage-limits-0A2EB80.html)
- [QuTS hero h5.1.x User Guide：Snapshot storage limitations](https://docs.qnap.com/operating-system/quts-hero/5.1.x/en-us/snapshot-storage-limitations-91D8C464.html)
- [FAQ：What are the maximum storage capacities and limits for QNAP NAS operating systems?](https://www.qnap.com/en/how-to/faq/article/what-are-the-maximum-storage-capacities-and-limits-for-qnap-nas-operating-systems)
- [FAQ：How many snapshots can I create on my QNAP NAS?](https://www.qnap.com/en/how-to/faq/article/how-many-snapshots-can-i-create-on-my-qnap-nas)
- [TS-464 Software Specifications](https://www.qnap.com/en/product/ts-464/specs/software)
