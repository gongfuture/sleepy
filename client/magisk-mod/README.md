# 配置

> [!TIP]
> by [kmizmal](https://github.com/kmizmal) <br/>
> 由 wyf9 小修本文的格式

配置文件在 `config.cfg`

`URL` 和 `SECRET` 填入你自己的网址和密钥 ***(必填)***

`DEVICE_NAME` 填入你自己的设备名称，不填会使用 `getprop ro.product.model` 获取到的型号数据

`DEVICE_ID` 填入设备 ID，注意多设备不能用同一个 ID

`GAME_PACKAGES` 里可以填游戏包名（空格分隔，双引号包裹），延长玩游戏时的请求间隔 *选填*

> 默认 **非游戏** `30s` 检查一次，*玩游戏*时 `600s`（10 分钟）检查一次

有特殊需求的自己去 `service.sh` 里的 `is_game()` 找 **30** 和 **600** 改

## 媒体状态

将 `MEDIA` 设为 `true` 并配置 `MEDIA_DEVICE_ID` / `MEDIA_DEVICE_SHOW_NAME` 后，脚本会以**独立 `using` 状态**单独上报媒体播放信息：

- 正在播放时：`using=true`，`app_name` 为 `♪歌名 - 歌手`
- 未播放时：`using=false`，`app_name` 为 `未在播放`
- 媒体状态变化（切歌、暂停等）会**立即**触发上报，不依赖前台应用变化

# 应用名称解析

应用名称解析**不再依赖应用商店**，解析优先级如下：

1. **缓存**（`cache.txt`）— 手动录入或之前自动解析的结果，最可靠
2. **`dumpsys package`** — 尝试从系统服务获取应用标签（部分 ROM 支持）
3. **包名** — 兜底方案

可在 `cache.txt` 中手动录入应用名称，格式为 `包名=显示名称`，每行一条，例如：

```
com.tencent.mm=微信
tv.danmaku.bili=哔哩哔哩
```

# 一些说明

锁屏时间持续超过约 30 分钟（60 次 × 30 秒等待，`NotificationShade` 不是游戏包名，始终走 30 秒分支）后上报 `using=false`（实际因系统休眠可能需要更长时间），可在 `service.sh` 的主循环中修改 **60** 这个阈值

设备状态和媒体状态使用**独立的 `using` 字段**，互不影响

*日志写在 `monitor.log`，可在出问题时检查*

> [!NOTE]
> **`monitor.log` 每次重启都会清空**
