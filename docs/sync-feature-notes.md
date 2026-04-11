# Orbital Sync Feature — 設計筆記

## 目標

讓兩台電腦共享 Orbital 的 session、memory 和環境設定。

## 使用場景

- **A. 同一人多台電腦** — 桌機和筆電共用同一個帳號的 session
- **B. 兩人協作** — pair programming，共享同一個 session

## 核心：同步 `~/.orbital/shared/`

這個目錄包含：
- `claude/projects/` — Claude session 檔案
- `claude/sessions/` — Claude session metadata
- `claude/session-env/` — Claude session 環境
- `codex/sessions/` — Codex session
- `gemini/tmp/` — Gemini session
- `memory/<project-key>/ORBITAL_MEMORY.md` — 共享記憶

## 方案比較

| 方式 | 即時性 | 複雜度 | 說明 |
|---|---|---|---|
| **rsync** | 手動 | 低 | `orbital sync push/pull` 包裝 rsync |
| **Git repo** | 手動 | 低 | 把 shared/ 當 git repo，push/pull |
| **自建 RPC** | 即時 | 高 | Orbital 自己跑 server，另一台連過來 |
| **Dropbox/iCloud** | 自動 | 零 | 把 shared/ symlink 到雲端同步目錄 |

## 建議實作順序

### Phase 1: `orbital sync`（rsync wrapper）

```bash
# 設定遠端
orbital sync set-remote user@host

# 推送到遠端
orbital sync push

# 從遠端拉取
orbital sync pull
```

底層：
```bash
rsync -avz ~/.orbital/shared/ user@host:~/.orbital/shared/
rsync -avz user@host:~/.orbital/shared/ ~/.orbital/shared/
```

### Phase 2: 即時 RPC（未來）

- Orbital 在一台電腦跑 `orbital sync serve`
- 另一台連上 `orbital sync connect host:port`
- 用 WebSocket 或 gRPC 即時同步 shared/ 的變更

### 替代方案：雲端同步

最簡單的做法 — 使用者已有 Dropbox/iCloud：

```bash
# 把 shared/ 移到 Dropbox
mv ~/.orbital/shared ~/Dropbox/orbital-shared
ln -s ~/Dropbox/orbital-shared ~/.orbital/shared

# 另一台電腦做同樣的事
ln -s ~/Dropbox/orbital-shared ~/.orbital/shared
```

可以做成 `orbital sync link ~/Dropbox/orbital-shared` 來簡化。

## 注意事項

- Session 檔案是 JSONL，同時寫入可能衝突
- Memory 檔案較小，衝突風險低
- rsync 只做單向同步，不會有衝突
- 雲端同步可能有延遲，但通常夠用
