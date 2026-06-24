# 測試安裝腳本

這個目錄包含用於測試安裝 Orrery 的腳本，讓你可以在另一台電腦上安裝當前的開發版本。

## 使用方式

### 1. 在開發機器上打包

```bash
./scripts/package-local.sh
```

這會：
- 編譯 release binary
- 打包成 tarball（檔名格式：`orrery-{os}-{arch}-{version}-local.tar.gz`）
- 輸出到當前目錄

你也可以指定輸出目錄：
```bash
./scripts/package-local.sh ~/Downloads
```

### 2. 傳輸到目標機器

將生成的 tarball 複製到目標機器（透過 scp、airdrop、USB 等）：

```bash
# 範例：使用 scp
scp orrery-darwin-arm64-3.1.0-rc.1-local.tar.gz user@target-machine:~/
```

### 3. 在目標機器上安裝

#### 方法 A：使用安裝腳本（推薦）

如果目標機器上也有這個 repo：
```bash
./scripts/install-local.sh orrery-darwin-arm64-3.1.0-rc.1-local.tar.gz
```

如果沒有 repo，可以手動執行安裝腳本的內容，或者只複製 `install-local.sh` 腳本到目標機器。

#### 方法 B：手動安裝

```bash
# 1. 解壓
tar -xzf orrery-darwin-arm64-3.1.0-rc.1-local.tar.gz

# 2. 安裝 binary
sudo cp orrery-bin /usr/local/bin/
sudo chmod +x /usr/local/bin/orrery-bin

# 3. macOS 專用：移除隔離屬性
sudo xattr -cr /usr/local/bin/orrery-bin
sudo codesign --force --sign - /usr/local/bin/orrery-bin

# 4. 執行 setup
orrery-bin setup

# 5. 啟用 shell integration
source ~/.orrery/activate.sh
```

## 注意事項

- **平台相容性**：tarball 是平台特定的。在 macOS ARM64 上打包的 binary 只能在 macOS ARM64 上運行
- **版本號**：tarball 檔名會包含當前的版本號（從 `Sources/OrreryCore/Version.swift` 讀取）
- **orrery-magi**：這些腳本只打包和安裝 `orrery-bin`，不包含 `orrery-magi` sidecar。如果需要完整功能，目標機器需要另外安裝 `orrery-magi`

## 腳本說明

### package-local.sh

打包腳本會：
1. 讀取當前版本號
2. 偵測 OS 和架構
3. 編譯 release binary
4. 複製 binary 和 resources 到臨時目錄
5. 創建 tarball
6. 顯示安裝說明

### install-local.sh

安裝腳本會：
1. 驗證 tarball 存在
2. 解壓到臨時目錄
3. 安裝 binary 到 `/usr/local/bin/`
4. 安裝 resources（如果有）
5. 移除舊版 binary（如果有）
6. macOS：移除隔離屬性和重新簽名
7. 執行 `orrery-bin setup`

## 疑難排解

### "Binary not found"
確保在專案根目錄執行 `package-local.sh`。

### "Permission denied"
安裝到 `/usr/local/bin/` 需要 sudo 權限。腳本會自動偵測並使用 sudo。

### macOS "Killed: 9"
這是 Gatekeeper 的安全機制。確保執行了：
```bash
sudo xattr -cr /usr/local/bin/orrery-bin
sudo codesign --force --sign - /usr/local/bin/orrery-bin
```
`install-local.sh` 會自動處理這個問題。
