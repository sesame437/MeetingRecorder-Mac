# Release Notes Template

Release title:

```text
MeetingRecorder vYYYY.M.D — Topic A + Topic B
```

## 概述

本版本主要新增/修复/移除：...

如果本版本移除功能，说明为什么移除，以及用户后续应该使用哪个替代路径或历史版本。

---

## 一、主要变更

### 功能/范围调整

- ...

### 保留或兼容行为

- ...

---

## 二、体验与配置

- ...

---

## 三、稳定性与修复

- ...

---

## 四、内部质量与打包

- ...

---

## 安装

1. 下载下方 `MeetingRecorder.dmg`
2. 挂载镜像，将 `MeetingRecorder.app` 拖入 `/Applications`
3. 首次启动时按提示授予 **Screen Recording** 和 **Microphone** 权限

系统要求：macOS 15+，Apple Silicon (arm64)

---

## 已知限制

- ...

## Release Checklist

- Tag uses `vYYYY.M.D`.
- `Info.plist` has `CFBundleShortVersionString` and `CFBundleVersion` set to `YYYY.M.D`.
- `MeetingRecorder.dmg` is attached to the GitHub release.
- Notes include install steps and known limitations.
- Removed features include migration guidance or historical-version guidance.
